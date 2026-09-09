import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#endif

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
        self.value = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.target = target.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
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
        self.calorieTarget = calorieTarget.flatMap { $0 >= 0 ? $0 : nil }
        self.caloriesConsumed = caloriesConsumed.flatMap { $0 >= 0 ? $0 : nil }
        self.sourceSupportedExpenditure = sourceSupportedExpenditure.flatMap { $0 >= 0 ? $0 : nil }
        self.macroValues = macroValues
        self.meals = meals
        self.hydrationMilliliters = hydrationMilliliters
        self.hydrationTargetMilliliters = hydrationTargetMilliliters.flatMap { $0 >= 0 ? $0 : nil }
        self.caffeineMilligrams = caffeineMilligrams
        self.alcoholUnits = alcoholUnits
        self.qualityScore = qualityScore.flatMap { (0...100).contains($0) ? $0 : nil }
        self.qualityDetail = qualityDetail
        self.qualityContributions = qualityContributions
    }

    /// Local goals supply targets only; they cannot create observed nutrition.
    func applyingGoal(_ goal: NutritionGoal?) -> FitnessNutritionSnapshot {
        FitnessNutritionSnapshot(
            calorieTarget: goal?.calorieTarget,
            caloriesConsumed: caloriesConsumed,
            sourceSupportedExpenditure: sourceSupportedExpenditure,
            macroValues: macroValues.map { macro in
                let target: Int?
                switch macro.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "protein": target = goal?.proteinGramsTarget
                case "carbs", "carbohydrates": target = goal?.carbGramsTarget
                case "fat": target = goal?.fatGramsTarget
                default: target = nil
                }
                return FitnessMacroValue(name: macro.name, value: macro.value, target: target.map(Double.init), unit: macro.unit, hue: macro.hue)
            },
            meals: meals,
            hydrationMilliliters: hydrationMilliliters,
            hydrationTargetMilliliters: hydrationTargetMilliliters,
            caffeineMilligrams: caffeineMilligrams,
            alcoholUnits: alcoholUnits,
            qualityScore: qualityScore,
            qualityDetail: qualityDetail,
            qualityContributions: qualityContributions
        )
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
                detail: "Open Food Facts · confirmed locally",
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
                detail: "Confirmed locally · device only",
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
    @State private var localGoal: NutritionGoal?
    @State private var goalPersistenceError: String?
    @State private var captureDraft: FitnessNutritionDraft
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
        _captureDraft = State(initialValue: FitnessNutritionDraft.new(selectedDate: selectedDate))
    }

    var body: some View {
        FitnessNutritionSurface(
            nutrition: effectiveNutrition,
            selectedDate: selectedDate,
            sourceStatus: snapshot.source.status,
            photoStage: $photoStage,
            localBarcodeRecordCount: effectiveBarcodeRecords.count,
            barcodePersistenceError: barcodePersistenceError,
            mealPersistenceError: mealPersistenceError ?? goalPersistenceError,
            onCapture: { method in
                let hasPendingDraft = captureDraft.isDirty || captureDraft.previewMeal != nil
                captureDraft = FitnessNutritionDraftFlow.reopenOrStart(
                    current: captureDraft,
                    selectedDate: selectedDate
                )
                if !hasPendingDraft {
                    captureMethod = method
                    captureAction = nil
                    photoStage = method == .photo ? .idle : .manualEntry
                }
                showingCapture = true
            },
            onEditMeal: { fitnessMeal in
                guard let match = localMeal(for: fitnessMeal) else { return }
                captureDraft = FitnessNutritionDraft.editing(match)
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
                draft: $captureDraft,
                onDiscardDraft: discardCaptureDraft,
                onKeepManualOnly: keepCaptureManualOnly,
                onBarcodeSaved: reloadBarcodeRecords,
                onMealSaved: reloadMeals
            )
                .presentationDetents([.large])
#if os(iOS)
                .presentationDragIndicator(.visible)
#endif
#if os(macOS)
                .frame(minWidth: 420, idealWidth: 560, maxWidth: 640, minHeight: 420, idealHeight: 560, maxHeight: 760)
#endif
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
        .onAppear {
            loadGoal()
            handleInitialEntryPointIfNeeded()
        }
        .onChange(of: selectedDate) { _, _ in loadGoal() }
        .task { await loadBarcodeRecords() }
        .task { await loadMeals() }
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
            let selectedMethod = method(for: action)
            let hasPendingDraft = captureDraft.isDirty || captureDraft.previewMeal != nil
            captureDraft = FitnessNutritionDraftFlow.reopenOrStart(
                current: captureDraft,
                selectedDate: selectedDate
            )
            if !hasPendingDraft {
                captureAction = action
                captureMethod = selectedMethod
                photoStage = selectedMethod == .photo ? .idle : .manualEntry
            }
            showingCapture = true
        }
    }

    private func discardCaptureDraft() {
        captureDraft = FitnessNutritionDraftFlow.discard(selectedDate: selectedDate)
        photoStage = .idle
        showingCapture = false
    }

    private func keepCaptureManualOnly() {
        captureAction = nil
        captureMethod = .manual
        photoStage = .manualEntry
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
            .applyingGoal(localGoal)
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

    private func loadGoal() {
        guard snapshot.source.status != .demo else { return }
        do {
            let store = try NutritionGoalStore(url: NutritionGoalStore.defaultURL())
            localGoal = try store.currentGoal(on: selectedDate)
            goalPersistenceError = nil
        } catch {
            localGoal = nil
            goalPersistenceError = "Local nutrition targets could not be read. Targets are unavailable."
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
            guard !Task.isCancelled else { return }
            await MainActor.run {
                localBarcodeRecords = loaded
                barcodePersistenceError = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
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
                Label("\(localBarcodeRecordCount) barcode meal\(localBarcodeRecordCount == 1 ? "" : "s") · saved locally", systemImage: "externaldrive.badge.checkmark")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-local-status")
            }
            if let barcodePersistenceError {
                Text(barcodePersistenceError)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-persistence-error")
            }
            if let mealPersistenceError {
                Text(mealPersistenceError)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-meal-persistence-error")
            }
            if hasObservedNutrition {
                FitnessNutritionHeroCard(nutrition: nutrition, isDemo: sourceStatus == .demo, selectedDate: selectedDate)
                FitnessNutritionMacroCard(macros: nutrition.macroValues, display: $macroDisplay)
                FitnessNutritionMealTimelineCard(
                    meals: nutrition.meals,
                    onAdd: { onCapture(.manual) },
                    onEdit: onEditMeal,
                    onDelete: onDeleteMeal,
                    onReview: { _ in photoStage = .needsConfirmation }
                )
                FitnessNutritionNetEnergyCard(nutrition: nutrition)
                FitnessNutritionQualityCard(
                    contributions: nutrition.qualityContributions,
                    score: nutrition.qualityScore,
                    detail: nutrition.qualityDetail
                )
                FitnessNutritionTrendsCard(nutrition: nutrition)
                FitnessHydrationLifestyleCard(
                    nutrition: nutrition,
                    selectedDate: selectedDate,
                    isFixture: sourceStatus == .demo
                )
            } else {
                FitnessNutritionEmptyState(onAddMeal: { onCapture(.manual) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("fitness-nutrition-surface")
    }

    private var hasObservedNutrition: Bool {
        nutrition.caloriesConsumed != nil
            || nutrition.sourceSupportedExpenditure != nil
            || !nutrition.meals.isEmpty
            || nutrition.macroValues.contains { $0.value != nil }
            || nutrition.hydrationMilliliters != nil
            || nutrition.caffeineMilligrams != nil
            || nutrition.alcoholUnits != nil
            || nutrition.qualityScore != nil
    }

    private var nutritionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nutrition")
                    .lifeOSTypography(.pageTitle)
                Text("Meals, macros, quality, and energy for \(selectedDate.fitnessDayLabel)")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(sourceStatus == .demo ? "Fixture values" : sourceStatus.label)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .accessibilityLabel("Nutrition data status")
                    .accessibilityValue(sourceStatus == .demo ? "Demo, not live" : sourceStatus.label)
                Menu {
                    ForEach(FitnessFoodCaptureMethod.allCases) { method in
                        Button {
                            onCapture(method)
                        } label: {
                            Label(method.rawValue, systemImage: method.systemImage)
                        }
                    }
                } label: {
                    Label("Add meal", systemImage: "plus")
                        .lifeOSTypography(.button)
                }
                .buttonStyle(LifeOSButtonStyle(.primary))
                .accessibilityIdentifier("nutrition-add-meal-header")
            }
        }
    }
}

private struct FitnessNutritionEmptyState: View {
    let onAddMeal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LifeOSIcon(.grocery)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("No meals logged")
                    .lifeOSTypography(.cardTitle)
                Text("Add a confirmed meal to start the selected day. No intake or energy value is inferred from the empty log.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add meal", action: onAddMeal)
                .buttonStyle(LifeOSButtonStyle(.secondary))
        }
        .padding(14)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-nutrition-empty-state")
    }
}

private struct FitnessNutritionHeroCard: View {
    let nutrition: FitnessNutritionSnapshot
    let isDemo: Bool
    let selectedDate: Date

    var body: some View {
        NutritionSurfaceCard(accent: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Calendar.current.isDateInToday(selectedDate) ? "Today" : selectedDate.fitnessDayLabel)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(nutrition.caloriesConsumed.map(String.init) ?? "—")
                            .lifeOSTypography(.metric)
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(Color.lifeOSTasksOrange)
                            .allowsTightening(true)
                            .layoutPriority(2)
                        Text("kcal eaten")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Text(protocolCaloriesLabel)
                        .lifeOSTypography(.body, weight: .medium)
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isDemo ? "Fixture values · not live" : provenanceLabel)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            FitnessNutritionSummaryRail(nutrition: nutrition)
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

private struct NutritionActionLabel: View {
    let title: String
    let icon: LifeOSIconName

    var body: some View {
        HStack(spacing: 6) {
            LifeOSIcon(icon).frame(width: 14, height: 14)
            Text(title).lifeOSTypography(.body, weight: .semibold)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                NutritionSummaryValue(title: "Protocol", value: nutrition.calorieTarget.map { "\($0)" } ?? "—", detail: "kcal goal", hue: .blue)
                Divider().frame(height: 42)
                NutritionSummaryValue(title: "Remaining", value: remainingValue, detail: "kcal", hue: .green)
                Divider().frame(height: 42)
                NutritionSummaryValue(title: "Burned", value: nutrition.sourceSupportedExpenditure.map(String.init) ?? "—", detail: "source kcal", hue: .orange)
            }
            VStack(alignment: .leading, spacing: 0) {
                NutritionSummaryValue(title: "Protocol", value: nutrition.calorieTarget.map { "\($0)" } ?? "—", detail: "kcal goal", hue: .blue)
                Divider()
                NutritionSummaryValue(title: "Remaining", value: remainingValue, detail: "kcal", hue: .green)
                Divider()
                NutritionSummaryValue(title: "Burned", value: nutrition.sourceSupportedExpenditure.map(String.init) ?? "—", detail: "source kcal", hue: .orange)
            }
        }
        .padding(.vertical, 2)
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
                Circle().fill(hue.base).frame(width: 6, height: 6)
                Text(title).lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText).lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    valueText
                    detailText
                }
                VStack(alignment: .leading, spacing: 1) {
                    valueText
                    detailText
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private var valueText: some View {
        Text(value)
            .lifeOSTypography(.body, weight: .semibold)
            .monospacedDigit()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var detailText: some View {
        Text(detail)
            .lifeOSTypography(.metadata)
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        macroHeading
                        Spacer(minLength: 8)
                        macroDisplayToggle
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        macroHeading
                        macroDisplayToggle
                    }
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
        let order = ["Protein", "Carbs", "Carbohydrates", "Fat"]
        var ordered: [FitnessMacroValue] = []
        ordered.reserveCapacity(macros.count)
        for name in order {
            ordered.append(contentsOf: macros.filter { $0.name == name })
        }
        ordered.append(contentsOf: macros.filter { !order.contains($0.name) })
        return ordered
    }

    private var macroHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Calories & macros")
                .lifeOSTypography(.sectionTitle)
            Text("Goals are user preferences; missing inputs stay unavailable")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }

    private var macroDisplayToggle: some View {
        NutritionMacroDisplayToggle(display: $display)
            .frame(width: 140)
            .accessibilityIdentifier("nutrition-macro-display")
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
                        .lifeOSTypography(.body, weight: .semibold)
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
    case "protein": LifeOSTokens.Module.business
    case "carbs", "carbohydrates": LifeOSTokens.Module.fitness
    case "fat": LifeOSTokens.secondaryText
    default: LifeOSTokens.secondaryText
    }
}

