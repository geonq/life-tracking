import Foundation
import SwiftUI
import WidgetKit

struct LifeOSTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LifeOSEntry {
        LifeOSEntry(date: .now, snapshot: DemoDataProvider.widget())
    }

    func getSnapshot(in context: Context, completion: @escaping (LifeOSEntry) -> Void) {
        let snapshot = context.isPreview
            ? DemoDataProvider.widget()
            : liveSnapshot()
        completion(LifeOSEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LifeOSEntry>) -> Void) {
        let now = Date.now
        let snapshot = liveSnapshot(at: now)
        let entry = LifeOSEntry(date: now, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(nextRefreshDate(for: snapshot, now: now))))
    }

    private func liveSnapshot(at date: Date = .now) -> WidgetSnapshot {
        guard let snapshot = SharedSnapshotStore.read(),
              snapshot.provenance.quality != .demo,
              !snapshot.providers.contains(where: { $0.provenance.quality == .demo }) else {
            return WidgetSnapshot.unavailable(at: date)
        }
        return snapshot
    }

    private func nextRefreshDate(for snapshot: WidgetSnapshot, now: Date) -> Date {
        let nextBoundary = snapshot.providers
            .flatMap { $0.windows.compactMap(\.resetAt) }
            .filter { $0 > now }
            .min()

        guard let nextBoundary, nextBoundary.timeIntervalSince(now) <= 2 * 60 * 60 else {
            return now.addingTimeInterval(30 * 60)
        }
        return max(nextBoundary, now.addingTimeInterval(60))
    }
}

struct LifeOSEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct UsageWidgetProviderData: Identifiable {
    let summary: UsageWidgetSummary
    let resetAt: Date?
    let quality: DataQuality
    let connector: ConnectorState
    let freshness: Freshness

    var id: Provider { summary.provider }
    var name: String { Self.displayName(for: summary.provider) }

    var hasValidatedTrend: Bool {
        guard quality == .observed || quality == .demo,
              summary.observedUsedPercent.isFinite,
              (0...1).contains(summary.observedUsedPercent),
              let projected = summary.projectedUsedPercent else { return false }
        return projected.isFinite && (0...1).contains(projected)
    }

    static func displayName(for provider: Provider) -> String {
        provider.displayName
    }
}

enum UsageWidgetConnectorDisclosure: Equatable {
    case live
    case refreshDue
    case aging
    case stale
    case rateLimited
    case reconnect
    case unavailable

    var allowsRetainedValues: Bool {
        self != .reconnect && self != .unavailable
    }

    var isLive: Bool {
        self == .live
    }

    var shortLabel: String {
        switch self {
        case .live: return "Current"
        case .refreshDue: return "Refresh due"
        case .aging: return "Aging"
        case .stale: return "Stale"
        case .rateLimited: return "Rate limited"
        case .reconnect: return "Reconnect required"
        case .unavailable: return "Not connected"
        }
    }

    var retainedFooter: String {
        switch self {
        case .live: return "Current use · projected dashed"
        case .refreshDue: return "Retained use · refresh due"
        case .aging: return "Retained use · aging · not live"
        case .stale: return "Retained use · stale"
        case .rateLimited: return "Retained use · rate limited"
        case .reconnect: return "Retained use · reconnect required"
        case .unavailable: return "Retained use · not live"
        }
    }

    var previewFooter: String {
        switch self {
        case .live: return "Preview use · projected dashed"
        case .refreshDue: return "Preview use · refresh due"
        case .aging: return "Preview use · aging · not live"
        case .stale: return "Preview use · stale"
        case .rateLimited: return "Preview use · rate limited"
        case .reconnect: return "Preview use · reconnect required"
        case .unavailable: return "Preview use · not live"
        }
    }

    var unavailableFooter: String {
        switch self {
        case .live: return "not connected"
        case .refreshDue: return "refresh due"
        case .aging: return "aging"
        case .stale: return "stale"
        case .rateLimited: return "rate limited"
        case .reconnect: return "reconnect required"
        case .unavailable: return "not connected"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .live: return "current data"
        case .refreshDue: return "retained data, refresh due, not live"
        case .aging: return "aging retained data, not live"
        case .stale: return "stale retained data, not live"
        case .rateLimited: return "retained data, rate limited, not live"
        case .reconnect: return "reconnect required, not live"
        case .unavailable: return "not connected, not live"
        }
    }

