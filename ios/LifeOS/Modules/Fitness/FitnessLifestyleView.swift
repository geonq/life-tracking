import SwiftUI
import Combine

public struct FitnessLifestyleRepositorySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let events: [FitnessLifestyleEvent]
    public let settings: [FitnessLifestyleSettings]
    public let loadStatus: FitnessLifestyleLoadStatus
    public let integrityWarning: String?
    public let error: FitnessLifestyleStoreError?
}

/// One observable repository is shared by the nutrition summary and its
/// detail routes. It owns the cached in-memory snapshot; all disk reads occur
/// from refresh tasks/notification callbacks, never from SwiftUI body.
public final class FitnessLifestyleRepository: ObservableObject {
    public let store: FitnessLifestyleLedgerStore
    @Published public private(set) var snapshot: FitnessLifestyleRepositorySnapshot
    private var observer: NSObjectProtocol?

    public init(
        usesVisualFixtures: Bool = false,
        persistenceURL: URL? = FitnessLifestyleLedgerStore.defaultPersistenceURL
    ) {
        let resolvedPersistenceURL = usesVisualFixtures ? nil : persistenceURL
        let resolvedStore = FitnessLifestyleLedgerStore(
            persistenceURL: resolvedPersistenceURL,
            fixtureOnly: usesVisualFixtures,
            loadImmediately: false,
            requirePersistence: !usesVisualFixtures
        )
        let initialSnapshot = FitnessLifestyleRepositorySnapshot(
            revision: resolvedStore.revision,
            events: resolvedStore.lastLoadError == nil ? resolvedStore.events : [],
            settings: resolvedStore.lastLoadError == nil ? FitnessLifestyleKind.allCases.compactMap { resolvedStore.savedSettings(for: $0) } : [],
            loadStatus: resolvedStore.loadStatus,
            integrityWarning: resolvedStore.integrityWarning,
            error: resolvedStore.lastLoadError
        )
        self.store = resolvedStore
        self.snapshot = initialSnapshot
        observer = NotificationCenter.default.addObserver(
            forName: .fitnessLifestyleLedgerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let key = note.object as? String,
                  key == self.store.persistenceKey else { return }
            self.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func refresh() {
        do {
            try store.reload()
            publish(error: store.lastLoadError)
        } catch let error as FitnessLifestyleStoreError {
            publish(error: error)
        } catch {
            publish(error: .corruptStorage(error.localizedDescription))
        }
    }

    public func events(on localDay: String, kind: FitnessLifestyleKind, timeZoneIdentifier: String) throws -> [FitnessLifestyleEvent] {
        try store.events(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
    }

    public func summary(on localDay: String, kind: FitnessLifestyleKind, timeZoneIdentifier: String) throws -> FitnessLifestyleDaySummary {
        try store.daySummary(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
    }

    public func settings(for kind: FitnessLifestyleKind) -> FitnessLifestyleSettings {
        store.settings(for: kind)
    }

    public func dailyInputSnapshot(on localDay: String, timeZoneIdentifier: String) throws -> FitnessLifestyleDailyInputSnapshot {
        try store.dailyInputSnapshot(on: localDay, timeZoneIdentifier: timeZoneIdentifier)
    }

    private func publish(error: FitnessLifestyleStoreError?) {
        snapshot = FitnessLifestyleRepositorySnapshot(
            revision: store.revision,
            events: error == nil ? store.events : [],
            settings: error == nil ? FitnessLifestyleKind.allCases.compactMap { store.savedSettings(for: $0) } : [],
            loadStatus: store.loadStatus,
            integrityWarning: store.integrityWarning,
            error: error
        )
    }
}

public enum FitnessLifestyleReminderSchedulingState: Equatable, Sendable {
    case idle
    case checking
    case awaitingPermission
    case permissionDenied
    case notScheduled
    case scheduled(pendingCount: Int)
    case unavailable(String)
    case error(String)
}

/// Owns the production permission/reconciliation lifecycle for lifestyle
/// reminders. A status read on appearance never prompts unexpectedly; a save
/// that explicitly enables reminders may request permission as a direct user
/// action. Generation checks keep stale callbacks from overwriting visible
/// state after a newer save or scene activation.
@MainActor
public final class FitnessLifestyleReminderCoordinator: ObservableObject {
    @Published public private(set) var authorization: FitnessLifestyleNotificationAuthorization = .unknown
    @Published public private(set) var scheduling: FitnessLifestyleReminderSchedulingState = .idle

    private let client: FitnessLifestyleNotificationClient?
    private let reconciler: FitnessLifestyleReminderReconciler?
    private var operationID = 0

    public init(client: FitnessLifestyleNotificationClient? = nil) {
#if canImport(UserNotifications)
        let resolvedClient = client ?? SystemFitnessLifestyleNotificationClient()
        self.client = resolvedClient
        self.reconciler = FitnessLifestyleReminderReconciler(client: resolvedClient)
#else
        self.client = client
        self.reconciler = client.map(FitnessLifestyleReminderReconciler.init)
#endif
    }

    public func reconcile(
        settings: [FitnessLifestyleSettings],
        timeZoneIdentifier: String,
        now: Date = Date(),
        requestPermissionIfNeeded: Bool = false
    ) {
        let operation = beginOperation()
        guard let client, let reconciler else {
            scheduling = .unavailable("Local notifications are unavailable on this platform.")
            return
        }
        client.authorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }
                self.authorization = status
                if status == .notDetermined {
                    let hasEnabledReminder = settings.contains(where: \.reminderEnabled)
                    guard hasEnabledReminder else {
                        self.readAndReconcile(
                            operation: operation,
                            client: client,
                            reconciler: reconciler,
                            settings: settings,
                            timeZoneIdentifier: timeZoneIdentifier,
                            now: now
                        )
                        return
                    }
                    self.scheduling = .awaitingPermission
                    guard requestPermissionIfNeeded else { return }
                    client.requestAuthorization { [weak self] result in
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == operation else { return }
                            switch result {
                            case .failure(let error):
                                self.scheduling = .error(error.localizedDescription)
                            case .success:
                                client.authorizationStatus { [weak self] refreshedStatus in
                                    Task { @MainActor [weak self] in
                                        guard let self, self.operationID == operation else { return }
                                        self.authorization = refreshedStatus
                                        self.readAndReconcile(
                                            operation: operation,
                                            client: client,
                                            reconciler: reconciler,
                                            settings: settings,
                                            timeZoneIdentifier: timeZoneIdentifier,
                                            now: now
                                        )
                                    }
                                }
                            }
                        }
                    }
                    return
                }
                self.readAndReconcile(
                    operation: operation,
                    client: client,
                    reconciler: reconciler,
                    settings: settings,
                    timeZoneIdentifier: timeZoneIdentifier,
                    now: now
                )
            }
        }
    }

