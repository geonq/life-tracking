import SwiftUI
import Combine

/// Detail surface for registry entries without a legacy chart reference. It
/// never borrows a different provider's chart, history, reset, or estimate.
struct UsageRegistryDetailView: View {
    let presentation: UsageRegistryPresentation
    let connectionID: UsageConnectionID
    let selectedWindowID: UsageWindowID?
    let onSelectWindow: (UsageWindowID) -> Void

    @State private var freshnessNow = Date.now

    private var connection: UsageRegistryConnection? { presentation.connection(id: connectionID) }
    private var descriptor: UsageProviderDescriptor? { connection.flatMap(presentation.descriptor(for:)) }
    private var windows: [UsageRegistryWindow] { presentation.windows(for: connectionID) }
    private var selectedWindow: UsageRegistryWindow? {
        windows.first { $0.id == selectedWindowID } ?? windows.first
    }
    private var selection: UsageRegistrySelection? {
        guard let selectedWindow else { return nil }
        return UsageRegistrySelection(
            connectionID: connectionID,
            windowID: selectedWindow.id,
            dimension: selectedWindow.dimension
        )
    }
    private var observation: UsageRegistryObservation? { presentation.observation(for: selection) }
    private var estimate: UsageRegistryEstimate? { presentation.estimate(for: selection) }

