import SwiftUI
import Combine

/// Compact local display management for the provider registry. These controls
/// change what appears in Usage; they do not disconnect a source or revoke
/// authentication.
enum UsageConnectionControlMetrics {
    static let macHitSize: CGFloat = 32
    static let iOSHitSize: CGFloat = 44
    static let minimumActionSpacing: CGFloat = 8

    static var hitSize: CGFloat {
#if os(iOS)
        return iOSHitSize
#else
        return macHitSize
#endif
    }
}

struct UsageConnectionsView: View {
    let presentation: UsageRegistryPresentation
    let onSave: (UsageRegistryPreferencesState) -> Bool
    let preferenceError: UsageRegistryPreferencesError?
    let onRetryPreferences: () -> Bool
    let onResetPreferences: () -> Bool
    let manualReadings: [UsageManualReading]
    let manualReadingErrorMessage: String?
    let onSaveManualReadings: (([UsageManualReading]) -> Bool)?
    let onDeleteManualReadings: (() -> Bool)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var orderedIDs: [UsageConnectionID]
    @State private var hiddenIDs: Set<UsageConnectionID>
    @State private var pinnedIDs: Set<UsageConnectionID>
    @State private var saveError: String?
    @State private var preferenceActionError: String?
    @State private var hasDirtyEdits = false
    @State private var showingManualReading = false
    @State private var freshnessNow = Date.now

    init(
        presentation: UsageRegistryPresentation,
        onSave: @escaping (UsageRegistryPreferencesState) -> Bool = { _ in true },
        preferenceError: UsageRegistryPreferencesError? = nil,
        onRetryPreferences: @escaping () -> Bool = { false },
        onResetPreferences: @escaping () -> Bool = { false },
        manualReadings: [UsageManualReading] = [],
        manualReadingErrorMessage: String? = nil,
        onSaveManualReadings: (([UsageManualReading]) -> Bool)? = nil,
        onDeleteManualReadings: (() -> Bool)? = nil
    ) {
        self.presentation = presentation
        self.onSave = onSave
        self.preferenceError = preferenceError
        self.onRetryPreferences = onRetryPreferences
        self.onResetPreferences = onResetPreferences
        self.manualReadings = manualReadings
        self.manualReadingErrorMessage = manualReadingErrorMessage
        self.onSaveManualReadings = onSaveManualReadings
        self.onDeleteManualReadings = onDeleteManualReadings
        _orderedIDs = State(initialValue: presentation.orderedConnections(includeHidden: true).map(\.connectionID))
        _hiddenIDs = State(initialValue: presentation.preferences.hiddenConnectionIDs)
        _pinnedIDs = State(initialValue: presentation.effectivePinnedConnectionIDs)
    }

    private var rows: [UsageRegistryConnection] {
        let lookup = Dictionary(uniqueKeysWithValues: presentation.connections.map { ($0.connectionID, $0) })
        let stored = orderedIDs.compactMap { lookup[$0] }
        let storedIDs = Set(stored.map(\.connectionID))
        let missing = presentation.connections
            .filter { !storedIDs.contains($0.connectionID) }
            .sorted { $0.connectionID < $1.connectionID }
        return stored + missing
    }