private struct NutritionMacroDotRow: View {
    let macro: FitnessMacroValue
    let display: NutritionMacroDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(macro.name).lifeOSTypography(.body, weight: .semibold)
                Spacer(minLength: 6)
                Text(displayValue).lifeOSTypography(.body, weight: .semibold).monospacedDigit()
                if let target = macro.target {
                    Text("Target \(target.formatted(.number.precision(.fractionLength(0)))) \(macro.unit)")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            if ratio != nil {
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
            Text(macro.value == nil ? "Observation unavailable" : (macro.target == nil ? "Recorded · target unavailable" : "Recorded · compared with target"))
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .padding(10)
        .background(LifeOSTokens.screenCanvas.opacity(0.32), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }

    private var ratio: Double? {
        guard let value = macro.value, let target = macro.target, target > 0 else { return nil }
        let ratio = value / target
        return ratio.isFinite && (ratio * 100).isFinite ? ratio : nil
    }

    private var filledDots: Int { Int((min(ratio ?? 0, 1) * 10).rounded(.down)) }

    private var displayValue: String {
        guard let value = macro.value else { return "Unavailable" }
        switch display {
        case .grams: return "\(value.formatted(.number.precision(.fractionLength(0)))) \(macro.unit)"
        case .percent:
            guard let ratio else { return "\(value.formatted(.number.precision(.fractionLength(0)))) \(macro.unit)" }
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
                                .lifeOSTypography(.sectionTitle)
                            Text("Eaten minus burned · a calculation, not a direct measurement")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        LifeOSIcon(.chevronRight).frame(width: 13, height: 13)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(balanceLabel)
                            .lifeOSTypography(.sectionTitle, weight: .bold)
                            .monospacedDigit()
                        Text("kcal balance")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    NutritionEnergyScale(eaten: nutrition.caloriesConsumed, burned: nutrition.sourceSupportedExpenditure)
                    HStack(spacing: 14) {
                        NutritionEnergyFact(title: "Eaten", value: nutrition.caloriesConsumed, hue: .green)
                        NutritionEnergyFact(title: "Burned", value: nutrition.sourceSupportedExpenditure, hue: .orange)
                        Spacer()
                    }
                    Text(provenance)
                        .lifeOSTypography(.metadata)
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
                .lifeOSTypography(.metadata)
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
                                .lifeOSTypography(.sectionTitle)
                            Text("Transparent inputs only · no proprietary formula is reproduced")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        Spacer()
                        Text(score.map { "\($0)/100" } ?? "Locked")
                            .lifeOSTypography(.body, weight: .semibold)
                            .foregroundStyle(score == nil ? LifeOSTokens.warning : LifeOSTokens.success)
                        LifeOSIcon(.chevronRight).frame(width: 13, height: 13)
                    }
                    NutritionAdaptiveGrid {
                        ForEach(categories, id: \.0) { category, hue in
                            let contribution = contributionByTitle[category.lowercased()]
                            NutritionContributionCell(category: category, hue: contribution?.hue ?? hue, value: contribution?.value, detail: contribution?.detail)
                        }
                    }
                    Text(score == nil ? "Quality is unavailable until user-recorded food-quality inputs exist." : (detail ?? "User-recorded inputs"))
                        .lifeOSTypography(.metadata)
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

    private var contributionByTitle: [String: FitnessNutritionQualityContribution] {
        Dictionary(uniqueKeysWithValues: contributions.map { ($0.title.lowercased(), $0) })
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
                Circle().fill(value == nil ? LifeOSTokens.tertiaryText : hue.base).frame(width: 6, height: 6)
                Text(category).lifeOSTypography(.metadata).lineLimit(1)
            }
            if let value {
                ProgressView(value: value)
                    .tint(hue.base)
                Text("\((value * 100).formatted(.number.precision(.fractionLength(0))))%")
                    .lifeOSTypography(.body, weight: .semibold).monospacedDigit()
                Text(detail ?? "Recorded input")
                    .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                Text("Unavailable")
                    .lifeOSTypography(.body, weight: .semibold)
                Text("No recorded input")
                    .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
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
                    .lifeOSTypography(.body, weight: .semibold)
                Text("Unavailable · no validated glucose source connected")
                    .lifeOSTypography(.metadata)
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
    @State private var visibleMealCount = 100

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
                            .lifeOSTypography(.sectionTitle)
                        Text("Empty, proposed, and confirmed records remain distinct")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer()
                    Button(action: onAdd) {
                        Label("Add meal", systemImage: "plus")
                            .lifeOSTypography(.body, weight: .semibold)
                    }
                    .buttonStyle(LifeOSButtonStyle(.secondary))
                    .accessibilityIdentifier("nutrition-add-meal")
                }
                if meals.isEmpty {
                    FitnessEmptyRow(title: "No meals recorded", detail: "No entry is different from zero consumption.", icon: .grocery)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleMeals) { meal in
                            FitnessNutritionMealRow(
                                meal: meal,
                                isDurable: isDurable(meal),
                                onEdit: { onEdit(meal) },
                                onDelete: { onDelete(meal) },
                                onReview: { onReview(meal) }
                            )
                        }
                    }
                    if meals.count > visibleMeals.count {
                        Button("Show all \(meals.count) meals") {
                            visibleMealCount = meals.count
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LifeOSTokens.accent)
                        .lifeOSTypography(.body, weight: .semibold)
                    }
                    FitnessNutritionMealDailyTotalsRow(meals: meals)
                }
            }
        }
        .accessibilityIdentifier("fitness-nutrition-meal-timeline")
        .onChange(of: meals.map(\.id)) { _, _ in
            visibleMealCount = min(100, meals.count)
        }
    }

    private var visibleMeals: [FitnessMeal] {
        Array(meals.prefix(visibleMealCount))
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
                .lifeOSTypography(.body, weight: .semibold)
                .monospacedDigit()
            Text(label)
                .lifeOSTypography(.metadata)
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
                Text(meal.name).lifeOSTypography(.body, weight: .semibold).lineLimit(2)
                Text("\(meal.source.rawValue) · \(meal.time.fitnessTimeLabel)")
                    .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
                Text(meal.detail)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(meal.source == .proposal ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 4) {
                Text(meal.calories.map { "\($0) kcal" } ?? "—")
                    .lifeOSTypography(.body, weight: .semibold).monospacedDigit()
                if meal.source == .proposal {
                    Button("Review", action: onReview)
                        .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.accent).buttonStyle(.plain)
                } else if isDurable {
                    HStack(spacing: 10) {
                        Button("Edit", action: onEdit)
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.accent).buttonStyle(.plain)
                        Button("Delete", role: .destructive, action: onDelete)
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.warning).buttonStyle(.plain)
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
                            .lifeOSTypography(.sectionTitle)
                        Text("Each metric keeps its own source and availability")
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
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
            Text(kind.rawValue).lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText).lineLimit(2)
            Text(value).lifeOSTypography(.body, weight: .semibold).monospacedDigit()
            Text(available ? "Selected-day input" : "Unavailable · source required")
                .lifeOSTypography(.metadata)
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .overlay(LifeOSTokens.cardShape.stroke(hovering ? accent.base.opacity(0.38) : Color.clear, lineWidth: 1))
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .animation(LifeOSMotion.curve(for: .hover, reduceMotion: reduceMotion)?.animation, value: hovering)
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
                                    Text(meal.name).lifeOSTypography(.body, weight: .semibold)
                                    Text(meal.source.rawValue).lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
                                }
                                Spacer()
                                Text(meal.calories.map { "\($0) kcal" } ?? "—").lifeOSTypography(.metadata).monospacedDigit()
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    Text("Persistence and server sync are not connected in this build; this route does not imply a saved library.")
                        .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.warning)
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
                    Text("Edit targets").lifeOSTypography(.sectionTitle)
                    FitnessEditableField(title: "Calories (kcal)", text: $calorieText, numeric: true)
                    FitnessEditableField(title: "Protein (g)", text: $proteinText, numeric: true)
                    FitnessEditableField(title: "Carbs (g)", text: $carbText, numeric: true)
                    FitnessEditableField(title: "Fat (g)", text: $fatText, numeric: true)
                    if let saveError {
                        Text(saveError)
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let savedConfirmation {
                        Text(savedConfirmation)
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.success)
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
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isDemo {
                        Text("Fixture values · goal editing is disabled in demo mode.")
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Saving records a new dated goal; it takes effect today and applies until you set another.")
                            .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
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
            .lifeOSTypography(.body, weight: .medium)
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
        if var goal = currentGoal {
            goal.calorieTarget = goal.calorieTarget.flatMap { $0 >= 0 ? $0 : nil }
            goal.proteinGramsTarget = goal.proteinGramsTarget.flatMap { $0 >= 0 ? $0 : nil }
            goal.carbGramsTarget = goal.carbGramsTarget.flatMap { $0 >= 0 ? $0 : nil }
            goal.fatGramsTarget = goal.fatGramsTarget.flatMap { $0 >= 0 ? $0 : nil }
            if goal != currentGoal {
                saveError = "Stored targets contain invalid values. Review and correct them before saving."
            }
            currentGoal = goal
        }

    }

    private func saveGoal() {
        saveError = nil
        savedConfirmation = nil
        guard let goalStore else {
            saveError = "Local goal storage is unavailable. Nothing was saved."
            return
        }
        guard !isDemo else { return }
        let inputs = [calorieText, proteinText, carbText, fatText].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let targets = inputs.map(Int.init)
        guard zip(inputs, targets).allSatisfy({ text, target in
            text.isEmpty || (target.map { $0 >= 0 } ?? false)
        }) else {
            saveError = "Enter non-negative whole numbers, or leave a target blank. Nothing was saved."
            return
        }
        let goal = NutritionGoal(
            effectiveFrom: .now,
            calorieTarget: targets[0],
            proteinGramsTarget: targets[1],
            carbGramsTarget: targets[2],
            fatGramsTarget: targets[3]
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
            Text(title).lifeOSTypography(.body, weight: .medium)
            Spacer()
            Text(value ?? "Unavailable").lifeOSTypography(.body, weight: .semibold).monospacedDigit()
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
                    Text(balanceDetail).lifeOSTypography(.sectionTitle).monospacedDigit()
                    Text("Sign convention: eaten minus source-supported expenditure. The data remains unavailable until both observations exist.")
                        .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
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
                        .lifeOSTypography(.sectionTitle)
                    Text(detail ?? "Add transparent, user-recorded food-quality inputs to review this surface. No proprietary score is recreated.")
                        .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
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
                        .lifeOSTypography(.metadata).foregroundStyle(available ? LifeOSTokens.tertiaryText : LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Long-range charts appear only after a validated history exists. Missing days are not silently converted to zero.")
                        .lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
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
                            .lifeOSTypography(.sectionTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Food records are separate from supplement records")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer()
                    Text(nutrition.caloriesConsumed.map(String.init) ?? "—")
                        .lifeOSTypography(.sectionTitle, weight: .bold)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                    Text(nutrition.caloriesConsumed == nil ? "" : " kcal")
                        .lifeOSTypography(.metadata)
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
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Net energy = eaten minus source-supported expenditure. This is a calculation, not a direct measurement.")
                        .lifeOSTypography(.metadata)
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
            Circle().fill(hue.base).frame(width: 6, height: 6)
            Text(title).lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .lifeOSTypography(.body, weight: .semibold)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum FitnessFoodCaptureMethod: String, CaseIterable, Identifiable {
    case photo = "Photo meal"
    case manual = "Manual meal"
    case barcode = "Barcode / package"
    case recipe = "Recipe"
    case recent = "Recent / favorite"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .manual: "square.and.pencil"
        case .barcode: "barcode.viewfinder"
        case .recipe: "book"
        case .recent: "clock.arrow.circlepath"
        }
    }
}

private enum FitnessPhotoStage: String {
    case idle = "Ready"
    case manualEntry = "Manual entry"
    case needsConfirmation = "Needs confirmation"
    case edited = "Edited manual preview"
    case confirmed = "User confirmed"
}

/// The presenting nutrition flow owns one focus model for every editable meal
/// review.  The order is deliberately a data contract: it is also used when
/// validation returns focus to the first invalid field.
private enum FitnessNutritionReviewField: String, CaseIterable, Hashable, Identifiable {
    case mealName
    case loggedAt
    case calories
    case protein
    case carbohydrates
    case fat

    var id: String { "nutrition-review-field-\(rawValue)" }

    var label: String {
        switch self {
        case .mealName: return "Meal name"
        case .loggedAt: return "Logged at"
        case .calories: return "Calories"
        case .protein: return "Protein"
        case .carbohydrates: return "Carbohydrates"
        case .fat: return "Fat"
        }
    }

    var unit: String? {
        switch self {
        case .mealName, .loggedAt: return nil
        case .calories: return "kcal"
        case .protein, .carbohydrates, .fat: return "g"
        }
    }

    var isNumeric: Bool {
        switch self {
        case .mealName, .loggedAt: return false
        case .calories, .protein, .carbohydrates, .fat: return true
        }
    }

    var next: FitnessNutritionReviewField? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex < Self.allCases.endIndex ? Self.allCases[nextIndex] : nil
    }
}

/// The presenter owns this session so a dismissed review sheet does not own
/// the only copy of the user's edits.  `activeMeal` is the latest durable
/// revision; `previewMeal` is deliberately separate and never implies that a
/// write happened.
struct FitnessNutritionSaveReceipt: Equatable, Sendable {
    let mealID: UUID
    let revision: Int
    let fingerprint: String
}

struct FitnessNutritionDraft: Equatable, Sendable {
    let draftID: UUID
    var loggedAt: Date
    var timeZoneIdentifier: String
    var mealName: String
    var calories: String
    var protein: String
    var carbohydrates: String
    var fat: String
    var portionGrams: String
    var barcodeInput: String
    var barcodeProductName: String
    var barcodeCalories: String
    var barcodeProtein: String
    var barcodeCarbohydrates: String
    var barcodeFat: String
    var barcodeGrams: String
    var barcodeValuesEdited: Bool
    var barcodeBasis: NutritionBarcodeBasis
    var barcodeMealAt: String
    var activeMeal: NutritionMeal?
    var previewMeal: NutritionMeal?
    var durableReceipt: FitnessNutritionSaveReceipt?

    init(
        draftID: UUID = UUID(),
        loggedAt: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        mealName: String = "Meal",
        calories: String = "",
        protein: String = "",
        carbohydrates: String = "",
        fat: String = "",
        portionGrams: String = "",
        barcodeInput: String = "",
        barcodeProductName: String = "",
        barcodeCalories: String = "",
        barcodeProtein: String = "",
        barcodeCarbohydrates: String = "",
        barcodeFat: String = "",
        barcodeGrams: String = "",
        barcodeValuesEdited: Bool = false,
        barcodeBasis: NutritionBarcodeBasis = .perServing,
        barcodeMealAt: String = "",
        activeMeal: NutritionMeal? = nil,
        previewMeal: NutritionMeal? = nil,
        durableReceipt: FitnessNutritionSaveReceipt? = nil
    ) {
        self.draftID = draftID
        self.loggedAt = loggedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.mealName = mealName
        self.calories = calories
        self.protein = protein
        self.carbohydrates = carbohydrates
        self.fat = fat
        self.portionGrams = portionGrams
        self.barcodeInput = barcodeInput
        self.barcodeProductName = barcodeProductName
        self.barcodeCalories = barcodeCalories
        self.barcodeProtein = barcodeProtein
        self.barcodeCarbohydrates = barcodeCarbohydrates
        self.barcodeFat = barcodeFat
        self.barcodeGrams = barcodeGrams
        self.barcodeValuesEdited = barcodeValuesEdited
        self.barcodeBasis = barcodeBasis
        self.barcodeMealAt = barcodeMealAt
        self.activeMeal = activeMeal
        self.previewMeal = previewMeal
        self.durableReceipt = durableReceipt
    }

    static func new(selectedDate: Date, calendar: Calendar = .current) -> FitnessNutritionDraft {
        let day = calendar.startOfDay(for: selectedDate)
        let loggedAt = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? selectedDate
        return FitnessNutritionDraft(
            loggedAt: loggedAt,
            timeZoneIdentifier: TimeZone.current.identifier,
            barcodeMealAt: ISO8601DateFormatter().string(from: loggedAt)
        )
    }

    static func editing(_ meal: NutritionMeal) -> FitnessNutritionDraft {
        FitnessNutritionDraft(
            draftID: meal.id,
            loggedAt: meal.loggedAt,
            timeZoneIdentifier: meal.timeZoneIdentifier ?? TimeZone.current.identifier,
            mealName: meal.name,
            calories: meal.kcal.map(String.init) ?? "",
            protein: meal.proteinGrams.map(String.init) ?? "",
            carbohydrates: meal.carbGrams.map(String.init) ?? "",
            fat: meal.fatGrams.map(String.init) ?? "",
            portionGrams: meal.portionGrams.map { String($0) } ?? "",
            activeMeal: meal
        )
    }

    var fingerprint: String {
        Self.fingerprint(
            loggedAt: loggedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            name: mealName,
            calories: calories,
            protein: protein,
            carbohydrates: carbohydrates,
            fat: fat,
            portionGrams: portionGrams
        )
    }

    var isDurablyCurrent: Bool {
        guard let durableReceipt, let activeMeal else { return false }
        return durableReceipt.mealID == activeMeal.id
            && durableReceipt.revision == activeMeal.revision
            && durableReceipt.fingerprint == fingerprint
    }

    var isDirty: Bool {
        if let activeMeal {
            return fingerprint != Self.fingerprint(for: activeMeal)
        }
        return mealName != "Meal"
            || !calories.isEmpty
            || !protein.isEmpty
            || !carbohydrates.isEmpty
            || !fat.isEmpty
            || !portionGrams.isEmpty
            || !barcodeInput.isEmpty
            || !barcodeProductName.isEmpty
            || !barcodeCalories.isEmpty
            || !barcodeProtein.isEmpty
            || !barcodeCarbohydrates.isEmpty
            || !barcodeFat.isEmpty
            || !barcodeGrams.isEmpty
    }

    mutating func applyLocalPreview() throws -> NutritionMeal {
        let meal = try validatedMeal(createdAt: activeMeal?.createdAt ?? .now)
        try meal.validateForPersistence()
        previewMeal = meal
        return meal
    }

    func validatedMeal(createdAt: Date = .now) throws -> NutritionMeal {
        let trimmedName = mealName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw NutritionValidationError.invalidText("mealName") }

        let kcal = NutritionBarcodeValueParser.parse(calories, maximum: 5_000)
        let proteinGrams = NutritionBarcodeValueParser.parse(protein, maximum: 2_000)
        let carbGrams = NutritionBarcodeValueParser.parse(carbohydrates, maximum: 2_000)
        let fatGrams = NutritionBarcodeValueParser.parse(fat, maximum: 2_000)
        let portion = NutritionBarcodeValueParser.parse(portionGrams, maximum: 1_000_000)
        let rawInputs = [calories, protein, carbohydrates, fat, portionGrams]
        let parsedValues: [Double?] = [kcal, proteinGrams, carbGrams, fatGrams, portion]
        guard zip(rawInputs, parsedValues).allSatisfy({ raw, value in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value != nil
        }) else {
            throw NutritionValidationError.invalidBounds("nutrition values")
        }

        let original = activeMeal
        let hasPortion = !portionGrams.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let resolvedPortion = hasPortion ? portion : nil
        return NutritionMeal(
            id: original?.id ?? draftID,
            loggedAt: loggedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            name: trimmedName,
            kcal: kcal.map { Int($0.rounded()) },
            proteinGrams: proteinGrams.map { Int($0.rounded()) },
            carbGrams: carbGrams.map { Int($0.rounded()) },
            fatGrams: fatGrams.map { Int($0.rounded()) },
            portionGrams: resolvedPortion,
            portionUnit: resolvedPortion == nil ? nil : (original?.portionUnit ?? .g),
            journalNote: original?.journalNote,
            provenance: original?.provenance ?? .manual,
            createdAt: createdAt,
            revision: original?.revision ?? 1,
            supersedesID: original?.supersedesID,
            photoLineage: original?.photoLineage
        )
    }

    mutating func markDurablySaved(_ meal: NutritionMeal) {
        activeMeal = meal
        previewMeal = nil
        durableReceipt = FitnessNutritionSaveReceipt(
            mealID: meal.id,
            revision: meal.revision,
            fingerprint: Self.fingerprint(for: meal)
        )
    }

    static func fingerprint(for meal: NutritionMeal) -> String {
        fingerprint(
            loggedAt: meal.loggedAt,
            timeZoneIdentifier: meal.timeZoneIdentifier ?? "",
            name: meal.name,
            calories: meal.kcal.map(String.init) ?? "",
            protein: meal.proteinGrams.map(String.init) ?? "",
            carbohydrates: meal.carbGrams.map(String.init) ?? "",
            fat: meal.fatGrams.map(String.init) ?? "",
            portionGrams: meal.portionGrams.map { String($0) } ?? ""
        )
    }

    private static func fingerprint(
        loggedAt: Date,
        timeZoneIdentifier: String,
        name: String,
        calories: String,
        protein: String,
        carbohydrates: String,
        fat: String,
        portionGrams: String
    ) -> String {
        [
            String(loggedAt.timeIntervalSinceReferenceDate),
            timeZoneIdentifier,
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            canonicalNumber(calories, integer: true),
            canonicalNumber(protein, integer: true),
            canonicalNumber(carbohydrates, integer: true),
            canonicalNumber(fat, integer: true),
            canonicalNumber(portionGrams, integer: false)
        ].joined(separator: "\u{1F}")
    }

    private static func canonicalNumber(_ raw: String, integer: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = NutritionBarcodeValueParser.parse(trimmed, maximum: 1_000_000) else {
            return trimmed
        }
        return integer ? String(Int(value.rounded())) : String(value)
    }

    static func == (lhs: FitnessNutritionDraft, rhs: FitnessNutritionDraft) -> Bool {
        lhs.draftID == rhs.draftID
            && lhs.loggedAt == rhs.loggedAt
            && lhs.timeZoneIdentifier == rhs.timeZoneIdentifier
            && lhs.mealName == rhs.mealName
            && lhs.calories == rhs.calories
            && lhs.protein == rhs.protein
            && lhs.carbohydrates == rhs.carbohydrates
            && lhs.fat == rhs.fat
            && lhs.portionGrams == rhs.portionGrams
            && lhs.barcodeInput == rhs.barcodeInput
            && lhs.barcodeProductName == rhs.barcodeProductName
            && lhs.barcodeCalories == rhs.barcodeCalories
            && lhs.barcodeProtein == rhs.barcodeProtein
            && lhs.barcodeCarbohydrates == rhs.barcodeCarbohydrates
            && lhs.barcodeFat == rhs.barcodeFat
            && lhs.barcodeGrams == rhs.barcodeGrams
            && lhs.barcodeValuesEdited == rhs.barcodeValuesEdited
            && lhs.barcodeBasis.rawValue == rhs.barcodeBasis.rawValue
            && lhs.barcodeMealAt == rhs.barcodeMealAt
            && lhs.activeMeal == rhs.activeMeal
            && lhs.previewMeal == rhs.previewMeal
            && lhs.durableReceipt == rhs.durableReceipt
    }
}

/// Pure presentation-flow rules shared by the presenter and its focused tests.
/// A dirty draft or an in-memory preview survives a sheet dismissal and the
/// next presentation. Starting over is an explicit discard action.
enum FitnessNutritionDraftFlow {
    static func startNew(selectedDate: Date, calendar: Calendar = .current) -> FitnessNutritionDraft {
        FitnessNutritionDraft.new(selectedDate: selectedDate, calendar: calendar)
    }

    static func reopenOrStart(
        current: FitnessNutritionDraft,
        selectedDate: Date,
        calendar: Calendar = .current
    ) -> FitnessNutritionDraft {
        current.isDirty || current.previewMeal != nil
            ? current
            : startNew(selectedDate: selectedDate, calendar: calendar)
    }

    static func discard(selectedDate: Date, calendar: Calendar = .current) -> FitnessNutritionDraft {
        startNew(selectedDate: selectedDate, calendar: calendar)
    }
}

/// Store boundary for a manual draft. It is idempotent for a repeated tap,
/// keeps the returned correction revision active, and reconciles a write whose
/// result was uncertain by looking for the exact durable candidate.
enum FitnessNutritionDurableSave {
    @discardableResult
    static func save(
        draft: inout FitnessNutritionDraft,
        to store: NutritionMealStore,
        now: Date = .now
    ) throws -> NutritionMeal {
        let candidate = try draft.validatedMeal(createdAt: now)
        if draft.isDurablyCurrent, let activeMeal = draft.activeMeal {
            return activeMeal
        }

        do {
            let saved: NutritionMeal
            if let activeMeal = draft.activeMeal {
                saved = try store.correct(id: activeMeal.id, now: now) { meal in
                    meal.loggedAt = candidate.loggedAt
                    meal.timeZoneIdentifier = candidate.timeZoneIdentifier
                    meal.name = candidate.name
                    meal.kcal = candidate.kcal
                    meal.proteinGrams = candidate.proteinGrams
                    meal.carbGrams = candidate.carbGrams
                    meal.fatGrams = candidate.fatGrams
                    meal.portionGrams = candidate.portionGrams
                    meal.portionUnit = candidate.portionUnit
                    meal.journalNote = candidate.journalNote
                }
            } else {
                try store.addConfirmed(candidate)
                saved = candidate
            }
            draft.markDurablySaved(saved)
            return saved
        } catch {
            if let reconciled = try reconcile(draft: draft, candidate: candidate, store: store) {
                draft.markDurablySaved(reconciled)
                return reconciled
            }
            throw error
        }
    }

    static func reconcile(
        draft: FitnessNutritionDraft,
        candidate: NutritionMeal,
        store: NutritionMealStore
    ) throws -> NutritionMeal? {
        let meals = try store.load()
        let candidateFingerprint = FitnessNutritionDraft.fingerprint(for: candidate)
        if let activeMeal = draft.activeMeal {
            return meals.first {
                !$0.isDeleted
                    && $0.supersedesID == activeMeal.id
                    && FitnessNutritionDraft.fingerprint(for: $0) == candidateFingerprint
            }
        }
        return meals.first {
            !$0.isDeleted
                && $0.id == draft.draftID
                && FitnessNutritionDraft.fingerprint(for: $0) == candidateFingerprint
        }
    }
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

/// Identifies one photo-analysis request across selection, transport, and
/// editable draft changes. Cancellation is only an optimization: a response
/// must still match all captured identity fields before it can touch review
/// state.
struct FitnessFoodPhotoAnalysisRequest: Equatable, Sendable {
    let selectionGeneration: Int
    let requestID: String
    let draftRevision: String

    func matchesSelection(generation: Int, requestID: String) -> Bool {
        selectionGeneration == generation && self.requestID == requestID
    }

    func canAdopt(
        generation: Int,
        requestID: String,
        draftRevision: String
    ) -> Bool {
        matchesSelection(generation: generation, requestID: requestID)
            && self.draftRevision == draftRevision
    }
}

/// Small deterministic state seam for the photo proposal race. Replacing an
/// active request invalidates its cleanup as well as its result, so a late
/// completion cannot clear a newer request's loading state.
struct FitnessFoodPhotoAnalysisCoordinator: Equatable, Sendable {
    private(set) var selectionGeneration = 0
    private(set) var activeRequest: FitnessFoodPhotoAnalysisRequest?

    mutating func selectionChanged() {
        selectionGeneration &+= 1
        activeRequest = nil
    }

    mutating func invalidateAnalysis() {
        activeRequest = nil
    }

    mutating func beginAnalysis(
        requestID: String,
        draftRevision: String
    ) -> FitnessFoodPhotoAnalysisRequest {
        let request = FitnessFoodPhotoAnalysisRequest(
            selectionGeneration: selectionGeneration,
            requestID: requestID,
            draftRevision: draftRevision
        )
        activeRequest = request
        return request
    }

    func canAdopt(
        _ request: FitnessFoodPhotoAnalysisRequest,
        currentRequestID: String,
        currentDraftRevision: String
    ) -> Bool {
        activeRequest == request
            && request.canAdopt(
                generation: selectionGeneration,
                requestID: currentRequestID,
                draftRevision: currentDraftRevision
            )
    }

    func ownsCleanup(
        _ request: FitnessFoodPhotoAnalysisRequest,
        currentRequestID: String,
        currentDraftRevision: String
    ) -> Bool {
        activeRequest == request
            && request.canAdopt(
                generation: selectionGeneration,
                requestID: currentRequestID,
                draftRevision: currentDraftRevision
            )
    }

    @discardableResult
    mutating func finish(
        _ request: FitnessFoodPhotoAnalysisRequest,
        currentRequestID: String,
        currentDraftRevision: String
    ) -> Bool {
        guard ownsCleanup(
            request,
            currentRequestID: currentRequestID,
            currentDraftRevision: currentDraftRevision
        ) else { return false }
        activeRequest = nil
        return true
    }
}

private struct FitnessFoodReviewSheet: View {
    let method: FitnessFoodCaptureMethod
    let action: FitnessNutritionCaptureAction?
    @Binding var stage: FitnessPhotoStage
    let isDemo: Bool
    let nutritionRecordStore: NutritionRecordStore
    let nutritionMealStore: NutritionMealStore?
    @Binding var draft: FitnessNutritionDraft
    let onDiscardDraft: () -> Void
    let onKeepManualOnly: () -> Void
    let onBarcodeSaved: () -> Void
    let onMealSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: FitnessNutritionReviewField?
    @State private var showingDismissPrompt = false
    @State private var validationErrors: [FitnessNutritionReviewField: String] = [:]
    @State private var pendingScrollField: FitnessNutritionReviewField?
    @StateObject private var photoPreparation = FoodPhotoPreparationCoordinator()
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAnalysisCoordinator = FitnessFoodPhotoAnalysisCoordinator()
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoProposalTask: Task<Void, Never>?
    @State private var photoProposal: FoodEstimateProposal?
    @State private var photoProposalRequest: FitnessFoodPhotoAnalysisRequest?
    @State private var photoProposalLoading = false
    @State private var photoProposalError: String?
    @State private var photoConfirmationAcknowledged = false
    @State private var photoMealSaved = false
    @State private var photoMealID = "photo-meal-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    @State private var photoRequestID = "photo-request-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    @State private var savedMessage: String?
    @State private var mealSaveError: String?
    @State private var mealSaving = false
    @State private var barcodeLookup: NutritionBarcodeLookup?
    @State private var barcodeProposal: NutritionBarcodeProposal?
    @State private var barcodeLoading = false
    @State private var barcodeError: String?
    @State private var confirmedBarcodeRecord: NutritionRecord?
    @State private var barcodeSaving = false
    @State private var barcodeLookupTask: Task<Void, Never>?
    @State private var barcodeRequestGate = NutritionBarcodeRequestGate()
    @State private var barcodeProposalToken: NutritionBarcodeRequestToken?
#if os(iOS)
    @StateObject private var barcodeScanner = NutritionBarcodeScannerCoordinator()
#endif
    private let barcodeClient = TailscaleSyncClient()

    private var reviewTitle: String {
        switch method {
        case .photo:
            return isDemo ? "Photo proposal" : "Photo meal"
        case .manual:
            return draft.activeMeal == nil ? "New meal" : "Edit meal"
        case .barcode:
            return "Package meal"
        case .recipe:
            return "Recipe meal"
        case .recent:
            return "Recent meal"
        }
    }

    private var reviewSubtitle: String {
        switch method {
        case .photo:
            return isDemo ? "Fixture values for visual review" : "Review an estimate before saving it locally"
        case .manual:
            return "Record the meal and when it was logged"
        case .barcode:
            return "Review provider values before saving locally"
        case .recipe, .recent:
            return "Review the meal details before saving locally"
        }
    }

    private var draftCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let timeZone = TimeZone(identifier: draft.timeZoneIdentifier) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reviewTitle)
                                .lifeOSTypography(.sectionTitle)
                            Text(reviewSubtitle)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let action, method != .photo {
                            disconnectedActionNotice(action)
                        }
                        if method == .photo {
                            photoPrivacyStatus
                        }
                        if method == .photo {
                            photoPreparationCard
                            photoProposalCard
                            if isDemo {
                                demoProposalFields
                            }
                        } else if method == .barcode {
                            barcodeReviewFields
                        } else {
                            manualPreviewFields
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
#if os(iOS)
                .scrollDismissesKeyboard(.interactively)
#endif
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sheetFooter
                }
                .onChange(of: pendingScrollField) { _, field in
                    guard let field else { return }
                    scrollProxy.scrollTo(field.id, anchor: .center)
                    pendingScrollField = nil
                }
                .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { requestDismissal() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(draft.isDirty)
#if os(iOS)
        .background(
            FitnessNutritionDismissBridge(
                isDirty: draft.isDirty,
                onAttempt: requestDismissal
            )
            .frame(width: 0, height: 0)
        )
#endif
        .confirmationDialog("Unsaved meal draft", isPresented: $showingDismissPrompt) {
            Button("Discard changes", role: .destructive) { onDiscardDraft() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Your edits are still in this draft. Keep editing to stay here, or discard them explicitly.")
        }
        .onAppear { prepareDraftForPresentation() }
#if os(macOS)
        .onExitCommand { requestDismissal() }
#endif
        .onDisappear {
#if os(iOS)
            barcodeScanner.stop()
#endif
            cancelBarcodeLookup()
            invalidatePhotoAnalysis(forSelectionChange: true)
            photoLoadTask?.cancel()
            photoLoadTask = nil
            photoPreparation.clear()
            selectedPhotoItems.removeAll()
        }
        .onChange(of: draft.barcodeInput) { _, newValue in
            guard barcodeRequestGate.invalidateIfVisibleInputChanged(newValue) else { return }
            barcodeLookupTask?.cancel()
            barcodeLookupTask = nil
            barcodeLoading = false
            barcodeLookup = nil
            barcodeProposal = nil
            barcodeProposalToken = nil
            confirmedBarcodeRecord = nil
            barcodeError = nil
            draft.barcodeValuesEdited = false
        }
        .onChange(of: draft.fingerprint) { _, newRevision in
            if method == .photo {
                if let request = photoAnalysisCoordinator.activeRequest,
                   request.draftRevision != newRevision {
                    invalidatePhotoAnalysis()
                }
                return
            }
            draft.previewMeal = nil
            savedMessage = nil
            mealSaveError = nil
            if stage == .confirmed { stage = .edited }
        }
    }

    private var mealSavedDurably: Bool {
        draft.isDurablyCurrent
    }

    private var photoProposalIsCurrent: Bool {
        guard let request = photoProposalRequest else { return false }
        return request.matchesSelection(
            generation: photoAnalysisCoordinator.selectionGeneration,
            requestID: photoRequestID
        )
    }

    private func makePhotoRequestID() -> String {
        "photo-request-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private func invalidatePhotoAnalysis(forSelectionChange: Bool = false) {
        if forSelectionChange {
            photoAnalysisCoordinator.selectionChanged()
            photoRequestID = makePhotoRequestID()
        } else {
            photoAnalysisCoordinator.invalidateAnalysis()
        }
        photoProposalTask?.cancel()
        photoProposalTask = nil
        photoProposal = nil
        photoProposalRequest = nil
        photoProposalError = nil
        photoProposalLoading = false
        photoConfirmationAcknowledged = false
    }

    private func reviewTextBinding(for field: FitnessNutritionReviewField) -> Binding<String> {
        Binding(
            get: {
                switch field {
                case .mealName: return draft.mealName
                case .loggedAt: return ""
                case .calories: return draft.calories
                case .protein: return draft.protein
                case .carbohydrates: return draft.carbohydrates
                case .fat: return draft.fat
                }
            },
            set: { value in
                switch field {
                case .mealName: draft.mealName = value
                case .loggedAt: break
                case .calories: draft.calories = value
                case .protein: draft.protein = value
                case .carbohydrates: draft.carbohydrates = value
                case .fat: draft.fat = value
                }
                clearReviewFeedback(for: field)
            }
        )
    }

    private func clearReviewFeedback(for field: FitnessNutritionReviewField) {
        validationErrors[field] = nil
        savedMessage = nil
        mealSaveError = nil
    }

    private func reviewValidationErrors() -> [FitnessNutritionReviewField: String] {
        var errors: [FitnessNutritionReviewField: String] = [:]
        let trimmedName = draft.mealName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            errors[.mealName] = "Enter a meal name."
        } else if trimmedName.utf16.count > 200 {
            errors[.mealName] = "Use 200 characters or fewer."
        }

        if !draft.loggedAt.timeIntervalSinceReferenceDate.isFinite {
            errors[.loggedAt] = "Choose a valid date and time."
        }

        let numericFields: [(FitnessNutritionReviewField, String, Double)] = [
            (.calories, draft.calories, 5_000),
            (.protein, draft.protein, 2_000),
            (.carbohydrates, draft.carbohydrates, 2_000),
            (.fat, draft.fat, 2_000)
        ]
        for (field, rawValue, maximum) in numericFields {
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty,
                  NutritionBarcodeValueParser.parse(trimmedValue, maximum: maximum) == nil else { continue }
            errors[field] = "Enter 0–\(maximum.formatted(.number)); commas and dots are supported."
        }

        return errors
    }

    private var hasUnmappedReviewValidationError: Bool {
        let portion = draft.portionGrams.trimmingCharacters(in: .whitespacesAndNewlines)
        return !portion.isEmpty
            && NutritionBarcodeValueParser.parse(portion, maximum: 1_000_000) == nil
    }

    @discardableResult
    private func validateManualReview() -> Bool {
        let errors = reviewValidationErrors()
        validationErrors = errors
        guard errors.isEmpty, !hasUnmappedReviewValidationError else {
            savedMessage = nil
            mealSaveError = "Review the highlighted fields before saving."
            if let firstInvalid = FitnessNutritionReviewField.allCases.first(where: { errors[$0] != nil }) {
                focusedField = firstInvalid
                pendingScrollField = firstInvalid
            }
            return false
        }
        return true
    }

    private func advanceFocus(after field: FitnessNutritionReviewField) {
        if let next = field.next {
            focusedField = next
            pendingScrollField = next
        } else {
            focusedField = nil
        }
    }

    private func keepManualOnly() {
        invalidatePhotoAnalysis(forSelectionChange: true)
        photoLoadTask?.cancel()
        photoLoadTask = nil
        photoPreparation.clear()
        selectedPhotoItems.removeAll()
        stage = .manualEntry
        onKeepManualOnly()
    }

    private var photoPrivacyStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: photoProposal == nil ? "lock.shield" : "checkmark.shield")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(photoProposal == nil ? LifeOSTokens.accent : LifeOSTokens.success)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(photoPrivacyStatusTitle)
                    .lifeOSTypography(.label)
                Text(photoPrivacyStatusDetail)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.raised, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("food-photo-privacy-status")
    }

    private var photoPrivacyStatusTitle: String {
        if isDemo { return "Demo proposal · no photo was uploaded" }
        if photoProposal != nil { return "Proposal ready · review before saving" }
        if action == .camera { return "Camera capture is unavailable" }
        return "Photos stay private until you analyze them"
    }

    private var photoPrivacyStatusDetail: String {
        if isDemo {
            return "The fixture is editable for review; it is not a photo result."
        }
        if photoProposal != nil {
            return "The estimate is assistive. Edit the values and confirm them explicitly before a local meal is written."
        }
        if action == .camera {
            return "Camera capture is not connected in this build. Choose photos below instead."
        }
        return "Nothing leaves this device until you consent below and tap Analyze. Analysis returns a proposal, never a confirmed meal."
    }

    private func prepareDraftForPresentation() {
        if isDemo && method == .photo && draft.mealName == "Meal" {
            draft.mealName = "Photo proposal · needs review"
            draft.calories = "760"
            draft.protein = "51"
            draft.carbohydrates = "74"
            draft.fat = "30"
        }
        if method == .barcode, draft.barcodeMealAt.isEmpty {
            draft.barcodeMealAt = ISO8601DateFormatter().string(from: draft.loggedAt)
        }
    }

    @ViewBuilder
    private var sheetFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let savedMessage {
                Text(savedMessage)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let mealSaveError {
                Text(mealSaveError)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-meal-save-error")
            }
            if method == .photo {
                Text(photoSaveExplanation)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                photoFooterActions
            } else if method == .barcode {
                barcodeFooterActions
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        draftDiscardButton
                        Spacer(minLength: 0)
                        applyPreviewButton
                        saveMealButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            draftDiscardButton
                            Spacer(minLength: 0)
                            applyPreviewButton
                        }
                        saveMealButton
                            .frame(maxWidth: .infinity)
                    }
                }
                Text(nutritionMealStore == nil
                    ? "Local meal storage is unavailable. Nothing can be saved."
                    : "Save meal stores the edited values and local timestamp on this device.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(nutritionMealStore == nil ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(LifeOSTokens.surface.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LifeOSTokens.quietBorder)
                .frame(height: 0.75)
        }
    }

    @ViewBuilder
    private var photoFooterActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button("Close") { requestDismissal() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LifeOSTokens.accent)
                Button("Keep manual only") { keepManualOnly() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LifeOSTokens.accent)
                Spacer(minLength: 0)
                if photoProposalIsCurrent {
                    photoConfirmButton
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("Close") { requestDismissal() }
                        .buttonStyle(.plain)
                        .foregroundStyle(LifeOSTokens.accent)
                    Button("Keep manual only") { keepManualOnly() }
                        .buttonStyle(.plain)
                        .foregroundStyle(LifeOSTokens.accent)
                }
                if photoProposalIsCurrent {
                    photoConfirmButton
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var barcodeFooterActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                barcodeDiscardButton
                barcodeKeepEditingButton
                Spacer(minLength: 0)
                barcodeSaveButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    barcodeDiscardButton
                    barcodeKeepEditingButton
                }
                barcodeSaveButton
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var barcodeDiscardButton: some View {
        Button("Discard", role: .destructive) { onDiscardDraft() }
            .buttonStyle(.plain)
            .foregroundStyle(LifeOSTokens.danger)
    }

    private var barcodeKeepEditingButton: some View {
        Button("Keep editing") { showingDismissPrompt = false }
            .buttonStyle(.plain)
            .foregroundStyle(LifeOSTokens.accent)
    }

    private var barcodeSaveButton: some View {
        Button(
            savedMessage == nil
                ? ((confirmedBarcodeRecord == nil && barcodeError == nil) ? "Confirm and save locally" : "Retry local save")
                : "Saved locally"
        ) {
            confirmBarcodeProposal()
        }
        .buttonStyle(LifeOSButtonStyle(.primary))
        .disabled((barcodeProposal == nil && confirmedBarcodeRecord == nil) || !barcodeConfirmationIsCurrent || barcodeLoading || barcodeSaving || savedMessage != nil)
    }

    private var draftDiscardButton: some View {
        Button("Discard", role: .destructive) {
            onDiscardDraft()
        }
        .buttonStyle(.plain)
        .foregroundStyle(LifeOSTokens.danger)
    }

    private var applyPreviewButton: some View {
        Button("Apply local preview") {
            guard validateManualReview() else { return }
            do {
                _ = try draft.applyLocalPreview()
                stage = .edited
                savedMessage = "Preview updated. Not saved."
                mealSaveError = nil
            } catch {
                mealSaveError = nutritionDraftErrorMessage(error)
            }
        }
        .buttonStyle(LifeOSButtonStyle(.secondary))
    }

    private var saveMealButton: some View {
        Button(mealSaving ? "Saving…" : (mealSavedDurably ? "Saved locally" : "Save meal")) {
            saveMealDurably()
        }
        .buttonStyle(LifeOSButtonStyle(.primary))
        .disabled(mealSaving || mealSavedDurably || nutritionMealStore == nil)
        .accessibilityIdentifier("nutrition-meal-save")
    }

    private var photoSaveExplanation: String {
        guard photoProposal != nil else {
            return "Analyze a photo before confirming a meal."
        }
        return "Confirming stores only the reviewed values and source lineage locally; sanitized photo bytes are cleared after save."
    }

    private func previewSummary(_ meal: NutritionMeal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview applied · not saved")
                .lifeOSTypography(.label, weight: .semibold)
                .foregroundStyle(LifeOSTokens.Series.estimate)
            Text("\(meal.name) · \(meal.kcal.map(String.init) ?? "—") kcal · \(meal.loggedAt.fitnessDayLabel)")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.Series.estimate.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In-memory preview applied")
        .accessibilityValue("\(meal.name), \(meal.kcal.map(String.init) ?? "calories unavailable") kilocalories, \(meal.loggedAt.fitnessDayLabel)")
    }

    private func requestDismissal() {
        invalidatePhotoAnalysis(forSelectionChange: true)
        if draft.isDirty {
            showingDismissPrompt = true
        } else {
            dismiss()
        }
    }

    private var photoConfirmButton: some View {
        Button(photoMealSaved ? "Saved locally" : "Review & confirm meal locally") {
            confirmPhotoProposal()
        }
        .buttonStyle(LifeOSButtonStyle(.primary))
        .disabled(photoMealSaved || nutritionMealStore == nil || photoProposalLoading || !photoProposalIsCurrent || !photoConfirmationAcknowledged)
        .accessibilityIdentifier("food-photo-confirm")
    }

    private func disconnectedActionNotice(_ action: FitnessNutritionCaptureAction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(action.title)
                .lifeOSTypography(.sectionTitle)
            Text(action.detail)
                .lifeOSTypography(.metadata)
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
                    .lifeOSTypography(.sectionTitle)
                Text("Manual entry is always available. On iPhone, the permission-gated camera scanner captures one checksum-validated code; the Windows LifeOS gateway then performs the bounded read-only lookup.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
#if os(iOS)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Camera scanner")
                            .lifeOSTypography(.sectionTitle)
                        Spacer()
                        Button(barcodeScanner.state == .scanning ? "Stop camera" : "Scan barcode") {
                            if barcodeScanner.state == .scanning { barcodeScanner.stop() }
                            else { startBarcodeCamera() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(barcodeScanner.state == .denied || barcodeScanner.state == .unavailable)
                    }
                    Text(barcodeScannerStatus)
                        .lifeOSTypography(.metadata)
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
                    TextField("EAN-8, EAN-13, or UPC-A", text: $draft.barcodeInput)
                        .textFieldStyle(.roundedBorder)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .accessibilityIdentifier("nutrition-barcode-input")
                    Button(barcodeLoading ? "Looking up…" : "Look up") {
                        startBarcodeLookup()
                    }
                    .buttonStyle(LifeOSButtonStyle(.secondary))
                    .disabled(barcodeLoading || NutritionBarcodeNormalizer.normalize(draft.barcodeInput) == nil)
                    .accessibilityIdentifier("nutrition-barcode-lookup")
                }
                if let barcodeError {
                    Text(barcodeError)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nutrition-barcode-error")
                }
                if barcodeLoading {
                    ProgressView("Loading product proposal…")
                        .lifeOSTypography(.metadata)
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
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nutrition-barcode-not-found")
        case .unavailable(_, let reason, let retryAfterSeconds, _):
            let retryText = retryAfterSeconds.map { " Retry in \($0)s." } ?? ""
            Text("Lookup unavailable (\(reason.rawValue)).\(retryText) No product values are available.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nutrition-barcode-unavailable")
        case .found(let found):
            VStack(alignment: .leading, spacing: 8) {
                Text(found.nutritionState == .unreliable ? "Proposal · provider quality warning" : "Editable proposal")
                    .lifeOSTypography(.sectionTitle)
                    .foregroundStyle(found.nutritionState == .unreliable ? LifeOSTokens.warning : .primary)
                if found.nutritionState == .unreliable {
                    Text("Open Food Facts marked this product data as unreliable. Review every field before confirming.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if found.nutritionState == .partial {
                    Text("Some provider nutrients are missing. Missing values remain blank; LifeOS does not infer them.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if found.nutritionState == .unavailable {
                    Text("The product was found, but no valid kcal/macronutrient values were supplied.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Provider basis", selection: $draft.barcodeBasis) {
                    if found.per100g != nil { Text("Per 100 g").tag(NutritionBarcodeBasis.per100g) }
                    if found.perServing != nil { Text("Per serving").tag(NutritionBarcodeBasis.perServing) }
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.barcodeBasis) { _, basis in applyBarcodeBasis(basis, found: found) }
                .accessibilityIdentifier("nutrition-barcode-basis")
                FitnessEditableField(title: "Product name", text: $draft.barcodeProductName)
                FitnessEditableField(
                    title: draft.barcodeBasis == .per100g ? "Grams eaten (required)" : "Grams (optional)",
                    text: $draft.barcodeGrams,
                    numeric: true
                )
                    .onChange(of: draft.barcodeGrams) { _, _ in
                        applyBarcodeBasis(draft.barcodeBasis, found: found)
                    }
                Text(draft.barcodeBasis == .per100g
                    ? "Enter the grams you ate; the kcal and macros below scale from the provider's per-100-g values."
                    : "Grams are recorded as eaten amount. Per-serving values are not scaled unless the provider supplies a serving-weight conversion.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-grams-help")
                FitnessNutritionFormGrid(spacing: 16, forceSingleColumn: dynamicTypeSize.isAccessibilitySize) {
                    FitnessEditableField(title: "Calories (kcal)", text: barcodeCaloriesBinding, numeric: true)
                    FitnessEditableField(title: "Protein (g)", text: barcodeProteinBinding, numeric: true)
                    FitnessEditableField(title: "Carbohydrates (g)", text: barcodeCarbohydratesBinding, numeric: true)
                    FitnessEditableField(title: "Fat (g)", text: barcodeFatBinding, numeric: true)
                }
                Text(draft.barcodeValuesEdited
                    ? "Edited values will be saved exactly as entered after validation."
                    : "Provider values are scaled from the selected basis and grams when you confirm.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(draft.barcodeValuesEdited ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-edit-state")
                Text("Source: Open Food Facts · ODbL-1.0 database / DbCL-1.0 contents. Volunteer-sourced data is not guaranteed accurate, complete, or reliable.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nutrition-barcode-provenance")
            }
        }
    }

    private func startBarcodeLookup() {
        guard let normalized = NutritionBarcodeNormalizer.normalize(draft.barcodeInput) else {
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
        draft.barcodeInput = normalized
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
                      barcodeRequestGate.accepts(request, visibleInput: draft.barcodeInput) else { return }
                barcodeLoading = false
                barcodeLookupTask = nil
                applyBarcodeLookup(lookup, token: request)
            } catch let error as TailscaleSyncError {
                guard !Task.isCancelled,
                      barcodeRequestGate.accepts(request, visibleInput: draft.barcodeInput) else { return }
                barcodeLoading = false
                barcodeLookupTask = nil
                barcodeError = barcodeErrorMessage(error)
            } catch {
                guard !Task.isCancelled,
                      barcodeRequestGate.accepts(request, visibleInput: draft.barcodeInput) else { return }
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
            draft.barcodeInput = captured
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
            draft.barcodeProductName = found.product.name ?? ""
            if let values = found.perServing {
                draft.barcodeBasis = .perServing
                applyBarcodeValues(values)
            } else if let values = found.per100g {
                draft.barcodeBasis = .per100g
                applyBarcodeValues(values)
            } else {
                draft.barcodeBasis = .perServing
                draft.barcodeCalories = ""
                draft.barcodeProtein = ""
                draft.barcodeCarbohydrates = ""
                draft.barcodeFat = ""
                draft.barcodeValuesEdited = false
            }
        } catch {
            barcodeProposal = nil
            barcodeProposalToken = nil
            barcodeError = "The provider response could not be turned into an editable proposal."
        }
    }

    private func applyBarcodeValues(_ values: NutritionBarcodeMacros) {
        let displayedValues: NutritionBarcodeMacros
        if let proposal = barcodeProposal,
           let grams = NutritionBarcodeValueParser.parse(draft.barcodeGrams, maximum: 5_000),
           let canonical = try? NutritionBarcodeFlow.canonicalValues(
               for: proposal,
               basis: draft.barcodeBasis,
               grams: grams
           ) {
            displayedValues = canonical
        } else if draft.barcodeBasis == .per100g,
                  let grams = NutritionBarcodeValueParser.parse(draft.barcodeGrams, maximum: 5_000),
                  let scaled = try? values.scaledFromPer100g(forGrams: grams) {
            displayedValues = scaled
        } else {
            displayedValues = values
        }
        draft.barcodeCalories = displayedValues.kcal.map(formatNutritionValue) ?? ""
        draft.barcodeProtein = displayedValues.proteinGrams.map(formatNutritionValue) ?? ""
        draft.barcodeCarbohydrates = displayedValues.carbsGrams.map(formatNutritionValue) ?? ""
        draft.barcodeFat = displayedValues.fatGrams.map(formatNutritionValue) ?? ""
        draft.barcodeValuesEdited = false
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
              barcodeRequestGate.accepts(barcodeProposalToken, visibleInput: draft.barcodeInput),
              barcodeProposal.barcode == barcodeProposalToken.barcode else {
            barcodeError = "The barcode input changed. Look up the current barcode before confirming."
            return
        }
        if let confirmedBarcodeRecord {
            saveBarcodeRecord(confirmedBarcodeRecord)
            return
        }
        let kcal = NutritionBarcodeValueParser.parse(draft.barcodeCalories, maximum: 5_000)
        let proteinGrams = NutritionBarcodeValueParser.parse(draft.barcodeProtein, maximum: 2_000)
        let carbsGrams = NutritionBarcodeValueParser.parse(draft.barcodeCarbohydrates, maximum: 2_000)
        let fatGrams = NutritionBarcodeValueParser.parse(draft.barcodeFat, maximum: 2_000)
        let nutritionInputs = [draft.barcodeCalories, draft.barcodeProtein, draft.barcodeCarbohydrates, draft.barcodeFat]
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
        let grams = NutritionBarcodeValueParser.parse(draft.barcodeGrams, maximum: 5_000)
        if !draft.barcodeGrams.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && grams == nil {
            barcodeError = "Enter a valid non-negative grams value (comma or dot decimals; up to 3 decimal places)."
            return
        }
        guard draft.barcodeBasis != .per100g || grams != nil else {
            barcodeError = "Enter how many grams you ate before confirming per-100-g nutrition."
            return
        }
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: barcodeProposal.proposalID,
            barcode: barcodeProposal.barcode,
            basis: draft.barcodeBasis,
            mealAt: draft.barcodeMealAt,
            productName: draft.barcodeProductName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.barcodeProductName,
            grams: grams, kcal: kcal, proteinGrams: proteinGrams,
            carbsGrams: carbsGrams, fatGrams: fatGrams,
            confirmedAt: ISO8601DateFormatter().string(from: .now),
            valuesAreEdited: draft.barcodeValuesEdited
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
            && barcodeRequestGate.accepts(barcodeProposalToken, visibleInput: draft.barcodeInput)
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
                    savedMessage = "Saved locally"
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

    // These bindings distinguish a user edit from the programmatic refresh
    // performed when basis/grams changes. That lets the domain flow apply
    // exact per-100-g scaling without discarding an intentional correction.
    private var barcodeCaloriesBinding: Binding<String> {
        Binding(
            get: { draft.barcodeCalories },
            set: {
                draft.barcodeCalories = $0
                draft.barcodeValuesEdited = true
            }
        )
    }

    private var barcodeProteinBinding: Binding<String> {
        Binding(
            get: { draft.barcodeProtein },
            set: {
                draft.barcodeProtein = $0
                draft.barcodeValuesEdited = true
            }
        )
    }

    private var barcodeCarbohydratesBinding: Binding<String> {
        Binding(
            get: { draft.barcodeCarbohydrates },
            set: {
                draft.barcodeCarbohydrates = $0
                draft.barcodeValuesEdited = true
            }
        )
    }

    private var barcodeFatBinding: Binding<String> {
        Binding(
            get: { draft.barcodeFat },
            set: {
                draft.barcodeFat = $0
                draft.barcodeValuesEdited = true
            }
        )
    }

    private func barcodeErrorMessage(_ error: TailscaleSyncError) -> String {
        switch error {
        case .notConfigured: return "LifeOS server is not configured. No lookup was attempted."
        case .invalidBarcode: return "Enter a checksum-valid EAN-8, EAN-13, or UPC-A barcode."
        case .httpError(let status): return "The authenticated gateway returned HTTP \(status). No values are available."
        case .responseTooLarge: return "The gateway response exceeded the safety bound. No values are available."
        case .requestTooLarge: return "The selected photos exceed the upload safety bound. No photo was sent."
        case .invalidResponse: return "The gateway returned an invalid barcode response. No values are available."
        case .invalidServerURL: return "The LifeOS server URL is not approved. No lookup was attempted."
        case .invalidInstitutionId, .invalidConnectionId, .invalidConsentURL,
             .connectionAlreadyLinking, .gatewayNotConfigured:
            return "The gateway returned an unexpected response. No values are available."
        }
    }

    private func saveMealDurably() {
        guard !mealSaving, !mealSavedDurably else { return }
        guard validateManualReview() else { return }
        guard let nutritionMealStore else {
            mealSaveError = "Local meal storage is unavailable. Nothing was saved."
            return
        }
        mealSaving = true
        mealSaveError = nil
        do {
            _ = try FitnessNutritionDurableSave.save(draft: &draft, to: nutritionMealStore)
            mealSaving = false
            stage = .confirmed
            savedMessage = "Saved locally"
            onMealSaved()
        } catch {
            mealSaving = false
            mealSaveError = nutritionDraftErrorMessage(error)
        }
    }

    private func nutritionDraftErrorMessage(_ error: Error) -> String {
        if let validationError = error as? NutritionValidationError {
            switch validationError {
            case .invalidText("mealName"):
                return "Enter a meal name before saving or applying a preview."
            case .invalidBounds:
                return "Enter valid non-negative nutrition values (comma or dot decimals; up to 3 decimal places)."
            default:
                break
            }
        }
        return "Local save failed or could not be reconciled. Nothing was replaced; try Save meal again."
    }

    @ViewBuilder
    private var manualPreviewFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            FitnessNutritionReviewFieldEditor(
                field: .mealName,
                text: reviewTextBinding(for: .mealName),
                error: validationErrors[.mealName],
                focusedField: $focusedField,
                onSubmit: { advanceFocus(after: .mealName) }
            )
            .id(FitnessNutritionReviewField.mealName.id)
            loggedAtField
            FitnessNutritionFormGrid(spacing: 16, forceSingleColumn: dynamicTypeSize.isAccessibilitySize) {
                FitnessNutritionReviewFieldEditor(
                    field: .calories,
                    text: reviewTextBinding(for: .calories),
                    error: validationErrors[.calories],
                    focusedField: $focusedField,
                    onSubmit: { advanceFocus(after: .calories) }
                )
                .id(FitnessNutritionReviewField.calories.id)
                FitnessNutritionReviewFieldEditor(
                    field: .protein,
                    text: reviewTextBinding(for: .protein),
                    error: validationErrors[.protein],
                    focusedField: $focusedField,
                    onSubmit: { advanceFocus(after: .protein) }
                )
                .id(FitnessNutritionReviewField.protein.id)
                FitnessNutritionReviewFieldEditor(
                    field: .carbohydrates,
                    text: reviewTextBinding(for: .carbohydrates),
                    error: validationErrors[.carbohydrates],
                    focusedField: $focusedField,
                    onSubmit: { advanceFocus(after: .carbohydrates) }
                )
                .id(FitnessNutritionReviewField.carbohydrates.id)
                FitnessNutritionReviewFieldEditor(
                    field: .fat,
                    text: reviewTextBinding(for: .fat),
                    error: validationErrors[.fat],
                    focusedField: $focusedField,
                    onSubmit: { advanceFocus(after: .fat) }
                )
                .id(FitnessNutritionReviewField.fat.id)
            }
            if let previewMeal = draft.previewMeal {
                previewSummary(previewMeal)
            }
        }
    }

    private var loggedAtField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Logged at")
                .lifeOSTypography(.label)
                .foregroundStyle(LifeOSTokens.secondaryText)
            DatePicker(
                "Meal logged date and time",
                selection: $draft.loggedAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            .environment(\.calendar, draftCalendar)
            .environment(\.timeZone, draftCalendar.timeZone)
            .focused($focusedField, equals: .loggedAt)
            .accessibilityIdentifier("nutrition-meal-logged-at")
            .id(FitnessNutritionReviewField.loggedAt.id)
            .onChange(of: draft.loggedAt) { _, _ in
                clearReviewFeedback(for: .loggedAt)
            }
        }
    }

    @ViewBuilder
    private var demoProposalFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DEMO PROPOSAL · fixture-only")
                .lifeOSTypography(.sectionTitle)
                .foregroundStyle(LifeOSTokens.warning)
            FitnessEditableField(title: "Meal name", text: $draft.mealName)
            FitnessNutritionFormGrid(spacing: 16, forceSingleColumn: dynamicTypeSize.isAccessibilitySize) {
                FitnessEditableField(title: "Calories (kcal)", text: $draft.calories, numeric: true)
                FitnessEditableField(title: "Protein (g)", text: $draft.protein, numeric: true)
                FitnessEditableField(title: "Carbohydrates (g)", text: $draft.carbohydrates, numeric: true)
                FitnessEditableField(title: "Fat (g)", text: $draft.fat, numeric: true)
            }
        }
        Text("This deterministic demo proposal is not a photo result and is not written or sent anywhere.")
            .lifeOSTypography(.metadata)
            .foregroundStyle(LifeOSTokens.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var photoPreparationCard: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Photos")
                    .lifeOSTypography(.sectionTitle)
                Text("Choose up to three images for the proposal.")
                    .lifeOSTypography(.metadata)
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
                    .lifeOSTypography(.metadata)
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
                    .lifeOSTypography(.body, weight: .medium)
                    .accessibilityIdentifier("food-photo-explicit-consent")
                    .accessibilityLabel("Consent: sanitized photos device to private Windows LifeOS gateway to Google")
                    Text("Consent resets when this photo selection changes.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(photoProposalLoading ? "Analyzing photos…" : (photoProposal == nil ? "Analyze sanitized photos" : "Analyze again")) {
                    sendPhotosForAnalysis()
                }
                .buttonStyle(LifeOSButtonStyle(.secondary))
                .disabled(isDemo || photoPreparation.state != .ready || !photoPreparation.explicitConsent || photoProposalLoading)
                .accessibilityIdentifier("food-photo-send")
                if let photoProposalError {
                    Text(photoProposalError)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("food-photo-send-error")
                }
            }
        }
    }

    @ViewBuilder
    private var photoProposalCard: some View {
        if let photoProposal, photoProposalIsCurrent {
            FitnessCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Review proposal")
                            .lifeOSTypography(.sectionTitle)
                        Spacer()
                        if !photoProposal.flags.isEmpty {
                            Text(photoProposal.flags.map(photoFlagLabel).joined(separator: " · "))
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.warning)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Text("Google AI Studio · \(photoProposal.provenance.modelIdentifier) · proposal only")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    ForEach(photoProposal.items, id: \.itemID) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Estimated · \(item.estimatedLabel)")
                                .lifeOSTypography(.button)
                                .foregroundStyle(LifeOSTokens.Series.estimate)
                            Text("Estimated portion: \(photoRange(item.grams, suffix: "g"))")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.Series.estimate)
                            Text("Estimated calories: \(photoRange(item.calories, suffix: "kcal"))")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.Series.estimate)
                            Text("\(item.confidence.rawValue.capitalized) confidence · \(item.unit.rawValue)")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(item.confidence == .low ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                        }
                        .padding(.vertical, 3)
                    }
                    Divider().overlay(LifeOSTokens.hairlineBorder)
                    Text("Estimated total · \(photoRange(photoProposal.totals.grams, suffix: "g")) · \(photoRange(photoProposal.totals.calories, suffix: "kcal"))")
                        .lifeOSTypography(.button)
                        .foregroundStyle(LifeOSTokens.Series.estimate)
                    FitnessEditableField(title: "Meal name", text: $draft.mealName)
                    FitnessEditableField(title: "Confirmed grams", text: photoGramsBinding, numeric: true)
                    FitnessNutritionFormGrid(spacing: 16, forceSingleColumn: dynamicTypeSize.isAccessibilitySize) {
                        FitnessEditableField(title: "Confirmed calories (kcal)", text: photoCaloriesBinding, numeric: true)
                        FitnessEditableField(title: "Confirmed protein (g)", text: photoProteinBinding, numeric: true)
                        FitnessEditableField(title: "Confirmed carbohydrates (g)", text: photoCarbohydratesBinding, numeric: true)
                        FitnessEditableField(title: "Confirmed fat (g)", text: photoFatBinding, numeric: true)
                    }
                    Toggle("I reviewed these values and want to save this meal", isOn: $photoConfirmationAcknowledged)
                        .lifeOSTypography(.body, weight: .medium)
                        .accessibilityIdentifier("food-photo-confirmation-acknowledgement")
                }
            }
        }
    }

    private func sendPhotosForAnalysis() {
        guard !isDemo, photoPreparation.state == .ready, photoPreparation.explicitConsent, !photoProposalLoading else { return }
        let requestID = makePhotoRequestID()
        let manifest: FoodPhotoManifest
        do {
            manifest = try photoPreparation.makeManifest(
                mealID: photoMealID,
                requestID: requestID,
                capturedAt: ISO8601DateFormatter().string(from: .now),
                clientTimeZone: TimeZone.current.identifier
            )
        } catch {
            photoProposalError = "The sanitized photo manifest is not ready. Select the photos again; nothing was sent."
            return
        }

        photoRequestID = requestID
        photoProposalTask?.cancel()
        photoProposalTask = nil
        photoAnalysisCoordinator.invalidateAnalysis()
        photoProposalError = nil
        photoProposal = nil
        photoProposalRequest = nil
        photoConfirmationAcknowledged = false
        let request = photoAnalysisCoordinator.beginAnalysis(
            requestID: requestID,
            draftRevision: draft.fingerprint
        )
        photoProposalLoading = true
        photoProposalTask = Task { @MainActor in
            defer {
                if photoAnalysisCoordinator.ownsCleanup(
                    request,
                    currentRequestID: photoRequestID,
                    currentDraftRevision: draft.fingerprint
                ) {
                    photoAnalysisCoordinator.finish(
                        request,
                        currentRequestID: photoRequestID,
                        currentDraftRevision: draft.fingerprint
                    )
                    photoProposalLoading = false
                    photoProposalTask = nil
                }
            }
            do {
                let proposal = try await barcodeClient.fetchFoodPhotoProposal(manifest)
                let validatedProposal = try validateFoodEstimateProposalAgainstManifest(
                    proposal,
                    manifest,
                    now: .now
                )
                guard !Task.isCancelled,
                      photoAnalysisCoordinator.canAdopt(
                          request,
                          currentRequestID: photoRequestID,
                          currentDraftRevision: draft.fingerprint
                      ) else { return }
                photoAnalysisCoordinator.finish(
                    request,
                    currentRequestID: photoRequestID,
                    currentDraftRevision: draft.fingerprint
                )
                photoProposalLoading = false
                photoProposalTask = nil
                photoProposal = validatedProposal
                photoProposalRequest = request
                draft.mealName = "Photo meal"
                draft.portionGrams = formatNutritionValue(validatedProposal.totals.grams.estimate)
                draft.calories = formatNutritionValue(validatedProposal.totals.calories.estimate)
                draft.protein = formatNutritionValue(validatedProposal.totals.protein.estimate)
                draft.carbohydrates = formatNutritionValue(validatedProposal.totals.carbs.estimate)
                draft.fat = formatNutritionValue(validatedProposal.totals.fat.estimate)
                photoConfirmationAcknowledged = false
                stage = .needsConfirmation
            } catch let error as TailscaleSyncError {
                guard !Task.isCancelled,
                      photoAnalysisCoordinator.canAdopt(
                          request,
                          currentRequestID: photoRequestID,
                          currentDraftRevision: draft.fingerprint
                      ) else { return }
                photoProposalError = photoProposalErrorMessage(error)
            } catch {
                guard !Task.isCancelled,
                      photoAnalysisCoordinator.canAdopt(
                          request,
                          currentRequestID: photoRequestID,
                          currentDraftRevision: draft.fingerprint
                      ) else { return }
                photoProposalError = "The gateway returned an invalid food proposal. Nothing was saved."
            }
        }
    }

    private func confirmPhotoProposal() {
        guard let proposal = photoProposal,
              let proposalRequest = photoProposalRequest,
              proposalRequest.matchesSelection(
                  generation: photoAnalysisCoordinator.selectionGeneration,
                  requestID: photoRequestID
              ),
              let nutritionMealStore,
              !photoMealSaved else {
            if !photoProposalIsCurrent {
                photoProposal = nil
                photoProposalRequest = nil
                photoConfirmationAcknowledged = false
            }
            return
        }
        guard photoConfirmationAcknowledged else {
            photoProposalError = "Review the values and explicitly acknowledge the confirmation before saving. Nothing was saved."
            return
        }
        do {
            let trimmedName = draft.mealName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw NutritionValidationError.invalidText("mealName")
            }
            guard let grams = NutritionBarcodeValueParser.parse(draft.portionGrams, maximum: 1_000_000),
                  let calories = NutritionBarcodeValueParser.parse(draft.calories, maximum: 5_000),
                  let protein = NutritionBarcodeValueParser.parse(draft.protein, maximum: 2_000),
                  let carbs = NutritionBarcodeValueParser.parse(draft.carbohydrates, maximum: 2_000),
                  let fat = NutritionBarcodeValueParser.parse(draft.fat, maximum: 2_000) else {
                throw NutritionValidationError.invalidBounds("confirmed photo values")
            }
            // The durable meal store keeps meal-level totals. An aggregate
            // confirmed item preserves the exact user-reviewed totals while
            // the proposal itself remains ephemeral.
            let fiber = proposal.totals.fiber?.estimate
            let items = [try FoodConfirmedItem(
                itemID: "confirmed-\(proposal.proposalID)",
                label: trimmedName,
                quantity: 1,
                unit: .portion,
                grams: grams,
                calories: calories,
                protein: protein,
                carbs: carbs,
                fat: fat,
                fiber: fiber
            )]
            let totals = try FoodConfirmedTotals(
                grams: grams,
                calories: calories,
                protein: protein,
                carbs: carbs,
                fat: fat,
                fiber: fiber
            )
            let now = Date.now
            let timestamp = ISO8601DateFormatter().string(from: draft.loggedAt)
            let confirmation = try FoodConfirmationRequest(
                mealID: proposal.mealID,
                requestID: proposal.requestID,
                proposalID: proposal.proposalID,
                action: .editAndConfirm,
                mealName: trimmedName,
                mealAt: timestamp,
                items: items,
                totals: totals,
                confirmedAt: ISO8601DateFormatter().string(from: now),
                correctionNotes: "User reviewed and confirmed the displayed photo estimate values."
            )
            _ = try validateFoodConfirmationAgainstProposal(confirmation, proposal, now: now)
            let lineage = try NutritionMealPhotoLineage(proposal: proposal)
            let meal = NutritionMeal(
                loggedAt: draft.loggedAt,
                timeZoneIdentifier: draft.timeZoneIdentifier,
                name: trimmedName,
                kcal: Int(calories.rounded()),
                proteinGrams: Int(protein.rounded()),
                carbGrams: Int(carbs.rounded()),
                fatGrams: Int(fat.rounded()),
                portionGrams: grams,
                portionUnit: .g,
                journalNote: "User-reviewed values from a food-photo proposal; provider estimates remain attributable but are not medical guidance.",
                provenance: .confirmedFromPhoto,
                photoLineage: lineage
            )
            try nutritionMealStore.addConfirmed(meal)
            photoMealSaved = true
            photoPreparation.clear()
            selectedPhotoItems.removeAll()
            stage = .confirmed
            savedMessage = "Saved locally"
            onMealSaved()
        } catch {
            photoProposalError = "The proposal could not be confirmed safely. Nothing was saved."
        }
    }

    private func photoRange(_ range: FoodEstimateRange, suffix: String) -> String {
        let estimate = formatNutritionValue(range.estimate)
        let minimum = formatNutritionValue(range.min)
        let maximum = formatNutritionValue(range.max)
        return abs(range.min - range.max) < 0.01 ? "\(estimate) \(suffix)" : "\(estimate) \(suffix) · \(minimum)–\(maximum)"
    }

    private var photoGramsBinding: Binding<String> {
        $draft.portionGrams
    }

    private var photoCaloriesBinding: Binding<String> {
        $draft.calories
    }

    private var photoProteinBinding: Binding<String> {
        $draft.protein
    }

    private var photoCarbohydratesBinding: Binding<String> {
        $draft.carbohydrates
    }

    private var photoFatBinding: Binding<String> {
        $draft.fat
    }

    private func photoFlagLabel(_ flag: FoodEstimateFlag) -> String {
        switch flag {
        case .needsConfirmation: "Needs confirmation"
        case .mixedDish: "Mixed dish"
        case .unknownPortion: "Portion uncertain"
        case .hiddenOil: "Oil uncertain"
        case .lowConfidence: "Low confidence"
        case .wideInterval: "Wide range"
        }
    }

    private func photoProposalErrorMessage(_ error: TailscaleSyncError) -> String {
        switch error {
        case .notConfigured: return "LifeOS server is not configured. No photo was sent."
        case .invalidServerURL: return "The LifeOS server URL is not approved. No photo was sent."
        case .requestTooLarge: return "The selected photos exceed the upload safety bound. No photo was sent."
        case .responseTooLarge: return "The proposal exceeded the response safety bound. Nothing was saved."
        case .httpError(503): return "Google AI Studio is not configured or temporarily unavailable on the private gateway."
        case .httpError(let status): return "The authenticated gateway returned HTTP \(status). Nothing was saved."
        default: return "The photo proposal could not be loaded. Nothing was saved."
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
        invalidatePhotoAnalysis(forSelectionChange: true)
        photoLoadTask?.cancel()
        photoLoadTask = nil
        let generation = photoAnalysisCoordinator.selectionGeneration
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
                if generation == photoAnalysisCoordinator.selectionGeneration {
                    photoLoadTask = nil
                }
            }
            do {
                var inputs: [FoodPhotoSanitizerInput] = []
                inputs.reserveCapacity(items.count)
                var totalBytes = 0
                for item in items {
                    guard !Task.isCancelled, generation == photoAnalysisCoordinator.selectionGeneration else { return }
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
                guard !Task.isCancelled, generation == photoAnalysisCoordinator.selectionGeneration else { return }
                photoPreparation.prepare(inputs: inputs)
            } catch {
                guard !Task.isCancelled, generation == photoAnalysisCoordinator.selectionGeneration else { return }
                photoPreparation.failPreparation()
            }
        }
    }
}

