import Combine
import Foundation
import SwiftUI

struct FinanceRecurringEvidenceLine: Equatable, Identifiable, Sendable {
    let id: UUID
    let bookedAt: Date
    let amountCents: Int
    let description: String
    let sourceNamespace: String
    let accountID: UUID
    let batchID: UUID?
    let sourceRowNumber: Int?
}

struct FinanceRecurringPaymentRow: Equatable, Identifiable, Sendable {
    let key: FinanceRecurringPaymentKey
    let candidate: FinanceRecurringPaymentCandidate?
    let override: FinanceRecurringPaymentOverride?
    let evidence: [FinanceRecurringEvidenceLine]
    let isStale: Bool

    var id: String { key.id }
    var displayName: String { key.normalizedMerchantKey.localizedCapitalized }
    var status: FinanceRecurringPaymentStatus { override?.status ?? .active }
    var cadence: FinanceRecurringCadence? { override?.cadence ?? candidate?.detectedCadence }
    var confidence: FinanceRecurringConfidence {
        isStale ? .needsReview : (candidate?.confidence ?? .needsReview)
    }

    var reasonCodes: [FinanceRecurringReasonCode] {
        var reasons = candidate?.reasonCodes ?? []
        if candidate == nil && !reasons.contains(.missingProvenance) {
            reasons.append(.missingProvenance)
        }
        if isStale && !reasons.contains(.detectorError) {
            reasons.append(.detectorError)
        }
        return reasons.sorted { $0.rawValue < $1.rawValue }
    }

    var anchor: FinanceRecurringAnchor? { override?.anchor ?? candidate?.anchor }
    var predictedDate: Date? {
        guard !isStale,
              status == .active,
              let cadence,
              let anchor else { return nil }

        var evidenceDates = evidence.map(\.bookedAt)
        if let latestEligiblePaymentDate = candidate?.latestEligiblePaymentDate,
           !evidenceDates.contains(latestEligiblePaymentDate) {
            evidenceDates.append(latestEligiblePaymentDate)
        }
        guard let latestEvidenceDate = evidenceDates.max() else {
            return nil
        }

        let prediction: Date?
        if override?.cadence == nil {
            prediction = candidate?.predictedDate
        } else {
            do {
                guard let periodIndex = try FinanceRecurringPaymentDetector.consumedPeriodIndex(
                    cadence: cadence,
                    anchor: anchor,
                    evidenceDates: evidenceDates
                ) else {
                    return nil
                }
                prediction = try FinanceRecurringPaymentDetector.nextExpectedDate(
                    cadence: cadence,
                    anchor: anchor,
                    afterConsumedPeriodIndex: periodIndex
                )
            } catch {
                return nil
            }
        }
        guard let prediction, prediction > latestEvidenceDate else { return nil }
        return prediction
    }
}

enum FinanceRecurringPaymentEditorOwner: Equatable, Sendable {
    case recurringCard
    case importedTransactions
}

