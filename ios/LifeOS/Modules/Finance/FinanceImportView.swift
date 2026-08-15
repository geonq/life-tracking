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
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
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

// MARK: - Formatting helpers (kept local to this file; Finance's private
// formatters in FinanceView.swift are not exposed outside that file)

private enum FinanceImportCurrencyFormatter {
    static func signedEuro(cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        let magnitude = formatter.string(from: NSNumber(value: Double(abs(cents)) / 100)) ?? "€\(abs(cents) / 100)"
        return cents < 0 ? "-\(magnitude)" : "+\(magnitude)"
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