    private var isManualObservation: Bool {
        observation?.evidenceKind == .manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageLayoutContract.contentGap) {
            header
            stateSummary
            if windows.isEmpty {
                unsupportedCard
            } else {
                windowPicker
                observationCard
            }
        }
        .accessibilityIdentifier("usage-registry-detail-\(connectionID.rawValue)")
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            guard isManualObservation else { return }
            freshnessNow = now
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(connectionTitle)
                .lifeOSTypography(.pageTitle, weight: .semibold)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text(connection?.planLabel ?? descriptor?.productKind.rawValue.capitalized ?? "Usage source")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
    }

    private var connectionTitle: String {
        guard let connection else { return descriptor?.displayName ?? "Usage source" }
        return connection.providerID.rawValue == "gemini_subscription" ? "Google AI Pro" : connection.label
    }

    private var stateSummary: some View {
        let displayedFreshness = effectiveManualFreshness ?? connection?.freshness
        return HStack(spacing: LifeOSTokens.Space.xs) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(availabilityText)
                .lifeOSTypography(.metadata, weight: .medium)
                .foregroundStyle(stateColor)
            if presentation.failure != .none {
                Text("· \(presentation.failure.label)")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warningText)
            } else if let freshness = displayedFreshness, freshness != .unknown && freshness != .unavailable {
                Text("· \(freshnessText(freshness))")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var windowPicker: some View {
        Menu {
            ForEach(windows) { window in
                Button {
                    onSelectWindow(window.id)
                } label: {
                    HStack {
                        Text(window.label)
                        if window.id == selectedWindow?.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: LifeOSTokens.Space.xs) {
                Text(selectedWindow?.label ?? "Select window")
                    .lifeOSTypography(.label, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .lineLimit(1)
                LifeOSIcon(.chevronRight, context: .disclosure)
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                    .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
            }
        }
        .accessibilityLabel("Usage window")
    }

    private var observationCard: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                UsageCardHeader(
                    title: selectedWindow?.label ?? "Usage",
                    subtitle: descriptor?.productKind == .api ? "Project or provider observation" : "Provider observation",
                    icon: .usage
                )
                if let observation {
                    valueBlock(observation)
                    Divider().overlay(LifeOSTokens.hairlineBorder)
                    evidenceBlock(observation)
                } else {
                    Text("No observed value for this window.")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Text(connection?.reasonCode == "automatic_quota_unavailable"
                         ? "Automatic consumer subscription quota is unavailable."
                         : "This source has not supplied an observation yet.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func valueBlock(_ observation: UsageRegistryObservation) -> some View {
        switch observation.value {
        case .percentage(let value):
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                Text("\(Int(value.rounded()))%")
                    .lifeOSTypography(.metric)
                    .foregroundStyle(LifeOSTokens.Series.actual)
                    .monospacedDigit()
                Text("used")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
        case .counter(let used, let limit):
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                Text(used.formatted(.number.notation(.compactName)))
                    .lifeOSTypography(.metric)
                    .foregroundStyle(LifeOSTokens.Series.actual)
                    .monospacedDigit()
                Text(limit.map { "of \($0.formatted(.number.notation(.compactName)))" } ?? "measured")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
        }

        if let resetAt = observation.resetAt {
            Text("Resets \(resetAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        if let estimate {
            Text(estimateText(estimate))
                .lifeOSTypography(.metadata, weight: .medium)
                .foregroundStyle(LifeOSTokens.estimate)
        }
    }

    private func evidenceBlock(_ observation: UsageRegistryObservation) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(evidenceText(observation))
                .lifeOSTypography(.metadata, weight: .medium)
                .foregroundStyle(LifeOSTokens.secondaryText)
            Text("Observed \(observation.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }

    private var unsupportedCard: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                UsageCardHeader(title: connectionTitle, subtitle: descriptor?.productKind == .api ? "API / project usage" : "Subscription usage", icon: .usage)
                Text(unsupportedMessage)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var availabilityText: String {
        switch connection?.authState {
        case .reauthRequired: return "Reauthorization required"
        case .revoked: return "Access revoked"
        case .disconnected where connection?.availability == .available: return "Disconnected · cached value"
        default: break
        }
        if isManualObservation, let observation {
            return effectiveManualFreshness == .stale
                ? "Needs updating"
                : "Manually recorded · \(observation.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        }
        switch connection?.availability {
        case .available: return "Observed source"
        case .unsupported: return "Automatic usage unavailable"
        case .disabled: return "Hidden from Usage"
        case .unavailable, .none: return "No observed usage"
        }
    }

    private var unsupportedMessage: String {
        switch connection?.providerID.rawValue {
        case "gemini_subscription":
            return "Google AI Pro is available as a catalog entry, but Google does not expose the consumer subscription quota through a documented endpoint for this app. No number is inferred or scraped."
        case "gemini_api":
            return "Gemini API is a separate project usage product. Automatic metering is not configured in this v1 presentation path, so it does not share or invent a subscription balance."
        default:
            return "This catalog entry has no validated observation yet. Connect a reviewed source before displaying a number."
        }
    }

    private var stateColor: Color {
        switch connection?.authState {
        case .reauthRequired, .revoked: return LifeOSTokens.warningText
        default: break
        }
        if isManualObservation, effectiveManualFreshness == .stale {
            return LifeOSTokens.warningText
        }
        switch connection?.availability {
        case .available: return LifeOSTokens.Series.actual
        case .disabled: return LifeOSTokens.warningText
        case .unsupported, .unavailable, .none: return LifeOSTokens.tertiaryText
        }
    }

    private var effectiveManualFreshness: UsageRegistryFreshness? {
        guard isManualObservation, let observation else { return nil }
        guard freshnessNow.timeIntervalSinceReferenceDate.isFinite,
              observation.observedAt.timeIntervalSinceReferenceDate.isFinite else {
            return .stale
        }
        let age = max(0, freshnessNow.timeIntervalSince(observation.observedAt))
        guard age < UsageManualReading.staleAfter,
              observation.resetAt.map({ freshnessNow < $0 }) ?? true else {
            return .stale
        }
        return age < UsageManualReading.staleAfter / 2 ? .fresh : .aging
    }

    private func freshnessText(_ freshness: UsageRegistryFreshness) -> String {
        switch freshness {
        case .fresh: return "Fresh"
        case .aging: return "Aging"
        case .stale: return "Stale"
        case .unavailable, .unknown: return "Unavailable"
        }
    }

    private func evidenceText(_ observation: UsageRegistryObservation) -> String {
        switch observation.evidenceKind {
        case .providerReported: return observation.official ? "Official provider observation · \(observation.source)" : "Provider observation · non-official"
        case .legacyValidated: return "Legacy validated observation · \(observation.source)"
        case .locallyMeasured: return "Locally measured · \(observation.source)"
        case .manual: return "Manual entry · non-official"
        case .estimated: return "Estimate · non-official"
        }
    }

    private func estimateText(_ estimate: UsageRegistryEstimate) -> String {
        if let projected = estimate.projectedPercentAtReset {
            return "Estimate at reset \(Int(projected.rounded()))% · \(estimate.confidence)"
        }
        return "Estimate · \(estimate.confidence)"
    }
}
