import SwiftUI
import PhotosUI

// MARK: - Nutrition data contracts

public struct FitnessMacroValue: Identifiable {
    public let id: String
    public let name: String
    public let value: Double?
    public let target: Double?
    public let unit: String
    public let hue: LifeOSTokens.Hue

    public init(name: String, value: Double?, target: Double?, unit: String = "g", hue: LifeOSTokens.Hue) {
        self.id = name
        self.name = name
        self.value = value
        self.target = target
        self.unit = unit
        self.hue = hue
    }
}

public struct FitnessMeal: Identifiable {
    public enum Source: String { case manual = "Manual", package = "Package label", recipe = "Recipe", photoConfirmed = "Photo-confirmed", proposal = "Photo proposal" }

    public let id: String
    public let name: String
    public let time: Date
    public let calories: Int?
    public let protein: Double?
    public let carbohydrates: Double?
    public let fat: Double?
    public let detail: String
    public let source: Source
    public let confidence: String?

    public init(id: String, name: String, time: Date, calories: Int?, protein: Double?, carbohydrates: Double?, fat: Double?, detail: String, source: Source, confidence: String? = nil) {
        self.id = id
        self.name = name
        self.time = time
        self.calories = calories
        self.protein = protein
        self.carbohydrates = carbohydrates
        self.fat = fat
        self.detail = detail
        self.source = source
        self.confidence = confidence
    }
}

/// A user-recorded food-quality input. LifeOS intentionally does not reproduce
/// Bevel's private quality formula; a contribution is shown only when a reviewed
/// source has supplied one explicitly.
public struct FitnessNutritionQualityContribution: Identifiable {
    public let id: String
    public let title: String
    public let value: Double?
    public let detail: String
    public let hue: LifeOSTokens.Hue

    public init(id: String? = nil, title: String, value: Double?, detail: String, hue: LifeOSTokens.Hue) {
        self.id = id ?? title
        self.title = title
        self.value = value
        self.detail = detail
        self.hue = hue
    }
}

public struct FitnessNutritionSnapshot {
    public let calorieTarget: Int?
    public let caloriesConsumed: Int?
    public let sourceSupportedExpenditure: Int?
    public let macroValues: [FitnessMacroValue]
    public let meals: [FitnessMeal]
    public let hydrationMilliliters: Int?
    public let hydrationTargetMilliliters: Int?
    public let caffeineMilligrams: Int?
    /// Legacy field name retained for snapshot compatibility. Values are
    /// canonical standard drinks; an Apple Health beverage count remains
    /// unavailable unless the importer receives explicit standard-drink
    /// semantics from its source.
    public let alcoholUnits: Double?
    public let qualityScore: Int?
    public let qualityDetail: String?
    public let qualityContributions: [FitnessNutritionQualityContribution]

    public init(
        calorieTarget: Int?,
        caloriesConsumed: Int?,
        sourceSupportedExpenditure: Int?,
        macroValues: [FitnessMacroValue],
        meals: [FitnessMeal],
        hydrationMilliliters: Int?,
        hydrationTargetMilliliters: Int?,
        caffeineMilligrams: Int?,
        alcoholUnits: Double?,
        qualityScore: Int? = nil,
        qualityDetail: String? = nil,
        qualityContributions: [FitnessNutritionQualityContribution] = []
    ) {
        self.calorieTarget = calorieTarget
        self.caloriesConsumed = caloriesConsumed
        self.sourceSupportedExpenditure = sourceSupportedExpenditure
        self.macroValues = macroValues
        self.meals = meals
        self.hydrationMilliliters = hydrationMilliliters
        self.hydrationTargetMilliliters = hydrationTargetMilliliters
        self.caffeineMilligrams = caffeineMilligrams
        self.alcoholUnits = alcoholUnits
        self.qualityScore = qualityScore
        self.qualityDetail = qualityDetail
        self.qualityContributions = qualityContributions
    }

    /// Adds only confirmed, local barcode records for the selected calendar
    /// day.  The caller decides whether the surrounding snapshot is a demo;
    /// production UI uses this method while demo fixtures deliberately keep
    /// their immutable fixture values unchanged.
    public func includingLocalBarcodeRecords(_ records: [NutritionRecord], for selectedDate: Date, calendar: Calendar = .current) -> FitnessNutritionSnapshot {
        let dayRecords = records
            .filter { record in
                guard let mealDate = record.mealDate else { return false }
                return calendar.isDate(mealDate, inSameDayAs: selectedDate)
            }
            .sorted { ($0.mealDate ?? .distantPast) < ($1.mealDate ?? .distantPast) }

        guard !dayRecords.isEmpty else { return self }

        let explicitCalories = dayRecords.compactMap(\.kcal)
        let addedCalories = explicitCalories.reduce(0, +)
        let addedProtein = dayRecords.compactMap(\.proteinGrams).reduce(0, +)
        let addedCarbs = dayRecords.compactMap(\.carbsGrams).reduce(0, +)
        let addedFat = dayRecords.compactMap(\.fatGrams).reduce(0, +)
        let mergedMacros = macroValues.map { macro in
            let macroKey = macro.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let addition: Double?
            switch macroKey {
            case "protein": addition = dayRecords.contains { $0.proteinGrams != nil } ? addedProtein : nil
            case "carbs", "carbohydrates": addition = dayRecords.contains { $0.carbsGrams != nil } ? addedCarbs : nil
            case "fat": addition = dayRecords.contains { $0.fatGrams != nil } ? addedFat : nil
            default: addition = nil
            }
            guard let addition else { return macro }
            return FitnessMacroValue(
                name: macro.name,
                value: (macro.value ?? 0) + addition,
                target: macro.target,
                unit: macro.unit,
                hue: macro.hue
            )
        }
        let barcodeMeals = dayRecords.compactMap { record -> FitnessMeal? in
            guard let time = record.mealDate else { return nil }
            let calories = record.kcal.map { Int($0.rounded()) }
            let name = record.productName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return FitnessMeal(
                id: "barcode-\(record.id.uuidString)",
                name: name?.isEmpty == false ? name! : "Packaged food · \(record.barcode)",
                time: time,
                calories: calories,
                protein: record.proteinGrams,
                carbohydrates: record.carbsGrams,
                fat: record.fatGrams,
                detail: "Open Food Facts · confirmed locally · sync pending",
                source: .package,
                confidence: "Provider data · review source"
            )
        }
        let mergedCalories: Int?
        if explicitCalories.isEmpty {
            // Macro-only confirmations must not collapse an unknown calorie
            // total into zero. An explicit kcal value of 0 remains a real
            // observed value because it is present in explicitCalories.
            mergedCalories = caloriesConsumed
        } else if let caloriesConsumed {
            mergedCalories = caloriesConsumed + Int(addedCalories.rounded())
        } else {
            mergedCalories = Int(addedCalories.rounded())
        }

        return FitnessNutritionSnapshot(
            calorieTarget: calorieTarget,
            caloriesConsumed: mergedCalories,
            sourceSupportedExpenditure: sourceSupportedExpenditure,
            macroValues: mergedMacros,
            meals: meals + barcodeMeals,
            hydrationMilliliters: hydrationMilliliters,
            hydrationTargetMilliliters: hydrationTargetMilliliters,
            caffeineMilligrams: caffeineMilligrams,
            alcoholUnits: alcoholUnits,
            qualityScore: qualityScore,
            qualityDetail: qualityDetail,
            qualityContributions: qualityContributions
        )
    }

    /// Adds only confirmed, local `NutritionMealStore` records for the
    /// selected calendar day. Mirrors `includingLocalBarcodeRecords`: the
    /// caller decides whether the surrounding snapshot is a demo; production
    /// UI uses this method while demo fixtures keep their immutable fixture
    /// values unchanged. Soft-deleted meals are never passed in by the
    /// caller (the store already excludes them via `meals(on:)`).
    public func includingLocalMeals(_ localMeals: [NutritionMeal], for selectedDate: Date, calendar: Calendar = .current) -> FitnessNutritionSnapshot {
        let dayMeals = localMeals
            .filter { !$0.isDeleted && calendar.isDate($0.loggedAt, inSameDayAs: selectedDate) }
            .sorted { $0.loggedAt < $1.loggedAt }

        guard !dayMeals.isEmpty else { return self }

        let explicitCalories = dayMeals.compactMap(\.kcal)
        let addedCalories = explicitCalories.reduce(0, +)
        let addedProtein = dayMeals.compactMap(\.proteinGrams).reduce(0, +)
        let addedCarbs = dayMeals.compactMap(\.carbGrams).reduce(0, +)
        let addedFat = dayMeals.compactMap(\.fatGrams).reduce(0, +)
        let mergedMacros = macroValues.map { macro -> FitnessMacroValue in
            let macroKey = macro.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let addition: Double?
            switch macroKey {
            case "protein": addition = dayMeals.contains { $0.proteinGrams != nil } ? Double(addedProtein) : nil
            case "carbs", "carbohydrates": addition = dayMeals.contains { $0.carbGrams != nil } ? Double(addedCarbs) : nil
            case "fat": addition = dayMeals.contains { $0.fatGrams != nil } ? Double(addedFat) : nil
            default: addition = nil
            }
            guard let addition else { return macro }
            return FitnessMacroValue(
                name: macro.name,
                value: (macro.value ?? 0) + addition,
                target: macro.target,
                unit: macro.unit,
                hue: macro.hue
            )
        }
        let localFitnessMeals = dayMeals.map { local -> FitnessMeal in
            let source: FitnessMeal.Source
            switch local.provenance {
            case .manual: source = .manual
            case .confirmedFromPhoto: source = .photoConfirmed
            case .confirmedFromBarcode: source = .package
            }
            return FitnessMeal(
                id: "meal-\(local.id.uuidString)",
                name: local.name,
                time: local.loggedAt,
                calories: local.kcal,
                protein: local.proteinGrams.map(Double.init),
                carbohydrates: local.carbGrams.map(Double.init),
                fat: local.fatGrams.map(Double.init),
                detail: "Confirmed locally · sync pending",
                source: source
            )
        }
        let mergedCalories: Int?
        if explicitCalories.isEmpty {
            mergedCalories = caloriesConsumed
        } else if let caloriesConsumed {
            mergedCalories = caloriesConsumed + addedCalories
        } else {
            mergedCalories = addedCalories
        }

        return FitnessNutritionSnapshot(
            calorieTarget: calorieTarget,
            caloriesConsumed: mergedCalories,
            sourceSupportedExpenditure: sourceSupportedExpenditure,
            macroValues: mergedMacros,
            meals: meals + localFitnessMeals,
            hydrationMilliliters: hydrationMilliliters,
            hydrationTargetMilliliters: hydrationTargetMilliliters,
            caffeineMilligrams: caffeineMilligrams,
            alcoholUnits: alcoholUnits,
            qualityScore: qualityScore,
            qualityDetail: qualityDetail,
            qualityContributions: qualityContributions
        )
    }

    public static let unavailable = FitnessNutritionSnapshot(
        calorieTarget: nil,
        caloriesConsumed: nil,
        sourceSupportedExpenditure: nil,
        macroValues: [
            FitnessMacroValue(name: "Protein", value: nil, target: nil, hue: .blue),
            FitnessMacroValue(name: "Carbs", value: nil, target: nil, hue: .orange),
            FitnessMacroValue(name: "Fat", value: nil, target: nil, hue: .pink)
        ],
        meals: [],
        hydrationMilliliters: nil,
        hydrationTargetMilliliters: nil,
        caffeineMilligrams: nil,
        alcoholUnits: nil
    )