    public func markUnavailable(_ detail: String) {
        reconciler?.cancel()
        operationID &+= 1
        scheduling = .unavailable(detail)
    }

    private func readAndReconcile(
        operation: Int,
        client: FitnessLifestyleNotificationClient,
        reconciler: FitnessLifestyleReminderReconciler,
        settings: [FitnessLifestyleSettings],
        timeZoneIdentifier: String,
        now: Date
    ) {
        guard operationID == operation else { return }
        scheduling = .checking
        reconciler.reconcile(settings: settings, timeZoneIdentifier: timeZoneIdentifier, now: now) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == operation else { return }
                switch result {
                case .failure(.authorizationDenied):
                    self.scheduling = self.authorization == .denied
                        ? .permissionDenied
                        : .unavailable("Notification authorization is not schedulable.")
                case .failure(let error):
                    self.scheduling = .error(error.localizedDescription)
                case .success(let identifiers):
                    let enabled = settings.contains(where: \.reminderEnabled)
                    self.scheduling = enabled ? .scheduled(pendingCount: identifiers.count) : .notScheduled
                }
            }
        }
    }

    private func beginOperation() -> Int {
        reconciler?.cancel()
        operationID &+= 1
        scheduling = .checking
        return operationID
    }
}

/// A small, local-first workflow for hydration, caffeine, and alcohol facts.
/// It deliberately owns logging and settings only; HealthKit remains a future
/// read boundary. Notification delivery is reconciled by the typed reminder
/// service after authorization, not guessed from this view.
public struct FitnessLifestyleView: View {
    public let kind: FitnessLifestyleKind
    public let usesVisualFixtures: Bool
    public let fixtureTotal: Double?
    public let fixtureUnit: FitnessLifestyleUnit?
    @State private var selectedDate: Date
    @State private var events: [FitnessLifestyleEvent] = []
    @State private var summary: FitnessLifestyleDaySummary
    @State private var settings: FitnessLifestyleSettings
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var editingEvent: FitnessLifestyleEvent?
    @State private var errorMessage: String?
    @State private var refreshToken = UUID()
    @ObservedObject private var repository: FitnessLifestyleRepository
    @StateObject private var reminderCoordinator: FitnessLifestyleReminderCoordinator
    @Environment(\.scenePhase) private var scenePhase

