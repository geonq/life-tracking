import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
private struct LifeOSHealthKitFitnessProjectionKey: EnvironmentKey {
    static let defaultValue: HealthKitFitnessProjection? = nil
}

extension EnvironmentValues {
    var lifeOSHealthKitFitnessProjection: HealthKitFitnessProjection? {
        get { self[LifeOSHealthKitFitnessProjectionKey.self] }
        set { self[LifeOSHealthKitFitnessProjectionKey.self] = newValue }
    }
}
#endif

/// The local-first training home.  It is intentionally standalone so the
/// existing Fitness navigation can mount it in a later integration tranche
/// without changing the durable coordinator contract.
public struct FitnessTrainingView: View {
    @StateObject private var coordinator: FitnessTrainingCoordinator
    @State private var selectedTemplate: FitnessTrainingTemplateOption?
    @State private var templateEditor: FitnessTrainingTemplateEditorPresentation?
    @State private var presentedSessionID: TrainingRecordID?
    @State private var selectedHistoryEntry: TrainingHistoryEntry?
    @State private var historyPage = 0
    @State private var pendingDelete: FitnessTrainingTemplateOption?
    @State private var pendingActiveDiscardSessionID: TrainingRecordID?
    @State private var historyProjectionCache: TrainingHistoryProjection?
    @State private var historyProjectionBoundary: FitnessTrainingProjectionBoundary?
    @State private var importedSnapshotCache: TrainingImportedHistorySnapshot?
    @State private var importedSnapshotSourceRevision: UInt64?
    @State private var importedSourceRevision: UInt64 = 0
    @State private var recoveryDocument: FitnessTrainingRecoveryDocument?
    @State private var isExportingRecovery = false
    @State private var recoveryExportMessage: String?
    @State private var calendarBoundaryTask: Task<Void, Never>?
    private let calendarClock: @Sendable () -> Date
    private let calendarSleeper: @Sendable (UInt64) async throws -> Void
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.lifeOSHealthKitFitnessProjection) private var healthKitFitnessProjection
#endif

    private static let historyPageSize = 12

    public init(
        coordinator: FitnessTrainingCoordinator? = nil,
        calendarClock: @escaping @Sendable () -> Date = { Date() },
        calendarSleeper: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        _coordinator = StateObject(wrappedValue: coordinator ?? FitnessTrainingCoordinator())
        self.calendarClock = calendarClock
        self.calendarSleeper = calendarSleeper
    }

    public var body: some View {
        let projection = combinedHistoryProjection

        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: LifeOSTokens.Space.lg, bottomPadding: LifeOSTokens.Space.xxxl) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxl) {
                    header
                    statusSurface

                    if let activeSession = coordinator.state.activeSession {
                        activeSessionCard(activeSession)
                    }

                    overviewCard(projection.statistics)
                    templateLibrary

                    if let latest = coordinator.state.latestCompletedSession {
                        latestSessionSummary(latest)
                    }

                    historySection(projection)
                    importedBoundary(projection)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .task {
            if case .idle = coordinator.state.loadState {
                await coordinator.refresh()
            }
        }
        .sheet(item: $selectedTemplate) { template in
            FitnessTrainingStartSheet(template: template) { title in
                start(template: template, title: title)
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 340)
            #endif
        }
        .sheet(item: $templateEditor) { presentation in
            FitnessTrainingTemplateEditor(template: presentation.template) { template in
                coordinator.saveTemplate(template)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
        .sheet(item: $presentedSessionID) { sessionID in
            FitnessTrainingSessionSheet(coordinator: coordinator, sessionID: sessionID)
                #if os(macOS)
                .frame(minWidth: 620, minHeight: 720)
                #endif
        }
        .sheet(item: $selectedHistoryEntry) { entry in
            FitnessTrainingHistoryDetailView(
                entry: entry,
                localSession: localSession(for: entry),
                linkState: linkState(for: entry, in: projection)
            )
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 620)
            #endif
        }
        .confirmationDialog(
            "Delete local template?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { template in
            Button("Delete \(template.name)", role: .destructive) {
                coordinator.deleteTemplate(id: template.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { template in
            Text("This removes the saved template. Completed local sessions keep their immutable template snapshot.")
        }
        .confirmationDialog(
            "Discard active session?",
            isPresented: Binding(
                get: { pendingActiveDiscardSessionID != nil },
                set: { if !$0 { pendingActiveDiscardSessionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let sessionID = pendingActiveDiscardSessionID {
                Button("Discard session", role: .destructive) {
                    pendingActiveDiscardSessionID = nil
                    Task { await coordinator.discard(sessionID: sessionID) }
                }
            }
            Button("Keep session", role: .cancel) {}
        } message: {
            Text("This removes the unfinished session from your active workflow. Completed history stays unchanged.")
        }
        .fileExporter(
            isPresented: $isExportingRecovery,
            document: recoveryDocument,
            contentType: .json,
            defaultFilename: "lifeos-training-recovery.json"
        ) { result in
            switch result {
            case .success:
                recoveryExportMessage = "The preserved training ledger was saved."
            case .failure(let error):
                recoveryExportMessage = "The recovery export was not saved: \(error.localizedDescription)"
            }
            recoveryDocument = nil
        }
        .onChange(of: coordinator.state.sessions) { _, _ in
            historyPage = 0
            refreshHistoryProjection()
        }
        .onChange(of: coordinator.historyProjectionRevision) { _, _ in
            historyPage = 0
            refreshHistoryProjection()
        }
#if os(iOS)
        .onChange(of: healthKitFitnessProjection) { _, _ in
            importedSourceRevision &+= 1
            importedSnapshotSourceRevision = nil
            historyPage = 0
            refreshHistoryProjection()
        }
#endif
        .onAppear {
            refreshHistoryProjection()
            startCalendarBoundaryTask()
        }
        .onChange(of: scenePhase) { _, phase in
            stopCalendarBoundaryTask()
            if phase == .active {
                startCalendarBoundaryTask()
            }
        }
        .onDisappear {
            stopCalendarBoundaryTask()
        }
        .accessibilityIdentifier("fitness-training")
    }

    private var combinedHistoryProjection: TrainingHistoryProjection {
        let boundary = currentHistoryProjectionBoundary
        guard let historyProjectionCache,
              historyProjectionBoundary == boundary else {
            // The fallback keeps the first render truthful without mutating
            // state from view evaluation. onAppear/onChange publishes the same
            // bounded projection into the cache for subsequent renders.
            return coordinator.historyProjection(importedSnapshot: importedSnapshotCache)
        }
        return historyProjectionCache
    }

    private func refreshHistoryProjection() {
        let importedSnapshot = refreshImportedSnapshotIfNeeded()
        let boundary = FitnessTrainingProjectionBoundary(
            localRevision: coordinator.currentHistoryProjectionRevision(),
            importedSourceRevision: importedSourceRevision
        )
        if historyProjectionCache == nil || historyProjectionBoundary != boundary {
            historyProjectionCache = coordinator.historyProjection(importedSnapshot: importedSnapshot)
            historyProjectionBoundary = boundary
        }
    }

    private func startCalendarBoundaryTask() {
        stopCalendarBoundaryTask()
        guard scenePhase == .active else { return }

        refreshHistoryProjection()
        let coordinator = coordinator
        let calendarClock = calendarClock
        let calendarSleeper = calendarSleeper
        calendarBoundaryTask = Task { @MainActor in
            // A foreground transition refreshes the durable source first. The
            // task is explicitly owned by this view and is cancelled below
            // when the scene changes phase or the view disappears.
            await coordinator.refresh()
            guard !Task.isCancelled else { return }

            await FitnessTrainingCalendarBoundaryScheduler.run(
                initialBoundary: FitnessTrainingCalendarBoundary.nextBerlinMidnight(after: calendarClock()),
                clock: calendarClock,
                sleeper: calendarSleeper,
                nextBoundary: { FitnessTrainingCalendarBoundary.nextBerlinMidnight(after: $0) },
                onBoundary: { now in
                    coordinator.refreshHistoryProjectionBoundary(now: now)
                }
            )
        }
    }

    private func stopCalendarBoundaryTask() {
        calendarBoundaryTask?.cancel()
        calendarBoundaryTask = nil
    }

    private var currentHistoryProjectionBoundary: FitnessTrainingProjectionBoundary {
        FitnessTrainingProjectionBoundary(
            localRevision: coordinator.currentHistoryProjectionRevision(),
            importedSourceRevision: importedSourceRevision
        )
    }

    private func refreshImportedSnapshotIfNeeded() -> TrainingImportedHistorySnapshot? {
        guard importedSnapshotSourceRevision != Optional(importedSourceRevision) else {
            return importedSnapshotCache
        }
#if os(iOS)
        importedSnapshotCache = healthKitFitnessProjection?.trainingImportedSnapshot()
#else
        importedSnapshotCache = nil
#endif
        importedSnapshotSourceRevision = importedSourceRevision
        return importedSnapshotCache
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: LifeOSTokens.Space.md) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                Text("Training")
                    .lifeOSTypography(.pageTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text("Plan, record, and review the work you actually did.")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LifeOSTokens.Space.sm)
            Button {
                templateEditor = .add
            } label: {
                Label("New template", systemImage: "plus")
            }
            .buttonStyle(LifeOSButtonStyle(.secondary))
            .accessibilityHint("Create a local workout template with custom exercises")
        }
    }

    @ViewBuilder
    private var statusSurface: some View {
        switch coordinator.state.loadState {
        case .idle:
            EmptyView()
        case .loading:
            LifeOSCard(level: .surface) {
                HStack(spacing: LifeOSTokens.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LifeOSTokens.Module.fitness)
                    Text("Loading local training")
                        .lifeOSTypography(.cardTitle)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Spacer(minLength: 0)
                }
            }
        case .saving:
            LifeOSCard(level: .surface) {
                HStack(spacing: LifeOSTokens.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LifeOSTokens.Module.fitness)
                    Text("Saving locally…")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Spacer(minLength: 0)
                }
            }
        case .ready:
            qualitySurface
        case .failed(let message):
            LifeOSCard(level: .surface) {
                LifeOSStateView(state: .error(message: message), retry: {
                    Task { await coordinator.retry() }
                })
            }
        case .recoveryRequired(let message):
            LifeOSCard(level: .surface) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                    LifeOSStateView(state: .error(message: message), retry: {
                        Task { await coordinator.retry() }
                    })
                    Text("The preserved ledger is never replaced with an empty file. Export the bounded preserved bytes before treating new reads as current. This screen cannot hold an oversized ledger in memory; supported oversized sources remain available through the store's bounded destination-based recovery API, while files beyond that limit require manual recovery.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        prepareRecoveryExport()
                    } label: {
                        Label("Export preserved ledger", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LifeOSButtonStyle(.secondary))
                    .disabled(coordinator.isBusy)
                    .accessibilityIdentifier("fitness-training-recovery-export")
                    if let recoveryExportMessage {
                        Text(recoveryExportMessage)
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if let notice = coordinator.state.notice {
            FitnessTrainingNoticeView(notice: notice)
        }

        if let warning = coordinator.state.templateWarning {
            FitnessTrainingNoticeView(notice: .error(warning))
        }
    }

    @ViewBuilder
    private var qualitySurface: some View {
        switch coordinator.state.dataQuality {
        case .current:
            EmptyView()
        case .stale(let detail):
            LifeOSCard(level: .surface) {
                LifeOSProvenanceNotice(kind: .stale, source: "Local training ledger", detail: detail)
            }
        case .unavailable(let detail):
            LifeOSCard(level: .surface) {
                LifeOSProvenanceNotice(kind: .unavailable, source: "Local training ledger", detail: detail)
            }
        }
    }

    private func activeSessionCard(_ session: TrainingSession) -> some View {
        LifeOSCard(level: .raised, cornerRadius: LifeOSTokens.Radius.hero, padding: LifeOSTokens.Space.xl) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    LifeOSStatusPill(
                        label: session.status == .paused ? "RESTING" : "IN PROGRESS",
                        tone: session.status == .paused ? .warning : .success,
                        systemImage: session.status == .paused ? "pause.fill" : "figure.strengthtraining.traditional"
                    )
                    Spacer(minLength: LifeOSTokens.Space.sm)
                    Text("Local only")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                }

                Text(session.title)
                    .lifeOSTypography(.sectionTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(activeSessionDetail(session))
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: LifeOSTokens.Space.sm) {
                    Button {
                        presentedSessionID = session.id
                    } label: {
                        Label(session.status == .paused ? "Resume session" : "Open session", systemImage: session.status == .paused ? "play.fill" : "arrow.up.right")
                    }
                    .buttonStyle(LifeOSButtonStyle(.primary))
                    .accessibilityIdentifier("fitness-training-active-session")

                    Button("Discard") {
                        pendingActiveDiscardSessionID = session.id
                    }
                    .buttonStyle(LifeOSButtonStyle(.destructive))
                    .disabled(coordinator.isBusy)
                    .accessibilityIdentifier("fitness-training-active-discard")
                }
            }
        }
    }

    private func overviewCard(_ statistics: TrainingStrengthStatistics) -> some View {
        let volumeSummary = fitnessTrainingOverviewVolumeSummary(statistics)
        return VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            LifeOSSectionHeader(
                title: "Your training",
                subtitle: "Local strength values are built from completed LifeOS sets."
            )
            LifeOSCard(level: .surface) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: LifeOSTokens.Space.xxl) {
                        overviewMetric(value: statistics.completedSessionCount.formatted(), label: "Completed")
                        overviewVolumeMetric(volumeSummary)
                        overviewMetric(value: formattedBestLoad(statistics), label: "Best working load")
                        overviewMetric(value: statistics.personalRecords.count.formatted(), label: "Exercise PRs")
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                        HStack(alignment: .top, spacing: LifeOSTokens.Space.xxl) {
                            overviewMetric(value: statistics.completedSessionCount.formatted(), label: "Completed")
                            overviewVolumeMetric(volumeSummary)
                        }
                        HStack(alignment: .top, spacing: LifeOSTokens.Space.xxl) {
                            overviewMetric(value: formattedBestLoad(statistics), label: "Best working load")
                            overviewMetric(value: statistics.personalRecords.count.formatted(), label: "Exercise PRs")
                        }
                    }
                }
            }
        }
    }

    private func overviewMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(value)
                .lifeOSTypography(.metricCompact)
                .foregroundStyle(LifeOSTokens.primaryText)
                .monospacedDigit()
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func overviewVolumeMetric(_ summary: FitnessTrainingOverviewVolumeSummary) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(summary.value)
                .lifeOSTypography(.metricCompact)
                .foregroundStyle(LifeOSTokens.primaryText)
                .monospacedDigit()
            Text(summary.label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.detail)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.metadataText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.label), \(summary.value)")
        .accessibilityValue(summary.detail)
    }

    private var templateLibrary: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            LifeOSSectionHeader(
                title: "Start a session",
                subtitle: "Curls, bench press, cardio, and your own exercises are ready to configure."
            )

            if coordinator.state.templates.isEmpty {
                LifeOSCard(level: .surface) {
                    LifeOSStateView(state: .empty(reason: "Create a template to make your next session one tap away.")) {
                        templateEditor = .add
                    }
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 248), spacing: LifeOSTokens.Space.md)],
                    spacing: LifeOSTokens.Space.md
                ) {
                    ForEach(coordinator.state.templates) { template in
                        FitnessTrainingTemplateCard(
                            template: template,
                            onStart: { selectedTemplate = template },
                            onEdit: template.editableTemplate.map { editable in
                                { templateEditor = .edit(editable) }
                            },
                            onDelete: template.source == .saved ? { pendingDelete = template } : nil
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-training-templates")
    }

    private func latestSessionSummary(_ session: TrainingSession) -> some View {
        let completedSets = session.completedSets.count
        return VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            LifeOSSectionHeader(title: "Last session", subtitle: "A quiet record of what you completed.")
            LifeOSCard(level: .surface) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LifeOSTokens.success)
                        Text(session.title)
                            .lifeOSTypography(.cardTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Spacer(minLength: LifeOSTokens.Space.sm)
                        Text(session.endedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Completed")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.metadataText)
                    }
                    FitnessTrainingResponsiveMetrics(metrics: [
                        .init(value: completedSets.formatted(), label: "Sets"),
                        .init(value: formatDuration(session.recordedDuration ?? 0), label: "Duration"),
                        .init(value: formattedVolume(session.recordedExternalVolumeKilograms), label: "Volume"),
                        .init(value: bestLoadText(session), label: "Best load")
                    ])
                }
            }
        }
    }

    private func historySection(_ projection: TrainingHistoryProjection) -> some View {
        let entries = projection.entries
        let pageCount = max(1, (entries.count + Self.historyPageSize - 1) / Self.historyPageSize)
        let page = min(historyPage, pageCount - 1)
        let pageEntries = Array(
            entries
                .dropFirst(page * Self.historyPageSize)
                .prefix(Self.historyPageSize)
        )

        return VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            LifeOSSectionHeader(
                title: "History",
                subtitle: "Imported wearable evidence stays separate and read-only."
            )

            if entries.isEmpty {
                LifeOSCard(level: .surface) {
                    LifeOSStateView(state: .empty(reason: "Finish a local session or connect a reviewed workout source to start building history."))
                }
            } else {
                LifeOSCard(level: .surface, padding: 0) {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(pageEntries.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    selectedHistoryEntry = entry
                                } label: {
                                    FitnessTrainingHistoryRow(
                                        entry: entry,
                                        linkState: linkState(for: entry, in: projection)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Open read-only training details")
                                if index < pageEntries.count - 1 {
                                    Divider()
                                        .overlay(LifeOSTokens.subtleBorder)
                                        .padding(.leading, LifeOSTokens.Space.xl)
                                }
                            }
                        }

                        if pageCount > 1 {
                            Divider()
                                .overlay(LifeOSTokens.subtleBorder)
                            HStack(spacing: LifeOSTokens.Space.sm) {
                                Text("Page \(page + 1) of \(pageCount)")
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.metadataText)
                                Spacer(minLength: 0)
                                Button {
                                    historyPage = max(0, page - 1)
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .buttonStyle(LifeOSButtonStyle(.secondary))
                                .disabled(page == 0)
                                .accessibilityLabel("Previous history page")
                                Button {
                                    historyPage = min(pageCount - 1, page + 1)
                                } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .buttonStyle(LifeOSButtonStyle(.secondary))
                                .disabled(page == pageCount - 1)
                                .accessibilityLabel("Next history page")
                            }
                            .padding(.horizontal, LifeOSTokens.Space.xl)
                            .padding(.vertical, LifeOSTokens.Space.md)
                        }
                    }
                }
            }
        }
    }

    private func importedBoundary(_ projection: TrainingHistoryProjection) -> some View {
        let copy = importedBoundaryCopy(projection)
        return LifeOSCard(level: .surface) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
                    Image(systemName: copy.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(copy.tint)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                        Text("Workout source")
                            .lifeOSTypography(.cardTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Text(copy.status)
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(copy.tint)
                    }
                    Spacer(minLength: 0)
                }

                Text(copy.summary)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "lifeos://settings")!) {
                    Label(copy.actionLabel, systemImage: "arrow.up.right")
                }
                .buttonStyle(LifeOSButtonStyle(.secondary))
                .accessibilityIdentifier("fitness-training-review-health-source")

                DisclosureGroup("Source details") {
                    Text(copy.details)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, LifeOSTokens.Space.xs)
                }
                .tint(LifeOSTokens.secondaryText)
            }
        }
    }

    private func importedBoundaryCopy(_ projection: TrainingHistoryProjection) -> FitnessImportedBoundaryCopy {
        let details = importedBoundaryDetails(projection)
        switch projection.importedQueryState {
        case .noSource:
            return FitnessImportedBoundaryCopy(status: "Not connected", summary: "Connect Apple Health to bring read-only workout evidence into History.", details: details, actionLabel: "Review Health & devices", icon: "heart.text.square", tint: LifeOSTokens.warning)
        case .imported:
            return FitnessImportedBoundaryCopy(status: "\(projection.importedEntries.count) workout\(projection.importedEntries.count == 1 ? "" : "s") available", summary: "Imported workouts appear in History beside your local sessions.", details: details, actionLabel: "Review source", icon: "checkmark.circle.fill", tint: LifeOSTokens.success)
        case .partial:
            return FitnessImportedBoundaryCopy(status: "Partially available", summary: "Some source workouts are available; review the connection before relying on the full window.", details: details, actionLabel: "Review source", icon: "exclamationmark.circle", tint: LifeOSTokens.warning)
        case .stale:
            return FitnessImportedBoundaryCopy(status: "Refresh needed", summary: "The last retained workout snapshot is older than the current source window.", details: details, actionLabel: "Review source", icon: "arrow.clockwise.circle", tint: LifeOSTokens.warning)
        case .conflict:
            return FitnessImportedBoundaryCopy(status: "Source needs review", summary: "Conflicting source records remain available as evidence until they are resolved.", details: details, actionLabel: "Review source", icon: "exclamationmark.triangle", tint: LifeOSTokens.warning)
        case .unavailable:
            return FitnessImportedBoundaryCopy(status: "Unavailable", summary: "Review Apple Health access to make workout evidence available.", details: details, actionLabel: "Review Health & devices", icon: "lock.circle", tint: LifeOSTokens.secondaryText)
        case .readIndeterminate:
            return FitnessImportedBoundaryCopy(status: "Access not confirmed", summary: "Review Apple Health read access before relying on imported workouts.", details: details, actionLabel: "Review Health & devices", icon: "questionmark.circle", tint: LifeOSTokens.warning)
        case .error:
            return FitnessImportedBoundaryCopy(status: "Update failed", summary: "Review the source connection and try the next refresh.", details: details, actionLabel: "Review source", icon: "xmark.circle", tint: LifeOSTokens.warning)
        }
    }

    private func importedBoundaryDetails(_ projection: TrainingHistoryProjection) -> String {
        let state: String
        switch projection.importedQueryState {
        case .noSource: state = "no source snapshot is retained"
        case .imported: state = "the source query is current"
        case .partial: state = "the source query is partial"
        case .stale: state = "the source query is stale"
        case .conflict: state = "the source query contains conflicts"
        case .unavailable: state = "the source is unavailable"
        case .readIndeterminate: state = "source read access is indeterminate"
        case .error: state = "the source query returned an error"
        }
        var diagnostics = ""
        if projection.rejectedImportedRowCount > 0 || projection.truncatedImportedRowCount > 0 {
            diagnostics = " \(projection.rejectedImportedRowCount) row(s) rejected and \(projection.truncatedImportedRowCount) truncated by the bounded import contract."
        }
        if !projection.importedConflictEvidence.isEmpty {
            diagnostics += " Conflicting source payloads remain visible as conflict evidence."
        }
        return "Apple Health is the read-only workout source and Zepp remains a transport into that source. The retained snapshot has \(projection.importedEntries.count) record(s); \(state). LifeOS preserves activity, duration, energy when supplied, identity, coverage, and provenance. It never infers sets, repetitions, load, Training Effect, recovery, zones, or routes.\(diagnostics)"
    }

    private func linkState(for entry: TrainingHistoryEntry, in projection: TrainingHistoryProjection) -> TrainingLinkState? {
        switch entry {
        case .local(let item):
            return projection.linkStates.first(where: { $0.localID == item.id })
        case .imported(let record):
            return projection.linkStates.first { state in
                state.importedRecordKey == record.id || state.importedIdentityKeys.contains(record.id)
            }
        }
    }

    private func localSession(for entry: TrainingHistoryEntry) -> TrainingSession? {
        guard case .local(let item) = entry else { return nil }
        return coordinator.state.sessions.first(where: { $0.id == item.id })
    }

    private func activeSessionDetail(_ session: TrainingSession) -> String {
        let completed = session.completedSets.count
        let total = session.exercises.reduce(0) { $0 + $1.sets.count }
        let exerciseCount = session.exercises.count == 1 ? "1 exercise" : "\(session.exercises.count) exercises"
        return "\(exerciseCount) · \(completed)/\(total) sets complete · changes save on this device"
    }

    @MainActor
    private func start(
        template: FitnessTrainingTemplateOption,
        title: String?
    ) async -> FitnessTrainingStartResult {
        guard let receipt = await coordinator.start(template: template, title: title) else {
            let message: String
            if coordinator.isBusy || coordinator.state.loadState == .saving {
                message = "A local training change is already being saved. Keep this draft open and try again."
            } else {
                message = coordinator.state.notice?.message ?? "The session could not be started. Keep this draft open and try again."
            }
            return .failure(message)
        }

        switch receipt.outcome {
        case .saved:
            return .success
        case .duplicate, .conflict, .blocked:
            return .failure(receipt.message ?? "The session was not started. Keep this draft open and try again.")
        }
    }

    private func prepareRecoveryExport() {
        guard !coordinator.isBusy else { return }
        recoveryExportMessage = nil
        Task { @MainActor in
            guard let data = await coordinator.recoveryExportData() else {
                recoveryExportMessage = "The preserved ledger could not be prepared for this export. The recovery state remains unchanged."
                return
            }
            recoveryDocument = FitnessTrainingRecoveryDocument(data: data)
            isExportingRecovery = true
        }
    }
}