#if os(iOS)
/// SwiftUI's interactive dismissal modifier blocks a dirty sheet, but does
/// not itself expose the user's attempted swipe. This bridge lets the sheet
/// show the same Discard/Keep editing decision for a swipe as it does for
/// Close and Escape.
private struct FitnessNutritionDismissBridge: UIViewControllerRepresentable {
    let isDirty: Bool
    let onAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isDirty: isDirty, onAttempt: onAttempt)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isHidden = true
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.onAttempt = onAttempt
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            let presentationController = controller.parent?.presentationController
                ?? controller.presentingViewController?.presentationController
            presentationController?.delegate = coordinator
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var isDirty: Bool
        var onAttempt: () -> Void

        init(isDirty: Bool, onAttempt: @escaping () -> Void) {
            self.isDirty = isDirty
            self.onAttempt = onAttempt
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isDirty
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isDirty {
                onAttempt()
            }
        }
    }
}
#endif

private struct FitnessNutritionFormGrid: Layout {
    let spacing: CGFloat
    let forceSingleColumn: Bool

    init(spacing: CGFloat = 12, forceSingleColumn: Bool = false) {
        self.spacing = spacing
        self.forceSingleColumn = forceSingleColumn
    }

    private func columnCount(for width: CGFloat) -> Int {
        forceSingleColumn ? 1 : (width >= 480 ? 2 : 1)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 0
        let count = min(columnCount(for: width), subviews.count)
        let columnWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            rowHeight = max(rowHeight, subviews[index].sizeThatFits(.init(width: columnWidth, height: nil)).height)
            if index % count == count - 1 || index == subviews.count - 1 {
                height += rowHeight
                if index < subviews.count - 1 { height += spacing }
                rowHeight = 0
            }
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let count = min(columnCount(for: bounds.width), subviews.count)
        let columnWidth = max(1, (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let column = index % count
            let size = subviews[index].sizeThatFits(.init(width: columnWidth, height: nil))
            rowHeight = max(rowHeight, size.height)
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: y),
                anchor: .topLeading,
                proposal: .init(width: columnWidth, height: size.height)
            )
            if column == count - 1 || index == subviews.count - 1 {
                y += rowHeight + spacing
                rowHeight = 0
            }
        }
    }
}