    var severity: Int {
        switch self {
        case .live: return 0
        case .refreshDue: return 1
        case .aging: return 2
        case .stale: return 3
        case .rateLimited: return 4
        case .reconnect: return 5
        case .unavailable: return 6
        }
    }

    static func from(_ connector: ConnectorState) -> Self {
        switch connector {
        case .healthy: return .live
        case .refreshDue: return .refreshDue
        case .rateLimited: return .rateLimited
        case .reauthRequired, .revoked: return .reconnect
        case .disabled, .unavailable, .error: return .unavailable
        }
    }

    static func from(_ connector: ConnectorState, freshness: Freshness) -> Self {
        let connectorDisclosure = from(connector)
        guard connectorDisclosure == .live else { return connectorDisclosure }
        switch freshness {
        case .fresh: return .live
        case .aging: return .aging
        case .stale: return .stale
        case .unavailable: return .unavailable
        }
    }
}

enum UsageWidgetChartState: Equatable {
    case observed
    case demo
    case partial
    case unavailable

    var rendersSeries: Bool {
        self == .observed || self == .demo
    }

    var title: String {
        switch self {
        case .observed: return "Observed trend"
        case .demo: return "Preview trend"
        case .partial: return "Partial trend"
        case .unavailable: return "Trend unavailable"
        }
    }

    var detail: String {
        switch self {
        case .observed, .demo: return ""
        case .partial: return "More provider data needed"
        case .unavailable: return "No connected provider data"
        }
    }

    func accessibilityLabel(isLive: Bool = true) -> String {
        switch self {
        case .observed:
            return isLive ? "Usage trend, observed data" : "Usage trend, observed data, not live"
        case .demo:
            return "Usage trend, preview data, not live"
        case .partial:
            return "Usage trend, partial data, not live"
        case .unavailable:
            return "Usage trend unavailable, not live"
        }
    }
}

enum UsageWidgetData {
    static func providers(
        from snapshot: WidgetSnapshot,
        at referenceDate: Date? = nil
    ) -> [UsageWidgetProviderData] {
        let resolvedReferenceDate = referenceDate ?? snapshot.updatedAt
        return snapshot.providers.compactMap { provider -> UsageWidgetProviderData? in
            guard provider.provenance.quality == .observed || provider.provenance.quality == .demo,
                  provider.provenance.quality == snapshot.provenance.quality,
                  UsageWidgetConnectorDisclosure.from(
                      provider.provenance.connector,
                      freshness: provider.provenance.freshness(now: resolvedReferenceDate)
                  ).allowsRetainedValues else { return nil }
            guard let summary = UsageWidgetSummary(snapshot: provider) else { return nil }
            guard summary.observedUsedPercent.isFinite,
                  (0...1).contains(summary.observedUsedPercent) else { return nil }
            return UsageWidgetProviderData(
                summary: summary,
                resetAt: provider.smallestObservedWindow?.resetAt,
                quality: provider.provenance.quality,
                connector: provider.provenance.connector,
                freshness: provider.provenance.freshness(now: resolvedReferenceDate)
            )
        }
    }

    static func hasDemoSource(in snapshot: WidgetSnapshot) -> Bool {
        snapshot.provenance.quality == .demo
            || snapshot.providers.contains { $0.provenance.quality == .demo }
    }

    static func providersForDisplay(
        from snapshot: WidgetSnapshot,
        allowDemo: Bool = true,
        at referenceDate: Date? = nil
    ) -> [UsageWidgetProviderData] {
        guard !hasInconsistentProvenance(in: snapshot) else { return [] }
        return providers(from: snapshot, at: referenceDate).filter { provider in
            guard allowDemo || provider.quality != .demo else { return false }
            return UsageWidgetConnectorDisclosure.from(
                provider.connector,
                freshness: provider.freshness
            ).allowsRetainedValues
        }
    }