    public init(
        kind: FitnessLifestyleKind,
        selectedDate: Date,
        usesVisualFixtures: Bool = false,
        fixtureTotal: Double? = nil,
        fixtureUnit: FitnessLifestyleUnit? = nil,
        repository: FitnessLifestyleRepository? = nil
    ) {
        self.kind = kind
        self.usesVisualFixtures = usesVisualFixtures
        self.fixtureTotal = fixtureTotal
        self.fixtureUnit = fixtureUnit
        _selectedDate = State(initialValue: selectedDate)
        _summary = State(initialValue: usesVisualFixtures
            ? FitnessLifestyleView.fixtureSummary(kind: kind, date: selectedDate, total: fixtureTotal, unit: fixtureUnit)
            : FitnessLifestyleView.emptySummary(kind: kind, date: selectedDate, timeZoneIdentifier: FitnessLifestyleView.currentTimeZoneIdentifier))
        _settings = State(initialValue: FitnessLifestyleSettings.defaults(for: kind))
        _repository = ObservedObject(wrappedValue: repository ?? FitnessLifestyleRepository(usesVisualFixtures: usesVisualFixtures))
        _reminderCoordinator = StateObject(wrappedValue: FitnessLifestyleReminderCoordinator())
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if usesVisualFixtures {
                    fixtureNotice
                } else if let errorMessage {
                    errorCard(errorMessage)
                }
                dayPicker
                overviewCard
                actionRow
                historyCard
                settingsSummary
            }
            .padding(.horizontal, LifeOSTokens.pagePadding)
            .padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle(kind.displayName)
        .task {
            reload()
            reconcileReminders(requestPermissionIfNeeded: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            reload()
            reconcileReminders(requestPermissionIfNeeded: false)
        }
        .onChange(of: selectedDate) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .fitnessLifestyleLedgerDidChange)) { note in
            guard !usesVisualFixtures,
                  let key = note.object as? String,
                  key == repository.store.persistenceKey else { return }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSSystemTimeZoneDidChange)) { _ in
            guard !usesVisualFixtures else { return }
            reload()
            reconcileReminders(requestPermissionIfNeeded: false)
        }
        .sheet(isPresented: $showingAdd) {
            FitnessLifestyleEntryEditor(kind: kind, selectedDate: selectedDate, initialEvent: nil,
                                        defaultSettings: settings, isFixture: usesVisualFixtures) { result in
                apply(result)
            }
        }
        .sheet(item: $editingEvent) { event in
            FitnessLifestyleEntryEditor(kind: kind, selectedDate: selectedDate, initialEvent: event,
                                        defaultSettings: settings, isFixture: usesVisualFixtures) { result in
                apply(result)
            }
        }
        .sheet(isPresented: $showingSettings) {
            FitnessLifestyleSettingsEditor(kind: kind, initialSettings: settings, isFixture: usesVisualFixtures) { updated in
                guard !usesVisualFixtures else { return }
                do {
                    settings = try repository.store.saveSettings(updated)
                    repository.refresh()
                    errorMessage = nil
                    refreshToken = UUID()
                    reconcileReminders(requestPermissionIfNeeded: updated.reminderEnabled)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .accessibilityIdentifier("fitness-lifestyle-\(kind.rawValue)-view")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.displayName)
                    .font(LifeOSFont.headerLarge(25))
                Text("Timestamped local facts · \(timeZoneIdentifier)")
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(usesVisualFixtures ? "Fixture preview" : "Saved locally")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(usesVisualFixtures ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
        }
    }

    private var fixtureNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            LifeOSIcon(.warning).frame(width: 15, height: 15)
            Text("DEMO FIXTURE · not live and not persisted. Logging controls are disabled in this preview.")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(LifeOSTokens.warning.opacity(0.08), in: LifeOSTokens.cardShape)
        .accessibilityIdentifier("fitness-lifestyle-fixture-notice")
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            LifeOSIcon(.warning).frame(width: 15, height: 15)
            Text(text)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(LifeOSTokens.warning.opacity(0.08), in: LifeOSTokens.cardShape)
        .accessibilityIdentifier("fitness-lifestyle-error")
    }

    private var dayPicker: some View {
        FitnessCard {
            HStack(spacing: 10) {
                Button {
                    shiftDay(-1)
                } label: {
                    LifeOSIcon(.chevronLeft).frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous day")
                .accessibilityIdentifier("fitness-lifestyle-previous-day")
                Spacer()
                VStack(spacing: 2) {
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                        .font(LifeOSFont.inter(14, weight: .semiBold))
                    Text(localDay)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer()
                Button {
                    shiftDay(1)
                } label: {
                    LifeOSIcon(.chevronRight).frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next day")
                .accessibilityIdentifier("fitness-lifestyle-next-day")
            }
        }
        .accessibilityIdentifier("fitness-lifestyle-day-picker")
    }

    private var overviewCard: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Day status")
                        .font(LifeOSFont.header(16))
                    Spacer()
                    Text(statusTitle)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(statusColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTotal)
                        .font(LifeOSFont.spaceGrotesk(31, weight: .bold))
                        .monospacedDigit()
                    Text(displayUnit)
                        .font(LifeOSFont.caption(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Text(statusDetail)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-lifestyle-overview")
    }

    private var actionRow: some View {
        HStack(spacing: 9) {
            Button {
                quickAdd()
            } label: {
                Label(quickActionTitle, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(LifeOSTokens.accent)
            .disabled(usesVisualFixtures || isIntegrityUnavailable || hasActiveHealthKitFacts || settings.quickAmount == nil || summary.explicitNone || summary.alcoholFree)
            .accessibilityIdentifier("fitness-lifestyle-quick-add")

            Button {
                showingAdd = true
            } label: {
                Label("Custom", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .disabled(usesVisualFixtures || isIntegrityUnavailable || hasActiveHealthKitFacts)
            .accessibilityIdentifier("fitness-lifestyle-custom-add")

            Button {
                addNone()
            } label: {
                Label("None today", systemImage: "minus.circle")
            }
            .buttonStyle(.bordered)
            .disabled(usesVisualFixtures || isIntegrityUnavailable || hasActiveHealthKitFacts || summary.missingness != .missing)
            .accessibilityIdentifier("fitness-lifestyle-none")

            if kind == .alcohol {
                Button {
                    addAlcoholFree()
                } label: {
                    Label("Alcohol-free", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(usesVisualFixtures || isIntegrityUnavailable || hasActiveHealthKitFacts || summary.missingness != .missing)
                .accessibilityIdentifier("fitness-lifestyle-alcohol-free")
            }
        }
        .controlSize(.small)
    }

    private var historyCard: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("History")
                        .font(LifeOSFont.header(16))
                    Spacer()
                    Text("\(events.count) active")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if hasActiveHealthKitFacts {
                    Label("HealthKit source-managed facts are read-only; manual changes are disabled to avoid double-counting.", systemImage: "lock.shield")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-lifestyle-source-managed")
                    activeEventRows
                } else if isIntegrityUnavailable {
                    Label("History unavailable until the local ledger is repaired", systemImage: "exclamationmark.triangle")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-lifestyle-integrity-unavailable")
                } else if usesVisualFixtures {
                    Label("Fixture values are shown for visual review only", systemImage: "eye")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-lifestyle-fixture-history")
                } else if summary.explicitNone {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Explicit none recorded for this day", systemImage: "checkmark.circle")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.success)
                            .accessibilityIdentifier("fitness-lifestyle-explicit-none")
                        activeEventRows
                    }
                } else if summary.alcoholFree {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Alcohol-free recorded for this day", systemImage: "checkmark.seal")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.success)
                            .accessibilityIdentifier("fitness-lifestyle-alcohol-free-history")
                        activeEventRows
                    }
                } else if events.isEmpty {
                    Text("No observation for this day. This is not the same as zero.")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-lifestyle-missing")
                } else {
                    activeEventRows
                }
            }
        }
        .accessibilityIdentifier("fitness-lifestyle-history")
    }

    @ViewBuilder
    private var activeEventRows: some View {
        ForEach(events) { event in
            FitnessLifestyleEventRow(event: event,
                                     onEdit: event.provenance == .manual && !hasActiveHealthKitFacts ? { editingEvent = event } : nil,
                                     onDelete: event.provenance == .manual && !hasActiveHealthKitFacts ? { delete(event) } : nil)
        }
    }

    private var settingsSummary: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tracking settings")
                            .font(LifeOSFont.header(15))
                        Text(settingsDetail)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Edit") {
                        showingSettings = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(usesVisualFixtures || isIntegrityUnavailable)
                    .accessibilityIdentifier("fitness-lifestyle-settings")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reminderStatusText)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(reminderStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if reminderCoordinator.scheduling == .awaitingPermission {
                        Button("Allow") {
                            reconcileReminders(requestPermissionIfNeeded: true)
                        }
                        .font(LifeOSFont.caption(10))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(usesVisualFixtures || isIntegrityUnavailable)
                        .accessibilityIdentifier("fitness-lifestyle-reminder-allow")
                    }
                }
                .accessibilityIdentifier("fitness-lifestyle-reminder-status")
            }
        }
    }

    private var localDay: String {
        FitnessLifestyleTime.localDay(for: selectedDate, timeZoneIdentifier: timeZoneIdentifier)
    }

    private var timeZoneIdentifier: String {
        let identifier = TimeZone.current.identifier
        return FitnessLifestyleTime.isValidTimeZoneIdentifier(identifier) ? identifier : "UTC"
    }

    private var statusTitle: String {
        if usesVisualFixtures { return "Fixture preview" }
        if isIntegrityUnavailable { return "Unavailable" }
        switch summary.missingness {
        case .observed: return "Observed"
        case .explicitNone: return "Explicit none"
        case .alcoholFree: return "Alcohol-free"
        case .missing: return "No observation"
        }
    }

    private var statusColor: Color {
        if usesVisualFixtures { return LifeOSTokens.warning }
        if isIntegrityUnavailable { return LifeOSTokens.warning }
        switch summary.missingness {
        case .observed: return LifeOSTokens.accent
        case .explicitNone: return LifeOSTokens.success
        case .alcoholFree: return LifeOSTokens.success
        case .missing: return LifeOSTokens.tertiaryText
        }
    }

    private var displayTotal: String {
        if isIntegrityUnavailable { return "—" }
        if summary.alcoholFree { return "Alcohol-free" }
        guard let total = summary.total else { return summary.explicitNone ? "None" : "—" }
        return total.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var displayUnit: String {
        if summary.alcoholFree { return "state" }
        return summary.unit?.label ?? (summary.explicitNone ? "logged" : kind == .hydration ? "ml" : kind == .caffeine ? "mg" : "standard drinks")
    }

    private var statusDetail: String {
        if usesVisualFixtures { return "Fixture-only preview; durable entries are intentionally hidden." }
        if isIntegrityUnavailable { return repository.snapshot.integrityWarning ?? "The local ledger is unavailable; no value was inferred." }
        if summary.missingness == .observed {
            let sources = summary.provenance.map(\.label).joined(separator: ", ")
            return "\(summary.sampleCount) source fact\(summary.sampleCount == 1 ? "" : "s") · \(sources.isEmpty ? "Source recorded" : sources) · exact timestamp retained."
        }
        if summary.explicitNone { return "The explicit none marker is retained separately from an unobserved day." }
        if summary.alcoholFree { return "Alcohol-free is a distinct user-recorded state, separate from none and alcohol quantities." }
        return "Add a timestamped quantity or record explicit none for this day."
    }

    private var quickActionTitle: String {
        guard let amount = settings.quickAmount, let unit = settings.quickUnit else { return "Quick add" }
        return "+\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(unit.label)"
    }

    private var settingsDetail: String {
        let goal = settings.goal.map { "Goal \($0.formatted(.number.precision(.fractionLength(0...2))))" } ?? "No goal"
        let quick = settings.quickAmount.map { "Quick \($0.formatted(.number.precision(.fractionLength(0...2)))) \(settings.quickUnit?.label ?? "")" } ?? "No quick amount"
        return "\(goal) · \(quick)"
    }

    private var reminderStatusText: String {
        if usesVisualFixtures { return "Reminder preview only · not scheduled" }
        if isIntegrityUnavailable { return "Reminder unavailable · repair the local ledger first" }
        switch reminderCoordinator.scheduling {
        case .idle, .checking: return settings.reminderEnabled ? "Checking notification permission and schedule…" : "No reminder scheduled"
        case .awaitingPermission: return "Permission required before a reminder can be scheduled"
        case .permissionDenied: return "Notifications denied · enable them in system settings"
        case .notScheduled: return "No reminder scheduled"
        case .scheduled(let pendingCount):
            if reminderCoordinator.authorization == .ephemeral {
                return "Temporary notification authorization · pending requests: \(pendingCount) · delivery is system-controlled"
            }
            return "Scheduled pending requests: \(pendingCount) · delivery is system-controlled"
        case .unavailable(let detail): return "Reminder unavailable · \(detail)"
        case .error(let detail): return "Reminder scheduling failed · \(detail)"
        }
    }

    private var reminderStatusColor: Color {
        switch reminderCoordinator.scheduling {
        case .scheduled: return LifeOSTokens.success
        case .permissionDenied, .awaitingPermission, .unavailable, .error: return LifeOSTokens.warning
        case .idle, .checking, .notScheduled: return LifeOSTokens.tertiaryText
        }
    }

    private func reconcileReminders(requestPermissionIfNeeded: Bool) {
        guard !usesVisualFixtures else { return }
        guard repository.snapshot.error == nil, !isIntegrityUnavailable else {
            reminderCoordinator.markUnavailable("The local ledger is unavailable.")
            return
        }
        let allSettings = FitnessLifestyleKind.allCases.map { kind in
            kind == self.kind ? settings : repository.settings(for: kind)
        }
        reminderCoordinator.reconcile(
            settings: allSettings,
            timeZoneIdentifier: timeZoneIdentifier,
            requestPermissionIfNeeded: requestPermissionIfNeeded
        )
    }

    private func quickAdd() {
        guard !usesVisualFixtures, !hasActiveHealthKitFacts,
              let amount = settings.quickAmount, let unit = settings.quickUnit else { return }
        do {
            let occurredAt = try FitnessLifestyleTime.datePreservingLocalDay(selectedDate, now: Date(), timeZoneIdentifier: timeZoneIdentifier)
            _ = try repository.store.addQuantity(kind: kind, amount: amount, unit: unit, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func addNone() {
        guard !usesVisualFixtures, !hasActiveHealthKitFacts else { return }
        do {
            let occurredAt = try FitnessLifestyleTime.datePreservingLocalDay(selectedDate, now: Date(), timeZoneIdentifier: timeZoneIdentifier)
            _ = try repository.store.addNone(kind: kind, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func addAlcoholFree() {
        guard !usesVisualFixtures, !hasActiveHealthKitFacts, kind == .alcohol else { return }
        do {
            let occurredAt = try FitnessLifestyleTime.datePreservingLocalDay(selectedDate, now: Date(), timeZoneIdentifier: timeZoneIdentifier)
            _ = try repository.store.addAlcoholFree(occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ event: FitnessLifestyleEvent) {
        guard !usesVisualFixtures, !hasActiveHealthKitFacts else { return }
        do {
            _ = try repository.store.delete(eventID: event.id)
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(_ result: FitnessLifestyleEntryEditor.Result) {
        guard !usesVisualFixtures else { return }
        guard !hasActiveHealthKitFacts else {
            errorMessage = "HealthKit source-managed facts are read-only; manual changes are disabled to avoid double-counting."
            return
        }
        do {
            switch result {
            case .addQuantity(let amount, let unit, let occurredAt, let entryTimeZone, let foldPolicy, let note):
                _ = try repository.store.addQuantity(kind: kind, amount: amount, unit: unit, occurredAt: occurredAt, timeZoneIdentifier: entryTimeZone, journalNote: note, localTimeFoldPolicy: foldPolicy)
            case .addNone(let occurredAt, let entryTimeZone, let foldPolicy, let note):
                _ = try repository.store.addNone(kind: kind, occurredAt: occurredAt, timeZoneIdentifier: entryTimeZone, journalNote: note, localTimeFoldPolicy: foldPolicy)
            case .addAlcoholFree(let occurredAt, let entryTimeZone, let foldPolicy, let note):
                _ = try repository.store.addAlcoholFree(occurredAt: occurredAt, timeZoneIdentifier: entryTimeZone, journalNote: note, localTimeFoldPolicy: foldPolicy)
            case .editQuantity(let eventID, let amount, let unit, let occurredAt, let entryTimeZone, let foldPolicy, let note):
                _ = try repository.store.editQuantity(eventID: eventID, amount: amount, unit: unit, occurredAt: occurredAt, timeZoneIdentifier: entryTimeZone, journalNote: note, clearJournalNote: note == nil, localTimeFoldPolicy: foldPolicy)
            case .editNone(let eventID, let occurredAt, let entryTimeZone, let foldPolicy, let note):
                _ = try repository.store.editToNone(eventID: eventID, occurredAt: occurredAt, timeZoneIdentifier: entryTimeZone, journalNote: note, clearJournalNote: note == nil, localTimeFoldPolicy: foldPolicy)
            case .editAlcoholFree(let eventID, let occurredAt, let entryTimeZone, let foldPolicy, let note):
                _ = try repository.store.editToAlcoholFree(eventID: eventID, occurredAt: occurredAt, timeZoneIdentifier: entryTimeZone, journalNote: note, clearJournalNote: note == nil, localTimeFoldPolicy: foldPolicy)
            }
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func reload() {
        refreshToken = UUID()
        guard !usesVisualFixtures else {
            events = []
            summary = FitnessLifestyleView.fixtureSummary(kind: kind, date: selectedDate, total: fixtureTotal, unit: fixtureUnit)
            return
        }
        do {
            repository.refresh()
            if repository.snapshot.error != nil {
                events = []
                summary = FitnessLifestyleView.emptySummary(kind: kind, date: selectedDate, timeZoneIdentifier: timeZoneIdentifier)
                settings = FitnessLifestyleSettings.defaults(for: kind)
                errorMessage = repository.snapshot.integrityWarning ?? repository.snapshot.error?.localizedDescription
                return
            }
            events = try repository.events(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
            summary = try repository.summary(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
            settings = repository.settings(for: kind)
            errorMessage = nil
        } catch {
            events = []
            summary = FitnessLifestyleView.emptySummary(kind: kind, date: selectedDate, timeZoneIdentifier: timeZoneIdentifier)
            errorMessage = error.localizedDescription
        }
    }

    private func shiftDay(_ value: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        selectedDate = calendar.date(byAdding: .day, value: value, to: selectedDate) ?? selectedDate
    }

    private var isIntegrityUnavailable: Bool {
        !usesVisualFixtures && repository.snapshot.error != nil
    }

    private var hasActiveHealthKitFacts: Bool {
        !usesVisualFixtures &&
            summary.missingness == .observed &&
            summary.provenance.contains(.healthKit)
    }

    private static var currentTimeZoneIdentifier: String {
        let identifier = TimeZone.current.identifier
        return FitnessLifestyleTime.isValidTimeZoneIdentifier(identifier) ? identifier : "UTC"
    }

    private static func emptySummary(kind: FitnessLifestyleKind, date: Date, timeZoneIdentifier: String) -> FitnessLifestyleDaySummary {
        FitnessLifestyleDaySummary(localDay: FitnessLifestyleTime.localDay(for: date, timeZoneIdentifier: timeZoneIdentifier), kind: kind,
                                   total: nil, unit: nil, explicitNone: false, missingness: .missing,
                                   provenance: [], sampleCount: 0)
    }

    private static func fixtureSummary(kind: FitnessLifestyleKind, date: Date, total: Double?, unit: FitnessLifestyleUnit?) -> FitnessLifestyleDaySummary {
        FitnessLifestyleDaySummary(localDay: FitnessLifestyleTime.localDay(for: date, timeZoneIdentifier: currentTimeZoneIdentifier), kind: kind,
                                   total: total, unit: unit, explicitNone: false,
                                   missingness: total == nil ? .missing : .observed,
                                   provenance: total == nil ? [] : [.manual], sampleCount: total == nil ? 0 : 1)
    }
}

private struct FitnessLifestyleEventRow: View {
    let event: FitnessLifestyleEvent
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(event.state == .quantity ? LifeOSTokens.accent : LifeOSTokens.success)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.state == .explicitNone ? "None recorded" : event.state == .alcoholFree ? "Alcohol-free" : "\(event.value?.formatted(.number.precision(.fractionLength(0...2))) ?? "—") \(event.unit?.label ?? "")")
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                Text("\(FitnessLifestyleTime.timeString(for: event.occurredAt, timeZoneIdentifier: event.timeZoneIdentifier)) · \(event.localTimeFoldPolicy == .earlierOffset ? "earlier occurrence" : "later occurrence") · \(event.provenance.label) · \(event.timeZoneIdentifier)")
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                if let note = event.journalNote {
                    Text("Note: \(note.text)")
                        .font(LifeOSFont.caption(9))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Text(note.displayLinkage)
                        .font(LifeOSFont.caption(8))
                        .foregroundStyle(LifeOSTokens.warning)
                }
            }
            Spacer(minLength: 5)
            if let onEdit, let onDelete {
                Button("Edit", action: onEdit)
                    .font(LifeOSFont.caption(10))
                    .buttonStyle(.plain)
                    .foregroundStyle(LifeOSTokens.accent)
                    .accessibilityIdentifier("fitness-lifestyle-edit-\(event.id.uuidString)")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete entry")
                .accessibilityIdentifier("fitness-lifestyle-delete-\(event.id.uuidString)")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-lifestyle-entry-\(event.id.uuidString)")
    }
}

private struct FitnessLifestyleEntryEditor: View {
    enum Result {
        case addQuantity(Double, FitnessLifestyleUnit, Date, String, FitnessLifestyleLocalTimeFoldPolicy, FitnessLifestyleJournalNote?)
        case addNone(Date, String, FitnessLifestyleLocalTimeFoldPolicy, FitnessLifestyleJournalNote?)
        case addAlcoholFree(Date, String, FitnessLifestyleLocalTimeFoldPolicy, FitnessLifestyleJournalNote?)
        case editQuantity(UUID, Double, FitnessLifestyleUnit, Date, String, FitnessLifestyleLocalTimeFoldPolicy, FitnessLifestyleJournalNote?)
        case editNone(UUID, Date, String, FitnessLifestyleLocalTimeFoldPolicy, FitnessLifestyleJournalNote?)
        case editAlcoholFree(UUID, Date, String, FitnessLifestyleLocalTimeFoldPolicy, FitnessLifestyleJournalNote?)
    }

    let kind: FitnessLifestyleKind
    let selectedDate: Date
    let initialEvent: FitnessLifestyleEvent?
    let defaultSettings: FitnessLifestyleSettings
    let isFixture: Bool
    let entryTimeZoneIdentifier: String
    let onSave: (Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var unit: FitnessLifestyleUnit
    @State private var occurredAt: Date
    @State private var explicitNone = false
    @State private var alcoholFree = false
    @State private var localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    @State private var noteText = ""
    @State private var errorMessage: String?

    init(kind: FitnessLifestyleKind, selectedDate: Date, initialEvent: FitnessLifestyleEvent?, defaultSettings: FitnessLifestyleSettings,
         isFixture: Bool, onSave: @escaping (Result) -> Void) {
        self.kind = kind
        self.selectedDate = selectedDate
        self.initialEvent = initialEvent
        self.defaultSettings = defaultSettings
        self.isFixture = isFixture
        let currentTimeZone = TimeZone.current.identifier
        self.entryTimeZoneIdentifier = initialEvent?.timeZoneIdentifier ??
            (FitnessLifestyleTime.isValidTimeZoneIdentifier(currentTimeZone) ? currentTimeZone : "UTC")
        self.onSave = onSave
        _amountText = State(initialValue: initialEvent?.value.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? defaultSettings.quickAmount.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "")
        _unit = State(initialValue: initialEvent?.unit ?? defaultSettings.quickUnit ?? kind.defaultQuickAmount?.unit ?? kind.defaultUnit)
        _occurredAt = State(initialValue: initialEvent?.occurredAt ?? selectedDate)
        _explicitNone = State(initialValue: initialEvent?.state == .explicitNone)
        _alcoholFree = State(initialValue: initialEvent?.state == .alcoholFree)
        _localTimeFoldPolicy = State(initialValue: initialEvent?.localTimeFoldPolicy ?? .earlierOffset)
        _noteText = State(initialValue: initialEvent?.journalNote?.text ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    Toggle("Explicit none", isOn: explicitNoneBinding)
                    if kind == .alcohol {
                        Toggle("Alcohol-free", isOn: alcoholFreeBinding)
                    }
                    if !explicitNone && !alcoholFree {
                        TextField("Amount", text: $amountText)
#if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
#endif
                        Stepper(value: amountBinding, in: 0...maximumAmount, step: stepAmount) {
                            Text("Adjust by \(stepAmount.formatted(.number.precision(.fractionLength(0...2)))) \(unit.label)")
                                .font(LifeOSFont.caption(10))
                        }
                        if kind.allowedUnits.count > 1 {
                            Picker("Unit", selection: $unit) {
                                ForEach(Array(kind.allowedUnits).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { unit in
                                    Text(unit.label).tag(unit)
                                }
                            }
                        } else {
                            LabeledContent("Unit", value: unit.label)
                        }
                    }
                    DatePicker("Time", selection: $occurredAt)
                    Picker("Repeated-hour choice", selection: $localTimeFoldPolicy) {
                        ForEach(FitnessLifestyleLocalTimeFoldPolicy.allCases, id: \.self) { policy in
                            Text(policy == .earlierOffset ? "Earlier occurrence" : "Later occurrence")
                                .tag(policy)
                        }
                    }
                    .accessibilityIdentifier("fitness-lifestyle-entry-fold-policy")
                    TextField("Optional journal note", text: $noteText, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(LifeOSTokens.warning)
                }
                Section {
                    Text("The exact timestamp and local timezone are retained. Alcohol uses standard drinks only; no ml or BAC values are accepted.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            .navigationTitle(initialEvent == nil ? "Add \(kind.displayName)" : "Edit \(kind.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isFixture)
                        .accessibilityIdentifier("fitness-lifestyle-editor-save")
                }
            }
        }
    }

    private func save() {
        guard !isFixture else { return }
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : FitnessLifestyleJournalNote(text: noteText)
        let resolvedOccurredAt: Date
        do {
            resolvedOccurredAt = try FitnessLifestyleTime.date(
                preservingLocalClockOf: occurredAt,
                timeZoneIdentifier: entryTimeZoneIdentifier,
                foldPolicy: localTimeFoldPolicy
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if alcoholFree && kind == .alcohol {
            if let initialEvent { onSave(.editAlcoholFree(initialEvent.id, resolvedOccurredAt, entryTimeZoneIdentifier, localTimeFoldPolicy, note)) }
            else { onSave(.addAlcoholFree(resolvedOccurredAt, entryTimeZoneIdentifier, localTimeFoldPolicy, note)) }
            dismiss()
            return
        }
        if explicitNone {
            if let initialEvent { onSave(.editNone(initialEvent.id, resolvedOccurredAt, entryTimeZoneIdentifier, localTimeFoldPolicy, note)) }
            else { onSave(.addNone(resolvedOccurredAt, entryTimeZoneIdentifier, localTimeFoldPolicy, note)) }
            dismiss()
            return
        }
        guard let amount = FitnessJournalQuantity.parse(amountText) else {
            errorMessage = "Enter a positive amount using up to two decimal places."
            return
        }
        guard amount > 0 else {
            errorMessage = "Amount must be greater than zero."
            return
        }
        if let initialEvent { onSave(.editQuantity(initialEvent.id, amount, unit, resolvedOccurredAt, entryTimeZoneIdentifier, localTimeFoldPolicy, note)) }
        else { onSave(.addQuantity(amount, unit, resolvedOccurredAt, entryTimeZoneIdentifier, localTimeFoldPolicy, note)) }
        dismiss()
    }

    private var explicitNoneBinding: Binding<Bool> {
        Binding(
            get: { explicitNone },
            set: { value in
                explicitNone = value
                if value { alcoholFree = false }
            }
        )
    }

    private var alcoholFreeBinding: Binding<Bool> {
        Binding(
            get: { alcoholFree },
            set: { value in
                alcoholFree = value
                if value { explicitNone = false }
            }
        )
    }

    private var stepAmount: Double {
        switch kind {
        case .hydration: return 50
        case .caffeine: return 5
        case .alcohol: return 0.5
        }
    }

    private var maximumAmount: Double {
        kind == .alcohol ? 100 : 100_000
    }

    private var amountBinding: Binding<Double> {
        Binding(
            get: { FitnessJournalQuantity.parse(amountText) ?? defaultSettings.quickAmount ?? stepAmount },
            set: { amountText = $0.formatted(.number.precision(.fractionLength(0...2))) }
        )
    }
}

private struct FitnessLifestyleSettingsEditor: View {
    let kind: FitnessLifestyleKind
    let initialSettings: FitnessLifestyleSettings
    let isFixture: Bool
    let onSave: (FitnessLifestyleSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var goalText: String
    @State private var quickText: String
    @State private var quickUnit: FitnessLifestyleUnit
    @State private var reminderEnabled: Bool
    @State private var reminderTime: Date
    @State private var reminderContext: FitnessLifestyleReminderContext
    @State private var reminderFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    @State private var errorMessage: String?

    init(kind: FitnessLifestyleKind, initialSettings: FitnessLifestyleSettings, isFixture: Bool,
         onSave: @escaping (FitnessLifestyleSettings) -> Void) {
        self.kind = kind
        self.initialSettings = initialSettings
        self.isFixture = isFixture
        self.onSave = onSave
        _goalText = State(initialValue: initialSettings.goal.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "")
        _quickText = State(initialValue: initialSettings.quickAmount.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "")
        _quickUnit = State(initialValue: initialSettings.quickUnit ?? kind.defaultQuickAmount?.unit ?? kind.defaultUnit)
        _reminderEnabled = State(initialValue: initialSettings.reminderEnabled)
        _reminderContext = State(initialValue: initialSettings.reminderContext)
        _reminderFoldPolicy = State(initialValue: initialSettings.reminderFoldPolicy)
        let minutes = initialSettings.reminderTimeMinutes ?? 21 * 60
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        _reminderTime = State(initialValue: Calendar.current.date(from: components) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Goals and quick amount") {
                    TextField("Optional daily goal", text: $goalText)
#if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
#endif
                    TextField("Quick amount", text: $quickText)
#if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
#endif
                    if kind.allowedUnits.count > 1 {
                        Picker("Quick unit", selection: $quickUnit) {
                            ForEach(Array(kind.allowedUnits).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                    } else {
                        LabeledContent("Quick unit", value: quickUnit.label)
                    }
                }
                Section("Reminder preference") {
                    Toggle("Enabled", isOn: $reminderEnabled)
                    Picker("Context", selection: $reminderContext) {
                        ForEach(FitnessLifestyleReminderContext.allCases, id: \.self) { context in
                            Text(context.label).tag(context)
                        }
                    }
                    Picker("DST fold", selection: $reminderFoldPolicy) {
                        ForEach(FitnessLifestyleLocalTimeFoldPolicy.allCases, id: \.self) { policy in
                            Text(policy == .earlierOffset ? "Earlier offset" : "Later offset").tag(policy)
                        }
                    }
                    DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        .disabled(!reminderEnabled)
                    Text("Local reminder is reconciled from this preference. Context is descriptive only; it is not medical advice or a causal recommendation.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fitness-lifestyle-reminder-not-scheduled")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(LifeOSTokens.warning) }
            }
            .navigationTitle("\(kind.displayName) settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isFixture)
                        .accessibilityIdentifier("fitness-lifestyle-settings-save")
                }
            }
        }
    }

    private func save() {
        guard !isFixture else { return }
        let goal = goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : FitnessJournalQuantity.parse(goalText)
        let quick = quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : FitnessJournalQuantity.parse(quickText)
        if !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && goal == nil {
            errorMessage = "Enter a valid goal or leave it empty."
            return
        }
        if !quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quick == nil {
            errorMessage = "Enter a valid quick amount or leave it empty."
            return
        }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: reminderTime)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let updated = FitnessLifestyleSettings(kind: kind, goal: goal, quickAmount: quick,
                                               quickUnit: quick == nil ? nil : quickUnit,
                                               reminderTimeMinutes: reminderEnabled ? minutes : nil,
                                               reminderEnabled: reminderEnabled,
                                               reminderContext: reminderContext,
                                               reminderFoldPolicy: reminderFoldPolicy)
        do {
            try FitnessLifestyleValidationProxy.validate(updated)
            onSave(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Keeps the view layer independent from the private validator implementation
/// while preserving the same settings matrix before a store write.
private enum FitnessLifestyleValidationProxy {
    static func validate(_ settings: FitnessLifestyleSettings) throws {
        let url = FitnessLifestyleLedgerStore(persistenceURL: nil)
        _ = try url.saveSettings(settings)
    }
}
