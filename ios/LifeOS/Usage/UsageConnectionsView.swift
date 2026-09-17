import SwiftUI

/// Compact local display management for the provider registry. These controls
/// change what appears in Usage; they do not disconnect a source or revoke
/// authentication.
struct UsageConnectionsView: View {
    let presentation: UsageRegistryPresentation
    let onSave: (UsageRegistryPreferencesState) -> Bool
    let preferenceError: UsageRegistryPreferencesError?
    let onRetryPreferences: () -> Bool
    let onResetPreferences: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var orderedIDs: [UsageConnectionID]
    @State private var hiddenIDs: Set<UsageConnectionID>
    @State private var pinnedIDs: Set<UsageConnectionID>
    @State private var saveError: String?
    @State private var preferenceActionError: String?
    @State private var hasDirtyEdits = false

    init(
        presentation: UsageRegistryPresentation,
        onSave: @escaping (UsageRegistryPreferencesState) -> Bool = { _ in true },
        preferenceError: UsageRegistryPreferencesError? = nil,
        onRetryPreferences: @escaping () -> Bool = { false },
        onResetPreferences: @escaping () -> Bool = { false }
    ) {
        self.presentation = presentation
        self.onSave = onSave
        self.preferenceError = preferenceError
        self.onRetryPreferences = onRetryPreferences
        self.onResetPreferences = onResetPreferences
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
                        Button("Reset saved display preferences", role: .destructive, action: resetPreferences)
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
                    Text("Hide, pin, or reorder sources without disconnecting them. Usage values remain source backed.")
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#else
            .listStyle(.inset)
#endif
            .navigationTitle("Usage sources")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done", action: save)
                        .fontWeight(.semibold)
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
            .onChange(of: presentation) { _, next in
                syncFromPresentation(next)
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
        return HStack(spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(.usage, context: .card)
                .foregroundStyle(isHidden ? LifeOSTokens.tertiaryText : LifeOSTokens.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(connectionTitle(connection, descriptor: descriptor))
                    .lifeOSTypography(.label, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .lineLimit(1)
                Text(connectionStatus(connection, descriptor: descriptor))
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(statusColor(connection))
                    .lineLimit(2)
            }
            Spacer(minLength: LifeOSTokens.Space.xs)
            Button {
                if isPinned { pinnedIDs.remove(connection.connectionID) }
                else { pinnedIDs.insert(connection.connectionID) }
                hasDirtyEdits = true
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isPinned ? LifeOSTokens.accent : LifeOSTokens.tertiaryText)
            .accessibilityLabel(isPinned ? "Unpin \(connectionTitle(connection, descriptor: descriptor))" : "Pin \(connectionTitle(connection, descriptor: descriptor))")

            Button {
                if isHidden { hiddenIDs.remove(connection.connectionID) }
                else { hiddenIDs.insert(connection.connectionID) }
                hasDirtyEdits = true
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHidden ? LifeOSTokens.warningText : LifeOSTokens.tertiaryText)
            .accessibilityLabel(isHidden ? "Show \(connectionTitle(connection, descriptor: descriptor)) in Usage" : "Hide \(connectionTitle(connection, descriptor: descriptor)) from Usage")
        }
        .padding(.vertical, 3)
        .opacity(isHidden ? 0.58 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-connection-\(connection.connectionID.rawValue)")
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
        if presentation.failure != .none, connection.availability == .available {
            return "\(presentation.failure.label) · cached value"
        }
        switch connection.providerID.rawValue {
        case "gemini_subscription":
            return "Automatic quota unavailable · Manual unsupported"
        case "gemini_api":
            return "API / project usage · No subscription balance"
        default:
            switch connection.availability {
            case .available:
                return connection.freshness == .stale ? "Observed · Stale" : "Observed source"
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
        switch connection.availability {
        case .available: return connection.freshness == .stale ? LifeOSTokens.warningText : LifeOSTokens.Series.actual
        case .unsupported, .unavailable: return LifeOSTokens.tertiaryText
        case .disabled: return LifeOSTokens.warningText
        }
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