private struct FitnessNutritionReviewFieldEditor: View {
    let field: FitnessNutritionReviewField
    @Binding var text: String
    let error: String?
    @FocusState.Binding var focusedField: FitnessNutritionReviewField?
    let onSubmit: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        field: FitnessNutritionReviewField,
        text: Binding<String>,
        error: String?,
        focusedField: FocusState<FitnessNutritionReviewField?>.Binding,
        onSubmit: @escaping () -> Void
    ) {
        self.field = field
        self._text = text
        self.error = error
        self._focusedField = focusedField
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(field.label)
                    .lifeOSTypography(.label)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                if let unit = field.unit {
                    Text(unit)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        input
                        if let unit = field.unit {
                            Text(unit)
                                .lifeOSTypography(.metadata, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    HStack(spacing: 0) {
                        input
                        if let unit = field.unit {
                            Text(unit)
                                .lifeOSTypography(.metadata, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(minWidth: 32, alignment: .trailing)
                                .padding(.trailing, 12)
                        }
                    }
                }
            }
            .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            if let error {
                Text(error)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(field.id)-error")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
        .accessibilityValue(error.map { "\(text), error: \($0)" } ?? text)
        .accessibilityIdentifier(field.id)
    }

    private var input: some View {
        TextField(field.label, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .lifeOSTypography(.body, weight: .medium)
            .frame(minHeight: inputMinimumHeight)
#if os(iOS)
            .keyboardType(field.isNumeric ? .numbersAndPunctuation : .default)
#endif
            .focused($focusedField, equals: field)
            .submitLabel(field == .fat ? .done : .next)
            .onSubmit { onSubmit() }
    }

    private var inputMinimumHeight: CGFloat {
#if os(iOS)
        44
#else
        36
#endif
    }
}

private struct FitnessEditableField: View {
    let title: String
    @Binding var text: String
    var numeric = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fieldLabel)
                    .lifeOSTypography(.label)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                if let fieldUnit {
                    Text(fieldUnit)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        textField
                        if let fieldUnit {
                            Text(fieldUnit)
                                .lifeOSTypography(.metadata, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    HStack(spacing: 0) {
                        textField
                        if let fieldUnit {
                            Text(fieldUnit)
                                .lifeOSTypography(.metadata, weight: .semibold)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(minWidth: 32, alignment: .trailing)
                                .padding(.trailing, 12)
                        }
                    }
                }
            }
            .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fieldLabel)
    }

    private var textField: some View {
        TextField(fieldLabel, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .lifeOSTypography(.body, weight: .medium)
            .frame(minHeight: 44)
#if os(iOS)
            .keyboardType(numeric ? .numbersAndPunctuation : .default)
#endif
    }

    private var fieldLabel: String {
        guard let open = title.lastIndex(of: "("), title.last == ")" else { return title }
        let candidate = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
        return recognizedUnit(candidate) == nil ? title : String(title[..<open]).trimmingCharacters(in: .whitespaces)
    }

    private var fieldUnit: String? {
        guard let open = title.lastIndex(of: "("), title.last == ")" else { return nil }
        let candidate = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
        return recognizedUnit(candidate)
    }

    private func recognizedUnit(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "g", "kcal", "mg", "ml", "%":
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return nil
        }
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
                            .lifeOSTypography(.sectionTitle)
                        Text(isFixture ? "Fixture preview · not persisted" : "Durable local facts · exact timestamps")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(isFixture ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    Text("Open logs")
                        .lifeOSTypography(.metadata)
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
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("No health-risk conclusion is inferred from these logs. Empty entries remain empty rather than becoming zero.")
                    .lifeOSTypography(.metadata)
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
                guard let amount = nutrition.hydrationMilliliters else { return "Fixture · no observation" }
                return "Fixture · \(amount) ml"
            case .caffeine:
                return nutrition.caffeineMilligrams.map { "Fixture · \($0) mg" } ?? "Fixture · no observation"
            case .alcohol:
                return nutrition.alcoholUnits.map { "Fixture · \($0.formatted(.number.precision(.fractionLength(1)))) standard drinks" } ?? "Fixture · no observation"
            }
        }
        switch summary(for: kind) {
        case .failure: return "Unavailable"
        case .success(let summary):
            if summary.explicitNone { return "None" }
            if summary.alcoholFree { return "Alcohol-free" }
            guard let total = summary.total else { return "No observation" }
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
            Circle().fill(hue.base).frame(width: 6, height: 6)
            Text(title).lifeOSTypography(.metadata).foregroundStyle(hue.base)
            Text(value)
                .lifeOSTypography(.body, weight: .semibold)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