enum FitnessTrainingMetricLayout: Equatable {
    case fourUp
    case twoUp
    case oneUp

    static let metricMinimumWidth: CGFloat = 96
    static let twoColumnMinimumWidth: CGFloat = 128
    static let interItemSpacing: CGFloat = LifeOSTokens.Space.md

    static func minimumWidth(for layout: Self) -> CGFloat {
        switch layout {
        case .fourUp: fourUpMinimumWidth
        case .twoUp: twoUpMinimumWidth
        case .oneUp: 0
        }
    }

    private static var fourUpMinimumWidth: CGFloat {
        metricMinimumWidth * 4 + interItemSpacing * 3
    }

    private static var twoUpMinimumWidth: CGFloat {
        twoColumnMinimumWidth * 2 + interItemSpacing
    }
}

private struct FitnessTrainingMetricItem: Identifiable {
    let value: String
    let label: String

    var id: String { label }
}

/// Runs the date-sensitive invalidation loop with injectable time and sleep
/// boundaries. A wake before the target boundary retries the same target, so
/// a 25-hour Berlin day cannot skip its next local midnight. A missed run is
/// coalesced to the next future boundary to avoid replaying an unbounded
/// backlog after suspension.
@MainActor
enum FitnessTrainingCalendarBoundaryScheduler {
    typealias Clock = () -> Date
    typealias Sleeper = (UInt64) async throws -> Void