    static func connectorDisclosure(
        for snapshot: WidgetSnapshot,
        lead: UsageWidgetProviderData? = nil,
        at referenceDate: Date? = nil
    ) -> UsageWidgetConnectorDisclosure {
        let resolvedReferenceDate = referenceDate ?? snapshot.updatedAt
        var disclosures = [UsageWidgetConnectorDisclosure.from(
            snapshot.provenance.connector,
            freshness: effectiveFreshness(for: snapshot, at: resolvedReferenceDate)
        )]
        if let lead {
            disclosures.append(.from(lead.connector, freshness: lead.freshness))
        }
        disclosures += providers(from: snapshot, at: resolvedReferenceDate).map {
            .from($0.connector, freshness: $0.freshness)
        }
        return disclosures.max(by: { $0.severity < $1.severity }) ?? .unavailable
    }

    private static func effectiveFreshness(
        for snapshot: WidgetSnapshot,
        at referenceDate: Date
    ) -> Freshness {
        let provenanceFreshness = snapshot.provenance.freshness(now: referenceDate)
        return moreStale(snapshot.freshness, provenanceFreshness)
    }

    private static func moreStale(_ lhs: Freshness, _ rhs: Freshness) -> Freshness {
        return freshnessSeverity(lhs) >= freshnessSeverity(rhs) ? lhs : rhs
    }

    private static func freshnessSeverity(_ freshness: Freshness) -> Int {
        switch freshness {
        case .fresh: return 0
        case .aging: return 1
        case .stale: return 2
        case .unavailable: return 3
        }
    }

    static func hasInconsistentProvenance(in snapshot: WidgetSnapshot) -> Bool {
        let providerQualities = snapshot.providers.map(\.provenance.quality)
        switch snapshot.provenance.quality {
        case .observed:
            return providerQualities.contains(.demo) || providerQualities.contains(.estimated)
        case .demo:
            return providerQualities.contains(.observed) || providerQualities.contains(.estimated)
        case .estimated:
            return providerQualities.contains(.observed) || providerQualities.contains(.demo)
        case .unavailable:
            return providerQualities.contains(.observed)
                || providerQualities.contains(.estimated)
                || providerQualities.contains(.demo)
        }
    }

    private static func hasBlockedProvider(
        in snapshot: WidgetSnapshot,
        at referenceDate: Date
    ) -> Bool {
        snapshot.providers.contains {
            ($0.provenance.quality == .observed || $0.provenance.quality == .demo)
                && $0.provenance.quality == snapshot.provenance.quality
                && !UsageWidgetConnectorDisclosure.from(
                    $0.provenance.connector,
                    freshness: $0.provenance.freshness(now: referenceDate)
                ).allowsRetainedValues
        }
    }

    static func leading(from providers: [UsageWidgetProviderData]) -> UsageWidgetProviderData? {
        providers.sorted(by: isHigherPriority).first
    }

    private static func isHigherPriority(
        _ lhs: UsageWidgetProviderData,
        _ rhs: UsageWidgetProviderData
    ) -> Bool {
        if lhs.summary.observedUsedPercent != rhs.summary.observedUsedPercent {
            return lhs.summary.observedUsedPercent > rhs.summary.observedUsedPercent
        }

        switch (lhs.resetAt, rhs.resetAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.name < rhs.name
        }
    }

    static func chartState(
        for snapshot: WidgetSnapshot,
        at referenceDate: Date? = nil
    ) -> UsageWidgetChartState {
        let resolvedReferenceDate = referenceDate ?? snapshot.updatedAt
        let providers = providersForDisplay(from: snapshot, at: resolvedReferenceDate)
        if hasInconsistentProvenance(in: snapshot) {
            return snapshot.provenance.quality == .unavailable ? .unavailable : .partial
        }

        guard let lead = leading(from: providers) else {
            let hasProviderData = snapshot.providers.contains {
                $0.provenance.quality == .observed
                    || $0.provenance.quality == .estimated
                    || $0.provenance.quality == .demo
            }
            if hasBlockedProvider(in: snapshot, at: resolvedReferenceDate) { return .unavailable }
            if snapshot.provenance.quality == .demo {
                return hasProviderData ? .partial : .unavailable
            }
            return hasProviderData ? .partial : .unavailable
        }

        switch (snapshot.provenance.quality, lead.quality) {
        case (.unavailable, _):
            return .unavailable
        case (.estimated, _):
            return .partial
        case (.observed, .observed):
            return lead.hasValidatedTrend ? .observed : .partial
        case (.demo, .demo):
            return lead.hasValidatedTrend ? .demo : .partial
        default:
            return .partial
        }
    }

