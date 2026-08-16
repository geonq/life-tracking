import SwiftUI
import UniformTypeIdentifiers

// MARK: - Manual bank-statement CSV import

/// Drives the CSV file picker, parse preview, and persistence for manually
/// imported bank-statement transactions. Deliberately independent of
/// `FinanceCoordinator`: this surface reads/writes only its own
/// `FinanceImportedTransactionStore` and never touches the live Finance
/// connector snapshot, so a manual import can never be mistaken for a
/// connector observation.
@MainActor
final class FinanceImportViewModel: ObservableObject {
    @Published var isImporterPresented = false
    @Published var pendingResult: FinanceImportResult?
    @Published var errorMessage: String?
    @Published private(set) var savedTransactions: [FinanceImportedTransaction] = []

    private let store: FinanceImportedTransactionStore?

    init() {
        let resolvedStore = try? FinanceImportedTransactionStore()
        self.store = resolvedStore
        self.savedTransactions = (try? resolvedStore?.all()) ?? []
    }

    var hasStore: Bool { store != nil }

    func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                pendingResult = FinanceStatementImporter.parseCSV(text)
            } catch {
                errorMessage = "The file could not be read as text: \(error.localizedDescription)"
            }
        }
    }

    func confirmImport() {
        guard let store, let pendingResult else { return }
        do {
            try store.add(pendingResult.transactions)
            savedTransactions = try store.all()
            self.pendingResult = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardPending() {
        pendingResult = nil
    }

    func delete(id: UUID) {
        guard let store else { return }
        do {
            try store.remove(id: id)
            savedTransactions = try store.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() {
        guard let store else { return }
        do {
            try store.clearAll()
            savedTransactions = try store.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A small card on the Finance screen offering CSV import. Self-contained:
/// it owns its own view model and store and never reads or mutates anything
/// from `FinanceCoordinator` or `FinanceView`'s scroll/route/accounts state.
struct FinanceImportCard: View {
    @StateObject private var model = FinanceImportViewModel()
    @State private var isShowingImportedList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import statement")
                    .font(LifeOSFont.header(18))
                Text("Manually imported, on-device only")
                    .font(LifeOSFont.inter(11))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }

            HStack(spacing: 10) {
                Button {
                    model.isImporterPresented = true
                } label: {
                    HStack(spacing: 6) {
                        LifeOSIcon(.importDocument).frame(width: 15, height: 15)
                        Text("Import statement (CSV)")
                    }
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(LifeOSTokens.success.opacity(0.14), in: Capsule())
                    .foregroundStyle(LifeOSTokens.success)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasStore)
                .accessibilityIdentifier("finance-import-csv-button")

                Button {
                    isShowingImportedList = true
                } label: {
                    Text(model.savedTransactions.isEmpty ? "No imported transactions" : "\(model.savedTransactions.count) imported")
                        .font(LifeOSFont.inter(12, weight: .medium))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("finance-imported-transactions-button")

                Spacer(minLength: 0)
            }

            Text("A CSV file you pick stays on this device. Imported rows are never sent anywhere and are kept separate from connected-account data.")
                .font(LifeOSFont.inter(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .overlay(LifeOSTokens.hairlineBorder)

            FinanceSpendingByCategorySection(transactions: model.savedTransactions)

            Divider()
                .overlay(LifeOSTokens.hairlineBorder)

            FinanceBudgetsSection(transactions: model.savedTransactions)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-import-card")
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            model.handlePickedFile(result)
        }
        .sheet(item: Binding(
            get: { model.pendingResult.map(FinanceImportPreviewSheetItem.init) },
            set: { newValue in if newValue == nil { model.discardPending() } }
        )) { item in
            FinanceImportPreviewView(result: item.result, onConfirm: model.confirmImport, onCancel: model.discardPending)
        }
        .sheet(isPresented: $isShowingImportedList) {
            FinanceImportedTransactionsListView(model: model)
        }
        .alert("Import statement", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// `Identifiable` wrapper so `FinanceImportResult` (a plain struct) can drive
/// a `.sheet(item:)` presentation.
private struct FinanceImportPreviewSheetItem: Identifiable {
    let id = UUID()
    let result: FinanceImportResult
}

/// Shows parsed-count, skipped-count, and the first rows before the user
/// commits to persisting anything. Nothing is written to the durable store
/// until the user explicitly taps Import.
private struct FinanceImportPreviewView: View {
    let result: FinanceImportResult
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var previewRows: [FinanceImportedTransaction] {
        Array(result.transactions.prefix(20))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Parsed")
                        Spacer()
                        Text("\(result.transactions.count)")
                            .foregroundStyle(LifeOSTokens.success)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("Skipped (invalid rows)")
                        Spacer()
                        Text("\(result.skippedRowCount)")
                            .foregroundStyle(result.skippedRowCount > 0 ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("Detected layout")
                        Spacer()
                        Text(result.detectedSource == .tradeRepublicCSV ? "Trade Republic" : "Generic CSV")
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }

                if result.transactions.isEmpty {
                    Section {
                        Text("No valid transactions were found in this file. Check that it has a date and amount column.")
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                } else {
                    Section("Preview (first \(previewRows.count))") {
                        ForEach(previewRows) { transaction in
                            FinanceImportPreviewRow(transaction: transaction)
                        }
                    }
                }
            }
            .navigationTitle("Review import")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(result.transactions.isEmpty)
                }
            }
        }
    }
}

private struct FinanceImportPreviewRow: View {
    let transaction: FinanceImportedTransaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .font(LifeOSFont.inter(12, weight: .medium))
                Text(FinanceImportDateFormatter.point(transaction.bookedAt))
                    .font(LifeOSFont.inter(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(FinanceImportCurrencyFormatter.signedEuro(cents: transaction.amountCents))
                .font(LifeOSFont.inter(12, weight: .semiBold))
                .foregroundStyle(transaction.isOutflow ? LifeOSTokens.danger : LifeOSTokens.success)
                .monospacedDigit()
        }
    }
}

/// Reads the durable store, grouped by month, with per-row delete and clear
/// all. Honest empty state when the store has nothing in it.
private struct FinanceImportedTransactionsListView: View {
    @ObservedObject var model: FinanceImportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingClearConfirmation = false

    private var groupedByMonth: [(key: Date, transactions: [FinanceImportedTransaction])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.savedTransactions) { transaction in
            calendar.date(from: calendar.dateComponents([.year, .month], from: transaction.bookedAt)) ?? transaction.bookedAt
        }
        return grouped
            .map { (key: $0.key, transactions: $0.value.sorted { $0.bookedAt > $1.bookedAt }) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.savedTransactions.isEmpty {
                    FinanceImportedEmptyState()
                } else {
                    List {
                        ForEach(groupedByMonth, id: \.key) { group in
                            Section(FinanceImportDateFormatter.month(group.key)) {
                                ForEach(group.transactions) { transaction in
                                    FinanceImportPreviewRow(transaction: transaction)
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        model.delete(id: group.transactions[index].id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Imported transactions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !model.savedTransactions.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear all", role: .destructive) {
                            isShowingClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear all imported transactions?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear all", role: .destructive) { model.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes manually imported rows stored on this device. It does not affect any connected account.")
            }
        }
    }
}

private struct FinanceImportedEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            LifeOSIcon(.importDocument)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 30, height: 30)
            Text("No imported transactions")
                .font(LifeOSFont.inter(14, weight: .semiBold))
            Text("Import a CSV to see your transactions here.")
                .font(LifeOSFont.inter(12))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No imported transactions")
    }
}

// MARK: - Spending by category

/// Groups the given imported transactions by month (newest first), keyed by
/// the first-of-month `Date`. Shared by the imported-transactions list and
/// the spending-by-category section so both use the same month buckets.
private func financeImportGroupedByMonth(
    _ transactions: [FinanceImportedTransaction]
) -> [(key: Date, transactions: [FinanceImportedTransaction])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: transactions) { transaction in
        calendar.date(from: calendar.dateComponents([.year, .month], from: transaction.bookedAt)) ?? transaction.bookedAt
    }
    return grouped
        .map { (key: $0.key, transactions: $0.value) }
        .sorted { $0.key > $1.key }
}

/// "Spending by category" section shown inside `FinanceImportCard`, below
/// the import controls. Operates purely on `FinanceCategorizer` against
/// whatever imported transactions already exist for the selected month —
/// no new store, no persistence of categories, categorized fresh every
/// render. Honest empty state when there are no imported transactions at
/// all, or none for the selected month.
private struct FinanceSpendingByCategorySection: View {
    let transactions: [FinanceImportedTransaction]
    @State private var selectedMonth: Date?

    private var monthGroups: [(key: Date, transactions: [FinanceImportedTransaction])] {
        financeImportGroupedByMonth(transactions)
    }

    private var currentMonth: Date? {
        selectedMonth ?? monthGroups.first?.key
    }

    private var transactionsForMonth: [FinanceImportedTransaction] {
        guard let currentMonth else { return [] }
        return monthGroups.first { $0.key == currentMonth }?.transactions ?? []
    }

    private var summary: [FinanceCategorySpend] {
        FinanceCategorizer.summary(for: transactionsForMonth)
    }

    private var totals: FinanceSpendTotals {
        FinanceCategorizer.totals(for: transactionsForMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending by category")
                    .font(LifeOSFont.header(15))
                Spacer(minLength: 8)
                if !monthGroups.isEmpty {
                    monthPicker
                }
            }

            if transactions.isEmpty {
                FinanceSpendingByCategoryEmptyState(hasAnyImports: false)
            } else if transactionsForMonth.isEmpty {
                FinanceSpendingByCategoryEmptyState(hasAnyImports: true)
            } else {
                FinanceSpendTotalsRow(totals: totals)
                VStack(spacing: 8) {
                    ForEach(summary, id: \.category) { spend in
                        FinanceCategorySpendRow(spend: spend, maxMagnitudeCents: maxMagnitudeCents)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-spending-by-category-section")
    }

    private var maxMagnitudeCents: Int {
        summary.map { $0.outflowCents + $0.inflowCents }.max() ?? 0
    }

    private var monthPicker: some View {
        Menu {
            ForEach(monthGroups, id: \.key) { group in
                Button(FinanceImportDateFormatter.month(group.key)) {
                    selectedMonth = group.key
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentMonth.map(FinanceImportDateFormatter.month) ?? "")
                    .font(LifeOSFont.inter(12, weight: .medium))
                LifeOSIcon(.chevronRight)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(90))
            }
            .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .accessibilityIdentifier("finance-spending-by-category-month-picker")
    }
}

private struct FinanceSpendTotalsRow: View {
    let totals: FinanceSpendTotals

    var body: some View {
        HStack(spacing: 14) {
            FinanceSpendTotalItem(label: "Spent", cents: totals.outflowCents, color: LifeOSTokens.danger)
            FinanceSpendTotalItem(label: "Income", cents: totals.inflowCents, color: LifeOSTokens.success)
            FinanceSpendTotalItem(
                label: "Net",
                cents: abs(totals.netCents),
                color: totals.netCents < 0 ? LifeOSTokens.danger : LifeOSTokens.success,
                isSigned: true,
                signedValue: totals.netCents
            )
            Spacer(minLength: 0)
        }
    }
}

private struct FinanceSpendTotalItem: View {
    let label: String
    let cents: Int
    let color: Color
    var isSigned: Bool = false
    var signedValue: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(LifeOSFont.inter(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(isSigned ? FinanceImportCurrencyFormatter.signedEuro(cents: signedValue) : FinanceImportCurrencyFormatter.magnitudeEuro(cents: cents))
                .font(LifeOSFont.inter(13, weight: .semiBold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

/// One row per category: icon/hue, name, transaction count, EUR total, and
/// a simple proportional bar. Outflow renders in `LifeOSTokens.danger`,
/// pure-income categories in `.success`.
private struct FinanceCategorySpendRow: View {
    let spend: FinanceCategorySpend
    let maxMagnitudeCents: Int
    @State private var hasAppeared = false

    private var magnitudeCents: Int { spend.outflowCents + spend.inflowCents }
    private var isPrimarilyIncome: Bool { spend.inflowCents > spend.outflowCents }
    private var amountColor: Color { isPrimarilyIncome ? LifeOSTokens.success : LifeOSTokens.danger }
    private var barFraction: CGFloat {
        guard maxMagnitudeCents > 0 else { return 0 }
        return CGFloat(magnitudeCents) / CGFloat(maxMagnitudeCents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                LifeOSIcon(spend.category.iconName)
                    .foregroundStyle(spend.category.hue.base)
                    .frame(width: 14, height: 14)
                Text(spend.category.displayName)
                    .font(LifeOSFont.inter(12, weight: .medium))
                Text("\(spend.count)")
                    .font(LifeOSFont.inter(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Spacer(minLength: 8)
                Text(isPrimarilyIncome
                     ? FinanceImportCurrencyFormatter.signedEuro(cents: spend.inflowCents)
                     : FinanceImportCurrencyFormatter.signedEuro(cents: -spend.outflowCents))
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .foregroundStyle(amountColor)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LifeOSTokens.Ring.track)
                    Capsule()
                        .fill(spend.category.hue.base)
                        .frame(width: proxy.size.width * (hasAppeared ? barFraction : 0))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spend.category.displayName), \(spend.count) transactions")
        .onAppear {
            if LifeOSMotion.reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(LifeOSMotion.chartDraw) { hasAppeared = true }
            }
        }
    }
}

private struct FinanceSpendingByCategoryEmptyState: View {
    /// `true` when imports exist overall but not for the selected month;
    /// `false` when there are no imported transactions at all. Both are
    /// honest — neither fabricates category data.
    let hasAnyImports: Bool

    var body: some View {
        Text(hasAnyImports
             ? "No imported transactions in this month."
             : "Import a CSV to see spending by category here.")
            .font(LifeOSFont.inter(12))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .accessibilityIdentifier("finance-spending-by-category-empty-state")
    }
}

// MARK: - Budgets

/// Drives budget persistence for the "Budgets" section: reads/writes its own
/// `FinanceBudgetStore` and is otherwise stateless. Self-contained, mirroring
/// `FinanceImportViewModel` — never touches `FinanceCoordinator` or any other
/// Finance surface.
@MainActor
final class FinanceBudgetViewModel: ObservableObject {
    @Published private(set) var currentBudgets: [FinanceTransactionCategory: FinanceCategoryBudget] = [:]
    @Published var errorMessage: String?

    private let store: FinanceBudgetStore?

    init() {
        let resolvedStore = try? FinanceBudgetStore()
        self.store = resolvedStore
        reload(on: .now)
    }

    var hasStore: Bool { store != nil }

    func reload(on date: Date) {
        guard let store else { return }
        do {
            currentBudgets = try store.currentBudgets(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sets a new monthly limit for `category`, effective from `date` (the
    /// selected month being viewed). Rejects non-positive limits and
    /// `.income` up front rather than round-tripping an invalid value
    /// through the store.
    func setLimit(cents: Int, for category: FinanceTransactionCategory, effectiveFrom date: Date) {
        guard let store, category.isBudgetable, cents > 0 else { return }
        do {
            try store.setBudget(FinanceCategoryBudget(category: category, monthlyLimitCents: cents, effectiveFrom: date))
            reload(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeBudget(for category: FinanceTransactionCategory, viewingDate date: Date) {
        guard let store else { return }
        do {
            try store.remove(category: category)
            reload(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "Budgets" section shown inside `FinanceImportCard`, below "Spending by
/// category." For the selected month, shows every budgetable category with
/// either its set monthly limit (editable) and actual spend as a progress
/// bar, or an honest "No budget set" row when nothing has been configured —
/// never a fabricated zero limit. Uses the same month-grouping helper as
/// "Spending by category" so both sections agree on month boundaries.
private struct FinanceBudgetsSection: View {
    let transactions: [FinanceImportedTransaction]
    @StateObject private var model = FinanceBudgetViewModel()
    @State private var selectedMonth: Date?

    private var monthGroups: [(key: Date, transactions: [FinanceImportedTransaction])] {
        financeImportGroupedByMonth(transactions)
    }

    private var currentMonth: Date {
        selectedMonth ?? monthGroups.first?.key ?? Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    }

    private var transactionsForMonth: [FinanceImportedTransaction] {
        monthGroups.first { $0.key == currentMonth }?.transactions ?? []
    }

    private var spendByCategory: [FinanceTransactionCategory: FinanceCategorySpend] {
        Dictionary(uniqueKeysWithValues: FinanceCategorizer.summary(for: transactionsForMonth).map { ($0.category, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Budgets")
                    .font(LifeOSFont.header(15))
                Spacer(minLength: 8)
                if !monthGroups.isEmpty {
                    monthPicker
                }
            }

            if transactions.isEmpty {
                Text("Import a CSV to set budgets against your spending.")
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .accessibilityIdentifier("finance-budgets-empty-state")
            } else {
                VStack(spacing: 10) {
                    ForEach(FinanceTransactionCategory.budgetableCategories, id: \.self) { category in
                        FinanceCategoryBudgetRow(
                            category: category,
                            budget: model.currentBudgets[category],
                            spend: spendByCategory[category],
                            onSetLimit: { cents in
                                model.setLimit(cents: cents, for: category, effectiveFrom: currentMonth)
                            },
                            onRemove: {
                                model.removeBudget(for: category, viewingDate: currentMonth)
                            }
                        )
                    }
                }
            }
        }
        .onAppear { model.reload(on: currentMonth) }
        .onChange(of: selectedMonth) { _, newValue in
            model.reload(on: newValue ?? currentMonth)
        }
        .alert("Budgets", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-budgets-section")
    }

    private var monthPicker: some View {
        Menu {
            ForEach(monthGroups, id: \.key) { group in
                Button(FinanceImportDateFormatter.month(group.key)) {
                    selectedMonth = group.key
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(FinanceImportDateFormatter.month(currentMonth))
                    .font(LifeOSFont.inter(12, weight: .medium))
                LifeOSIcon(.chevronRight)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(90))
            }
            .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .accessibilityIdentifier("finance-budgets-month-picker")
    }
}

/// One row per budgetable category: icon/name, editable limit field, and
/// (when a limit is set) actual spend this month with a progress bar and an
/// honest remaining/over-by readout. When no limit is set, shows "No budget
/// set" plus the entry field — never a fabricated zero limit standing in for
/// "unset."
private struct FinanceCategoryBudgetRow: View {
    let category: FinanceTransactionCategory
    let budget: FinanceCategoryBudget?
    let spend: FinanceCategorySpend?
    let onSetLimit: (Int) -> Void
    let onRemove: () -> Void

    @State private var limitText: String = ""
    @FocusState private var isFieldFocused: Bool
    @State private var hasAppeared = false

    private var spentCents: Int { spend?.outflowCents ?? 0 }
    private var limitCents: Int? { budget?.monthlyLimitCents }
    private var isOverBudget: Bool {
        guard let limitCents else { return false }
        return spentCents > limitCents
    }
    private var progressFraction: CGFloat {
        guard let limitCents, limitCents > 0 else { return 0 }
        return min(CGFloat(spentCents) / CGFloat(limitCents), 1)
    }
    private var progressColor: Color {
        isOverBudget ? LifeOSTokens.danger : LifeOSTokens.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LifeOSIcon(category.iconName)
                    .foregroundStyle(category.hue.base)
                    .frame(width: 14, height: 14)
                Text(category.displayName)
                    .font(LifeOSFont.inter(12, weight: .medium))
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("€")
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    TextField("Limit", text: $limitText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .frame(width: 56)
                        .focused($isFieldFocused)
                        .onSubmit(commitLimit)
                        .accessibilityIdentifier("finance-budget-limit-field-\(category.rawValue)")
                }
            }

            if let limitCents {
                HStack(spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(LifeOSTokens.Ring.track)
                            Capsule()
                                .fill(progressColor)
                                .frame(width: proxy.size.width * (hasAppeared ? progressFraction : 0))
                        }
                    }
                    .frame(height: 5)
                    .accessibilityHidden(true)
                }
                .onAppear {
                    if LifeOSMotion.reduceMotion {
                        hasAppeared = true
                    } else {
                        withAnimation(LifeOSMotion.chartDraw) { hasAppeared = true }
                    }
                }

                HStack(spacing: 6) {
                    Text(FinanceImportCurrencyFormatter.magnitudeEuro(cents: spentCents) + " of " + FinanceImportCurrencyFormatter.magnitudeEuro(cents: limitCents))
                        .font(LifeOSFont.inter(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Spacer(minLength: 8)
                    Text(isOverBudget
                         ? "Over by \(FinanceImportCurrencyFormatter.magnitudeEuro(cents: spentCents - limitCents))"
                         : "\(FinanceImportCurrencyFormatter.magnitudeEuro(cents: limitCents - spentCents)) remaining")
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(isOverBudget ? LifeOSTokens.danger : LifeOSTokens.success)
                    Button("Remove", role: .destructive, action: onRemove)
                        .font(LifeOSFont.inter(10))
                        .buttonStyle(.plain)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .accessibilityIdentifier("finance-budget-remove-\(category.rawValue)")
                }
            } else {
                Text("No budget set")
                    .font(LifeOSFont.inter(11))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .accessibilityIdentifier("finance-budget-unset-\(category.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-budget-row-\(category.rawValue)")
        .onChange(of: isFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitLimit()
            }
        }
        .onAppear {
            limitText = limitCents.map { String($0 / 100) } ?? ""
        }
        .onChange(of: limitCents) { _, newValue in
            if !isFieldFocused {
                limitText = newValue.map { String($0 / 100) } ?? ""
            }
        }
    }

    private func commitLimit() {
        let trimmed = limitText.trimmingCharacters(in: .whitespaces)
        guard let euros = Int(trimmed), euros > 0 else {
            // Invalid or empty entry: revert the field rather than silently
            // writing a fabricated limit.
            limitText = limitCents.map { String($0 / 100) } ?? ""
            return
        }
        onSetLimit(euros * 100)
    }
}

// MARK: - Formatting helpers (kept local to this file; Finance's private
// formatters in FinanceView.swift are not exposed outside that file)

private enum FinanceImportCurrencyFormatter {
    static func signedEuro(cents: Int) -> String {
        let magnitude = magnitudeEuro(cents: cents)
        return cents < 0 ? "-\(magnitude)" : "+\(magnitude)"
    }

    /// Unsigned EUR string for `abs(cents)`. Used for totals rows where the
    /// sign is already conveyed by a label ("Spent" / "Income") or color.
    static func magnitudeEuro(cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(abs(cents)) / 100)) ?? "€\(abs(cents) / 100)"
    }
}

private enum FinanceImportDateFormatter {
    static func point(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}