    static func nanoseconds(until boundary: Date, now: Date) -> UInt64 {
        let seconds = boundary.timeIntervalSince(now)
        guard seconds.isFinite else { return 60 * 1_000_000_000 }
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let boundedSeconds = min(max(seconds, 0.001), maximumSeconds)
        return max(1, UInt64((boundedSeconds * 1_000_000_000).rounded(.up)))
    }

    static func run(
        initialBoundary: Date,
        clock: @escaping Clock,
        sleeper: @escaping Sleeper,
        nextBoundary: @escaping (Date) -> Date,
        shouldContinue: @escaping () -> Bool = { true },
        onBoundary: @escaping (Date) -> Void
    ) async {
        var boundary = initialBoundary
        while !Task.isCancelled && shouldContinue() {
            let now = clock()
            guard now >= boundary else {
                do {
                    try await sleeper(nanoseconds(until: boundary, now: now))
                } catch {
                    return
                }
                continue
            }

            onBoundary(now)
            let next = nextBoundary(boundary)
            guard next > boundary else { return }
            boundary = next > now ? next : nextBoundary(now)
        }
    }
}

private struct FitnessTrainingProjectionBoundary: Equatable {
    let localRevision: FitnessTrainingProjectionRevision
    let importedSourceRevision: UInt64
}