    var body: some View {
        NavigationStack {
            List {
                if let preferenceError {
                    Section {
                        Label(
                            preferenceError.errorDescription ?? "Saved Usage display preferences are unavailable.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(LifeOSTokens.warningText)
                        Button("Retry loading preferences", action: retryPreferences)
                            .accessibilityIdentifier("usage-preferences-retry")
                        Button("Reset saved display preferences", role: .destructive, action: resetPreferences)
                            .accessibilityIdentifier("usage-preferences-reset")
                    } header: {
                        Text("Display settings need attention")
                    } footer: {
                        Text("Retry keeps the saved state. Reset writes a fresh bounded state using the reviewed defaults.")
                    }
                }
                Section {
                    ForEach(rows) { connection in
                        connectionRow(connection)
                    }
                    .onMove(perform: moveRows)
                } header: {
                    Text("Show in Usage")
                } footer: {
                    Text("Manage display order and source actions without changing authentication. Usage values remain source backed.")
                }
            }
            .accessibilityIdentifier("usage-connections-list")
#if os(iOS)
            .listStyle(.insetGrouped)
#else
            .listStyle(.inset)
#endif
            .navigationTitle("Usage sources")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("usage-connections-cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done", action: save)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("usage-connections-done")
                }
#if os(iOS)
                ToolbarItem(placement: .automatic) {
                    EditButton()
                }
#endif
            }
            .alert("Could not save Usage preferences", isPresented: saveErrorBinding) {
                Button("Try again", action: save)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(saveError ?? "Try again when local storage is available.")
            }
            .alert("Could not recover Usage preferences", isPresented: preferenceActionErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(preferenceActionError ?? "Try again or reset the saved display state.")
            }
            .sheet(isPresented: $showingManualReading) {
                UsageManualReadingView(
                    currentReadings: manualReadings,
                    now: freshnessNow,
                    initialErrorMessage: manualReadingErrorMessage,
                    onSave: { readings in
                        onSaveManualReadings?(readings) ?? false
                    },
                    onDelete: {
                        onDeleteManualReadings?() ?? false
                    }
                )
#if os(iOS)
                .presentationDetents([.medium, .large])
#else
                .frame(minWidth: 520, minHeight: 520)
#endif
            }
            .onChange(of: presentation) { _, next in
                syncFromPresentation(next)
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
                freshnessNow = date
            }
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private var preferenceActionErrorBinding: Binding<Bool> {
        Binding(
            get: { preferenceActionError != nil },
            set: { if !$0 { preferenceActionError = nil } }
        )
    }

    private func connectionRow(_ connection: UsageRegistryConnection) -> some View {
        let descriptor = presentation.descriptor(for: connection)
        let isHidden = hiddenIDs.contains(connection.connectionID)
        let isPinned = pinnedIDs.contains(connection.connectionID)
        let actions = UsageConnectionActionResolver.actions(for: connection, descriptor: descriptor)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                connectionStackedLayout(
                    connection,
                    descriptor: descriptor,
                    actions: actions,
                    isPinned: isPinned,
                    isHidden: isHidden
                )
            } else {
                ViewThatFits(in: .horizontal) {
                    connectionInlineLayout(
                        connection,
                        descriptor: descriptor,
                        actions: actions,
                        isPinned: isPinned,
                        isHidden: isHidden
                    )
                    connectionStackedLayout(
                        connection,
                        descriptor: descriptor,
                        actions: actions,
                        isPinned: isPinned,
                        isHidden: isHidden
                    )
                }
            }
        }
        .frame(minHeight: 56, alignment: .center)
        .opacity(isHidden ? 0.58 : 1)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-connection-\(connection.connectionID.rawValue)")
    }

    private func connectionInlineLayout(
        _ connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?,
        actions: [UsageConnectionAction],
        isPinned: Bool,
        isHidden: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
            connectionIdentity(
                connection,
                descriptor: descriptor,
                isPinned: isPinned,
                isHidden: isHidden
            )
            Spacer(minLength: LifeOSTokens.Space.xs)
            connectionControls(
                for: connection,
                descriptor: descriptor,
                actions: actions,
                isPinned: isPinned,
                isHidden: isHidden
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionStackedLayout(
        _ connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?,
        actions: [UsageConnectionAction],
        isPinned: Bool,
        isHidden: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            connectionIdentity(
                connection,
                descriptor: descriptor,
                isPinned: isPinned,
                isHidden: isHidden
            )
            HStack(spacing: UsageConnectionControlMetrics.minimumActionSpacing) {
                Spacer(minLength: 0)
                connectionControls(
                    for: connection,
                    descriptor: descriptor,
                    actions: actions,
                    isPinned: isPinned,
                    isHidden: isHidden
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionIdentity(
        _ connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?,
        isPinned: Bool,
        isHidden: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
            ZStack(alignment: .bottomTrailing) {
                LifeOSIcon(providerIcon(for: descriptor), context: .card)
                    .foregroundStyle(isHidden ? LifeOSTokens.tertiaryText : LifeOSTokens.accent)
                    .frame(width: 24, height: 24)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LifeOSTokens.accent)
                        .background(LifeOSTokens.surface, in: Circle().inset(by: -2))
                        .accessibilityLabel("Pinned")
                }
            }
            .frame(width: 28, height: 32, alignment: .center)
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(connectionTitle(connection, descriptor: descriptor))
                    .lifeOSTypography(.label, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("usage-connection-label-\(connection.connectionID.rawValue)")
                Text(connectionStatus(connection, descriptor: descriptor))
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(statusColor(connection))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func connectionControls(
        for connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?,
        actions: [UsageConnectionAction],
        isPinned: Bool,
        isHidden: Bool
    ) -> some View {
        HStack(spacing: UsageConnectionControlMetrics.minimumActionSpacing) {
            if let primaryAction = actions.first {
                Button {
                    perform(primaryAction)
                } label: {
                    Label {
                        Text(primaryAction.isManualEntry ? primaryAction.title : "Open")
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: primaryAction.isManualEntry ? "square.and.pencil" : "arrow.up.right")
                    }
                    .frame(
                        minWidth: UsageConnectionControlMetrics.hitSize,
                        minHeight: UsageConnectionControlMetrics.hitSize
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
#if os(macOS)
                .controlSize(.small)
#endif
                .accessibilityLabel(primaryAction.title)
                .accessibilityIdentifier("usage-connection-action-\(primaryAction.id)")
                .help(primaryAction.detail)
            }
            displayMenu(
                for: connection,
                descriptor: descriptor,
                actions: Array(actions.dropFirst()),
                isPinned: isPinned,
                isHidden: isHidden
            )
        }
    }

    private func displayMenu(
        for connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?,
        actions: [UsageConnectionAction],
        isPinned: Bool,
        isHidden: Bool
    ) -> some View {
        Menu {
            if !actions.isEmpty {
                Section("Source") {
                    ForEach(actions) { action in
                        Button {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.isManualEntry ? "square.and.pencil" : "arrow.up.right")
                        }
                    }
                }
                Divider()
            }
            Button {
                if isPinned { pinnedIDs.remove(connection.connectionID) }
                else { pinnedIDs.insert(connection.connectionID) }
                hasDirtyEdits = true
            } label: {
                Label(
                    isPinned ? "Unpin \(connectionTitle(connection, descriptor: descriptor))" : "Pin \(connectionTitle(connection, descriptor: descriptor))",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                if isHidden { hiddenIDs.remove(connection.connectionID) }
                else { hiddenIDs.insert(connection.connectionID) }
                hasDirtyEdits = true
            } label: {
                Label(
                    isHidden ? "Show \(connectionTitle(connection, descriptor: descriptor))" : "Hide \(connectionTitle(connection, descriptor: descriptor))",
                    systemImage: isHidden ? "eye" : "eye.slash"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(
                    width: UsageConnectionControlMetrics.hitSize,
                    height: UsageConnectionControlMetrics.hitSize
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(LifeOSTokens.secondaryText)
        .accessibilityLabel("More options for \(connectionTitle(connection, descriptor: descriptor))")
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .accessibilityIdentifier("usage-connection-options-\(connection.connectionID.rawValue)")
    }

    private func providerIcon(for descriptor: UsageProviderDescriptor?) -> LifeOSIconName {
        guard let descriptor else { return .questionmark }
        return LifeOSIconName(
            providerIconToken: descriptor.iconToken,
            productKind: descriptor.productKind
        )
    }

    private func connectionTitle(
        _ connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?
    ) -> String {
        if connection.providerID.rawValue == "gemini_subscription" { return "Google AI Pro" }
        return connection.label.isEmpty ? (descriptor?.displayName ?? connection.providerID.rawValue) : connection.label
    }

    private func connectionStatus(
        _ connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?
    ) -> String {
        switch connection.authState {
        case .reauthRequired: return "Reauthorization required"
        case .revoked: return "Access revoked"
        case .disconnected where connection.availability == .available:
            return "Disconnected · cached value"
        default: break
        }
        if connection.providerID.rawValue == "gemini_subscription",
           let latest = manualReadings.max(by: { $0.observedAt < $1.observedAt }) {
            if manualReadings.contains(where: { $0.status(at: freshnessNow) == .needsUpdating }) {
                return "Needs updating"
            }
            return "Manually recorded · \(latest.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        }
        if presentation.failure != .none, connection.availability == .available {
            return "\(presentation.failure.label) · cached value"
        }
        switch connection.providerID.rawValue {
        case "gemini_subscription":
            return manualReadingErrorMessage == nil
                ? "Automatic usage unavailable · Add a reading"
                : "Saved reading unavailable · Recover"
        case "gemini_api":
            return "API / project usage · No subscription balance"
        default:
            switch connection.availability {
            case .available:
                switch connection.freshness {
                case .stale: return "Observed · Stale"
                case .aging: return "Observed · Aging"
                case .fresh: return "Observed · Current"
                case .unavailable, .unknown: return "Observed source"
                }
            case .unsupported:
                return "Automatic usage unavailable"
            case .disabled:
                return "Disabled for display"
            case .unavailable:
                return connection.reasonCode == "no_observation" ? "No observed usage yet" : "Unavailable"
            }
        }
    }

    private func statusColor(_ connection: UsageRegistryConnection) -> Color {
        switch connection.authState {
        case .reauthRequired, .revoked: return LifeOSTokens.warningText
        default: break
        }
        if connection.providerID.rawValue == "gemini_subscription", !manualReadings.isEmpty {
            return manualReadings.contains {
                $0.status(at: freshnessNow) == .needsUpdating
            } ? LifeOSTokens.warningText : LifeOSTokens.Series.actual
        }
        switch connection.availability {
        case .available: return connection.freshness == .stale ? LifeOSTokens.warningText : LifeOSTokens.Series.actual
        case .unsupported, .unavailable: return LifeOSTokens.tertiaryText
        case .disabled: return LifeOSTokens.warningText
        }
    }

    private func perform(_ action: UsageConnectionAction) {
        if action.isManualEntry {
            guard onSaveManualReadings != nil, onDeleteManualReadings != nil else {
                preferenceActionError = "Manual usage entry is unavailable in this fixture."
                return
            }
            freshnessNow = Date.now
            showingManualReading = true
            return
        }
        guard let url = action.destination?.url else {
            preferenceActionError = "This Usage action has no reviewed destination."
            return
        }
        openURL(url)
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        var next = rows.map(\.connectionID)
        next.move(fromOffsets: source, toOffset: destination)
        orderedIDs = next
        hasDirtyEdits = true
    }

    private func syncFromPresentation(_ next: UsageRegistryPresentation) {
        let sourceIDs = next.orderedConnections(includeHidden: true).map(\.connectionID)
        let sourceSet = Set(sourceIDs)
        let reconciledOrder = orderedIDs.filter(sourceSet.contains)
            + sourceIDs.filter { !orderedIDs.contains($0) }
        orderedIDs = hasDirtyEdits ? reconciledOrder : sourceIDs
        guard hasDirtyEdits else {
            hiddenIDs = next.preferences.hiddenConnectionIDs
            pinnedIDs = next.effectivePinnedConnectionIDs
            return
        }
        hiddenIDs.formIntersection(sourceSet)
        pinnedIDs.formIntersection(sourceSet)
    }

    private func retryPreferences() {
        guard !onRetryPreferences() else { return }
        preferenceActionError = UsageRegistryPreferencesError.loadFailed.errorDescription
    }

    /// Builds the reviewed first-run display state from connection metadata.
    /// Saved preferences are intentionally ignored here: this is also the
    /// recovery path when the persisted state is corrupt or stale.
    static func firstRunPreferences(
        for presentation: UsageRegistryPresentation
    ) throws -> UsageRegistryPreferencesState {
        let enabledConnections = presentation.connections
            .filter(\.enabled)
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.connectionID < $1.connectionID
            }

        return try UsageRegistryPreferencesState(
            hiddenConnectionIDs: [],
            pinnedConnectionIDs: Set(enabledConnections.filter(\.pinned).map(\.connectionID)),
            pinningConfigured: false,
            orderedConnectionIDs: enabledConnections.map(\.connectionID)
        )
    }

    private func resetPreferences() {
        let resetState: UsageRegistryPreferencesState
        do {
            resetState = try Self.firstRunPreferences(for: presentation)
        } catch {
            preferenceActionError = error.localizedDescription
            return
        }

        guard onResetPreferences() else {
            preferenceActionError = UsageRegistryPreferencesError.saveFailed.errorDescription
            return
        }

        // Apply the local draft explicitly. The coordinator may publish a
        // value-equal presentation, so SwiftUI's onChange is not guaranteed
        // to run after a successful reset.
        orderedIDs = resetState.orderedConnectionIDs
        hiddenIDs = resetState.hiddenConnectionIDs
        pinnedIDs = resetState.pinnedConnectionIDs
        hasDirtyEdits = false
    }

    private func save() {
        guard hasDirtyEdits else {
            dismiss()
            return
        }

        do {
            let state = try UsageRegistryPreferencesState(
                hiddenConnectionIDs: hiddenIDs,
                pinnedConnectionIDs: pinnedIDs,
                pinningConfigured: true,
                orderedConnectionIDs: orderedIDs
            )
            guard onSave(state) else {
                saveError = "The saved display state could not be written."
                return
            }
            hasDirtyEdits = false
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