/// Owns recurring metadata presentation and the asynchronous detector result.
/// It receives immutable snapshots from `FinanceImportViewModel` and never
/// becomes a second transaction authority.
@MainActor
final class FinanceRecurringPaymentsViewModel: ObservableObject {
    @Published private(set) var assessment: FinanceRecurringPaymentAssessment?
    @Published private(set) var rows: [FinanceRecurringPaymentRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var staleMessage: String?
    @Published private(set) var isStale = false
    @Published private(set) var editingRow: FinanceRecurringPaymentRow?
    @Published private(set) var editingOwner: FinanceRecurringPaymentEditorOwner?

    private let store: FinanceRecurringPaymentStore?
    private let computationStartHook: (@Sendable () async -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var currentState: FinanceRecurringPaymentStoreState?
    private var rowByEvidenceID: [UUID: FinanceRecurringPaymentRow] = [:]

    init(
        store: FinanceRecurringPaymentStore?,
        onComputationStarted: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.computationStartHook = onComputationStarted
        if let store {
            self.currentState = try? store.load()
        } else {
            self.currentState = nil
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var timeZoneIdentifier: String {
        currentState?.financeTimeZoneIdentifier ?? FinanceRecurringPaymentContract.defaultTimeZoneIdentifier
    }

    func refresh(
        transactions: [FinanceImportedTransaction],
        batches: [FinanceImportBatchProvenance]
    ) {
        generation &+= 1
        let requestGeneration = generation
        refreshTask?.cancel()
        guard let store else {
            assessment = nil
            rows = []
            rowByEvidenceID.removeAll(keepingCapacity: true)
            errorMessage = "Recurring payments need local Finance storage."
            staleMessage = nil
            isStale = false
            isRefreshing = false
            return
        }

        isRefreshing = true
        errorMessage = nil
        staleMessage = nil
        isStale = false
        let timeZoneIdentifier = currentState?.financeTimeZoneIdentifier
            ?? FinanceRecurringPaymentContract.defaultTimeZoneIdentifier
        let worker = FinanceRecurringRefreshWorker(
            store: store,
            onComputationStarted: computationStartHook
        )
        refreshTask = Task { [weak self, worker] in
            do {
                let result = try await worker.refresh(
                    transactions: transactions,
                    batches: batches,
                    timeZoneIdentifier: timeZoneIdentifier
                )
                guard !Task.isCancelled, let self, requestGeneration == self.generation else { return }
                self.currentState = result.state
                self.assessment = result.assessment
                self.isStale = false
                self.staleMessage = nil
                self.publishRows(result.rows)
                self.isRefreshing = false
            } catch is CancellationError {
                guard let self, requestGeneration == self.generation else { return }
                self.isRefreshing = false
            } catch {
                guard let self, requestGeneration == self.generation else { return }
                let stale = await worker.staleMaterial(
                    transactions: transactions,
                    batches: batches,
                    timeZoneIdentifier: timeZoneIdentifier
                )
                guard !Task.isCancelled, requestGeneration == self.generation else { return }
                self.isRefreshing = false
                self.errorMessage = Self.message(for: error)
                self.isStale = true
                self.staleMessage = "Recurring detection is stale. No cached prediction is being presented as current."
                self.assessment = nil
                self.currentState = stale.state ?? self.currentState
                if !stale.rows.isEmpty || stale.state != nil {
                    self.staleMessage = stale.usesCache
                        ? "Last detection is stale. Predictions are hidden until a fresh scan succeeds."
                        : self.staleMessage
                    self.publishRows(stale.rows)
                } else {
                    self.publishRows(Self.managedStaleRows(from: self.currentState))
                }
            }
        }
    }

    func presentSnapshotReadError(_ error: Error) {
        generation &+= 1
        refreshTask?.cancel()
        isRefreshing = false
        errorMessage = Self.message(for: error)
        assessment = nil
        isStale = true
        staleMessage = "Finance data could not be read. Existing recurring decisions are shown as stale."
        // The transaction snapshot is no longer trustworthy. Rebuild from
        // durable overrides only so a cold-start failure preserves decisions
        // without presenting old evidence or a cached assessment as current.
        publishRows(Self.managedStaleRows(from: currentState))
    }

    func beginManage(for row: FinanceRecurringPaymentRow) {
        beginManage(for: row, owner: .recurringCard)
    }

    func beginManage(transactionID: UUID) {
        guard let row = rowByEvidenceID[transactionID] else { return }
        beginManage(for: row, owner: .importedTransactions)
    }

    func editorBinding(
        for owner: FinanceRecurringPaymentEditorOwner
    ) -> Binding<FinanceRecurringPaymentRow?> {
        Binding(
            get: { [weak self] in
                guard let self, self.editingOwner == owner else { return nil }
                return self.editingRow
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let newValue {
                    guard self.editingOwner == owner else { return }
                    self.editingRow = newValue
                } else {
                    self.dismissManage(owner: owner)
                }
            }
        )
    }

    func shouldPresentEditor(for owner: FinanceRecurringPaymentEditorOwner) -> Bool {
        editingOwner == owner && editingRow != nil
    }

    func dismissManage(owner: FinanceRecurringPaymentEditorOwner) {
        guard editingOwner == owner else { return }
        editingRow = nil
        editingOwner = nil
    }

    private func beginManage(
        for row: FinanceRecurringPaymentRow,
        owner: FinanceRecurringPaymentEditorOwner
    ) {
        editingOwner = owner
        editingRow = row
    }

    func hasManagedRow(for transactionID: UUID) -> Bool {
        rowByEvidenceID[transactionID] != nil
    }

    @discardableResult
    func save(
        row: FinanceRecurringPaymentRow,
        cadence: FinanceRecurringCadence?,
        status: FinanceRecurringPaymentStatus,
        anchorDate: Date?
    ) -> Bool {
        errorMessage = nil
        guard let store else {
            errorMessage = "Recurring-payment storage is unavailable."
            return false
        }
        do {
            let anchor: FinanceRecurringAnchor?
            if cadence != nil, let anchorDate {
                anchor = try FinanceRecurringAnchor(
                    date: anchorDate,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            } else {
                anchor = nil
            }
            let requested = try FinanceRecurringPaymentOverride(
                key: row.key,
                cadence: cadence,
                anchor: anchor,
                status: status
            )
            let expectedRevision = try currentRevision(for: store)
            let state = try store.saveOverride(
                requested,
                expectedRevision: expectedRevision
            )
            currentState = state
            rebuildRows(using: state.overrides)
            errorMessage = nil
            editingRow = nil
            editingOwner = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func resetAutomatic(for row: FinanceRecurringPaymentRow) -> Bool {
        errorMessage = nil
        guard let store else {
            errorMessage = "Recurring-payment storage is unavailable."
            return false
        }
        do {
            let expectedRevision = try currentRevision(for: store)
            let state = try store.clearOverride(
                for: row.key,
                expectedRevision: expectedRevision
            )
            currentState = state
            rebuildRows(using: state.overrides)
            errorMessage = nil
            editingRow = nil
            editingOwner = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private func currentRevision(for store: FinanceRecurringPaymentStore) throws -> Int {
        if let currentState { return currentState.revision }
        return try store.load().revision
    }

    private func rebuildRows(using overrides: [FinanceRecurringPaymentOverride]) {
        let overridesByID = overrides.reduce(into: [String: FinanceRecurringPaymentOverride]()) { result, override in
            result[override.key.id] = override
        }
        let rebuilt = rows.compactMap { row -> FinanceRecurringPaymentRow? in
            let override = overridesByID[row.id]
            guard override != nil || row.candidate != nil else { return nil }
            return FinanceRecurringPaymentRow(
                key: row.key,
                candidate: row.candidate,
                override: override,
                evidence: row.evidence,
                isStale: row.isStale
            )
        }
        publishRows(rebuilt)
    }

    private func publishRows(_ newRows: [FinanceRecurringPaymentRow]) {
        rows = newRows
        rowByEvidenceID.removeAll(keepingCapacity: true)
        for row in newRows {
            for evidence in row.evidence where rowByEvidenceID[evidence.id] == nil {
                rowByEvidenceID[evidence.id] = row
            }
        }
    }

    nonisolated fileprivate static func makeRows(
        assessment: FinanceRecurringPaymentAssessment?,
        transactions: [FinanceImportedTransaction],
        overrides: [FinanceRecurringPaymentOverride],
        staleCache: FinanceRecurringPaymentAssessment?,
        isStale: Bool
    ) -> [FinanceRecurringPaymentRow] {
        let transactionsByID = presentationTransactions(from: transactions).reduce(into: [UUID: FinanceImportedTransaction]()) { result, transaction in
            result[transaction.id] = transaction
        }
        let overridesByID = overrides.reduce(into: [String: FinanceRecurringPaymentOverride]()) { result, override in
            if let existing = result[override.key.id], existing.localRevision > override.localRevision {
                return
            }
            result[override.key.id] = override
        }
        var candidatesByID = [String: FinanceRecurringPaymentCandidate]()
        for candidate in assessment?.candidates ?? [] {
            candidatesByID[candidate.id] = candidate
        }
        var cachedCandidatesByID = [String: FinanceRecurringPaymentCandidate]()
        for candidate in staleCache?.candidates ?? [] {
            cachedCandidatesByID[candidate.id] = candidate
        }

        // If evidence disappears after a successful prior scan, keep the
        // managed row visible with its last known identity and an honest empty
        // evidence state. The cache is never treated as current detection.
        for override in overrides where candidatesByID[override.key.id] == nil {
            if let cached = cachedCandidatesByID[override.key.id] {
                candidatesByID[override.key.id] = cached
            }
        }

        var keysByID = [String: FinanceRecurringPaymentKey]()
        for candidate in candidatesByID.values { keysByID[candidate.id] = candidate.key }
        for override in overrides { keysByID[override.key.id] = override.key }

        var rows: [FinanceRecurringPaymentRow] = []
        rows.reserveCapacity(keysByID.count)
        for id in keysByID.keys.sorted() {
            guard let key = keysByID[id] else { continue }
            let candidate = candidatesByID[id]
            let lines = (candidate?.supportingEvidence ?? []).compactMap { reference -> FinanceRecurringEvidenceLine? in
                guard let transaction = transactionsByID[reference.transactionID],
                      transaction.mappedIdentity?.accountID == key.accountID else { return nil }
                return FinanceRecurringEvidenceLine(
                    id: transaction.id,
                    bookedAt: transaction.bookedAt,
                    amountCents: transaction.amountCents,
                    description: transaction.description,
                    sourceNamespace: reference.sourceNamespace,
                    accountID: key.accountID,
                    batchID: reference.batchID,
                    sourceRowNumber: reference.sourceRowNumber
                )
            }.sorted { lhs, rhs in
                if lhs.bookedAt != rhs.bookedAt { return lhs.bookedAt < rhs.bookedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            rows.append(FinanceRecurringPaymentRow(
                key: key,
                candidate: candidate,
                override: overridesByID[id],
                evidence: lines,
                isStale: isStale
            ))
        }
        return rows.sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.id < rhs.id
        }
    }

    nonisolated fileprivate static func presentationTransactions(
        from transactions: [FinanceImportedTransaction]
    ) -> [FinanceImportedTransaction] {
        var seen = Set<UUID>()
        var result: [FinanceImportedTransaction] = []
        result.reserveCapacity(transactions.count)
        for transaction in transactions.sorted(by: { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
            if lhs.bookedAt != rhs.bookedAt { return lhs.bookedAt < rhs.bookedAt }
            return lhs.description < rhs.description
        }) where seen.insert(transaction.id).inserted {
            result.append(transaction)
        }
        return result
    }

    nonisolated fileprivate static func managedStaleRows(
        from state: FinanceRecurringPaymentStoreState?
    ) -> [FinanceRecurringPaymentRow] {
        state?.overrides.map { override in
            FinanceRecurringPaymentRow(
                key: override.key,
                candidate: nil,
                override: override,
                evidence: [],
                isStale: true
            )
        } ?? []
    }

    private static func message(for error: Error) -> String {
        switch error {
        case FinanceRecurringPaymentDetectorError.invalidTimeZone:
            return "The saved Finance timezone is invalid."
        case FinanceRecurringPaymentDetectorError.inputTooLarge:
            return "Recurring detection stopped at the safe imported-row limit."
        case FinanceRecurringPaymentDetectorError.conflictingTransactionID:
            return "Recurring detection found conflicting observations for one imported row."
        case FinanceRecurringPaymentStoreError.revisionConflict:
            return "Recurring-payment state changed elsewhere. Reload the Finance section and retry."
        case FinanceRecurringPaymentStoreError.invalidEnvelope, FinanceRecurringPaymentStoreError.readFailed:
            return "Recurring-payment storage is invalid or unavailable; the original file was kept."
        default:
            return "Recurring-payment detection is unavailable right now."
        }
    }
}

/// Performs all refresh work that can be expensive away from the main actor.
/// The actor hop is structured through the caller's task, so cancellation is
/// inherited and generation checks still guard every UI publication.
private actor FinanceRecurringRefreshWorker {
    private let store: FinanceRecurringPaymentStore
    private let onComputationStarted: (@Sendable () async -> Void)?

    init(
        store: FinanceRecurringPaymentStore,
        onComputationStarted: (@Sendable () async -> Void)?
    ) {
        self.store = store
        self.onComputationStarted = onComputationStarted
    }

    func refresh(
        transactions: [FinanceImportedTransaction],
        batches: [FinanceImportBatchProvenance],
        timeZoneIdentifier: String
    ) async throws -> FinanceRecurringRefreshResult {
        try Task.checkCancellation()
        if let onComputationStarted {
            await onComputationStarted()
        }
        try Task.checkCancellation()

        let loadedState = try store.load()
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: batches,
            timeZoneIdentifier: timeZoneIdentifier
        )
        try Task.checkCancellation()
        let assessment = try FinanceRecurringPaymentDetector.detect(input: input, now: .now)
        try Task.checkCancellation()

        // The revision check and atomic write stay in the worker as well. A
        // cancellation is observed before the write, while a concurrent
        // override still wins through the store's revision conflict path.
        var state = loadedState
        do {
            state = try store.saveAssessment(
                assessment,
                inputDigest: input.inputDigest,
                expectedRevision: loadedState.revision
            )
        } catch FinanceRecurringPaymentStoreError.revisionConflict {
            state = (try? store.load()) ?? loadedState
        }
        try Task.checkCancellation()

        let rows = FinanceRecurringPaymentsViewModel.makeRows(
            assessment: assessment,
            transactions: input.transactions,
            overrides: state.overrides,
            staleCache: nil,
            isStale: false
        )
        return FinanceRecurringRefreshResult(
            state: state,
            assessment: assessment,
            rows: rows
        )
    }

    func staleMaterial(
        transactions: [FinanceImportedTransaction],
        batches: [FinanceImportBatchProvenance],
        timeZoneIdentifier: String
    ) -> FinanceRecurringStaleResult {
        guard let state = try? store.load() else {
            return FinanceRecurringStaleResult(state: nil, rows: [], usesCache: false)
        }

        guard let input = try? FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: batches,
            timeZoneIdentifier: timeZoneIdentifier
        ) else {
            return FinanceRecurringStaleResult(
                state: state,
                rows: FinanceRecurringPaymentsViewModel.managedStaleRows(from: state),
                usesCache: false
            )
        }

        if let cache = state.evidenceCache,
           cache.inputDigest == input.inputDigest,
           FinanceRecurringPaymentDetector.validateCachedAssessment(cache.assessment, for: input) {
            let rows = FinanceRecurringPaymentsViewModel.makeRows(
                assessment: nil,
                transactions: input.transactions,
                overrides: state.overrides,
                staleCache: cache.assessment,
                isStale: true
            )
            return FinanceRecurringStaleResult(state: state, rows: rows, usesCache: true)
        }

        let rows = FinanceRecurringPaymentsViewModel.makeRows(
            assessment: nil,
            transactions: input.transactions,
            overrides: state.overrides,
            staleCache: nil,
            isStale: true
        )
        return FinanceRecurringStaleResult(state: state, rows: rows, usesCache: false)
    }
}

private struct FinanceRecurringRefreshResult: Sendable {
    let state: FinanceRecurringPaymentStoreState
    let assessment: FinanceRecurringPaymentAssessment
    let rows: [FinanceRecurringPaymentRow]
}

private struct FinanceRecurringStaleResult: Sendable {
    let state: FinanceRecurringPaymentStoreState?
    let rows: [FinanceRecurringPaymentRow]
    let usesCache: Bool
}

struct FinanceRecurringPaymentsView: View {
    @ObservedObject var viewModel: FinanceRecurringPaymentsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
                LifeOSIcon(.refresh, context: .card)
                    .foregroundStyle(LifeOSTokens.Module.finance)
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text("Recurring payments")
                        .lifeOSTypography(.cardTitle)
                    Text("Local estimates from reviewed mapped imports")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 0)
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let staleMessage = viewModel.staleMessage {
                Label(staleMessage, systemImage: "clock.badge.exclamationmark")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.rows.isEmpty {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    Text("No validated recurring evidence yet")
                        .lifeOSTypography(.button)
                    Text("Only mapped-v3 imported rows with a stable account identity are assessed. Live bank observations and legacy imports stay unavailable here.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    ForEach(viewModel.rows) { row in
                        Button { viewModel.beginManage(for: row) } label: {
                            FinanceRecurringPaymentRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("finance-recurring-row-\(row.id)")
                    }
                }
            }

            Text("Estimates are reviewable and do not confirm a subscription or change a bank payment. Saved on this device.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .sheet(item: viewModel.editorBinding(for: .recurringCard)) { row in
            FinanceRecurringPaymentManageSheet(
                row: row,
                timeZoneIdentifier: viewModel.timeZoneIdentifier,
                errorMessage: viewModel.errorMessage,
                onSave: { cadence, status, anchorDate in
                    viewModel.save(row: row, cadence: cadence, status: status, anchorDate: anchorDate)
                },
                onReset: { viewModel.resetAutomatic(for: row) }
            )
        }
    }
}

private struct FinanceRecurringPaymentRowView: View {
    let row: FinanceRecurringPaymentRow

    var body: some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(.refresh, context: .card)
                .foregroundStyle(row.status == .active ? LifeOSTokens.Module.finance : LifeOSTokens.tertiaryText)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                HStack(spacing: LifeOSTokens.Space.xs) {
                    Text(row.displayName)
                        .lifeOSTypography(.button)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    if row.override != nil {
                        Text("Set by you")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.accent)
                    }
                }
                HStack(spacing: LifeOSTokens.Space.xs) {
                    Text(row.cadence?.displayName ?? "Needs review")
                    Text("·")
                    Text(row.status.displayName)
                }
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                if row.isStale {
                    Text("Stale assessment · refresh required")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                } else if let next = row.predictedDate {
                    Text("Estimated next payment · \(next, style: .date)")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.estimate)
                } else if row.evidence.isEmpty {
                    Text("Evidence unavailable")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                }
            }
            Spacer(minLength: LifeOSTokens.Space.sm)
            if let last = row.evidence.last {
                Text(FinanceRecurringPaymentFormatter.euro(cents: last.amountCents))
                    .lifeOSTypography(.button)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .monospacedDigit()
            }
            LifeOSIcon(.chevronRight, context: .disclosure)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.top, 3)
        }
        .padding(.vertical, LifeOSTokens.Space.xs)
        .contentShape(Rectangle())
    }
}

struct FinanceRecurringPaymentManageSheet: View {
    enum CadenceChoice: String, CaseIterable, Identifiable {
        case automatic
        case weekly
        case monthly
        case yearly