private struct FitnessImportedBoundaryCopy {
    let status: String
    let summary: String
    let details: String
    let actionLabel: String
    let icon: String
    let tint: Color
}

private struct FitnessTrainingResponsiveMetrics: View {
    let metrics: [FitnessTrainingMetricItem]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                oneColumn
            } else {
                ViewThatFits(in: .horizontal) {
                    fourColumn
                        .frame(minWidth: FitnessTrainingMetricLayout.minimumWidth(for: .fourUp), alignment: .leading)
                    twoColumn
                        .frame(minWidth: FitnessTrainingMetricLayout.minimumWidth(for: .twoUp), alignment: .leading)
                    oneColumn
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fourColumn: some View {
        HStack(alignment: .top, spacing: FitnessTrainingMetricLayout.interItemSpacing) {
            ForEach(metrics) { metric in
                FitnessTrainingMetricCell(metric: metric)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var twoColumn: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: FitnessTrainingMetricLayout.twoColumnMinimumWidth), alignment: .leading),
                GridItem(.flexible(minimum: FitnessTrainingMetricLayout.twoColumnMinimumWidth), alignment: .leading)
            ],
            alignment: .leading,
            spacing: LifeOSTokens.Space.md
        ) {
            ForEach(metrics) { metric in
                FitnessTrainingMetricCell(metric: metric)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var oneColumn: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            ForEach(metrics) { metric in
                FitnessTrainingMetricCell(metric: metric)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FitnessTrainingMetricCell: View {
    let metric: FitnessTrainingMetricItem

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(metric.value)
                .lifeOSTypography(.metricCompact)
                .foregroundStyle(LifeOSTokens.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
            Text(metric.label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: FitnessTrainingMetricLayout.metricMinimumWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct FitnessTrainingSessionSheet: View {
    @ObservedObject var coordinator: FitnessTrainingCoordinator
    let sessionID: TrainingRecordID
    @Environment(\.dismiss) private var dismiss
    @State private var retainedSession: TrainingSession?
    @State private var terminalState: FitnessTrainingTerminalState?
    @State private var locallyCompleted = false

    init(coordinator: FitnessTrainingCoordinator, sessionID: TrainingRecordID) {
        self.coordinator = coordinator
        self.sessionID = sessionID
        let initialSession = coordinator.state.sessions.first {
            $0.id == sessionID && ($0.status == .active || $0.status == .paused)
        }
        _retainedSession = State(initialValue: initialSession)
    }

    var body: some View {
        Group {
            if locallyCompleted,
               let completed = coordinator.state.sessions.first(where: { $0.id == sessionID && $0.status == .completed }) {
                FitnessTrainingCompletionView(session: completed) {
                    dismiss()
                }
            } else if let retainedSession {
                FitnessTrainingSessionView(
                    session: retainedSession,
                    isProcessing: coordinator.state.loadState == .saving,
                    onSave: { draft in
                        actionResult(await coordinator.save(draft: draft))
                    },
                    onPause: { draft in
                        actionResult(await coordinator.pause(draft: draft))
                    },
                    onResume: { draft in
                        actionResult(await coordinator.resume(draft: draft))
                    },
                    onFinish: { draft in
                        actionResult(await coordinator.finish(draft: draft))
                    },
                    onDiscard: { draft in
                        actionResult(await coordinator.discard(sessionID: draft.id))
                    },
                    externalTerminalState: terminalState,
                    onFinished: {
                        locallyCompleted = true
                    }
                )
            } else if let completed = coordinator.state.sessions.first(where: { $0.id == sessionID && $0.status == .completed }) {
                FitnessTrainingCompletionView(session: completed) {
                    dismiss()
                }
            } else {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                    LifeOSStateView(state: .empty(reason: "This local session is no longer active."))
                    Button("Close") { dismiss() }
                        .buttonStyle(LifeOSButtonStyle(.secondary))
                }
                .padding(LifeOSTokens.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .onAppear {
            reconcilePublishedSession()
        }
        .onChange(of: coordinator.state.sessions) { _, _ in
            reconcilePublishedSession()
        }
    }

    private func reconcilePublishedSession() {
        guard !locallyCompleted else { return }
        guard let publishedSession = coordinator.state.sessions.first(where: { $0.id == sessionID }) else {
            if retainedSession != nil {
                terminalState = .deleted
            }
            return
        }

        switch publishedSession.status {
        case .active, .paused:
            guard terminalState == nil else { return }
            retainedSession = publishedSession
        case .completed:
            terminalState = .completed(publishedSession)
        case .discarded:
            terminalState = .discarded(publishedSession)
        }
    }

    private func actionResult(_ receipt: TrainingCommitReceipt?) -> FitnessTrainingActionResult {
        guard let receipt else {
            return .failure(coordinator.state.notice?.message ?? "LifeOS could not save this local training change. Keep the draft open and try again.")
        }
        switch receipt.outcome {
        case .saved, .duplicate:
            return .success(message: receipt.message)
        case .conflict, .blocked:
            return .failure(receipt.message ?? "LifeOS could not save this local training change. Keep the draft open and try again.")
        }
    }
}

struct FitnessTrainingCompletionView: View {
    let session: TrainingSession
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: LifeOSTokens.Space.xxxl, bottomPadding: LifeOSTokens.Space.xxxl) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxl) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(LifeOSTokens.success)
                        Text("Session complete")
                            .lifeOSTypography(.pageTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Text(session.title)
                            .lifeOSTypography(.body)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }

                    LifeOSCard(level: .raised, cornerRadius: LifeOSTokens.Radius.hero, padding: LifeOSTokens.Space.xl) {
                        let volumeSummary = fitnessTrainingCompletionVolumeSummary(session)
                        VStack(alignment: .leading, spacing: LifeOSTokens.Space.lg) {
                            FitnessTrainingResponsiveMetrics(metrics: [
                                .init(value: session.completedSets.count.formatted(), label: "Sets"),
                                .init(value: formatDuration(session.recordedDuration ?? 0), label: "Duration"),
                                .init(value: volumeSummary.value, label: volumeSummary.label),
                                .init(value: bestLoadText(session), label: "Best load")
                            ])
                            Text(volumeSummary.detail)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("Saved locally. If an app-owned HealthKit workout snapshot is available, it stays separate and read-only and does not change this summary.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Done", action: onClose)
                        .buttonStyle(LifeOSButtonStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
    }

}

private struct FitnessTrainingTemplateCard: View {
    let template: FitnessTrainingTemplateOption
    let onStart: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        LifeOSCard(level: .surface) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
                    Image(systemName: template.activityKind == .cardio ? "figure.run" : "figure.strengthtraining.traditional")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LifeOSTokens.Module.fitness)
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                        Text(template.name)
                            .lifeOSTypography(.cardTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                            .lineLimit(2)
                        Text(template.detail)
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.metadataText)
                    }
                    Spacer(minLength: 0)
                    if let onEdit, let onDelete {
                        Menu {
                            Button("Edit", action: onEdit)
                            Button("Delete", role: .destructive, action: onDelete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 32, height: 32)
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("Actions for \(template.name)")
                    }
                }

                if template.snapshot.exercises.isEmpty {
                    Text("No exercises yet")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                } else {
                    ForEach(template.snapshot.exercises.prefix(3), id: \.id) { exercise in
                        HStack(spacing: LifeOSTokens.Space.xs) {
                            Circle()
                                .fill(LifeOSTokens.Module.fitness)
                                .frame(width: 5, height: 5)
                            Text(exercise.name)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: LifeOSTokens.Space.xs)
                            Text("\(exercise.targetSets) × \(exercise.targetRepetitions)")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.metadataText)
                                .monospacedDigit()
                        }
                    }
                    if template.snapshot.exercises.count > 3 {
                        Text("+\(template.snapshot.exercises.count - 3) more")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.metadataText)
                    }
                }

                Button("Start session", action: onStart)
                    .buttonStyle(LifeOSButtonStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("fitness-training-start-\(template.id)")
            }
        }
        .opacity(isHovered ? 0.86 : 1)
        .animation(LifeOSMotion.decorative(LifeOSMotion.hover), value: isHovered)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
    }
}

private struct FitnessTrainingHistoryRow: View {
    let entry: TrainingHistoryEntry
    let linkState: TrainingLinkState?

    var body: some View {
        HStack(spacing: LifeOSTokens.Space.md) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(title)
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .lineLimit(1)
                Text(startedAt.formatted(date: .abbreviated, time: .shortened))
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
            }
            Spacer(minLength: LifeOSTokens.Space.sm)
            VStack(alignment: .trailing, spacing: LifeOSTokens.Space.xxs) {
                Text(statusLabel)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(tint)
                if let duration {
                    Text(formatDuration(duration))
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .monospacedDigit()
                }
                if let linkState {
                    Text(linkState.status.displayName)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                } else if isImported {
                    Text("Read only")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                }
            }
        }
        .padding(.horizontal, LifeOSTokens.Space.xl)
        .padding(.vertical, LifeOSTokens.Space.md)
        .accessibilityElement(children: .combine)
    }

    private var isImported: Bool {
        if case .imported = entry { return true }
        return false
    }

    private var title: String {
        switch entry {
        case .local(let item): item.title
        case .imported: "Imported workout"
        }
    }

    private var startedAt: Date { entry.startedAt }

    private var duration: TimeInterval? {
        switch entry {
        case .local(let item): item.duration
        case .imported(let record): record.durationSeconds
        }
    }

    private var statusLabel: String {
        switch entry {
        case .local(let item): item.status.displayName
        case .imported(let record): record.sourceState.displayName
        }
    }

    private var icon: String {
        switch entry {
        case .local(let item): item.status == .completed ? "checkmark.circle" : "clock"
        case .imported: "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch entry {
        case .local(let item): item.status == .completed ? LifeOSTokens.success : LifeOSTokens.warning
        case .imported(let record): record.sourceState == .imported ? LifeOSTokens.success : LifeOSTokens.warning
        }
    }
}

