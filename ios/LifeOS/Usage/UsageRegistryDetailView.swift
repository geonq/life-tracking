import SwiftUI
import Combine

/// Detail surface for registry entries without a legacy chart reference. It
/// never borrows a different provider's chart, history, reset, or estimate.
struct UsageRegistryDetailView: View {
    let presentation: UsageRegistryPresentation
    let connectionID: UsageConnectionID
    let selectedWindowID: UsageWindowID?
    let onSelectWindow: (UsageWindowID) -> Void
    let onOpenSettings: (() -> Void)?

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

    private var observationColor: Color {
        guard let observation else { return LifeOSTokens.tertiaryText }
        if observation.freshness == .stale || effectiveManualFreshness == .stale {
            return LifeOSTokens.warningText
        }
        switch observation.evidenceKind {
        case .estimated:
            return LifeOSTokens.estimate
        case .providerReported, .legacyValidated, .locallyMeasured, .manual:
            return LifeOSTokens.Series.actual
        }
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
                .lifeOSTypography(.sectionTitle, weight: .semibold)
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
            .frame(minHeight: LifeOSTokens.Control.standardHeight, alignment: .leading)
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
                    subtitle: descriptor?.productKind == .api ? "API usage" : "Subscription usage",
                    icon: .usage
                )
                if let observation {
                    valueBlock(observation)
                    Divider().overlay(LifeOSTokens.hairlineBorder)
                    sourceDisclosure(observation)
                } else {
                    Text("No value for this window.")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Text(connection?.reasonCode == "automatic_quota_unavailable"
                         ? "Automatic subscription usage is unavailable."
                         : "No usage has been reported for this window yet.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    if let onOpenSettings {
                        LifeOSButton("Open Settings", variant: .tertiary, action: onOpenSettings)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func valueBlock(_ observation: UsageRegistryObservation) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                switch observation.value {
                case .percentage(let usedPercent):
                    Text("\(Int((100 - usedPercent).rounded()))%")
                        .lifeOSTypography(.inlineMonitoringValue)
                        .foregroundStyle(observationColor)
                    Text("remaining")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                case .counter(let used, let limit):
                    Text(used.formatted(.number.notation(.compactName)))
                        .lifeOSTypography(.inlineMonitoringValue)
                        .foregroundStyle(observationColor)
                    Text(limit.map { "of \($0.formatted(.number.notation(.compactName)))" } ?? "measured")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }

                Spacer(minLength: LifeOSTokens.Space.xs)
                if let resetAt = observation.resetAt {
                    Text("Resets \(resetAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            if case .percentage(let usedPercent) = observation.value {
                HStack(alignment: .center, spacing: LifeOSTokens.Space.xs) {
                    Text("Used")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(LifeOSTokens.primaryText.opacity(0.10))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(observationColor)
                                    .frame(width: geometry.size.width * CGFloat(min(max(usedPercent / 100, 0), 1)))
                            }
                    }
                    .frame(height: 4)
                }
                .frame(minHeight: 14, alignment: .center)
            }

            if let estimate {
                Text(estimateText(estimate))
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(LifeOSTokens.estimate)
            }
        }
    }

    private func sourceDisclosure(_ observation: UsageRegistryObservation) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text("Observed \(observation.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text("Source: \(observation.source)")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            .padding(.top, LifeOSTokens.Space.xxs)
        } label: {
            HStack(spacing: LifeOSTokens.Space.xs) {
                Text(evidenceText(observation))
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                Spacer(minLength: 0)
            }
        }
    }

    private var unsupportedCard: some View {
        LifeOSCard(level: .surface, cornerRadius: LifeOSTokens.Radius.card, padding: UsageLayoutContract.cardPadding) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                UsageCardHeader(title: "Usage unavailable", subtitle: descriptor?.productKind == .api ? "API / project usage" : "Subscription usage", icon: .usage)
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
        case .available: return "Usage available"
        case .unsupported: return "Automatic usage unavailable"
        case .disabled: return "Hidden from Usage"
        case .unavailable, .none: return "No observed usage"
        }
    }

    private var unsupportedMessage: String {
        switch connection?.providerID.rawValue {
        case "gemini_subscription":
            return "Automatic Google AI Pro usage is unavailable. Add a manual reading from the official Gemini page to show a value."
        case "gemini_api":
            return "Gemini API uses project usage separately from Google AI Pro. Automatic project usage is unavailable here, so no subscription balance is shown."
        default:
            return "Usage is unavailable for this source until a value is reported."
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
        case .providerReported: return observation.official ? "Official provider · \(observation.source)" : "Provider reported · not verified"
        case .legacyValidated: return "Validated source · \(observation.source)"
        case .locallyMeasured: return "Measured locally · \(observation.source)"
        case .manual: return "Manual entry"
        case .estimated: return "Estimate"
        }
    }

    private func estimateText(_ estimate: UsageRegistryEstimate) -> String {
        if let projected = estimate.projectedPercentAtReset {
            return "Estimate at reset \(Int(projected.rounded()))% · \(estimate.confidence)"
        }
        return "Estimate · \(estimate.confidence)"
    }
}