        var id: String { rawValue }
        var cadence: FinanceRecurringCadence? {
            switch self {
            case .automatic: nil
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        }
        var displayName: String {
            switch self {
            case .automatic: "Automatic"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            }
        }
    }

    enum StatusChoice: String, CaseIterable, Identifiable {
        case active
        case paused
        case ignored

        var id: String { rawValue }
        var status: FinanceRecurringPaymentStatus { FinanceRecurringPaymentStatus(rawValue: rawValue) ?? .active }
        var displayName: String { status.displayName }
    }

    let row: FinanceRecurringPaymentRow
    let timeZoneIdentifier: String
    let onSave: (FinanceRecurringCadence?, FinanceRecurringPaymentStatus, Date?) -> Bool
    let onReset: () -> Bool
    let errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var cadenceChoice: CadenceChoice
    @State private var statusChoice: StatusChoice
    @State private var anchorDate: Date

    init(
        row: FinanceRecurringPaymentRow,
        timeZoneIdentifier: String,
        errorMessage: String? = nil,
        onSave: @escaping (FinanceRecurringCadence?, FinanceRecurringPaymentStatus, Date?) -> Bool,
        onReset: @escaping () -> Bool
    ) {
        self.row = row
        self.timeZoneIdentifier = timeZoneIdentifier
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onReset = onReset
        _cadenceChoice = State(initialValue: CadenceChoice(
            rawValue: row.override?.cadence?.rawValue ?? CadenceChoice.automatic.rawValue
        ) ?? .automatic)
        _statusChoice = State(initialValue: StatusChoice(
            rawValue: row.status.rawValue
        ) ?? .active)
        _anchorDate = State(initialValue: row.anchor?.date ?? row.evidence.last?.bookedAt ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(row.displayName)
                        .font(.headline)
                    Text("Manage Payment")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Text("This control changes LifeOS tracking only. It never starts, stops, or edits a bank payment.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Schedule") {
                    Picker("Frequency", selection: $cadenceChoice) {
                        ForEach(CadenceChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    if cadenceChoice != .automatic {
                        DatePicker("Anchor date", selection: $anchorDate, displayedComponents: .date)
                    }
                    Picker("Status", selection: $statusChoice) {
                        ForEach(StatusChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                }

                Section("Assessment") {
                    Text(row.confidence.displayName)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(row.confidence == .high ? LifeOSTokens.success : LifeOSTokens.warning)
                    if !row.reasonCodes.isEmpty {
                        let reasonText = row.reasonCodes.map(\.displayName).joined(separator: " · ")
                        Text("Review reasons · \(reasonText)")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detected = row.candidate?.detectedCadence {
                        Text("Detected cadence · \(detected.displayName)")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }
                    if row.isStale {
                        Text("Stale assessment · refresh required before treating a prediction as current.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Evidence") {
                    if row.evidence.isEmpty {
                        Text("Evidence unavailable. The managed decision remains visible until new mapped import evidence is available.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warning)
                    } else {
                        ForEach(row.evidence) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(line.bookedAt, style: .date)
                                    Spacer()
                                    Text(FinanceRecurringPaymentFormatter.euro(cents: line.amountCents))
                                        .monospacedDigit()
                                }
                                .lifeOSTypography(.metadata)
                                Text("\(line.sourceNamespace) · account \(line.accountID.uuidString.prefix(8)) · \(FinanceRecurringPaymentFormatter.batchDescription(batchID: line.batchID, row: line.sourceRowNumber))")
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                        }
                    }
                }

                Section {
                    Text("Saved on this device · timezone \(timeZoneIdentifier)")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    if statusChoice == .paused {
                        Text("Paused only changes LifeOS tracking; it does not stop a bank payment.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warning)
                    }
                }
            }
            .navigationTitle("Manage Payment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(cadenceChoice.cadence, statusChoice.status, cadenceChoice == .automatic ? nil : anchorDate) {
                            dismiss()
                        }
                    }
                    .disabled(cadenceChoice != .automatic && anchorDate.timeIntervalSinceReferenceDate.isFinite == false)
                }
                if row.override != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Reset to automatic") {
                            if onReset() {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}

private enum FinanceRecurringPaymentFormatter {
    static func euro(cents: Int) -> String {
        let sign = cents < 0 ? "−" : ""
        let magnitude = cents == Int.min ? Int.max : abs(cents)
        let euros = magnitude / 100
        let remainder = magnitude % 100
        return String(format: "%@€%d.%02d", sign, euros, remainder)
    }

    static func batchDescription(batchID: UUID?, row: Int?) -> String {
        let batch = batchID.map { "batch \($0.uuidString.prefix(8))" } ?? "batch unavailable"
        let sourceRow = row.map { "row \($0)" } ?? "row unavailable"
        return "\(batch) · \(sourceRow)"
    }
}

private extension FinanceRecurringCadence {
    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}

private extension FinanceRecurringPaymentStatus {
    var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .ignored: "Ignored"
        }
    }
}

private extension FinanceRecurringConfidence {
    var displayName: String {
        switch self {
        case .high: "High confidence"
        case .needsReview: "Needs review"
        }
    }
}

private extension FinanceRecurringReasonCode {
    var displayName: String {
        var words = ""
        for character in rawValue {
            if character.isUppercase, !words.isEmpty {
                words.append(" ")
            }
            words.append(contentsOf: character.lowercased())
        }
        return words.capitalized
    }
}