private struct FitnessTrainingHistoryDetailView: View {
    let entry: TrainingHistoryEntry
    let localSession: TrainingSession?
    let linkState: TrainingLinkState?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LifeOSResponsiveContentContainer(topPadding: LifeOSTokens.Space.lg, bottomPadding: LifeOSTokens.Space.xxxl) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xl) {
                        switch entry {
                        case .local(let item):
                            localDetails(item)
                        case .imported(let record):
                            importedDetails(record)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("Training details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func localDetails(_ item: TrainingHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xl) {
            detailHeader(
                title: item.title,
                subtitle: "Local LifeOS session · \(item.status.displayName)",
                icon: item.status == .completed ? "checkmark.circle.fill" : "clock"
            )
            LifeOSCard(level: .surface) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                    detailRow(label: "Started", value: item.startedAt.formatted(date: .complete, time: .shortened))
                    if let endedAt = item.endedAt {
                        detailRow(label: "Ended", value: endedAt.formatted(date: .complete, time: .shortened))
                    }
                    if let duration = item.duration {
                        detailRow(label: "Duration", value: formatDuration(duration))
                    }
                    detailRow(label: "Source", value: "Local set log")
                    detailRow(label: "Coverage", value: item.coverage.kind.displayName)
                }
            }

            if let localSession {
                LifeOSCard(level: .surface) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                        Text("Logged sets")
                            .lifeOSTypography(.sectionTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        ForEach(localSession.exercises) { exercise in
                            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                                Text(exercise.name)
                                    .lifeOSTypography(.cardTitle)
                                    .foregroundStyle(LifeOSTokens.primaryText)
                                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                                        HStack(spacing: LifeOSTokens.Space.sm) {
                                            Text("Set \(index + 1)")
                                                .lifeOSTypography(.metadata)
                                                .foregroundStyle(LifeOSTokens.primaryText)
                                            Text(set.kind.rawValue.capitalized)
                                                .lifeOSTypography(.metadata)
                                                .foregroundStyle(LifeOSTokens.secondaryText)
                                            Spacer(minLength: 0)
                                            Label(
                                                set.isCompleted ? "Completed" : "Unfinished",
                                                systemImage: set.isCompleted ? "checkmark.circle.fill" : "clock"
                                            )
                                            .lifeOSTypography(.metadata)
                                            .foregroundStyle(set.isCompleted ? LifeOSTokens.success : LifeOSTokens.warning)
                                        }
                                        HStack(spacing: LifeOSTokens.Space.sm) {
                                            if let repetitions = set.actualRepetitions {
                                                Text("\(repetitions) reps")
                                                    .lifeOSTypography(.metadata)
                                                    .foregroundStyle(LifeOSTokens.secondaryText)
                                            }
                                            if let load = set.actualLoadKilograms {
                                                Text("\(formatTrainingLoad(load)) kg")
                                                    .lifeOSTypography(.metadata)
                                                    .foregroundStyle(LifeOSTokens.secondaryText)
                                                    .monospacedDigit()
                                            }
                                            if !set.isCompleted {
                                                Text("Draft values are excluded from totals")
                                                    .lifeOSTypography(.metadata)
                                                    .foregroundStyle(LifeOSTokens.metadataText)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if let notes = localSession.notes, !notes.isEmpty {
                            Divider().overlay(LifeOSTokens.subtleBorder)
                            detailRow(label: "Note", value: notes)
                        }
                    }
                }
            } else {
                LifeOSCard(level: .surface) {
                    Text("The local session payload is not present in this read snapshot. The indexed history metadata remains available.")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            linkDetails
        }
    }

    private func importedDetails(_ record: TrainingImportedHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xl) {
            detailHeader(
                title: "Imported workout",
                subtitle: "Read-only HealthKit source evidence · \(record.sourceState.displayName)",
                icon: "arrow.down.circle.fill"
            )
            LifeOSCard(level: .surface) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                    detailRow(label: "Activity type", value: "Raw HealthKit value \(record.activityTypeRawValue)")
                    detailRow(label: "Started", value: record.startedAt.formatted(date: .complete, time: .shortened))
                    detailRow(label: "Ended", value: record.endedAt.formatted(date: .complete, time: .shortened))
                    detailRow(label: "Duration", value: formatDuration(record.durationSeconds))
                    if let energy = record.activeEnergyKilocalories {
                        detailRow(label: "Active energy", value: "\(formatTrainingLoad(energy)) kcal")
                    }
                    detailRow(label: "Coverage", value: record.coverage.kind.displayName)
                    detailRow(label: "Identity", value: record.id)
                }
            }

            if let provenance = record.provenance {
                LifeOSCard(level: .surface) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        Text("Source provenance")
                            .lifeOSTypography(.sectionTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        provenanceRows(provenance)
                    }
                }
            }

            LifeOSCard(level: .surface) {
                Text("LifeOS keeps this workout read-only. It does not infer sets, repetitions, load, Training Effect, recovery, heart-rate zones, or routes from this record.")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            linkDetails
        }
    }

    private var linkDetails: some View {
        LifeOSCard(level: .surface) {
            if let linkState {
                detailRow(label: "LifeOS link", value: linkState.status.displayName)
            } else {
                detailRow(label: "LifeOS link", value: "No local session linked")
            }
        }
    }

    private func detailHeader(title: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LifeOSTokens.Module.fitness)
            Text(title)
                .lifeOSTypography(.pageTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text(subtitle)
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.md) {
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.metadataText)
            Spacer(minLength: LifeOSTokens.Space.sm)
            Text(value)
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func provenanceRows(_ provenance: TrainingImportedWorkoutProvenance) -> some View {
        let values: [(String, String?)] = [
            ("Source", provenance.sourceName),
            ("Bundle", provenance.sourceBundleIdentifier),
            ("Version", provenance.sourceVersion),
            ("Device", provenance.deviceName),
            ("Manufacturer", provenance.deviceManufacturer),
            ("Model", provenance.deviceModel),
            ("Qualification", provenance.helioMatch.displayName)
        ]
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            if let text = value.1 {
                detailRow(label: value.0, value: text)
            }
        }
    }
}