    static func isLive(
        for snapshot: WidgetSnapshot,
        at referenceDate: Date? = nil
    ) -> Bool {
        let resolvedReferenceDate = referenceDate ?? snapshot.updatedAt
        guard chartState(for: snapshot, at: resolvedReferenceDate) == .observed,
              snapshot.provenance.quality == .observed,
              !hasDemoSource(in: snapshot),
              !hasInconsistentProvenance(in: snapshot),
              let lead = leading(from: providersForDisplay(from: snapshot, at: resolvedReferenceDate)) else { return false }
        return connectorDisclosure(
            for: snapshot,
            lead: lead,
            at: resolvedReferenceDate
        ) == .live
    }

}

private enum UsageWidgetDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func updated(_ date: Date) -> String {
        "Updated \(formatter.string(from: date))"
    }
}

private struct UsageRingView: View {
    let progress: Double?
    let diameter: CGFloat
    let lineWidth: CGFloat
    let heroFontSize: CGFloat
    let disclosure: UsageWidgetConnectorDisclosure
    let isPreview: Bool

    private var clampedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    private var heroText: String {
        guard let progress else { return "—" }
        let remainingPercent = Int((min(max(progress, 0), 1) * 100).rounded())
        return "\(remainingPercent)%"
    }

    private var accessibilityText: String {
        guard let progress else {
            if isPreview { return "Usage not connected, Preview data, not live" }
            return "Usage not connected, \(disclosure.accessibilityLabel)"
        }
        let remainingPercent = Int((min(max(progress, 0), 1) * 100).rounded())
        var result = "\(remainingPercent) percent remaining, \(disclosure.accessibilityLabel)"
        if isPreview { result += ", Preview data, not live" }
        return result
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(LifeOSTokens.Ring.track, lineWidth: lineWidth)

            if progress != nil, clampedProgress > 0 {
                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        LifeOSTokens.Ring.progress(.blue),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(heroText)
                .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(progress == nil ? Color.secondary : Color.primary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

struct LifeOSUsageSmallWidgetView: View {
    let entry: LifeOSEntry

    private var providers: [UsageWidgetProviderData] {
        UsageWidgetData.providersForDisplay(from: entry.snapshot, at: entry.date)
    }

    private var lead: UsageWidgetProviderData? {
        UsageWidgetData.leading(from: providers)
    }

    private var label: String {
        guard let lead else {
            let disclosure = UsageWidgetData.connectorDisclosure(for: entry.snapshot, at: entry.date)
            return disclosure == .live ? "Not connected" : disclosure.shortLabel
        }
        let disclosure = UsageWidgetData.connectorDisclosure(for: entry.snapshot, lead: lead, at: entry.date)
        let suffix = disclosure == .live ? "" : " · \(disclosure.shortLabel)"
        return "\(lead.name) · \(lead.summary.windowIndicator)\(suffix)"
    }

    var body: some View {
        VStack(spacing: 4) {
            UsageRingView(
                progress: lead.map { $0.summary.remainingPercent },
                diameter: 56,
                lineWidth: 6,
                heroFontSize: 15,
                disclosure: UsageWidgetData.connectorDisclosure(for: entry.snapshot, lead: lead, at: entry.date),
                isPreview: UsageWidgetData.hasDemoSource(in: entry.snapshot)
            )

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 5) {
                Text(UsageWidgetDate.updated(entry.snapshot.updatedAt))
                if UsageWidgetData.hasDemoSource(in: entry.snapshot) {
                    Text("PREVIEW").fontWeight(.bold)
                }
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(10)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://usage"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let lead else {
            let state = UsageWidgetData.chartState(for: entry.snapshot, at: entry.date)
            var result = state == .unavailable ? "Usage, not connected" : "Usage, partial data, not live"
            if UsageWidgetData.hasDemoSource(in: entry.snapshot) {
                result += ", Preview data, not live"
            }
            return result
        }
        let disclosure = UsageWidgetData.connectorDisclosure(for: entry.snapshot, lead: lead, at: entry.date)
        var result = "Usage, \(lead.name), \(Int((lead.summary.remainingPercent * 100).rounded())) percent remaining, \(lead.summary.windowIndicator) window"
        if disclosure != .live {
            result += ", \(disclosure.accessibilityLabel)"
        }
        if UsageWidgetData.hasDemoSource(in: entry.snapshot) {
            result += ", Preview data, not live"
        }
        return result
    }
}

struct LifeOSWidgetView: View {
    let entry: LifeOSEntry

    private var providers: [UsageWidgetProviderData] {
        UsageWidgetData.providersForDisplay(from: entry.snapshot, at: entry.date)
    }

    private var lead: UsageWidgetProviderData? {
        UsageWidgetData.leading(from: providers)
    }

    private var secondary: UsageWidgetProviderData? {
        providers.first { $0.id != lead?.id }
    }

    private var chartState: UsageWidgetChartState {
        UsageWidgetData.chartState(for: entry.snapshot, at: entry.date)
    }

    private var chartIsLive: Bool {
        UsageWidgetData.isLive(for: entry.snapshot, at: entry.date)
    }

    private var connectorDisclosure: UsageWidgetConnectorDisclosure {
        UsageWidgetData.connectorDisclosure(for: entry.snapshot, lead: lead, at: entry.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    UsageRingView(
                        progress: lead.map { $0.summary.remainingPercent },
                        diameter: 72,
                        lineWidth: 8,
                        heroFontSize: 18,
                        disclosure: UsageWidgetData.connectorDisclosure(for: entry.snapshot, lead: lead, at: entry.date),
                        isPreview: UsageWidgetData.hasDemoSource(in: entry.snapshot)
                    )

                    Text(leadLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let secondary {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LifeOSTokens.Hue.teal.base)
                                .frame(width: 5, height: 5)
                            Text(secondary.name)
                            Spacer(minLength: 1)
                            Text(secondaryPercentage)
                                .monospacedDigit()
                                .foregroundStyle(LifeOSTokens.Hue.teal.base)
                        }
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                    }
                }
                .frame(width: 106)

                SharedUsageGraph(
                    summary: lead,
                    state: chartState,
                    isLive: chartIsLive
                )
                    .frame(maxWidth: .infinity, minHeight: 74)
            }

            HStack(spacing: 4) {
                Text(chartFooter)
                Spacer(minLength: 4)
                Text(UsageWidgetDate.updated(entry.snapshot.updatedAt))
                if UsageWidgetData.hasDemoSource(in: entry.snapshot) {
                    Text("PREVIEW").fontWeight(.bold)
                }
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(12)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://usage"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let lead else {
            var result = "Usage overview, \(chartState.accessibilityLabel(isLive: false))"
            if UsageWidgetData.hasDemoSource(in: entry.snapshot), chartState != .demo {
                result += ", Preview data, not live"
            }
            if connectorDisclosure != .live {
                result += ", \(connectorDisclosure.accessibilityLabel)"
            }
            return result
        }
        var result = "Usage overview, \(lead.name) \(Int((lead.summary.remainingPercent * 100).rounded())) percent remaining, \(lead.summary.windowIndicator) window"
        if let secondary {
            result += ", \(secondary.name) \(Int((secondary.summary.remainingPercent * 100).rounded())) percent remaining"
            let secondaryDisclosure = UsageWidgetConnectorDisclosure.from(
                secondary.connector,
                freshness: secondary.freshness
            )
            if secondaryDisclosure != .live {
                result += ", \(secondaryDisclosure.accessibilityLabel)"
            }
        }
        result += ", \(chartState.accessibilityLabel(isLive: chartIsLive))"
        if connectorDisclosure != .live {
            result += ", \(connectorDisclosure.accessibilityLabel)"
        }
        if UsageWidgetData.hasDemoSource(in: entry.snapshot), chartState != .demo {
            result += ", Preview data, not live"
        }
        return result
    }

    private var chartFooter: String {
        switch chartState {
        case .observed:
            return connectorDisclosure.retainedFooter
        case .demo:
            return connectorDisclosure.previewFooter
        case .partial:
            if connectorDisclosure != .live {
                return "Partial trend · \(connectorDisclosure.shortLabel.lowercased())"
            }
            return "Partial trend · more data needed"
        case .unavailable:
            return "Trend unavailable · \(connectorDisclosure.unavailableFooter)"
        }
    }

    private var leadLabel: String {
        guard let lead else { return "Not connected" }
        let suffix = connectorDisclosure == .live ? "" : " · \(connectorDisclosure.shortLabel)"
        return "\(lead.name) · \(lead.summary.windowIndicator) window\(suffix)"
    }

    private var secondaryPercentage: String {
        guard let secondary else { return "" }
        let disclosure = UsageWidgetConnectorDisclosure.from(
            secondary.connector,
            freshness: secondary.freshness
        )
        let suffix = disclosure == .live ? "" : " · \(disclosure.shortLabel.lowercased())"
        return "\(Int((secondary.summary.remainingPercent * 100).rounded()))%\(suffix)"
    }
}

private struct SharedUsageGraph: View {
    let summary: UsageWidgetProviderData?
    let state: UsageWidgetChartState
    let isLive: Bool

    private let observedX = 0.62

    @ViewBuilder
    var body: some View {
        if state.rendersSeries, let summary, summary.hasValidatedTrend,
           let projected = summary.summary.projectedUsedPercent {
            validatedGraph(summary: summary, projected: projected)
        } else {
            VStack(spacing: 3) {
                Text(state.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func validatedGraph(
        summary: UsageWidgetProviderData,
        projected: Double
    ) -> some View {
        GeometryReader { proxy in
            let inset: CGFloat = 4
            let width = max(1, proxy.size.width - inset * 2)
            let height = max(1, proxy.size.height - inset * 2)
            let observedValue = summary.summary.observedUsedPercent
            let newestValue = projected
            let newestX = 1.0
            let newestPoint = point(
                x: newestX,
                value: newestValue,
                width: width,
                height: height,
                inset: inset
            )

            ZStack {
                Canvas { context, size in
                    let graphWidth = max(1, size.width - inset * 2)
                    let graphHeight = max(1, size.height - inset * 2)
                    let observedEndX = observedX
                    let start = point(x: 0, value: observedValue, width: graphWidth, height: graphHeight, inset: inset)
                    let observedEnd = point(x: observedEndX, value: observedValue, width: graphWidth, height: graphHeight, inset: inset)
                    let end = point(x: 1, value: projected, width: graphWidth, height: graphHeight, inset: inset)

                    var trend = Path()
                    trend.move(to: start)
                    trend.addLine(to: observedEnd)
                    trend.addLine(to: end)

                    var area = trend
                    area.addLine(to: CGPoint(x: end.x, y: size.height - inset))
                    area.addLine(to: CGPoint(x: start.x, y: size.height - inset))
                    area.closeSubpath()
                    context.fill(
                        area,
                        with: .linearGradient(
                            Gradient(colors: [
                                LifeOSTokens.Hue.blue.base.opacity(0.12),
                                Color.clear
                            ]),
                            startPoint: CGPoint(x: 0, y: inset),
                            endPoint: CGPoint(x: 0, y: size.height - inset)
                        )
                    )

                    var observed = Path()
                    observed.move(to: start)
                    observed.addLine(to: observedEnd)
                    context.stroke(
                        observed,
                        with: .linearGradient(
                            Gradient(colors: [LifeOSTokens.Hue.blue.base, LifeOSTokens.Hue.blue.glow]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: size.width, y: 0)
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )

                    var estimate = Path()
                    estimate.move(to: observedEnd)
                    estimate.addLine(to: end)
                    context.stroke(
                        estimate,
                        with: .linearGradient(
                            Gradient(colors: [
                                LifeOSTokens.Hue.blue.base.opacity(0.50),
                                LifeOSTokens.Hue.blue.glow.opacity(0.50)
                            ]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: size.width, y: 0)
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [3, 3])
                    )
                }

                Circle()
                    .fill(LifeOSTokens.Hue.blue.base)
                    .frame(width: 5, height: 5)
                    .position(newestPoint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(isLive: isLive))
    }

    private func point(x: Double, value: Double, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGPoint {
        CGPoint(
            x: inset + width * CGFloat(x),
            y: inset + height * (1 - min(max(value, 0), 1))
        )
    }
}

struct LifeOSWidget: Widget {
    let kind = "LifeOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSWidgetView(entry: $0) }
            .configurationDisplayName("Usage overview")
            .description("Connected AI provider limits with a shared projection graph")
            .supportedFamilies([.systemMedium])
    }
}

struct LifeOSUsageSmallWidget: Widget {
    let kind = "LifeOSUsageSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSUsageSmallWidgetView(entry: $0) }
            .configurationDisplayName("Usage ring")
            .description("Remaining AI usage in a compact ring")
            .supportedFamilies([.systemSmall])
    }
}

enum UsageWidgetAccessoryDisplayState: Equatable {
    case live
    case retained(UsageWidgetConnectorDisclosure)
    case empty

    static func resolve(
        hasValue: Bool,
        disclosure: UsageWidgetConnectorDisclosure
    ) -> Self {
        guard hasValue else { return .empty }
        guard disclosure.allowsRetainedValues else { return .empty }
        return disclosure == .live ? .live : .retained(disclosure)
    }
}

#if os(iOS)
private struct LifeOSUsageAccessoryCircularView: View {
    let entry: LifeOSEntry

    private var lead: UsageWidgetProviderData? {
        let providers = UsageWidgetData.providersForDisplay(from: entry.snapshot, allowDemo: false, at: entry.date)
        return UsageWidgetData.leading(from: providers)
    }

    private var disclosure: UsageWidgetConnectorDisclosure {
        UsageWidgetData.connectorDisclosure(for: entry.snapshot, lead: lead, at: entry.date)
    }

    private var displayState: UsageWidgetAccessoryDisplayState {
        UsageWidgetAccessoryDisplayState.resolve(hasValue: lead != nil, disclosure: disclosure)
    }

    private var progress: Double {
        lead?.summary.remainingPercent ?? 0
    }

    @ViewBuilder
    private var accessoryProgress: some View {
        switch displayState {
        case .live:
            circularProgress(tint: LifeOSTokens.Hue.blue.base)
        case .retained:
            ZStack {
                circularProgress(tint: LifeOSTokens.warning)
                Circle()
                    .fill(LifeOSTokens.warning)
                    .frame(width: 5, height: 5)
                    .offset(y: -14)
                    .accessibilityHidden(true)
            }
        case .empty:
            ProgressView(value: 0, total: 1)
                .progressViewStyle(.circular)
                .tint(LifeOSTokens.Ring.track)
        }
    }

    private func circularProgress(tint: Color) -> some View {
        ProgressView(value: progress, total: 1)
            .progressViewStyle(.circular)
            .tint(tint)
    }

    var body: some View {
        accessoryProgress
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "lifeos://usage"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let lead else {
            var result = UsageWidgetData.chartState(for: entry.snapshot, at: entry.date) == .unavailable
                ? "Usage, not connected"
                : "Usage, partial data, not live"
            if UsageWidgetData.hasDemoSource(in: entry.snapshot) {
                result += ", Preview data, not live"
            }
            if disclosure != .live {
                result += ", \(disclosure.accessibilityLabel)"
            }
            return result
        }
        var result = "Usage, \(lead.name), \(Int((lead.summary.remainingPercent * 100).rounded())) percent remaining"
        if disclosure != .live {
            result += ", \(disclosure.accessibilityLabel)"
        }
        if UsageWidgetData.hasDemoSource(in: entry.snapshot) {
            result += ", Preview data, not live"
        }
        return result
    }
}

struct LifeOSUsageLockScreenWidget: Widget {
    let kind = "LifeOSUsageLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSUsageAccessoryCircularView(entry: $0) }
            .configurationDisplayName("Usage")
            .description("Remaining AI usage on the Lock Screen")
            .supportedFamilies([.accessoryCircular])
    }
}
#endif