    public static let demo: FitnessNutritionSnapshot = {
        let now = Date.now
        return FitnessNutritionSnapshot(
            calorieTarget: 2_200,
            caloriesConsumed: 1_860,
            sourceSupportedExpenditure: 2_340,
            macroValues: [
                FitnessMacroValue(name: "Protein", value: 138, target: 160, hue: .blue),
                FitnessMacroValue(name: "Carbs", value: 194, target: 250, hue: .orange),
                FitnessMacroValue(name: "Fat", value: 61, target: 75, hue: .pink)
            ],
            meals: [
                FitnessMeal(id: "demo-breakfast", name: "Greek yogurt + berries", time: now.addingTimeInterval(-28_800), calories: 420, protein: 31, carbohydrates: 44, fat: 12, detail: "Confirmed manual entry", source: .manual),
                FitnessMeal(id: "demo-lunch", name: "Rice bowl", time: now.addingTimeInterval(-21_600), calories: 680, protein: 42, carbohydrates: 76, fat: 19, detail: "User edited package/recipe record", source: .recipe),
                FitnessMeal(id: "demo-photo", name: "Photo proposal · needs review", time: now.addingTimeInterval(-12_600), calories: 760, protein: 51, carbohydrates: 74, fat: 30, detail: "Proposal only · hidden oil / portion unknown", source: .proposal, confidence: "Medium · ±20% not established")
            ],
            hydrationMilliliters: 1_250,
            hydrationTargetMilliliters: 2_000,
            caffeineMilligrams: 120,
            alcoholUnits: 0,
            qualityScore: 72,
            qualityDetail: "User-recorded contribution inputs · demo fixture; no proprietary formula",
            qualityContributions: [
                FitnessNutritionQualityContribution(title: "Vegetables", value: 0.72, detail: "User-recorded input", hue: .green),
                FitnessNutritionQualityContribution(title: "Wholegrain", value: 0.40, detail: "User-recorded input", hue: .amber),
                FitnessNutritionQualityContribution(title: "Healthy oils", value: 0.55, detail: "User-recorded input", hue: .orange),
                FitnessNutritionQualityContribution(title: "Fruit", value: 0.68, detail: "User-recorded input", hue: .pink),
                FitnessNutritionQualityContribution(title: "Nuts / legumes", value: 0.34, detail: "User-recorded input", hue: .violet),
                FitnessNutritionQualityContribution(title: "Omega-3", value: 0.25, detail: "User-recorded input", hue: .teal)
            ]
        )
    }()
}

// MARK: - Nutrition screen

public enum FitnessNutritionCaptureAction: String, Equatable, Sendable {
    case photoLibrary
    case camera
    case barcode
    case aiProposal
    case search
}

public enum FitnessNutritionEntryPoint: Equatable, Sendable {
    case overview
    case goals
    case netEnergy
    case capture(FitnessNutritionCaptureAction)
}

private extension FitnessNutritionCaptureAction {
    var title: String {
        switch self {
        case .photoLibrary: return "Photo library import"
        case .camera: return "Camera capture proposal"
        case .barcode: return "Barcode lookup proposal"
        case .aiProposal: return "AI photo proposal"
        case .search: return "Food search proposal"
        }
    }

    var detail: String {
        switch self {
        case .photoLibrary:
            return "The app-side review flow is open. Photos remain local until an explicit future send; nothing is uploaded implicitly."
        case .camera:
            return "Camera capture is not connected in this build. This is an honest proposal state; no camera or upload was started."
        case .barcode:
#if os(iOS)
            return "Scan an EAN-8, EAN-13, or UPC-A with the permission-gated camera, or enter it manually for a read-only Germany-capable lookup."
#else
            return "Enter an EAN-8, EAN-13, or UPC-A manually for a read-only Germany-capable lookup. Camera scanning is available only on iPhone."
#endif
        case .aiProposal:
            return "Server-side Google/Gemini analysis is not connected. The proposal remains unconfirmed and no image was sent."
        case .search:
            return "Food search is not connected in this build. No database result or calorie value was invented."
        }
    }
}

struct FitnessNutritionView: View {
    let snapshot: FitnessSnapshot
    let selectedDate: Date
    let initialEntryPoint: FitnessNutritionEntryPoint?
    @State private var showingCapture = false
    @State private var captureMethod: FitnessFoodCaptureMethod = .manual
    @State private var captureAction: FitnessNutritionCaptureAction?
    @State private var photoStage: FitnessPhotoStage = .idle
    @State private var showingGoals = false
    @State private var showingNetEnergy = false
    @State private var handledEntryPoint = false
    @State private var localBarcodeRecords: [NutritionRecord] = []
    @State private var barcodePersistenceError: String?
    @State private var localMeals: [NutritionMeal] = []
    @State private var mealPersistenceError: String?
    @State private var editingMeal: NutritionMeal?
    @State private var mealPendingDeletion: NutritionMeal?
    private let nutritionRecordStore = NutritionRecordStore(url: NutritionRecordStore.defaultPersistenceURL)
    private let nutritionMealStore: NutritionMealStore?

    init(
        snapshot: FitnessSnapshot,
        selectedDate: Date,
        initialEntryPoint: FitnessNutritionEntryPoint? = nil
    ) {
        self.snapshot = snapshot
        self.selectedDate = selectedDate
        self.initialEntryPoint = initialEntryPoint
        self.nutritionMealStore = try? NutritionMealStore(url: NutritionMealStore.defaultURL())
        _captureAction = State(initialValue: nil)
    }

    var body: some View {
        FitnessNutritionSurface(
            nutrition: effectiveNutrition,
            selectedDate: selectedDate,
            sourceStatus: snapshot.source.status,
            photoStage: $photoStage,
            localBarcodeRecordCount: effectiveBarcodeRecords.count,
            barcodePersistenceError: barcodePersistenceError,
            mealPersistenceError: mealPersistenceError,
            onCapture: { method in
                captureMethod = method
                captureAction = nil
                editingMeal = nil
                photoStage = method == .photo ? .idle : .manualEntry
                showingCapture = true
            },
            onEditMeal: { fitnessMeal in
                guard let match = localMeal(for: fitnessMeal) else { return }
                editingMeal = match
                captureMethod = .manual
                captureAction = nil
                photoStage = .manualEntry
                showingCapture = true
            },
            onDeleteMeal: { fitnessMeal in
                guard let match = localMeal(for: fitnessMeal) else { return }
                mealPendingDeletion = match
            }
        )
        .sheet(isPresented: $showingCapture) {
            FitnessFoodReviewSheet(
                method: captureMethod,
                action: captureAction,
                stage: $photoStage,
                isDemo: snapshot.source.status == .demo,
                nutritionRecordStore: nutritionRecordStore,
                nutritionMealStore: nutritionMealStore,
                editingMeal: editingMeal,
                onBarcodeSaved: reloadBarcodeRecords,
                onMealSaved: reloadMeals
            )
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: $showingGoals) {
            NutritionGoalsView(nutrition: effectiveNutrition, selectedDate: selectedDate, isDemo: snapshot.source.status == .demo)
        }
        .navigationDestination(isPresented: $showingNetEnergy) {
            NutritionNetEnergyView(nutrition: effectiveNutrition)
        }
        .alert(
            "Delete this meal?",
            isPresented: Binding(
                get: { mealPendingDeletion != nil },
                set: { if !$0 { mealPendingDeletion = nil } }
            ),
            presenting: mealPendingDeletion
        ) { meal in
            Button("Delete", role: .destructive) { deleteMeal(meal) }
            Button("Cancel", role: .cancel) { mealPendingDeletion = nil }
        } message: { meal in
            Text("\(meal.name) will be removed from the meal timeline and daily totals.")
        }
        .onAppear { handleInitialEntryPointIfNeeded() }
        .task { await loadBarcodeRecords() }
        .task { await loadMeals() }
        .onChange(of: selectedDate) { _, _ in
            Task { await loadBarcodeRecords() }
            Task { await loadMeals() }
        }
        .onChange(of: initialEntryPoint) { _, _ in
            handledEntryPoint = false
            handleInitialEntryPointIfNeeded()
        }
    }

    private func handleInitialEntryPointIfNeeded() {
        guard !handledEntryPoint, let initialEntryPoint else { return }
        handledEntryPoint = true
        switch initialEntryPoint {
        case .overview:
            break
        case .goals:
            showingGoals = true
        case .netEnergy:
            showingNetEnergy = true
        case .capture(let action):
            captureAction = action
            captureMethod = method(for: action)
            editingMeal = nil
            photoStage = captureMethod == .photo ? .idle : .manualEntry
            showingCapture = true
        }
    }

    private func method(for action: FitnessNutritionCaptureAction) -> FitnessFoodCaptureMethod {
        switch action {
        case .photoLibrary, .camera, .aiProposal: return .photo
        case .barcode: return .barcode
        case .search: return .recent
        }
    }

    private var effectiveBarcodeRecords: [NutritionRecord] {
        guard snapshot.source.status != .demo else { return [] }
        return localBarcodeRecords.filter { record in
            guard let mealDate = record.mealDate else { return false }
            return Calendar.current.isDate(mealDate, inSameDayAs: selectedDate)
        }
    }

    private var effectiveNutrition: FitnessNutritionSnapshot {
        guard snapshot.source.status != .demo else { return snapshot.nutrition }
        return snapshot.nutrition
            .includingLocalBarcodeRecords(localBarcodeRecords, for: selectedDate)
            .includingLocalMeals(localMeals, for: selectedDate)
    }

    /// Resolves a displayed `FitnessMeal` row back to the durable
    /// `NutritionMeal` it was built from. Only meals produced by
    /// `includingLocalMeals` carry the `meal-` id prefix; barcode and demo
    /// rows never match and correctly fall through to `nil`.
    private func localMeal(for fitnessMeal: FitnessMeal) -> NutritionMeal? {
        guard fitnessMeal.id.hasPrefix("meal-"),
              let uuid = UUID(uuidString: String(fitnessMeal.id.dropFirst("meal-".count))) else { return nil }
        return localMeals.first { $0.id == uuid && !$0.isDeleted }
    }

    private func deleteMeal(_ meal: NutritionMeal) {
        mealPendingDeletion = nil
        guard let nutritionMealStore else {
            mealPersistenceError = "Local meal storage is unavailable. Nothing was deleted."
            return
        }
        do {
            try nutritionMealStore.softDelete(id: meal.id)
            reloadMeals()
        } catch {
            mealPersistenceError = "The meal could not be deleted locally. Nothing was changed."
        }
    }

    private func reloadBarcodeRecords() {
        Task { await loadBarcodeRecords() }
    }

    private func reloadMeals() {
        Task { await loadMeals() }
    }

    private func loadBarcodeRecords() async {
        guard snapshot.source.status != .demo else { return }
        do {
            let loaded = try await nutritionRecordStore.load()
            await MainActor.run {
                localBarcodeRecords = loaded
                barcodePersistenceError = nil
            }
        } catch {
            await MainActor.run {
                localBarcodeRecords = []
                barcodePersistenceError = "Local barcode food log could not be read. No totals were added."
            }
        }
    }

    private func loadMeals() async {
        guard snapshot.source.status != .demo else { return }
        guard let nutritionMealStore else {
            await MainActor.run {
                localMeals = []
                mealPersistenceError = "Local meal storage is unavailable. No manual meal totals were added."
            }
            return
        }
        do {
            let loaded = try nutritionMealStore.load()
            await MainActor.run {
                localMeals = loaded
                mealPersistenceError = nil
            }
        } catch {
            await MainActor.run {
                localMeals = []
                mealPersistenceError = "Local meal log could not be read. No manual meal totals were added."
            }
        }
    }
}

// MARK: - Bevel nutrition composition

/// The Nutrition section is intentionally a reading-order surface rather than
/// an equal-weight bento. The first screen answers: how much was eaten, what is
/// left, what was burned, and which records need attention. Detail routes keep
/// the feature set discoverable without adding another root tab.
private struct FitnessNutritionSurface: View {
    let nutrition: FitnessNutritionSnapshot
    let selectedDate: Date
    let sourceStatus: FitnessSourceState.Status
    @Binding var photoStage: FitnessPhotoStage
    let localBarcodeRecordCount: Int
    let barcodePersistenceError: String?
    let mealPersistenceError: String?
    let onCapture: (FitnessFoodCaptureMethod) -> Void
    let onEditMeal: (FitnessMeal) -> Void
    let onDeleteMeal: (FitnessMeal) -> Void
    @State private var macroDisplay: NutritionMacroDisplay = .grams

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            nutritionHeader
            if localBarcodeRecordCount > 0 {
                Label("\(localBarcodeRecordCount) barcode meal\(localBarcodeRecordCount == 1 ? "" : "s") · saved locally · sync pending", systemImage: "externaldrive.badge.checkmark")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-local-status")
            }
            if let barcodePersistenceError {
                Text(barcodePersistenceError)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-persistence-error")
            }
            if let mealPersistenceError {
                Text(mealPersistenceError)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-meal-persistence-error")
            }
            FitnessNutritionHeroCard(nutrition: nutrition, isDemo: sourceStatus == .demo, selectedDate: selectedDate)
            FitnessNutritionSummaryRail(nutrition: nutrition)
            FitnessNutritionMacroCard(macros: nutrition.macroValues, display: $macroDisplay)
            FitnessNutritionNetEnergyCard(nutrition: nutrition)
            FitnessNutritionQualityCard(
                contributions: nutrition.qualityContributions,
                score: nutrition.qualityScore,
                detail: nutrition.qualityDetail
            )
            FitnessFoodCaptureCard(
                isDemo: sourceStatus == .demo,
                photoStage: photoStage,
                onCapture: onCapture
            )
            FitnessNutritionMealTimelineCard(
                meals: nutrition.meals,
                onAdd: { onCapture(.manual) },
                onEdit: onEditMeal,
                onDelete: onDeleteMeal,
                onReview: { _ in photoStage = .needsConfirmation }
            )
            FitnessNutritionTrendsCard(nutrition: nutrition)
            FitnessHydrationLifestyleCard(
                nutrition: nutrition,
                selectedDate: selectedDate,
                isFixture: sourceStatus == .demo
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("fitness-nutrition-surface")
    }