private struct FitnessTrainingNoticeView: View {
    let notice: FitnessTrainingNotice

    var body: some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
            Image(systemName: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(notice.isError ? LifeOSTokens.warning : LifeOSTokens.success)
            Text(notice.message)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LifeOSTokens.Space.sm)
        .accessibilityElement(children: .combine)
    }
}

private struct FitnessTrainingStartResult: Equatable, Sendable {
    let didPersist: Bool
    let message: String?

    static let success = Self(didPersist: true, message: nil)

    static func failure(_ message: String) -> Self {
        Self(didPersist: false, message: message)
    }
}

private struct FitnessTrainingStartSheet: View {
    let template: FitnessTrainingTemplateOption
    let onStart: @MainActor (String?) async -> FitnessTrainingStartResult
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isStarting = false
    @State private var errorMessage: String?

    init(
        template: FitnessTrainingTemplateOption,
        onStart: @escaping @MainActor (String?) async -> FitnessTrainingStartResult
    ) {
        self.template = template
        self.onStart = onStart
        _title = State(initialValue: template.name)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xl) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        Text("Ready when you are")
                            .lifeOSTypography(.pageTitle)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Text("This creates one local session from the immutable template snapshot. You can still edit targets and actual results while training.")
                            .lifeOSTypography(.body)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LifeOSCard(level: .surface) {
                        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                            Text(template.name)
                                .lifeOSTypography(.sectionTitle)
                                .foregroundStyle(LifeOSTokens.primaryText)
                            Text(template.detail)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.metadataText)
                            TextField("Session title", text: $title)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .textInputAutocapitalization(.sentences)
                                #endif
                        }
                    }

                    if let errorMessage {
                        LifeOSCard(level: .surface) {
                            HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(LifeOSTokens.warning)
                                Text(errorMessage)
                                    .lifeOSTypography(.body)
                                    .foregroundStyle(LifeOSTokens.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Start failed")
                        .accessibilityValue(errorMessage)
                    }

                    Button {
                        startSession()
                    } label: {
                        if isStarting {
                            Label("Saving locally…", systemImage: "arrow.down.circle")
                        } else if errorMessage != nil {
                            Label("Try again", systemImage: "arrow.clockwise")
                        } else {
                            Label("Start \(template.name)", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(LifeOSButtonStyle(.primary))
                    .disabled(isStarting)
                    .accessibilityIdentifier("fitness-training-start")
                }
                .padding(LifeOSTokens.Space.xl)
            }
            .scrollIndicators(.hidden)
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("New session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isStarting)
                }
            }
            .interactiveDismissDisabled(isStarting)
        }
    }

    private func startSession() {
        guard !isStarting else { return }
        let requestedTitle = title.trimmedOrNil
        errorMessage = nil
        isStarting = true
        Task { @MainActor in
            let result = await onStart(requestedTitle)
            isStarting = false
            if result.didPersist {
                dismiss()
            } else {
                errorMessage = result.message ?? "The session was not started. Keep this draft open and try again."
            }
        }
    }
}

private struct FitnessTrainingTemplateEditor: View {
    let template: FitnessStrengthTemplate?
    let onSave: (FitnessStrengthTemplate) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var exercises: [FitnessTrainingTemplateDraftExercise]
    @State private var errorMessage: String?
    @State private var draftTemplateID: String
    @State private var hasSaveFailure = false
    @State private var showDiscardConfirmation = false
    @State private var initialDraftSignature: String

    init(template: FitnessStrengthTemplate?, onSave: @escaping (FitnessStrengthTemplate) -> Bool) {
        self.template = template
        self.onSave = onSave
        let initialName = template?.name ?? ""
        let initialExercises = template?.exercises.map(FitnessTrainingTemplateDraftExercise.init) ?? []
        _name = State(initialValue: initialName)
        _exercises = State(initialValue: initialExercises)
        _draftTemplateID = State(initialValue: template?.id ?? UUID().uuidString.lowercased())
        _initialDraftSignature = State(initialValue: Self.draftSignature(name: initialName, exercises: initialExercises))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.lg) {
                    LifeOSCard(level: .surface) {
                        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                            Text("Template")
                                .lifeOSTypography(.cardTitle)
                                .foregroundStyle(LifeOSTokens.primaryText)
                            TextField("Template name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .textInputAutocapitalization(.words)
                                #endif
                        }
                    }

                    LifeOSSectionHeader(
                        title: "Exercises",
                        subtitle: "Every exercise becomes an editable local set plan."
                    )

                    if exercises.isEmpty {
                        LifeOSCard(level: .surface) {
                            Text("Add at least one exercise so a session can be completed with a real local set.")
                                .lifeOSTypography(.body)
                                .foregroundStyle(LifeOSTokens.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ForEach($exercises) { $exercise in
                        FitnessTrainingTemplateDraftRow(exercise: $exercise) {
                            exercises.removeAll { $0.id == exercise.id }
                        }
                    }

                    Button {
                        exercises.append(FitnessTrainingTemplateDraftExercise())
                    } label: {
                        Label("Add custom exercise", systemImage: "plus")
                    }
                    .buttonStyle(LifeOSButtonStyle(.secondary))

                    if let errorMessage {
                        Text(errorMessage)
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, LifeOSTokens.Space.xl)
                .padding(.vertical, LifeOSTokens.Space.lg)
            }
            .scrollIndicators(.hidden)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle(template == nil ? "New template" : "Edit template")
            .interactiveDismissDisabled(isDirty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: requestDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(hasSaveFailure ? "Retry save" : "Save", action: save)
                        .disabled(name.trimmedOrNil == nil || exercises.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Discard template changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(hasSaveFailure ? "The last save failed. Keep editing to retry, or discard this template draft." : "Your template edits have not been saved.")
        }
    }

    private var isDirty: Bool {
        hasSaveFailure || Self.draftSignature(name: name, exercises: exercises) != initialDraftSignature
    }

    private func requestDismiss() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func save() {
        do {
            guard !exercises.isEmpty else {
                throw FitnessTrainingTemplateEditorError.requiresExercise
            }
            let now = Date.now
            let domainExercises = try exercises.map { try $0.makeDomainExercise() }
            let saved = try FitnessStrengthTemplate(
                id: draftTemplateID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                exercises: domainExercises,
                createdAt: template?.createdAt ?? now,
                updatedAt: now
            )
            guard onSave(saved) else {
                hasSaveFailure = true
                errorMessage = "LifeOS could not save this template locally. Your edits are still here; fix the storage issue or try Save again."
                return
            }
            hasSaveFailure = false
            errorMessage = nil
            dismiss()
        } catch {
            hasSaveFailure = true
            errorMessage = error.localizedDescription
        }
    }

    private static func draftSignature(
        name: String,
        exercises: [FitnessTrainingTemplateDraftExercise]
    ) -> String {
        var values = [name]
        for exercise in exercises {
            values.append(exercise.id)
            values.append(exercise.name)
            values.append(exercise.muscleGroup.rawValue)
            values.append(String(exercise.sets))
            values.append(String(exercise.repetitions))
            values.append(exercise.loadText)
        }
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

private enum FitnessTrainingTemplateEditorError: LocalizedError {
    case requiresExercise

    var errorDescription: String? {
        "Add at least one exercise to save this template."
    }
}

private struct FitnessTrainingTemplateDraftExercise: Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var muscleGroup: FitnessStrengthMuscleGroup = .arms
    var sets: Int = 3
    var repetitions: Int = 8
    var loadText: String = ""

    init() {}

    init(_ exercise: FitnessStrengthExercise) {
        id = exercise.id
        name = exercise.name
        muscleGroup = exercise.muscleGroup
        sets = exercise.sets
        repetitions = exercise.repetitions
        loadText = exercise.loadKilograms.map { FitnessTrainingLoadText.string($0) } ?? ""
    }

    func makeDomainExercise() throws -> FitnessStrengthExercise {
        let trimmedLoad = loadText.trimmingCharacters(in: .whitespacesAndNewlines)
        let load: Double?
        if trimmedLoad.isEmpty {
            load = nil
        } else {
            let value: Double
            do {
                guard let parsed = try FitnessTrainingLoadText.parse(trimmedLoad) else {
                    throw FitnessStrengthTemplateValidationError.invalidLoad
                }
                value = parsed
            } catch {
                throw FitnessStrengthTemplateValidationError.invalidLoad
            }
            guard value.isFinite, value >= 0 else {
                throw FitnessStrengthTemplateValidationError.invalidLoad
            }
            load = value
        }
        return try FitnessStrengthExercise(
            id: id,
            name: name,
            muscleGroup: muscleGroup,
            sets: sets,
            repetitions: repetitions,
            loadKilograms: load
        )
    }
}

private struct FitnessTrainingTemplateDraftRow: View {
    @Binding var exercise: FitnessTrainingTemplateDraftExercise
    let onDelete: () -> Void

    var body: some View {
        LifeOSCard(level: .surface) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                HStack(spacing: LifeOSTokens.Space.sm) {
                    TextField("Exercise name", text: $exercise.name)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove exercise")
                }

                Picker("Muscle group", selection: $exercise.muscleGroup) {
                    ForEach(FitnessStrengthMuscleGroup.allCases) { group in
                        Text(group.title).tag(group)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LifeOSTokens.Space.md) {
                        Stepper("Sets \(exercise.sets)", value: $exercise.sets, in: 1...100)
                        Stepper("Reps \(exercise.repetitions)", value: $exercise.repetitions, in: 1...1_000)
                    }
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        Stepper("Sets \(exercise.sets)", value: $exercise.sets, in: 1...100)
                        Stepper("Reps \(exercise.repetitions)", value: $exercise.repetitions, in: 1...1_000)
                    }
                }

                TextField("Target load kg (optional)", text: $exercise.loadText)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        }
    }
}

private enum FitnessTrainingTemplateEditorPresentation: Identifiable {
    case add
    case edit(FitnessStrengthTemplate)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let template): "edit-\(template.id)"
        }
    }

    var template: FitnessStrengthTemplate? {
        if case .edit(let template) = self { return template }
        return nil
    }
}