    private var nutritionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nutrition")
                    .font(LifeOSFont.headerLarge(25))
                Text("Meals, macros, quality, and energy for \(selectedDate.fitnessDayLabel)")
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(sourceStatus == .demo ? "Fixture values" : sourceStatus.label)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .accessibilityLabel("Nutrition data status")
                .accessibilityValue(sourceStatus == .demo ? "Demo, not live" : sourceStatus.label)
        }
    }
}

private struct FitnessNutritionHeroCard: View {
    let nutrition: FitnessNutritionSnapshot
    let isDemo: Bool
    let selectedDate: Date

    var body: some View {
        NutritionSurfaceCard(accent: .green) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Today")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(nutrition.caloriesConsumed.map(String.init) ?? "—")
                            .font(LifeOSFont.spaceGrotesk(36, weight: .bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .allowsTightening(true)
                            .layoutPriority(2)
                        Text("kcal eaten")
                            .font(LifeOSFont.caption(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Text(protocolCaloriesLabel)
                        .font(LifeOSFont.inter(12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isDemo ? "Fixture values · not live" : provenanceLabel)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                NutritionQualityGauge(score: nutrition.qualityScore, detail: nutrition.qualityDetail)
            }
            HStack(spacing: 8) {
                NavigationLink(destination: NutritionFoodLibraryView(meals: nutrition.meals)) {
                    NutritionActionLabel(title: "Food library", icon: .grocery)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens food library")
                NavigationLink(destination: NutritionGoalsView(nutrition: nutrition, selectedDate: selectedDate, isDemo: isDemo)) {
                    NutritionActionLabel(title: "Goals", icon: .budget)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens calorie and macro goals")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-nutrition-hero")
    }

    private var protocolCaloriesLabel: String {
        guard let target = nutrition.calorieTarget else { return "Protocol calories · unavailable" }
        return "Protocol calories · \(target.formatted()) kcal target"
    }

    private var provenanceLabel: String {
        if nutrition.caloriesConsumed == nil { return "Food log unavailable · no confirmed observation" }
        return "Food log · confirmed/manual records only"
    }
}

private struct NutritionQualityGauge: View {
    let score: Int?
    let detail: String?

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(LifeOSTokens.quietBorder.opacity(0.75), lineWidth: 9)
                if let score {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                        .stroke(
                            AngularGradient(colors: [LifeOSTokens.success, LifeOSTokens.accent], center: .center),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(score)")
                            .font(LifeOSFont.spaceGrotesk(24, weight: .bold))
                            .monospacedDigit()
                        Text("quality")
                            .font(LifeOSFont.caption(9))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                } else {
                    LifeOSIcon(.security)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 82, height: 82)
            Text(score == nil ? "Quality unavailable" : "Quality")
                .font(LifeOSFont.inter(11, weight: .semiBold))
            Text(score == nil ? "Needs recorded inputs" : (detail ?? "Recorded inputs"))
                .font(LifeOSFont.caption(9))
                .foregroundStyle(score == nil ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 150)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Food quality")
        .accessibilityValue(score.map { "\($0) out of 100" } ?? "Unavailable; recorded quality inputs are required")
    }
}

private struct NutritionActionLabel: View {
    let title: String
    let icon: LifeOSIconName

    var body: some View {
        HStack(spacing: 6) {
            LifeOSIcon(icon).frame(width: 14, height: 14)
            Text(title).font(LifeOSFont.inter(11, weight: .semiBold))
            LifeOSIcon(.chevronRight).frame(width: 10, height: 10)
        }
        .foregroundStyle(LifeOSTokens.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(LifeOSTokens.accent.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(LifeOSTokens.accent.opacity(0.18), lineWidth: 0.75))
    }
}

private struct FitnessNutritionSummaryRail: View {
    let nutrition: FitnessNutritionSnapshot

    var body: some View {
        HStack(spacing: 8) {
            NutritionSummaryValue(title: "Protocol", value: nutrition.calorieTarget.map { "\($0)" } ?? "—", detail: "kcal goal", hue: .blue)
            NutritionSummaryValue(title: "Remaining", value: remainingValue, detail: "kcal", hue: .green)
            NutritionSummaryValue(title: "Burned", value: nutrition.sourceSupportedExpenditure.map(String.init) ?? "—", detail: "source kcal", hue: .orange)
        }
    }

    private var remainingValue: String {
        guard let target = nutrition.calorieTarget, let eaten = nutrition.caloriesConsumed else { return "—" }
        return "\(target - eaten)"
    }
}

private struct NutritionSummaryValue: View {
    let title: String
    let value: String
    let detail: String
    let hue: LifeOSTokens.Hue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(LifeOSTokens.tertiaryText).frame(width: 6, height: 6)
                Text(title).font(LifeOSFont.caption(9)).foregroundStyle(LifeOSTokens.tertiaryText).lineLimit(1)
            }
            Text(value).font(LifeOSFont.inter(13, weight: .semiBold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(LifeOSFont.caption(8)).foregroundStyle(LifeOSTokens.tertiaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .glassCard()
    }
}

private enum NutritionMacroDisplay: String, CaseIterable, Identifiable {
    case grams = "Grams"
    case percent = "%"
    var id: String { rawValue }
}

private struct FitnessNutritionMacroCard: View {
    let macros: [FitnessMacroValue]
    @Binding var display: NutritionMacroDisplay

    var body: some View {
        NutritionSurfaceCard(accent: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Calories & macros")
                            .font(LifeOSFont.header(16))
                        Text("Goals are user preferences; missing inputs stay unavailable")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    NutritionMacroDisplayToggle(display: $display)
                    .frame(width: 140)
                    .accessibilityIdentifier("nutrition-macro-display")
                }
                NutritionAdaptiveGrid {
                    ForEach(orderedMacros) { macro in
                        NutritionMacroDotRow(macro: macro, display: display)
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-nutrition-macros")
    }

    private var orderedMacros: [FitnessMacroValue] {
        let order = ["Fat", "Carbs", "Carbohydrates", "Protein"]
        return macros.sorted { lhs, rhs in
            (order.firstIndex(of: lhs.name) ?? order.count) < (order.firstIndex(of: rhs.name) ?? order.count)
        }
    }
}

private struct NutritionMacroDisplayToggle: View {
    @Binding var display: NutritionMacroDisplay

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NutritionMacroDisplay.allCases) { item in
                Button {
                    display = item
                } label: {
                    Text(item.rawValue)
                        .font(LifeOSFont.inter(11, weight: .semiBold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(display == item ? Color.primary : LifeOSTokens.tertiaryText)
                        .background(display == item ? LifeOSTokens.surface : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item == .grams ? "Show grams" : "Show percentage")
                .accessibilityAddTraits(display == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(LifeOSTokens.quietBorder.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Macro display")
        .accessibilityValue(display == .grams ? "Grams" : "Percentage")
    }
}


/// §5.5: macro colors are data semantics keyed by name — protein accent,
/// carbs success, fat warning. The legacy per-metric hue ramp is not used.
private func nutritionMacroColor(name: String) -> Color {
    switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "protein": LifeOSTokens.accent
    case "carbs", "carbohydrates": LifeOSTokens.success
    case "fat": LifeOSTokens.warning
    default: LifeOSTokens.secondaryText
    }
}

private struct NutritionMacroDotRow: View {
    let macro: FitnessMacroValue
    let display: NutritionMacroDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(macro.name).font(LifeOSFont.inter(12, weight: .semiBold))
                Spacer(minLength: 6)
                Text(displayValue).font(LifeOSFont.inter(12, weight: .semiBold)).monospacedDigit()
                if let target = macro.target {
                    Text("/ \(target.formatted(.number.precision(.fractionLength(0)))) g")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? nutritionMacroColor(name: macro.name) : LifeOSTokens.quietBorder.opacity(0.75))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(macro.name) progress")
            .accessibilityValue(displayValue)
        }
        .padding(10)
        .background(LifeOSTokens.screenCanvas.opacity(0.32), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }

    private var ratio: Double? {
        guard let value = macro.value, let target = macro.target, target > 0 else { return nil }
        return min(max(value / target, 0), 1)
    }

    private var filledDots: Int { Int(((ratio ?? 0) * 10).rounded(.down)) }

    private var displayValue: String {
        guard let value = macro.value else { return "Unavailable" }
        switch display {
        case .grams: return "\(value.formatted(.number.precision(.fractionLength(0)))) g"
        case .percent:
            guard let ratio else { return "Unavailable" }
            return "\((ratio * 100).formatted(.number.precision(.fractionLength(0))))%"
        }
    }
}

private struct FitnessNutritionNetEnergyCard: View {
    let nutrition: FitnessNutritionSnapshot

    var body: some View {
        NavigationLink(destination: NutritionNetEnergyView(nutrition: nutrition)) {
            NutritionSurfaceCard(accent: .orange) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Net energy")
                                .font(LifeOSFont.header(16))
                            Text("Eaten minus burned · a calculation, not a direct measurement")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        LifeOSIcon(.chevronRight).frame(width: 13, height: 13)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(balanceLabel)
                            .font(LifeOSFont.spaceGrotesk(27, weight: .bold))
                            .monospacedDigit()
                        Text("kcal balance")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    NutritionEnergyScale(eaten: nutrition.caloriesConsumed, burned: nutrition.sourceSupportedExpenditure)
                    HStack(spacing: 14) {
                        NutritionEnergyFact(title: "Eaten", value: nutrition.caloriesConsumed, hue: .green)
                        NutritionEnergyFact(title: "Burned", value: nutrition.sourceSupportedExpenditure, hue: .orange)
                        Spacer()
                    }
                    Text(provenance)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(nutrition.caloriesConsumed != nil && nutrition.sourceSupportedExpenditure != nil ? LifeOSTokens.tertiaryText : LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens net energy detail")
        .accessibilityIdentifier("fitness-nutrition-net-energy")
    }

    private var balanceLabel: String {
        guard let eaten = nutrition.caloriesConsumed, let burned = nutrition.sourceSupportedExpenditure else { return "—" }
        return eaten >= burned ? "+\(eaten - burned)" : "−\(burned - eaten)"
    }

    private var provenance: String {
        guard nutrition.caloriesConsumed != nil, nutrition.sourceSupportedExpenditure != nil else {
            return "Unavailable · both confirmed food intake and source-supported expenditure are required"
        }
        return "Food log + source-supported expenditure · selected-day observation"
    }
}

private struct NutritionEnergyFact: View {
    let title: String
    let value: Int?
    let hue: LifeOSTokens.Hue

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(LifeOSTokens.tertiaryText).frame(width: 6, height: 6)
            Text("\(title) \(value.map(String.init) ?? "—")")
                .font(LifeOSFont.caption(10))
                .monospacedDigit()
        }
    }
}

private struct NutritionEnergyScale: View {
    let eaten: Int?
    let burned: Int?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(LifeOSTokens.quietBorder.opacity(0.7))
                if let eaten, let burned {
                    let total = max(eaten, burned, 500)
                    let eatenWidth = width * CGFloat(eaten) / CGFloat(total)
                    let burnedWidth = width * CGFloat(burned) / CGFloat(total)
                    Capsule().fill(LifeOSTokens.success.opacity(0.52)).frame(width: min(width, CGFloat(eatenWidth)))
                    Capsule().fill(LifeOSTokens.warning.opacity(0.7)).frame(width: min(width, CGFloat(burnedWidth)))
                }
            }
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eaten versus burned energy scale")
        .accessibilityValue("Eaten \(eaten.map(String.init) ?? "unavailable") kilocalories; burned \(burned.map(String.init) ?? "unavailable") kilocalories")
    }
}

private struct FitnessNutritionQualityCard: View {
    let contributions: [FitnessNutritionQualityContribution]
    let score: Int?
    let detail: String?

    private let categories: [(String, LifeOSTokens.Hue)] = [
        ("Vegetables", .green), ("Wholegrain", .amber), ("Healthy oils", .orange),
        ("Fruit", .pink), ("Nuts / legumes", .violet), ("Omega-3", .teal)
    ]

    var body: some View {
        NavigationLink(destination: NutritionQualityView(contributions: contributions, score: score, detail: detail)) {
            NutritionSurfaceCard(accent: .green) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Food quality")
                                .font(LifeOSFont.header(16))
                            Text("Transparent inputs only · no proprietary formula is reproduced")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        Spacer()
                        Text(score.map { "\($0)/100" } ?? "Locked")
                            .font(LifeOSFont.inter(12, weight: .semiBold))
                            .foregroundStyle(score == nil ? LifeOSTokens.warning : LifeOSTokens.success)
                        LifeOSIcon(.chevronRight).frame(width: 13, height: 13)
                    }
                    NutritionAdaptiveGrid {
                        ForEach(categories, id: \.0) { category, hue in
                            let contribution = contributions.first(where: { $0.title.caseInsensitiveCompare(category) == .orderedSame })
                            NutritionContributionCell(category: category, hue: contribution?.hue ?? hue, value: contribution?.value, detail: contribution?.detail)
                        }
                    }
                    Text(score == nil ? "Quality is unavailable until user-recorded food-quality inputs exist." : (detail ?? "User-recorded inputs"))
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(score == nil ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    NutritionGlucoseUnavailableRow()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens food quality details")
        .accessibilityIdentifier("fitness-nutrition-quality")
    }
}

private struct NutritionContributionCell: View {
    let category: String
    let hue: LifeOSTokens.Hue
    let value: Double?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(value == nil ? LifeOSTokens.tertiaryText : LifeOSTokens.secondaryText).frame(width: 6, height: 6)
                Text(category).font(LifeOSFont.caption(10)).lineLimit(1)
            }
            if let value {
                ProgressView(value: value)
                    .tint(LifeOSTokens.accent)
                Text("\((value * 100).formatted(.number.precision(.fractionLength(0))))%")
                    .font(LifeOSFont.inter(12, weight: .semiBold)).monospacedDigit()
                Text(detail ?? "Recorded input")
                    .font(LifeOSFont.caption(9)).foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                Text("Unavailable")
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                Text("No recorded input")
                    .font(LifeOSFont.caption(9)).foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(LifeOSTokens.screenCanvas.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }
}

private struct NutritionGlucoseUnavailableRow: View {
    var body: some View {
        HStack(spacing: 8) {
            LifeOSIcon(.heartRate).foregroundStyle(LifeOSTokens.tertiaryText).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Glucose")
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                Text("Unavailable · no validated glucose source connected")
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.warning)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .background(LifeOSTokens.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.warning.opacity(0.2), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Glucose")
        .accessibilityValue("Unavailable; no validated glucose source connected")
    }
}

private struct FitnessNutritionMealTimelineCard: View {
    let meals: [FitnessMeal]
    let onAdd: () -> Void
    let onEdit: (FitnessMeal) -> Void
    let onDelete: (FitnessMeal) -> Void
    let onReview: (FitnessMeal) -> Void

    /// A durable meal is editable/deletable through this card only when it
    /// was built from `NutritionMealStore` (manual entry or a future photo
    /// confirmation). Barcode (`.package`) and demo/proposal rows are backed
    /// by a different store or no store at all, so they intentionally do not
    /// get Edit/Delete here.
    private func isDurable(_ meal: FitnessMeal) -> Bool {
        meal.source == .manual || meal.source == .photoConfirmed
    }

    var body: some View {
        NutritionSurfaceCard(accent: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meal timeline")
                            .font(LifeOSFont.header(16))
                        Text("Empty, proposed, and confirmed records remain distinct")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer()
                    Button(action: onAdd) {
                        Label("Add meal", systemImage: "plus")
                            .font(LifeOSFont.inter(11, weight: .semiBold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSTokens.accent)
                    .accessibilityIdentifier("nutrition-add-meal")
                }
                if meals.isEmpty {
                    FitnessEmptyRow(title: "No meals recorded", detail: "No entry is different from zero consumption.", icon: .grocery)
                } else {
                    ForEach(meals) { meal in
                        FitnessNutritionMealRow(
                            meal: meal,
                            isDurable: isDurable(meal),
                            onEdit: { onEdit(meal) },
                            onDelete: { onDelete(meal) },
                            onReview: { onReview(meal) }
                        )
                    }
                    FitnessNutritionMealDailyTotalsRow(meals: meals)
                }
            }
        }
        .accessibilityIdentifier("fitness-nutrition-meal-timeline")
    }
}

private struct FitnessNutritionMealDailyTotalsRow: View {
    let meals: [FitnessMeal]

    private var totalKcal: Int? {
        let values = meals.compactMap(\.calories)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var totalProtein: Double? {
        let values = meals.compactMap(\.protein)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var totalCarbs: Double? {
        let values = meals.compactMap(\.carbohydrates)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var totalFat: Double? {
        let values = meals.compactMap(\.fat)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var body: some View {
        Divider().padding(.vertical, 2)
        HStack(spacing: 12) {
            totalItem(label: "kcal", value: totalKcal.map(String.init))
            totalItem(label: "protein g", value: totalProtein.map { $0.formatted(.number.precision(.fractionLength(0))) })
            totalItem(label: "carbs g", value: totalCarbs.map { $0.formatted(.number.precision(.fractionLength(0))) })
            totalItem(label: "fat g", value: totalFat.map { $0.formatted(.number.precision(.fractionLength(0))) })
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nutrition-meal-daily-totals")
    }

    private func totalItem(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(LifeOSFont.inter(13, weight: .semiBold))
                .monospacedDigit()
            Text(label)
                .font(LifeOSFont.caption(9))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FitnessNutritionMealRow: View {
    let meal: FitnessMeal
    let isDurable: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(meal.source == .proposal ? LifeOSTokens.warning.opacity(0.13) : LifeOSTokens.accent.opacity(0.10))
                .frame(width: 36, height: 36)
                .overlay(LifeOSIcon(meal.source == .proposal ? .image : .grocery)
                    .foregroundStyle(meal.source == .proposal ? LifeOSTokens.warning : LifeOSTokens.accent)
                    .frame(width: 17, height: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text(meal.name).font(LifeOSFont.inter(13, weight: .semiBold)).lineLimit(2)
                Text("\(meal.source.rawValue) · \(meal.time.fitnessTimeLabel)")
                    .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                Text(meal.detail)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(meal.source == .proposal ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 4) {
                Text(meal.calories.map { "\($0) kcal" } ?? "—")
                    .font(LifeOSFont.inter(12, weight: .semiBold)).monospacedDigit()
                if meal.source == .proposal {
                    Button("Review", action: onReview)
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.accent).buttonStyle(.plain)
                } else if isDurable {
                    HStack(spacing: 10) {
                        Button("Edit", action: onEdit)
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.accent).buttonStyle(.plain)
                        Button("Delete", role: .destructive, action: onDelete)
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.warning).buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(meal.name)
        .accessibilityValue("\(meal.source.rawValue), \(meal.calories.map { "\($0) kilocalories" } ?? "calories unavailable")")
    }
}

private struct FitnessNutritionTrendsCard: View {
    let nutrition: FitnessNutritionSnapshot

    var body: some View {
        NutritionSurfaceCard(accent: .violet) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Trends")
                            .font(LifeOSFont.header(16))
                        Text("Each metric keeps its own source and availability")
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer()
                }
                NutritionAdaptiveGrid {
                    ForEach(NutritionTrendKind.allCases) { kind in
                        NavigationLink(destination: NutritionTrendDetailView(kind: kind, nutrition: nutrition)) {
                            NutritionTrendCell(kind: kind, nutrition: nutrition)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-nutrition-trends")
    }
}

private enum NutritionTrendKind: String, CaseIterable, Identifiable {
    case nutritionScore = "Nutrition score"
    case macroBalance = "Macro balance"
    case netEnergy = "Net energy surplus"
    case fastingGlucose = "Fasting glucose"
    case averageGlucose = "Average glucose"
    case glucoseVariability = "Glucose variability"
    var id: String { rawValue }
}

private struct NutritionTrendCell: View {
    let kind: NutritionTrendKind
    let nutrition: FitnessNutritionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kind.rawValue).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText).lineLimit(2)
            Text(value).font(LifeOSFont.inter(14, weight: .semiBold)).monospacedDigit()
            Text(available ? "Selected-day input" : "Unavailable · source required")
                .font(LifeOSFont.caption(9))
                .foregroundStyle(available ? LifeOSTokens.success : LifeOSTokens.warning)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(10)
        .background(LifeOSTokens.screenCanvas.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var available: Bool {
        switch kind {
        case .nutritionScore: return nutrition.qualityScore != nil
        case .macroBalance: return nutrition.macroValues.contains { $0.value != nil }
        case .netEnergy: return nutrition.caloriesConsumed != nil && nutrition.sourceSupportedExpenditure != nil
        case .fastingGlucose, .averageGlucose, .glucoseVariability: return false
        }
    }

    private var value: String {
        switch kind {
        case .nutritionScore: return nutrition.qualityScore.map { "\($0)/100" } ?? "—"
        case .macroBalance: return available ? "Tracked" : "—"
        case .netEnergy:
            guard let eaten = nutrition.caloriesConsumed, let burned = nutrition.sourceSupportedExpenditure else { return "—" }
            return eaten >= burned ? "+\(eaten - burned) kcal" : "−\(burned - eaten) kcal"
        case .fastingGlucose, .averageGlucose, .glucoseVariability: return "—"
        }
    }
}

private struct NutritionSurfaceCard<Content: View>: View {
    let accent: LifeOSTokens.Hue
    @ViewBuilder let content: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .overlay(LifeOSTokens.cardShape.stroke(hovering ? LifeOSTokens.strongBorder : Color.clear, lineWidth: 1))
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: hovering)
    }
}

private struct NutritionAdaptiveGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 11)], spacing: 11) {
            content
        }
    }
}

// MARK: - Nutrition detail routes

private struct NutritionFoodLibraryView: View {
    let meals: [FitnessMeal]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitnessSectionHeading(title: "Food library", subtitle: "Recent and confirmed records")
                NutritionSurfaceCard(accent: .blue) {
                    if meals.isEmpty {
                        FitnessEmptyRow(title: "No saved foods", detail: "Food library entries appear after a confirmed local record.", icon: .grocery)
                    } else {
                        ForEach(meals) { meal in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(meal.name).font(LifeOSFont.inter(13, weight: .semiBold))
                                    Text(meal.source.rawValue).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                                }
                                Spacer()
                                Text(meal.calories.map { "\($0) kcal" } ?? "—").font(LifeOSFont.caption(11)).monospacedDigit()
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    Text("Persistence and server sync are not connected in this build; this route does not imply a saved library.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Food library")
    }
}

private struct NutritionGoalsView: View {
    let nutrition: FitnessNutritionSnapshot
    let selectedDate: Date
    let isDemo: Bool

    private let goalStore: NutritionGoalStore?
    private let mealStore: NutritionMealStore?

    @State private var currentGoal: NutritionGoal?
    @State private var actualTotals: NutritionMealDailyTotals?
    @State private var calorieText = ""
    @State private var proteinText = ""
    @State private var carbText = ""
    @State private var fatText = ""
    @State private var saveError: String?
    @State private var savedConfirmation: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(nutrition: FitnessNutritionSnapshot, selectedDate: Date, isDemo: Bool) {
        self.nutrition = nutrition
        self.selectedDate = selectedDate
        self.isDemo = isDemo
        self.goalStore = try? NutritionGoalStore(url: NutritionGoalStore.defaultURL())
        self.mealStore = try? NutritionMealStore(url: NutritionMealStore.defaultURL())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitnessSectionHeading(title: "Nutrition goals", subtitle: "Durable targets you set, not a fixture")
                NutritionSurfaceCard(accent: .green) {
                    progressSummary
                    Divider().padding(.vertical, 6)
                    Text("Edit targets").font(LifeOSFont.header(15))
                    FitnessEditableField(title: "Calories (kcal)", text: $calorieText, numeric: true)
                    FitnessEditableField(title: "Protein (g)", text: $proteinText, numeric: true)
                    FitnessEditableField(title: "Carbs (g)", text: $carbText, numeric: true)
                    FitnessEditableField(title: "Fat (g)", text: $fatText, numeric: true)
                    if let saveError {
                        Text(saveError)
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let savedConfirmation {
                        Text(savedConfirmation)
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("Save goal") { saveGoal() }
                            .buttonStyle(.borderedProminent)
                            .tint(LifeOSTokens.success)
                            .disabled(goalStore == nil || isDemo)
                            .accessibilityIdentifier("nutrition-goal-save")
                    }
                    if goalStore == nil {
                        Text("Local goal storage is unavailable. Nothing can be saved right now.")
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isDemo {
                        Text("Fixture values · goal editing is disabled in demo mode.")
                            .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Saving records a new dated goal; it takes effect today and applies until you set another.")
                            .font(LifeOSFont.caption(9)).foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Goals")
        .task { await loadGoalAndActuals() }
    }

    @ViewBuilder
    private var progressSummary: some View {
        NutritionGoalLine(title: "Calories", value: currentGoal?.calorieTarget.map { "\($0) kcal" })
        NutritionGoalLine(title: "Protein", value: currentGoal?.proteinGramsTarget.map { "\($0) g" })
        NutritionGoalLine(title: "Carbs", value: currentGoal?.carbGramsTarget.map { "\($0) g" })
        NutritionGoalLine(title: "Fat", value: currentGoal?.fatGramsTarget.map { "\($0) g" })
        Text(progressLabel)
            .font(LifeOSFont.inter(12, weight: .medium))
            .foregroundStyle(progressAvailable ? Color.primary.opacity(0.82) : LifeOSTokens.warning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    /// Progress is only ever shown when BOTH a persisted goal and an actual
    /// logged intake exist for the day. Either half missing is an honest
    /// "Goal not set" / "No meals logged" state — never a fabricated 0% or a
    /// total that implies data that was never recorded.
    private var progressAvailable: Bool {
        currentGoal?.calorieTarget != nil && actualTotals?.kcal != nil
    }

    private var progressLabel: String {
        guard let target = currentGoal?.calorieTarget else { return "Goal not set" }
        guard let eaten = actualTotals?.kcal else { return "No meals logged" }
        let percent = target > 0 ? Int((Double(eaten) / Double(target) * 100).rounded()) : 0
        return "\(eaten.formatted()) / \(target.formatted()) kcal (\(percent)%)"
    }

    private func loadGoalAndActuals() async {
        guard !isDemo else {
            currentGoal = nil
            actualTotals = nil
            return
        }
        if let goalStore {
            currentGoal = try? goalStore.currentGoal(on: selectedDate)
        } else {
            currentGoal = nil
        }
        if let mealStore {
            actualTotals = try? mealStore.dailyTotals(on: selectedDate)
        } else {
            actualTotals = nil
        }
        calorieText = currentGoal?.calorieTarget.map(String.init) ?? ""
        proteinText = currentGoal?.proteinGramsTarget.map(String.init) ?? ""
        carbText = currentGoal?.carbGramsTarget.map(String.init) ?? ""
        fatText = currentGoal?.fatGramsTarget.map(String.init) ?? ""
    }

    private func saveGoal() {
        saveError = nil
        savedConfirmation = nil
        guard let goalStore else {
            saveError = "Local goal storage is unavailable. Nothing was saved."
            return
        }
        let goal = NutritionGoal(
            effectiveFrom: .now,
            calorieTarget: Int(calorieText.trimmingCharacters(in: .whitespaces)),
            proteinGramsTarget: Int(proteinText.trimmingCharacters(in: .whitespaces)),
            carbGramsTarget: Int(carbText.trimmingCharacters(in: .whitespaces)),
            fatGramsTarget: Int(fatText.trimmingCharacters(in: .whitespaces))
        )
        do {
            try goalStore.setGoal(goal)
            currentGoal = goal
            savedConfirmation = "Saved."
        } catch {
            saveError = "Could not save this goal. Nothing was changed."
        }
    }
}

private struct NutritionGoalLine: View {
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Text(title).font(LifeOSFont.inter(12, weight: .medium))
            Spacer()
            Text(value ?? "Unavailable").font(LifeOSFont.inter(12, weight: .semiBold)).monospacedDigit()
                .foregroundStyle(value == nil ? LifeOSTokens.warning : .primary)
        }
        .padding(.vertical, 7)
    }
}

private struct NutritionNetEnergyView: View {
    let nutrition: FitnessNutritionSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitnessSectionHeading(title: "Net energy", subtitle: "Eaten, burned, and the signed balance")
                NutritionSurfaceCard(accent: .orange) {
                    NutritionEnergyFact(title: "Eaten", value: nutrition.caloriesConsumed, hue: .green)
                    NutritionEnergyFact(title: "Burned", value: nutrition.sourceSupportedExpenditure, hue: .orange)
                    Divider().padding(.vertical, 3)
                    Text(balanceDetail).font(LifeOSFont.header(22)).monospacedDigit()
                    Text("Sign convention: eaten minus source-supported expenditure. The data remains unavailable until both observations exist.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Net energy")
    }

    private var balanceDetail: String {
        guard let eaten = nutrition.caloriesConsumed, let burned = nutrition.sourceSupportedExpenditure else { return "Balance unavailable" }
        let balance = eaten - burned
        return balance >= 0 ? "+\(balance) kcal surplus" : "−\(-balance) kcal deficit"
    }
}

private struct NutritionQualityView: View {
    let contributions: [FitnessNutritionQualityContribution]
    let score: Int?
    let detail: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitnessSectionHeading(title: "Food quality", subtitle: "Recorded contributions, not an inferred formula")
                NutritionSurfaceCard(accent: .green) {
                    Text(score.map { "Recorded quality input: \($0)/100" } ?? "Quality is locked")
                        .font(LifeOSFont.header(18))
                    Text(detail ?? "Add transparent, user-recorded food-quality inputs to review this surface. No proprietary score is recreated.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    NutritionAdaptiveGrid {
                        ForEach(contributions) { contribution in
                            NutritionContributionCell(category: contribution.title, hue: contribution.hue, value: contribution.value, detail: contribution.detail)
                        }
                    }
                    NutritionGlucoseUnavailableRow()
                }
            }
            .padding(16)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Food quality")
    }
}

private struct NutritionTrendDetailView: View {
    let kind: NutritionTrendKind
    let nutrition: FitnessNutritionSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitnessSectionHeading(title: kind.rawValue, subtitle: "Source-honest detail")
                NutritionSurfaceCard(accent: .violet) {
                    NutritionTrendCell(kind: kind, nutrition: nutrition)
                    Text(detail)
                        .font(LifeOSFont.caption(11)).foregroundStyle(available ? LifeOSTokens.tertiaryText : LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Long-range charts appear only after a validated history exists. Missing days are not silently converted to zero.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle(kind.rawValue)
    }

    private var available: Bool {
        switch kind {
        case .nutritionScore: return nutrition.qualityScore != nil
        case .macroBalance: return nutrition.macroValues.contains { $0.value != nil }
        case .netEnergy: return nutrition.caloriesConsumed != nil && nutrition.sourceSupportedExpenditure != nil
        case .fastingGlucose, .averageGlucose, .glucoseVariability: return false
        }
    }

    private var detail: String {
        if available {
            return "A selected-day input is available. A trend requires multiple validated observations and will retain its source and freshness."
        }
        switch kind {
        case .fastingGlucose, .averageGlucose, .glucoseVariability:
            return "Unavailable without a validated glucose source. LifeOS does not infer glucose from meals or generic health data."
        default:
            return "Unavailable for this day because the required confirmed nutrition observation is missing."
        }
    }
}

public struct FitnessNutritionSummaryCard: View {
    let nutrition: FitnessNutritionSnapshot

    public init(nutrition: FitnessNutritionSnapshot) {
        self.nutrition = nutrition
    }

    public var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Calories & energy balance")
                            .font(LifeOSFont.header(15))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Food records are separate from supplement records")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer()
                    Text(nutrition.caloriesConsumed.map(String.init) ?? "—")
                        .font(LifeOSFont.spaceGrotesk(29, weight: .bold))
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                    Text(nutrition.caloriesConsumed == nil ? "" : " kcal")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: true, vertical: false)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 10) {
                    NutritionEnergyColumn(title: "Target", value: nutrition.calorieTarget.map { "\($0) kcal" } ?? "Not available", hue: .blue)
                    NutritionEnergyColumn(title: "Remaining", value: remainingLabel, hue: .green)
                    NutritionEnergyColumn(title: "Net energy", value: netEnergyLabel, hue: .orange)
                }
                if nutrition.sourceSupportedExpenditure == nil {
                    Text("Net energy needs a source-supported expenditure observation; it is not inferred from a generic default.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Net energy = eaten minus source-supported expenditure. This is a calculation, not a direct measurement.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calories and energy balance")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let consumed = nutrition.caloriesConsumed.map { "\($0) kilocalories" } ?? "not available"
        let target = nutrition.calorieTarget.map { "\($0) kilocalories" } ?? "not available"
        return "Consumed \(consumed). Target \(target). Net energy \(netEnergyLabel)."
    }

    private var remainingLabel: String {
        guard let target = nutrition.calorieTarget, let consumed = nutrition.caloriesConsumed else { return "Not available" }
        return "\(max(0, target - consumed)) kcal"
    }

    private var netEnergyLabel: String {
        guard let consumed = nutrition.caloriesConsumed, let expenditure = nutrition.sourceSupportedExpenditure else { return "Not available" }
        return "\(consumed - expenditure) kcal"
    }
}

private struct NutritionEnergyColumn: View {
    let title: String
    let value: String
    let hue: LifeOSTokens.Hue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Circle().fill(LifeOSTokens.tertiaryText).frame(width: 6, height: 6)
            Text(title).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .font(LifeOSFont.inter(12, weight: .semiBold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FitnessMacroCard: View {
    let macros: [FitnessMacroValue]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Macros")
                        .font(LifeOSFont.header(15))
                    Spacer()
                    Text("Daily targets are user preferences")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(macros) { macro in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(macro.name).font(LifeOSFont.caption(11))
                            Spacer()
                            Text(macro.value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) \(macro.unit)" } ?? "Not available")
                                .font(LifeOSFont.inter(11, weight: .semiBold)).monospacedDigit()
                            if let target = macro.target {
                                Text("/ \(target.formatted(.number.precision(.fractionLength(0))))")
                                    .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                        }
                        GeometryReader { proxy in
                            let progress = macro.target.flatMap { target in macro.value.map { min(1, $0 / max(target, 1)) } } ?? 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(LifeOSTokens.quietBorder.opacity(0.65))
                                Capsule().fill(nutritionMacroColor(name: macro.name)).frame(width: proxy.size.width * progress)
                            }
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
    }
}

private enum FitnessFoodCaptureMethod: String, CaseIterable, Identifiable {
    case photo = "Photo meal"
    case manual = "Manual meal"
    case barcode = "Barcode / package"
    case recipe = "Recipe"
    case recent = "Recent / favorite"
    var id: String { rawValue }
}

private enum FitnessPhotoStage: String {
    case idle = "Ready"
    case manualEntry = "Manual entry"
    case needsConfirmation = "Needs confirmation"
    case edited = "Edited manual preview"
    case confirmed = "User confirmed"
}

/// Identifies one normalized barcode lookup.  The visible input remains
/// editable while a lookup is in flight, so a result is only allowed to touch
/// the review state when both its generation and its canonical barcode still
/// match the current sheet.
struct NutritionBarcodeRequestToken: Equatable, Sendable {
    let generation: UInt64
    let barcode: String
}

/// Small, deterministic guard for the asynchronous barcode review flow.
///
/// Cancellation is an optimization; the generation and normalized-identity
/// checks are the correctness boundary because a transport may still invoke a
/// completion after cancellation.  Keeping this model independent from the
/// network client makes the stale-result and dismissed-sheet cases testable
/// without inventing provider data or depending on timing.
struct NutritionBarcodeRequestGate: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var activeBarcode: String?

    mutating func begin(rawInput: String) -> NutritionBarcodeRequestToken? {
        invalidate()
        guard let barcode = NutritionBarcodeNormalizer.normalize(rawInput) else { return nil }
        generation &+= 1
        activeBarcode = barcode
        return NutritionBarcodeRequestToken(generation: generation, barcode: barcode)
    }

    /// Invalidates a request only when the user's visible input changed its
    /// canonical barcode identity. Formatting changes such as spaces or a
    /// hyphen do not make an already-valid proposal stale.
    @discardableResult
    mutating func invalidateIfVisibleInputChanged(_ rawInput: String) -> Bool {
        guard let activeBarcode,
              NutritionBarcodeNormalizer.normalize(rawInput) != activeBarcode else { return false }
        invalidate()
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        activeBarcode = nil
    }

    func accepts(_ token: NutritionBarcodeRequestToken, visibleInput: String) -> Bool {
        activeBarcode == token.barcode
            && generation == token.generation
            && NutritionBarcodeNormalizer.normalize(visibleInput) == token.barcode
    }
}

private struct FitnessFoodCaptureCard: View {
    let isDemo: Bool
    let photoStage: FitnessPhotoStage
    let onCapture: (FitnessFoodCaptureMethod) -> Void

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add food")
                            .font(LifeOSFont.header(15))
                        Text("Manual logging always stays available")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer()
                    Text(photoStage.rawValue)
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(photoStage == .confirmed ? LifeOSTokens.success : LifeOSTokens.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background((photoStage == .confirmed ? LifeOSTokens.success : LifeOSTokens.warning).opacity(0.12), in: Capsule())
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                    ForEach(FitnessFoodCaptureMethod.allCases) { method in
                        Button {
                            onCapture(method)
                        } label: {
                            VStack(spacing: 6) {
                                LifeOSIcon(method == .photo ? .image : method == .manual ? .add : .grocery).frame(width: 17, height: 17)
                                Text(method == .barcode ? "Package" : method.rawValue.replacingOccurrences(of: " meal", with: ""))
                                    .font(LifeOSFont.caption(10))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(method == .photo ? LifeOSTokens.accent : .primary)
                            .background(LifeOSTokens.screenCanvas.opacity(0.66), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(method == .photo ? LifeOSTokens.accent.opacity(0.34) : LifeOSTokens.quietBorder, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if photoStage == .needsConfirmation {
                    Text(isDemo ? "Demo proposal shown below; it is not a measured result." : "Photo assistant is not connected. No image has left this device.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct FitnessFoodReviewSheet: View {
    let method: FitnessFoodCaptureMethod
    let action: FitnessNutritionCaptureAction?
    @Binding var stage: FitnessPhotoStage
    let isDemo: Bool
    let nutritionRecordStore: NutritionRecordStore
    let nutritionMealStore: NutritionMealStore?
    /// When set, the manual entry form is pre-filled from this durable meal
    /// and "Save meal" calls `NutritionMealStore.correct` instead of
    /// `addConfirmed`.
    let editingMeal: NutritionMeal?
    let onBarcodeSaved: () -> Void
    let onMealSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var photoPreparation = FoodPhotoPreparationCoordinator()
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoSelectionGeneration = 0
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var mealName = "Meal"
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbohydrates = ""
    @State private var fat = ""
    @State private var savedMessage: String?
    @State private var mealSaveError: String?
    @State private var mealSaving = false
    @State private var mealSavedDurably = false
    @State private var barcodeInput = ""
    @State private var barcodeLookup: NutritionBarcodeLookup?
    @State private var barcodeProposal: NutritionBarcodeProposal?
    @State private var barcodeProductName = ""
    @State private var barcodeCalories = ""
    @State private var barcodeProtein = ""
    @State private var barcodeCarbohydrates = ""
    @State private var barcodeFat = ""
    @State private var barcodeGrams = ""
    @State private var barcodeBasis: NutritionBarcodeBasis = .perServing
    @State private var barcodeLoading = false
    @State private var barcodeError: String?
    @State private var confirmedBarcodeRecord: NutritionRecord?
    @State private var barcodeMealAt = ""
    @State private var barcodeSaving = false
    @State private var barcodeLookupTask: Task<Void, Never>?
    @State private var barcodeRequestGate = NutritionBarcodeRequestGate()
    @State private var barcodeProposalToken: NutritionBarcodeRequestToken?
#if os(iOS)
    @StateObject private var barcodeScanner = NutritionBarcodeScannerCoordinator()
#endif
    private let barcodeClient = TailscaleSyncClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(method == .photo ? (isDemo ? "Demo photo proposal" : "Photo meal review") : method.rawValue)
                        .font(LifeOSFont.headerLarge(22))
                    if let action {
                        disconnectedActionNotice(action)
                    }
                    if method == .photo {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Privacy and accuracy boundary")
                                .font(LifeOSFont.header(14))
                            Text("Sanitized photos would go device → private Windows LifeOS gateway → Google only after a future send. Nothing has left this device now. No estimate has been returned.")
                                .font(LifeOSFont.body(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Text(isDemo ? "DEMO PROPOSAL · fixture-only; no photo was uploaded" : "NO RESPONSE · nothing has left this device")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.warning)
                        }
                        .padding(13)
                        .background(LifeOSTokens.warning.opacity(0.08), in: LifeOSTokens.cardShape)
                    }
                    if method == .photo {
                        photoPreparationCard
                        if isDemo {
                            demoProposalFields
                        }
                    } else if method == .barcode {
                        barcodeReviewFields
                    } else {
                        manualPreviewFields
                    }
                    if let savedMessage {
                        Text(savedMessage).font(LifeOSFont.caption(11)).foregroundStyle(LifeOSTokens.success)
                    }
                    if let mealSaveError {
                        Text(mealSaveError)
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("nutrition-meal-save-error")
                    }
                    if method == .photo {
                        Button("Close") { dismiss() }
                            .buttonStyle(.bordered)
                    } else if method == .barcode {
                        HStack {
                            Button("Cancel") { dismiss() }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button(savedMessage == nil ? ((confirmedBarcodeRecord == nil && barcodeError == nil) ? "Confirm and save locally" : "Retry local save") : "Saved locally") { confirmBarcodeProposal() }
                                .buttonStyle(.borderedProminent)
                                .tint(LifeOSTokens.accent)
                                .disabled((barcodeProposal == nil && confirmedBarcodeRecord == nil) || !barcodeConfirmationIsCurrent || barcodeLoading || barcodeSaving || savedMessage != nil)
                        }
                    } else {
                        VStack(spacing: 8) {
                            HStack {
                                Button("Keep manual only") {
                                    stage = .manualEntry
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button("Apply local preview") {
                                    stage = .edited
                                    savedMessage = "Manual preview updated locally. Nothing was written to persistent storage."
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(LifeOSTokens.accent)
                            }
                            HStack {
                                Spacer()
                                Button(mealSaving ? "Saving…" : (mealSavedDurably ? "Saved" : (editingMeal == nil ? "Save meal" : "Confirm changes"))) {
                                    saveMealDurably()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(LifeOSTokens.success)
                                .disabled(mealSaving || mealSavedDurably || nutritionMealStore == nil)
                                .accessibilityIdentifier("nutrition-meal-save")
                            }
                            if nutritionMealStore == nil {
                                Text("Local meal storage is unavailable. Nothing can be saved right now.")
                                    .font(LifeOSFont.caption(10))
                                    .foregroundStyle(LifeOSTokens.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("\"Save meal\" writes this entry to durable local storage; the other buttons above remain in-memory only.")
                                    .font(LifeOSFont.caption(9))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("Review")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .onAppear {
            if isDemo && method == .photo {
                mealName = "Photo proposal · needs review"
                calories = "760"
                protein = "51"
                carbohydrates = "74"
                fat = "30"
            }
            if let editingMeal {
                mealName = editingMeal.name
                calories = editingMeal.kcal.map(String.init) ?? ""
                protein = editingMeal.proteinGrams.map(String.init) ?? ""
                carbohydrates = editingMeal.carbGrams.map(String.init) ?? ""
                fat = editingMeal.fatGrams.map(String.init) ?? ""
            }
            if method == .barcode, barcodeMealAt.isEmpty { barcodeMealAt = ISO8601DateFormatter().string(from: .now) }
        }
        .onDisappear {
#if os(iOS)
            barcodeScanner.stop()
#endif
            cancelBarcodeLookup()
            photoSelectionGeneration &+= 1
            photoLoadTask?.cancel()
            photoLoadTask = nil
            photoPreparation.clear()
            selectedPhotoItems.removeAll()
        }
        .onChange(of: barcodeInput) { _, newValue in
            guard barcodeRequestGate.invalidateIfVisibleInputChanged(newValue) else { return }
            barcodeLookupTask?.cancel()
            barcodeLookupTask = nil
            barcodeLoading = false
            barcodeLookup = nil
            barcodeProposal = nil
            barcodeProposalToken = nil
            confirmedBarcodeRecord = nil
            barcodeError = nil
        }
    }

    private func disconnectedActionNotice(_ action: FitnessNutritionCaptureAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(action.title)
                .font(LifeOSFont.header(13))
            Text(action.detail)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(LifeOSTokens.warning.opacity(0.08), in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.warning.opacity(0.2), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.title)
        .accessibilityValue(action.detail)
    }

    @ViewBuilder
    private var barcodeReviewFields: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open Food Facts proposal")
                    .font(LifeOSFont.header(14))
                Text("Manual entry is always available. On iPhone, the permission-gated camera scanner captures one checksum-validated code; the Windows LifeOS gateway then performs the bounded read-only lookup.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
#if os(iOS)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Camera scanner")
                            .font(LifeOSFont.header(12))
                        Spacer()
                        Button(barcodeScanner.state == .scanning ? "Stop camera" : "Scan barcode") {
                            if barcodeScanner.state == .scanning { barcodeScanner.stop() }
                            else { startBarcodeCamera() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(barcodeScanner.state == .denied || barcodeScanner.state == .unavailable)
                    }
                    Text(barcodeScannerStatus)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(barcodeScanner.state == .denied || barcodeScanner.state == .unavailable ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    if barcodeScanner.state == .scanning {
                        NutritionBarcodeCameraPreview(coordinator: barcodeScanner)
                            .frame(height: 190)
                            .clipShape(LifeOSTokens.cardShape)
                            .accessibilityIdentifier("nutrition-barcode-camera-preview")
                    }
                }
                .padding(10)
                .background(LifeOSTokens.screenCanvas, in: LifeOSTokens.cardShape)
#endif
                HStack(spacing: 8) {
                    TextField("EAN-8, EAN-13, or UPC-A", text: $barcodeInput)
                        .textFieldStyle(.roundedBorder)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .accessibilityIdentifier("nutrition-barcode-input")
                    Button(barcodeLoading ? "Looking up…" : "Look up") {
                        startBarcodeLookup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSTokens.accent)
                    .disabled(barcodeLoading || NutritionBarcodeNormalizer.normalize(barcodeInput) == nil)
                    .accessibilityIdentifier("nutrition-barcode-lookup")
                }
                if let barcodeError {
                    Text(barcodeError)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nutrition-barcode-error")
                }
                if barcodeLoading {
                    ProgressView("Loading product proposal…")
                        .font(LifeOSFont.caption(10))
                        .accessibilityIdentifier("nutrition-barcode-loading")
                }
                if let barcodeLookup {
                    barcodeLookupView(barcodeLookup)
                }
            }
        }
    }

    @ViewBuilder
    private func barcodeLookupView(_ lookup: NutritionBarcodeLookup) -> some View {
        switch lookup {
        case .notFound(let barcode, _):
            Text("No product was found for \(barcode). Nothing was inferred or saved.")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nutrition-barcode-not-found")
        case .unavailable(_, let reason, let retryAfterSeconds, _):
            let retryText = retryAfterSeconds.map { " Retry in \($0)s." } ?? ""
            Text("Lookup unavailable (\(reason.rawValue)).\(retryText) No product values are available.")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nutrition-barcode-unavailable")
        case .found(let found):
            VStack(alignment: .leading, spacing: 8) {
                Text(found.nutritionState == .unreliable ? "Proposal · provider quality warning" : "Editable proposal")
                    .font(LifeOSFont.header(13))
                    .foregroundStyle(found.nutritionState == .unreliable ? LifeOSTokens.warning : .primary)
                if found.nutritionState == .unreliable {
                    Text("Open Food Facts marked this product data as unreliable. Review every field before confirming.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if found.nutritionState == .partial {
                    Text("Some provider nutrients are missing. Missing values remain blank; LifeOS does not infer them.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if found.nutritionState == .unavailable {
                    Text("The product was found, but no valid kcal/macronutrient values were supplied.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Provider basis", selection: $barcodeBasis) {
                    if found.per100g != nil { Text("Per 100 g").tag(NutritionBarcodeBasis.per100g) }
                    if found.perServing != nil { Text("Per serving").tag(NutritionBarcodeBasis.perServing) }
                }
                .pickerStyle(.segmented)
                .onChange(of: barcodeBasis) { _, basis in applyBarcodeBasis(basis, found: found) }
                .accessibilityIdentifier("nutrition-barcode-basis")
                FitnessEditableField(title: "Product name", text: $barcodeProductName)
                FitnessEditableField(title: "Grams (optional)", text: $barcodeGrams, numeric: true)
                FitnessEditableField(title: "Calories (kcal)", text: $barcodeCalories, numeric: true)
                FitnessEditableField(title: "Protein (g)", text: $barcodeProtein, numeric: true)
                FitnessEditableField(title: "Carbohydrates (g)", text: $barcodeCarbohydrates, numeric: true)
                FitnessEditableField(title: "Fat (g)", text: $barcodeFat, numeric: true)
                Text("Source: Open Food Facts · ODbL-1.0 database / DbCL-1.0 contents. Volunteer-sourced data is not guaranteed accurate, complete, or reliable.")
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-provenance")
            }
        }
    }

    private func startBarcodeLookup() {
        guard let normalized = NutritionBarcodeNormalizer.normalize(barcodeInput) else {
            cancelBarcodeLookup()
            barcodeError = "Enter a checksum-valid EAN-8, EAN-13, or UPC-A barcode."
            barcodeLookup = nil
            barcodeProposal = nil
            barcodeProposalToken = nil
            return
        }
        barcodeLookupTask?.cancel()
        barcodeLookupTask = nil
        guard let request = barcodeRequestGate.begin(rawInput: normalized) else { return }
        barcodeInput = normalized
        barcodeError = nil
        barcodeLookup = nil
        barcodeProposal = nil
        barcodeProposalToken = nil
        confirmedBarcodeRecord = nil
        barcodeLoading = true
        barcodeLookupTask = Task { @MainActor in
            do {
                let lookup = try await barcodeClient.fetchNutritionBarcode(normalized)
                guard !Task.isCancelled,
                      barcodeRequestGate.accepts(request, visibleInput: barcodeInput) else { return }
                barcodeLoading = false
                barcodeLookupTask = nil
                applyBarcodeLookup(lookup, token: request)
            } catch let error as TailscaleSyncError {
                guard !Task.isCancelled,
                      barcodeRequestGate.accepts(request, visibleInput: barcodeInput) else { return }
                barcodeLoading = false
                barcodeLookupTask = nil
                barcodeError = barcodeErrorMessage(error)
            } catch {
                guard !Task.isCancelled,
                      barcodeRequestGate.accepts(request, visibleInput: barcodeInput) else { return }
                barcodeLoading = false
                barcodeLookupTask = nil
                barcodeError = "Barcode lookup returned an invalid response. No values are available."
            }
        }
    }

    private func cancelBarcodeLookup() {
        barcodeLookupTask?.cancel()
        barcodeLookupTask = nil
        barcodeRequestGate.invalidate()
        barcodeLoading = false
    }

#if os(iOS)
    private var barcodeScannerStatus: String {
        switch barcodeScanner.state {
        case .permissionRequired: return "Camera permission is required. If denied, enter the barcode manually below."
        case .denied: return "Camera access is denied or restricted. Enable it in Settings, or use manual entry."
        case .unavailable: return "This device has no available camera scanner. Manual entry remains available."
        case .ready: return "Camera is ready for a one-shot EAN-8, EAN-13, or UPC-A scan."
        case .scanning: return "Scanning one barcode… No camera frame is stored."
        case .captured(let barcode): return "Captured \(barcode); starting the bounded lookup."
        case .failed: return "Camera could not start. Manual entry remains available."
        }
    }

    private func startBarcodeCamera() {
        barcodeError = nil
        barcodeScanner.start { captured in
            barcodeInput = captured
            startBarcodeLookup()
        }
    }
#endif

    private func applyBarcodeLookup(_ lookup: NutritionBarcodeLookup, token: NutritionBarcodeRequestToken) {
        barcodeLookup = lookup
        guard case .found(let found) = lookup else {
            barcodeProposal = nil
            barcodeProposalToken = nil
            return
        }
        do {
            let proposal = try NutritionBarcodeProposal(proposalID: "barcode-\(found.barcode)", lookup: lookup)
            barcodeProposal = proposal
            barcodeProposalToken = token
            barcodeProductName = found.product.name ?? ""
            if let values = found.perServing {
                barcodeBasis = .perServing
                applyBarcodeValues(values)
            } else if let values = found.per100g {
                barcodeBasis = .per100g
                applyBarcodeValues(values)
            } else {
                barcodeBasis = .perServing
                barcodeCalories = ""
                barcodeProtein = ""
                barcodeCarbohydrates = ""
                barcodeFat = ""
            }
        } catch {
            barcodeProposal = nil
            barcodeProposalToken = nil
            barcodeError = "The provider response could not be turned into an editable proposal."
        }
    }

    private func applyBarcodeValues(_ values: NutritionBarcodeMacros) {
        barcodeCalories = values.kcal.map(formatNutritionValue) ?? ""
        barcodeProtein = values.proteinGrams.map(formatNutritionValue) ?? ""
        barcodeCarbohydrates = values.carbsGrams.map(formatNutritionValue) ?? ""
        barcodeFat = values.fatGrams.map(formatNutritionValue) ?? ""
    }

    private func applyBarcodeBasis(_ basis: NutritionBarcodeBasis, found: NutritionBarcodeFound) {
        switch basis {
        case .per100g:
            if let values = found.per100g { applyBarcodeValues(values) }
        case .perServing:
            if let values = found.perServing { applyBarcodeValues(values) }
        }
    }

    private func confirmBarcodeProposal() {
        guard let barcodeProposal,
              let barcodeProposalToken,
              barcodeRequestGate.accepts(barcodeProposalToken, visibleInput: barcodeInput),
              barcodeProposal.barcode == barcodeProposalToken.barcode else {
            barcodeError = "The barcode input changed. Look up the current barcode before confirming."
            return
        }
        if let confirmedBarcodeRecord {
            saveBarcodeRecord(confirmedBarcodeRecord)
            return
        }
        let kcal = NutritionBarcodeValueParser.parse(barcodeCalories, maximum: 5_000)
        let proteinGrams = NutritionBarcodeValueParser.parse(barcodeProtein, maximum: 2_000)
        let carbsGrams = NutritionBarcodeValueParser.parse(barcodeCarbohydrates, maximum: 2_000)
        let fatGrams = NutritionBarcodeValueParser.parse(barcodeFat, maximum: 2_000)
        let nutritionInputs = [barcodeCalories, barcodeProtein, barcodeCarbohydrates, barcodeFat]
        let nutritionValues = [kcal, proteinGrams, carbsGrams, fatGrams]
        guard zip(nutritionInputs, nutritionValues).allSatisfy({ raw, value in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value != nil
        }) else {
            barcodeError = "Enter valid non-negative nutrition values (comma or dot decimals; up to 3 decimal places)."
            return
        }
        guard nutritionValues.contains(where: { $0 != nil }) else {
            barcodeError = "Enter at least one kcal or macronutrient value before confirming."
            return
        }
        let grams = NutritionBarcodeValueParser.parse(barcodeGrams, maximum: 5_000)
        if !barcodeGrams.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && grams == nil {
            barcodeError = "Enter a valid non-negative grams value (comma or dot decimals; up to 3 decimal places)."
            return
        }
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: barcodeProposal.proposalID,
            barcode: barcodeProposal.barcode,
            basis: barcodeBasis,
            mealAt: barcodeMealAt,
            productName: barcodeProductName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : barcodeProductName,
            grams: grams, kcal: kcal, proteinGrams: proteinGrams,
            carbsGrams: carbsGrams, fatGrams: fatGrams,
            confirmedAt: ISO8601DateFormatter().string(from: .now)
        )
        do {
            let record = try NutritionBarcodeFlow.confirm(confirmation, for: barcodeProposal)
            // Retain the validated record before the write so a failed write
            // exposes a deterministic Retry action without rebuilding or
            // changing the user's editable values.
            confirmedBarcodeRecord = record
            saveBarcodeRecord(record)
        } catch {
            barcodeError = "Review the barcode, timestamp, and nutrition values before confirming. Nothing was persisted."
        }
    }

    private var barcodeConfirmationIsCurrent: Bool {
        guard let barcodeProposal,
              let barcodeProposalToken else { return false }
        return barcodeProposal.barcode == barcodeProposalToken.barcode
            && barcodeRequestGate.accepts(barcodeProposalToken, visibleInput: barcodeInput)
    }

    private func saveBarcodeRecord(_ record: NutritionRecord) {
        barcodeSaving = true
        barcodeError = nil
        savedMessage = nil
        Task {
            do {
                try await nutritionRecordStore.save(record)
                await MainActor.run {
                    barcodeSaving = false
                    stage = .confirmed
                    savedMessage = "Saved locally · Open Food Facts provenance retained · sync pending."
                    onBarcodeSaved()
                }
            } catch {
                await MainActor.run {
                    barcodeSaving = false
                    stage = .manualEntry
                    barcodeError = "Local save failed. Nothing was replaced; try again with Retry local save."
                }
            }
        }
    }

    private func formatNutritionValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func barcodeErrorMessage(_ error: TailscaleSyncError) -> String {
        switch error {
        case .notConfigured: return "LifeOS server is not configured. No lookup was attempted."
        case .invalidBarcode: return "Enter a checksum-valid EAN-8, EAN-13, or UPC-A barcode."
        case .httpError(let status): return "The authenticated gateway returned HTTP \(status). No values are available."
        case .responseTooLarge: return "The gateway response exceeded the safety bound. No values are available."
        case .invalidResponse: return "The gateway returned an invalid barcode response. No values are available."
        case .invalidServerURL: return "The LifeOS server URL is not approved. No lookup was attempted."
        case .invalidInstitutionId, .invalidConnectionId, .invalidConsentURL,
             .connectionAlreadyLinking, .gatewayNotConfigured:
            return "The gateway returned an unexpected response. No values are available."
        }
    }

    private func saveMealDurably() {
        guard let nutritionMealStore else {
            mealSaveError = "Local meal storage is unavailable. Nothing was saved."
            return
        }
        let trimmedName = mealName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            mealSaveError = "Enter a meal name before saving."
            return
        }
        let kcal = NutritionBarcodeValueParser.parse(calories, maximum: 5_000)
        let proteinGrams = NutritionBarcodeValueParser.parse(protein, maximum: 2_000)
        let carbGrams = NutritionBarcodeValueParser.parse(carbohydrates, maximum: 2_000)
        let fatGrams = NutritionBarcodeValueParser.parse(fat, maximum: 2_000)
        let rawInputs = [calories, protein, carbohydrates, fat]
        let parsedValues = [kcal, proteinGrams, carbGrams, fatGrams]
        guard zip(rawInputs, parsedValues).allSatisfy({ raw, value in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value != nil
        }) else {
            mealSaveError = "Enter valid non-negative nutrition values (comma or dot decimals; up to 3 decimal places)."
            return
        }

        mealSaving = true
        mealSaveError = nil
        do {
            if let editingMeal {
                try nutritionMealStore.correct(id: editingMeal.id) { draft in
                    draft.name = trimmedName
                    draft.kcal = kcal.map { Int($0.rounded()) }
                    draft.proteinGrams = proteinGrams.map { Int($0.rounded()) }
                    draft.carbGrams = carbGrams.map { Int($0.rounded()) }
                    draft.fatGrams = fatGrams.map { Int($0.rounded()) }
                }
            } else {
                let meal = NutritionMeal(
                    loggedAt: .now,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    name: trimmedName,
                    kcal: kcal.map { Int($0.rounded()) },
                    proteinGrams: proteinGrams.map { Int($0.rounded()) },
                    carbGrams: carbGrams.map { Int($0.rounded()) },
                    fatGrams: fatGrams.map { Int($0.rounded()) },
                    provenance: .manual
                )
                try nutritionMealStore.addConfirmed(meal)
            }
            mealSaving = false
            mealSavedDurably = true
            stage = .confirmed
            savedMessage = "Saved locally · durable · sync pending."
            onMealSaved()
        } catch {
            mealSaving = false
            mealSaveError = "Local save failed. Nothing was replaced; try Save meal again."
        }
    }

    @ViewBuilder
    private var manualPreviewFields: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Manual meal entry")
                        .font(LifeOSFont.header(14))
                    Text("\"Apply local preview\" stays in-memory only. \"Save meal\" below writes this entry to durable local storage.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FitnessEditableField(title: "Meal name", text: $mealName)
                FitnessEditableField(title: "Calories (kcal)", text: $calories, numeric: true)
                FitnessEditableField(title: "Protein (g)", text: $protein, numeric: true)
                FitnessEditableField(title: "Carbohydrates (g)", text: $carbohydrates, numeric: true)
                FitnessEditableField(title: "Fat (g)", text: $fat, numeric: true)
            }
        }
        Text("Edit items, grams, calories, ranges, and confidence in this local preview. Nothing here claims medical or photo accuracy.")
            .font(LifeOSFont.caption(10))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var demoProposalFields: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("DEMO PROPOSAL · fixture-only")
                    .font(LifeOSFont.header(14))
                    .foregroundStyle(LifeOSTokens.warning)
                FitnessEditableField(title: "Meal name", text: $mealName)
                FitnessEditableField(title: "Calories (kcal)", text: $calories, numeric: true)
                FitnessEditableField(title: "Protein (g)", text: $protein, numeric: true)
                FitnessEditableField(title: "Carbohydrates (g)", text: $carbohydrates, numeric: true)
                FitnessEditableField(title: "Fat (g)", text: $fat, numeric: true)
            }
        }
        Text("This deterministic demo proposal is not a photo result and is not written or sent anywhere.")
            .font(LifeOSFont.caption(10))
            .foregroundStyle(LifeOSTokens.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var photoPreparationCard: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prepare photos locally")
                    .font(LifeOSFont.header(14))
                Text("Choose up to three images. LifeOS validates and sanitizes them on this device before any later send action.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: FoodPhotoSanitizer.maximumImageCount,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 7) {
                        LifeOSIcon(.image)
                            .frame(width: 16, height: 16)
                        Text("Choose up to 3 photos")
                    }
                }
                .accessibilityIdentifier("food-photo-picker")
                .onChange(of: selectedPhotoItems) { _, items in
                    loadSelectedPhotos(items)
                }
                Text(preparationStatus)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(photoPreparation.state == .error ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("food-photo-preparation-status")
                if photoPreparation.state == .ready {
                    Toggle(
                        "I consent: sanitized photos device → private Windows LifeOS gateway → Google",
                        isOn: Binding(
                            get: { photoPreparation.explicitConsent },
                            set: { photoPreparation.setExplicitConsent($0) }
                        )
                    )
                    .font(LifeOSFont.inter(12, weight: .medium))
                    .accessibilityIdentifier("food-photo-explicit-consent")
                    .accessibilityLabel("Consent: sanitized photos device to private Windows LifeOS gateway to Google")
                    Text("Consent is required for a future send and resets whenever this selection changes, fails, or is cleared.")
                        .font(LifeOSFont.caption(9))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Send unavailable") {}
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSTokens.accent)
                    .disabled(true)
                    .accessibilityIdentifier("food-photo-send-unavailable")
                Text("Nothing has left this device now. The private Windows LifeOS gateway and future Google send are unavailable.")
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preparationStatus: String {
        switch photoPreparation.state {
        case .idle:
            return "No photos selected."
        case .preparing:
            return "Preparing photos locally…"
        case .ready:
            let noun = photoPreparation.sanitizedImageCount == 1 ? "photo" : "photos"
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(photoPreparation.sanitizedByteCount),
                countStyle: .file
            )
            return "\(photoPreparation.sanitizedImageCount) sanitized \(noun) · \(size)"
        case .error:
            return "Photo preparation failed. Select different images; no photo was sent."
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        photoSelectionGeneration &+= 1
        let generation = photoSelectionGeneration
        photoLoadTask?.cancel()
        photoLoadTask = nil
        guard !items.isEmpty else {
            photoPreparation.clear()
            return
        }
        guard items.count <= FoodPhotoSanitizer.maximumImageCount else {
            photoPreparation.failPreparation()
            return
        }

        photoPreparation.beginSelection()
        photoLoadTask = Task { @MainActor in
            defer {
                if generation == photoSelectionGeneration {
                    photoLoadTask = nil
                }
            }
            do {
                var inputs: [FoodPhotoSanitizerInput] = []
                inputs.reserveCapacity(items.count)
                var totalBytes = 0
                for item in items {
                    guard !Task.isCancelled, generation == photoSelectionGeneration else { return }
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw FoodPhotoPreparationError.preparationFailed
                    }
                    let (nextTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
                    guard !overflow, nextTotal <= FoodPhotoSanitizer.maximumAggregateInputBytes else {
                        throw FoodPhotoPreparationError.preparationFailed
                    }
                    totalBytes = nextTotal
                    let identifier = "photo-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
                    inputs.append(try FoodPhotoSanitizerInput(imageID: identifier, data: data))
                }
                guard !Task.isCancelled, generation == photoSelectionGeneration else { return }
                photoPreparation.prepare(inputs: inputs)
            } catch {
                guard !Task.isCancelled, generation == photoSelectionGeneration else { return }
                photoPreparation.failPreparation()
            }
        }
    }
}

private struct FitnessEditableField: View {
    let title: String
    @Binding var text: String
    var numeric = false

    var body: some View {
        HStack {
            Text(title).font(LifeOSFont.caption(11)).foregroundStyle(LifeOSTokens.tertiaryText)
            Spacer()
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .font(LifeOSFont.inter(13, weight: .medium))
#if os(iOS)
                .keyboardType(numeric ? .numbersAndPunctuation : .default)
#endif
        }
    }
}

private struct FitnessMealTimeline: View {
    let meals: [FitnessMeal]
    @Binding var photoStage: FitnessPhotoStage

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Meal timeline")
                    .font(LifeOSFont.header(15))
                if meals.isEmpty {
                    FitnessEmptyRow(title: "No meals", detail: "No entries is distinct from zero consumption.", icon: .grocery)
                } else {
                    ForEach(meals) { meal in
                        FitnessMealRow(meal: meal, onReview: meal.source == .proposal ? { photoStage = .needsConfirmation } : nil)
                    }
                }
            }
        }
    }
}

private struct FitnessMealRow: View {
    let meal: FitnessMeal
    let onReview: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(meal.source == .proposal ? LifeOSTokens.warning.opacity(0.14) : LifeOSTokens.accent.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay(LifeOSIcon(meal.source == .proposal ? .image : .grocery).foregroundStyle(meal.source == .proposal ? LifeOSTokens.warning : LifeOSTokens.accent).frame(width: 17, height: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text(meal.name)
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(meal.source.rawValue) · \(meal.time.fitnessTimeLabel)")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meal.detail)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(meal.source == .proposal ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 2) {
                Text(meal.calories.map { "\($0) kcal" } ?? "—")
                    .font(LifeOSFont.inter(12, weight: .semiBold)).monospacedDigit()
                if let confidence = meal.confidence {
                    Text(confidence)
                        .font(LifeOSFont.caption(9))
                        .foregroundStyle(LifeOSTokens.warning)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onReview {
                    Button("Review", action: onReview)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FitnessHydrationLifestyleCard: View {
    let nutrition: FitnessNutritionSnapshot
    let selectedDate: Date
    let isFixture: Bool
    @StateObject private var repository: FitnessLifestyleRepository
    @State private var refreshToken = UUID()

    init(nutrition: FitnessNutritionSnapshot, selectedDate: Date, isFixture: Bool) {
        self.nutrition = nutrition
        self.selectedDate = selectedDate
        self.isFixture = isFixture
        _repository = StateObject(wrappedValue: FitnessLifestyleRepository(usesVisualFixtures: isFixture))
    }

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hydration, caffeine, alcohol")
                            .font(LifeOSFont.header(15))
                        Text(isFixture ? "Fixture preview · not persisted" : "Durable local facts · exact timestamps")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(isFixture ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    Text("Open logs")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.accent)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 10) {
                    lifestyleLink(kind: .hydration, hue: .blue)
                    lifestyleLink(kind: .caffeine, hue: .orange)
                    lifestyleLink(kind: .alcohol, hue: .pink)
                }
                if !isFixture,
                   nutrition.hydrationMilliliters != nil || nutrition.caffeineMilligrams != nil {
                    Text(appleHealthDaySummary)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("No health-risk conclusion is inferred from these logs. Empty entries remain empty rather than becoming zero.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .task { reloadLedger() }
        .onChange(of: selectedDate) { _, _ in reloadLedger() }
        .onReceive(NotificationCenter.default.publisher(for: .fitnessLifestyleLedgerDidChange)) { note in
            guard !isFixture,
                  let key = note.object as? String,
                  key == repository.store.persistenceKey else { return }
            reloadLedger()
        }
        .accessibilityIdentifier("fitness-lifestyle-summary-card")
    }

    @ViewBuilder
    private func lifestyleLink(kind: FitnessLifestyleKind, hue: LifeOSTokens.Hue) -> some View {
        NavigationLink {
            FitnessLifestyleView(
                kind: kind,
                selectedDate: selectedDate,
                usesVisualFixtures: isFixture,
                fixtureTotal: fixtureTotal(for: kind),
                fixtureUnit: fixtureUnit(for: kind),
                repository: repository
            )
        } label: {
            LifestyleColumn(title: kind.displayName, value: value(for: kind), detail: detail(for: kind), hue: hue)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fitness-lifestyle-open-\(kind.rawValue)")
    }

    private var timeZoneIdentifier: String {
        let identifier = TimeZone.current.identifier
        return FitnessLifestyleTime.isValidTimeZoneIdentifier(identifier) ? identifier : "UTC"
    }

    /// Exact selected-day HealthKit totals supplied by the production
    /// composition. They are shown as a separate labeled fact — never merged
    /// into the local ledger totals — so a value logged by hand and a value
    /// synced from Apple Health can never silently double-count.
    private var appleHealthDaySummary: String {
        var parts: [String] = []
        if let hydration = nutrition.hydrationMilliliters {
            parts.append("Water \(hydration) ml")
        }
        if let caffeine = nutrition.caffeineMilligrams {
            parts.append("Caffeine \(caffeine) mg")
        }
        guard !parts.isEmpty else { return "" }
        return "Apple Health · selected day · " + parts.joined(separator: " · ")
    }

    private func reloadLedger() {
        guard !isFixture else {
            refreshToken = UUID()
            return
        }
        repository.refresh()
        refreshToken = UUID()
    }

    private func summary(for kind: FitnessLifestyleKind) -> Result<FitnessLifestyleDaySummary, FitnessLifestyleStoreError> {
        _ = refreshToken
        guard !isFixture else {
            return .failure(.corruptStorage("fixture summary is supplied by the preview snapshot"))
        }
        let localDay = FitnessLifestyleTime.localDay(for: selectedDate, timeZoneIdentifier: timeZoneIdentifier)
        do {
            return .success(try repository.summary(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier))
        } catch let error as FitnessLifestyleStoreError {
            return .failure(error)
        } catch {
            return .failure(.corruptStorage(error.localizedDescription))
        }
    }

    private func value(for kind: FitnessLifestyleKind) -> String {
        if isFixture {
            switch kind {
            case .hydration:
                guard let amount = nutrition.hydrationMilliliters else { return "Fixture · —" }
                return "Fixture · \(amount) ml"
            case .caffeine:
                return nutrition.caffeineMilligrams.map { "Fixture · \($0) mg" } ?? "Fixture · —"
            case .alcohol:
                return nutrition.alcoholUnits.map { "Fixture · \($0.formatted(.number.precision(.fractionLength(1)))) standard drinks" } ?? "Fixture · —"
            }
        }
        switch summary(for: kind) {
        case .failure: return "Unavailable"
        case .success(let summary):
            if summary.explicitNone { return "None" }
            if summary.alcoholFree { return "Alcohol-free" }
            guard let total = summary.total else { return "—" }
            return "\(total.formatted(.number.precision(.fractionLength(0...2)))) \(summary.unit?.label ?? "")"
        }
    }

    private func fixtureTotal(for kind: FitnessLifestyleKind) -> Double? {
        guard isFixture else { return nil }
        switch kind {
        case .hydration: return nutrition.hydrationMilliliters.map(Double.init)
        case .caffeine: return nutrition.caffeineMilligrams.map(Double.init)
        case .alcohol: return nutrition.alcoholUnits
        }
    }

    private func fixtureUnit(for kind: FitnessLifestyleKind) -> FitnessLifestyleUnit? {
        guard isFixture else { return nil }
        switch kind {
        case .hydration: return .milliliters
        case .caffeine: return .milligrams
        case .alcohol: return .standardDrinks
        }
    }

    private func detail(for kind: FitnessLifestyleKind) -> String {
        if isFixture { return "Fixture only · not live" }
        switch summary(for: kind) {
        case .failure: return "Local log unavailable"
        case .success(let summary):
            switch summary.missingness {
            case .observed: return "\(summary.sampleCount) saved fact\(summary.sampleCount == 1 ? "" : "s")"
            case .explicitNone: return "Explicit none"
            case .alcoholFree: return "Alcohol-free"
            case .missing: return "No observation"
            }
        }
    }
}

private struct LifestyleColumn: View {
    let title: String
    let value: String
    let detail: String
    let hue: LifeOSTokens.Hue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Circle().fill(LifeOSTokens.tertiaryText).frame(width: 6, height: 6)
            Text(title).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .font(LifeOSFont.inter(11, weight: .semiBold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(LifeOSFont.caption(9))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