struct FitnessTrainingOverviewVolumeSummary: Equatable {
    let value: String
    let label: String
    let detail: String
}

struct FitnessTrainingCompletionVolumeSummary: Equatable {
    let value: String
    let label: String
    let detail: String
}

func fitnessTrainingCompletionVolumeSummary(
    _ session: TrainingSession
) -> FitnessTrainingCompletionVolumeSummary {
    let completedSetCount = session.completedSets.count
    guard completedSetCount > 0 else {
        return FitnessTrainingCompletionVolumeSummary(
            value: "—",
            label: "External volume · unavailable",
            detail: "No completed sets are available for an external-volume calculation."
        )
    }

    var knownContributions: [Double] = []
    knownContributions.reserveCapacity(completedSetCount)
    for exercise in session.exercises {
        guard exercise.loadConvention == .externalTotal else { continue }
        for set in exercise.completedSets {
            guard let repetitions = set.actualRepetitions,
                  let load = set.actualLoadKilograms else { continue }
            let contribution = Double(repetitions) * load
            guard contribution.isFinite else { continue }
            knownContributions.append(contribution)
        }
    }

    let missingSetCount = completedSetCount - knownContributions.count
    let knownTotal = knownContributions.reduce(0, +)
    guard knownTotal.isFinite else {
        return FitnessTrainingCompletionVolumeSummary(
            value: "—",
            label: "External volume · unavailable",
            detail: "The completed sets did not produce a finite qualified volume value."
        )
    }
    if missingSetCount == 0 {
        return FitnessTrainingCompletionVolumeSummary(
            value: "\(formatTrainingLoad(knownTotal)) kg",
            label: "External volume",
            detail: "All \(completedSetCount) completed sets include a qualified external load."
        )
    }

    let knownValue = knownContributions.isEmpty ? "—" : "≥ \(formatTrainingLoad(knownTotal)) kg"
    let setLabel = missingSetCount == 1 ? "set is" : "sets are"
    return FitnessTrainingCompletionVolumeSummary(
        value: knownValue,
        label: "External volume · partial",
        detail: "\(missingSetCount) completed \(setLabel) missing a qualified external load; the displayed value is a lower bound."
    )
}

func fitnessTrainingOverviewVolumeSummary(
    _ statistics: TrainingStrengthStatistics
) -> FitnessTrainingOverviewVolumeSummary {
    switch statistics.volumeCoverage {
    case .complete:
        guard let volume = statistics.knownExternalVolumeKilograms, volume.isFinite else {
            return FitnessTrainingOverviewVolumeSummary(
                value: "—",
                label: "External volume · unavailable",
                detail: "The projection did not produce a qualified volume value."
            )
        }
        return FitnessTrainingOverviewVolumeSummary(
            value: "\(formatTrainingLoad(volume)) kg",
            label: "External volume",
            detail: "All \(statistics.completedSetCount) completed sets include a qualified external load."
        )
    case .partial:
        let missingCount = statistics.incompleteVolumeSetCount
        let setLabel = missingCount == 1 ? "set is" : "sets are"
        let value = statistics.knownExternalVolumeKilograms.map {
            "≥ \(formatTrainingLoad($0)) kg"
        } ?? "—"
        return FitnessTrainingOverviewVolumeSummary(
            value: value,
            label: "External volume · partial",
            detail: "\(missingCount) completed \(setLabel) missing a qualified external load."
        )
    case .unavailable:
        let detail = statistics.completedSetCount == 0
            ? "Complete a set with repetitions and an external load to calculate volume."
            : "No qualified external volume is available from the completed sets."
        return FitnessTrainingOverviewVolumeSummary(
            value: "—",
            label: "External volume · unavailable",
            detail: detail
        )
    }
}

private func formattedBestLoad(_ statistics: TrainingStrengthStatistics) -> String {
    guard let value = statistics.personalRecords
        .compactMap(\.maximumExternalLoadKilograms)
        .max() else {
        return "—"
    }
    return "\(formatTrainingLoad(value)) kg"
}

private func formattedVolume(_ volume: Double?) -> String {
    guard let volume, volume.isFinite else { return "—" }
    return "\(formatTrainingLoad(volume)) kg"
}

private func bestLoadText(_ session: TrainingSession) -> String {
    let loads = session.exercises
        .filter { $0.loadConvention == .externalTotal }
        .flatMap(\.completedWorkingSets)
        .compactMap(\.actualLoadKilograms)
    guard let best = loads.max() else { return "—" }
    return "\(formatTrainingLoad(best)) kg"
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(max(0, seconds) / 60)
    if totalMinutes >= 60 {
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
    return "\(totalMinutes)m"
}

private func formatTrainingLoad(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension TrainingSessionStatus {
    var displayName: String {
        switch self {
        case .active: "In progress"
        case .paused: "Resting"
        case .completed: "Completed"
        case .discarded: "Discarded"
        }
    }
}

private extension TrainingSourceState {
    var displayName: String {
        switch self {
        case .local: "Local"
        case .imported: "Imported"
        case .mixed: "Mixed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .conflict: "Conflict"
        case .unavailable: "Unavailable"
        case .readIndeterminate: "Permission unclear"
        case .error: "Error"
        }
    }
}

private extension TrainingCoverageKind {
    var displayName: String {
        switch self {
        case .complete: "Complete"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }
}

private extension TrainingLinkStatus {
    var displayName: String {
        switch self {
        case .unlinked: "Unlinked"
        case .linked: "Linked"
        case .conflict: "Link conflict"
        case .missingImported: "Imported record missing"
        case .ambiguousImported: "Imported match ambiguous"
        case .invalidImportedKey: "Invalid imported link"
        case .noImportedSource: "No imported source"
        case .unavailable: "Link unavailable"
        }
    }
}

private extension TrainingSourceQualification {
    var displayName: String {
        switch self {
        case .confirmed: "Confirmed"
        case .candidate: "Candidate"
        case .unattributed: "Unattributed"
        case .other: "Other"
        case .conflict: "Conflict"
        }
    }
}

/// A bounded document wrapper for the preserved training ledger. The store
/// owns all source validation and size limits; this type only gives the
/// recovery-required UI a standard user-selected destination.
private struct FitnessTrainingRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
