import SwiftUI
import WidgetKit

/// Text colors shared by every chrome-managed widget. Accented/vibrant homescreen
/// rendering composites the widget over a system backdrop, where opaque token
/// surfaces and dark text become illegible; those modes resolve to white/opacity
/// pairs over a cleared container background instead.
struct LifeOSWidgetChrome {
    let hero: Color
    let secondary: Color
    let tertiary: Color
    let usesTransparentTreatment: Bool

    static func resolving(
        showsContainerBackground: Bool,
        renderingMode: WidgetRenderingMode
    ) -> Self {
        let usesTransparentTreatment = !showsContainerBackground || renderingMode != .fullColor
        return LifeOSWidgetChrome(
            hero: usesTransparentTreatment ? .white : .primary,
            secondary: usesTransparentTreatment ? .white.opacity(0.76) : .secondary,
            tertiary: usesTransparentTreatment ? .white.opacity(0.53) : LifeOSTokens.tertiaryText,
            usesTransparentTreatment: usesTransparentTreatment
        )
    }
}

private struct LifeOSWidgetChromeKey: EnvironmentKey {
    static let defaultValue = LifeOSWidgetChrome(hero: .primary, secondary: .secondary, tertiary: LifeOSTokens.tertiaryText, usesTransparentTreatment: false)
}

extension EnvironmentValues {
    var lifeOSWidgetChrome: LifeOSWidgetChrome {
        get { self[LifeOSWidgetChromeKey.self] }
        set { self[LifeOSWidgetChromeKey.self] = newValue }
    }
}

private struct LifeOSWidgetContainerModifier<Background: View>: ViewModifier {
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    let background: Background

    init(@ViewBuilder background: () -> Background) {
        self.background = background()
    }

    func body(content: Content) -> some View {
        let chrome = LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
        return content
            .containerBackground(for: .widget) {
                chrome.usesTransparentTreatment ? AnyView(Color.clear) : AnyView(background)
            }
            // Establish one inherited hero role for any metric text that does
            // not need a more specific semantic treatment. This keeps tinted,
            // vibrant, and clear widgets from falling back to system `.primary`
            // over an arbitrary wallpaper.
            .foregroundStyle(chrome.hero)
            .environment(\.lifeOSWidgetChrome, chrome)
    }
}

extension View {
    func lifeOSWidgetContainer(@ViewBuilder background: () -> some View) -> some View {
        modifier(LifeOSWidgetContainerModifier(background: background))
    }
}

/// A single unavailable entry shared by every future-module widget.
///
/// These widgets are selectable before their modules have connectors. Keeping the entry free of
/// module-specific fields makes it impossible for a preview or timeline to accidentally imply
/// that an unavailable metric is zero.
struct FutureModuleWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: FutureWidgetSnapshot

    init(date: Date = .now, snapshot: FutureWidgetSnapshot? = nil) {
        self.date = date
        self.snapshot = snapshot ?? .unavailable(at: date)
    }
}

struct FutureModuleTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FutureModuleWidgetEntry {
        FutureModuleWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (FutureModuleWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FutureModuleWidgetEntry>) -> Void) {
        let entry = loadEntry()
        // WidgetKit does not re-evaluate a persisted entry as it ages. Schedule
        // the next read at the bounded freshness boundary so the widget can
        // honestly transition from fresh to stale (or unavailable) without
        // requiring the app process to be running.
        completion(Timeline(
            entries: [entry],
            policy: .after(nextRefreshDate(for: entry.snapshot, loadedAt: entry.date))
        ))
    }

    private func nextRefreshDate(for snapshot: FutureWidgetSnapshot, loadedAt: Date) -> Date {
        let boundaries = [snapshot.finance.observedAt, snapshot.fitness.observedAt,
                          snapshot.fitnessWidgets.observedAt, snapshot.nutrition.observedAt]
            .compactMap { $0?.addingTimeInterval(futureWidgetFreshnessWindow) }
            .filter { $0 > loadedAt }
        return boundaries.min() ?? loadedAt.addingTimeInterval(futureWidgetFreshnessWindow)
    }

    private func loadEntry(at date: Date = .now) -> FutureModuleWidgetEntry {
        guard let snapshot = FutureWidgetSnapshotStore.read(now: date) else {
            return FutureModuleWidgetEntry(date: date)
        }
        // TimelineEntry.date is the load time, never an old observation time.
        return FutureModuleWidgetEntry(date: date, snapshot: snapshot)
    }
}

private func futureModuleCurrency(_ cents: Int, maximumFractionDigits: Int = 0) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "EUR"
    formatter.maximumFractionDigits = maximumFractionDigits
    formatter.minimumFractionDigits = maximumFractionDigits
    return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "€—"
}

private func futureModuleScore(_ score: Double) -> String {
    String(format: "%.0f", score)
}

private func futureModuleStateText(_ state: WidgetAggregateAvailability) -> String {
    switch state {
    case .fresh: return "Aggregate"
    case .stale: return "Stale summary"
    case .unavailable: return "Not connected"
    case .redacted: return "Summary hidden"
    }
}

private func futureModuleAccessibilityState(_ state: WidgetAggregateAvailability) -> String {
    switch state {
    case .fresh: return "aggregate summary"
    case .stale: return "stale aggregate summary"
    case .unavailable: return "not connected"
    case .redacted: return "summary hidden"
}
}

private struct FutureModuleWidgetHeader: View {
    let title: String
    let icon: LifeOSIconName
    let accent: Color

    @Environment(\.lifeOSWidgetChrome) private var chrome

    init(title: String, icon: LifeOSIconName, accent: Color = LifeOSTokens.accent) {
        self.title = title
        self.icon = icon
        self.accent = accent
    }

    var body: some View {
        let iconColor = chrome.usesTransparentTreatment ? chrome.secondary : accent
        HStack(spacing: 7) {
            LifeOSIcon(icon)
                .frame(width: 16, height: 16)
                .foregroundStyle(iconColor)
            Text(title)
                .font(LifeOSFont.widgetHeader())
                .foregroundStyle(chrome.hero)
                Spacer(minLength: 0)
        }
    }
}

private func futureModuleMetricState(
    _ aggregateState: WidgetAggregateAvailability,
    hasValue: Bool
) -> WidgetAggregateAvailability {
    if aggregateState == .redacted { return .redacted }
    return hasValue ? aggregateState : .unavailable
}

private func futureModuleAccessibilityLabel(
    title: String,
    aggregateState: WidgetAggregateAvailability,
    hasValue: Bool
) -> String {
    "\(title), \(futureModuleAccessibilityState(futureModuleMetricState(aggregateState, hasValue: hasValue)))"
}

private struct FutureModuleUnavailableHero: View {
    let state: WidgetAggregateAvailability

    init(state: WidgetAggregateAvailability = .unavailable) {
        self.state = state
    }

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(spacing: 2) {
            Text(state == .redacted ? "Hidden" : "—")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(chrome.hero)
            Text(state == .redacted ? "Summary hidden" : "Not connected")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(chrome.tertiary)
        }
    }
}

private struct FutureModuleTrackRing: View {
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        Circle()
            .stroke(
                LifeOSTokens.Ring.track,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

private struct FutureModuleProgressRing: View {
    let diameter: CGFloat
    let lineWidth: CGFloat
    let progress: Double

    var body: some View {
        ZStack {
            FutureModuleTrackRing(diameter: diameter, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    LifeOSTokens.Ring.progressArc,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .accessibilityHidden(true)
        }
    }
}

private struct FutureModuleFlatTrend: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let baseline = proxy.size.height * 0.5
                path.move(to: CGPoint(x: 0, y: baseline))
                path.addLine(to: CGPoint(x: proxy.size.width, y: baseline))
            }
            .stroke(
                LifeOSTokens.tertiaryText.opacity(0.42),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
        .frame(minHeight: 36)
        .accessibilityHidden(true)
    }
}

private struct FutureModuleEmptyHealthBars: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                Capsule()
                    .fill(LifeOSTokens.Ring.track)
                    .frame(width: 8, height: 52)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FutureModuleEmptyCashFlowTracks: View {
    var body: some View {
        HStack(spacing: 10) {
            FutureModuleCashFlowTrack(label: "In")
            FutureModuleCashFlowTrack(label: "Out")
        }
        .accessibilityHidden(true)
    }
}

private struct FutureModuleCashFlowTrack: View {
    let label: String

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(chrome.tertiary)
            Capsule()
                .fill(LifeOSTokens.Ring.track)
                .frame(height: 5)
        }
    }
}

struct NetWorthWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FutureModuleWidgetHeader(title: "Net Worth", icon: .netWorth, accent: LifeOSTokens.Module.finance)

            if let netWorth = entry.snapshot.finance.netWorthCents,
               entry.snapshot.financeDisplayState(at: entry.date) == .fresh || entry.snapshot.financeDisplayState(at: entry.date) == .stale {
                Text(futureModuleCurrency(netWorth, maximumFractionDigits: 2))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(chrome.hero)
                Text(futureModuleStateText(entry.snapshot.financeDisplayState(at: entry.date)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                Spacer(minLength: 0)
                Text("Aggregate only")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.financeDisplayState(at: entry.date),
                    hasValue: entry.snapshot.finance.netWorthCents != nil
                ))
                Spacer(minLength: 0)
                FutureModuleFlatTrend()
            }
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://finance"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(futureModuleAccessibilityLabel(
            title: "Net Worth",
            aggregateState: entry.snapshot.financeDisplayState(at: entry.date),
            hasValue: entry.snapshot.finance.netWorthCents != nil
        ))
    }
}

struct SpendRingWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            FutureModuleWidgetHeader(title: "Spend", icon: .spending, accent: LifeOSTokens.Module.finance)

            Spacer(minLength: 0)
            if let spend = entry.snapshot.finance.spendCents,
               entry.snapshot.financeDisplayState(at: entry.date) == .fresh || entry.snapshot.financeDisplayState(at: entry.date) == .stale {
                VStack(spacing: 4) {
                    Text(futureModuleCurrency(spend))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(chrome.hero)
                        .minimumScaleFactor(0.65)
                    Text("Observed spend")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(chrome.tertiary)
                }
                Text(futureModuleStateText(entry.snapshot.financeDisplayState(at: entry.date)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            } else {
                ZStack {
                    FutureModuleTrackRing(diameter: 64, lineWidth: 6)
                    Text("—")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(chrome.hero)
                }
                Text(futureModuleStateText(futureModuleMetricState(
                    entry.snapshot.financeDisplayState(at: entry.date),
                    hasValue: entry.snapshot.finance.spendCents != nil
                )))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://finance/spend"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(futureModuleAccessibilityLabel(
            title: "Spend",
            aggregateState: entry.snapshot.financeDisplayState(at: entry.date),
            hasValue: entry.snapshot.finance.spendCents != nil
        ))
    }
}

struct CashFlowWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FutureModuleWidgetHeader(title: "Cash Flow", icon: .cashFlow, accent: LifeOSTokens.Module.finance)

            if let cashFlow = entry.snapshot.finance.cashFlowCents,
               entry.snapshot.financeDisplayState(at: entry.date) == .fresh || entry.snapshot.financeDisplayState(at: entry.date) == .stale {
                Text(futureModuleCurrency(cashFlow, maximumFractionDigits: 2))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(chrome.hero)
                Text(futureModuleStateText(entry.snapshot.financeDisplayState(at: entry.date)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                Spacer(minLength: 0)
                Text("Aggregate only")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.financeDisplayState(at: entry.date),
                    hasValue: entry.snapshot.finance.cashFlowCents != nil
                ))
                Spacer(minLength: 0)
                FutureModuleFlatTrend()
                    .frame(height: 32)
                FutureModuleEmptyCashFlowTracks()
            }
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://finance/cashflow"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(futureModuleAccessibilityLabel(
            title: "Cash Flow",
            aggregateState: entry.snapshot.financeDisplayState(at: entry.date),
            hasValue: entry.snapshot.finance.cashFlowCents != nil
        ))
    }
}

struct HealthMonitorWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FutureModuleWidgetHeader(title: "Health Monitor", icon: .health, accent: LifeOSTokens.Module.fitness)

            if let health = entry.snapshot.fitness.healthScore,
               entry.snapshot.fitnessDisplayState(at: entry.date) == .fresh || entry.snapshot.fitnessDisplayState(at: entry.date) == .stale {
                Text(futureModuleScore(health))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(chrome.hero)
                Text("Health aggregate")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                Spacer(minLength: 0)
                Text(futureModuleStateText(entry.snapshot.fitnessDisplayState(at: entry.date)))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    FutureModuleUnavailableHero(state: futureModuleMetricState(
                        entry.snapshot.fitnessDisplayState(at: entry.date),
                        hasValue: entry.snapshot.fitness.healthScore != nil
                    ))
                        .frame(width: 92, alignment: .leading)
                    FutureModuleEmptyHealthBars()
                }
                Spacer(minLength: 0)
                Text(futureModuleStateText(futureModuleMetricState(
                    entry.snapshot.fitnessDisplayState(at: entry.date),
                    hasValue: entry.snapshot.fitness.healthScore != nil
                )))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            }
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(futureModuleAccessibilityLabel(
            title: "Health Monitor",
            aggregateState: entry.snapshot.fitnessDisplayState(at: entry.date),
            hasValue: entry.snapshot.fitness.healthScore != nil
        ))
    }
}

struct RecoveryRingWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                LifeOSIcon(.heartRate)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(chrome.usesTransparentTreatment ? chrome.secondary : LifeOSTokens.Module.fitness)
                Text("Recovery")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chrome.hero)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            if let recovery = entry.snapshot.fitness.recoveryScore,
               entry.snapshot.fitnessDisplayState(at: entry.date) == .fresh || entry.snapshot.fitnessDisplayState(at: entry.date) == .stale {
                ZStack {
                    FutureModuleProgressRing(diameter: 56, lineWidth: 6, progress: recovery / 100)
                    Text(futureModuleScore(recovery))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(chrome.hero)
                }
                Text(futureModuleStateText(futureModuleMetricState(
                    entry.snapshot.fitnessDisplayState(at: entry.date),
                    hasValue: entry.snapshot.fitness.recoveryScore != nil
                )))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            } else {
                ZStack {
                    FutureModuleTrackRing(diameter: 56, lineWidth: 6)
                    Text("—")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(chrome.hero)
                }
                Text(futureModuleStateText(entry.snapshot.fitnessDisplayState(at: entry.date)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            }
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(futureModuleAccessibilityLabel(
            title: "Recovery and Strain",
            aggregateState: entry.snapshot.fitnessDisplayState(at: entry.date),
            hasValue: entry.snapshot.fitness.recoveryScore != nil
        ))
    }
}

struct TasksSmallWidgetView: View {
    let entry: FutureModuleWidgetEntry

    var body: some View {
        VStack(spacing: 8) {
            FutureModuleWidgetHeader(title: "Today's Tasks", icon: .tasks, accent: LifeOSTokens.Module.tasks)

            Spacer(minLength: 0)
            FutureModuleUnavailableHero(
                state: entry.snapshot.privacyMode == .redacted ? .redacted : .unavailable
            )
            Spacer(minLength: 0)
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://tasks/today"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Today's Tasks, \(entry.snapshot.privacyMode == .redacted ? "summary hidden" : "not connected")"
        )
    }
}

struct TasksMediumWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            FutureModuleWidgetHeader(title: "Today's Tasks", icon: .tasks, accent: LifeOSTokens.Module.tasks)
                .frame(maxWidth: 132, alignment: .topLeading)

            Divider()
                .overlay(LifeOSTokens.hairlineBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.snapshot.privacyMode == .redacted ? "Hidden" : "—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(chrome.hero)
                Text(entry.snapshot.privacyMode == .redacted ? "Summary hidden" : "Not connected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://tasks/today"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Today's Tasks, \(entry.snapshot.privacyMode == .redacted ? "summary hidden" : "not connected")"
        )
    }
}

struct TasksWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: FutureModuleWidgetEntry

    @ViewBuilder
    var body: some View {
        switch widgetFamily {
        case .systemMedium:
            TasksMediumWidgetView(entry: entry)
        default:
            TasksSmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Exact Nutrition medium widgets

private func nutritionWidgetMetricState(
    _ metric: WidgetNutritionMetric,
    at date: Date
) -> WidgetAggregateAvailability {
    metric.state(at: date)
}

private func nutritionWidgetHasValue(_ metric: WidgetNutritionMetric, at date: Date) -> Bool {
    guard metric.value != nil else { return false }
    switch nutritionWidgetMetricState(metric, at: date) {
    case .fresh, .stale: return true
    case .unavailable, .redacted: return false
    }
}

private func nutritionWidgetStateText(_ state: WidgetAggregateAvailability) -> String {
    switch state {
    case .fresh: return "Aggregate"
    case .stale: return "Stale summary"
    case .unavailable: return "Not connected"
    case .redacted: return "Summary hidden"
    }
}

private func nutritionWidgetValue(
    _ metric: WidgetNutritionMetric,
    at date: Date,
    unit: String = "",
    fractionDigits: Int = 0
) -> String {
    guard nutritionWidgetHasValue(metric, at: date), let value = metric.value else {
        return metric.state == .redacted ? "Hidden" : "—"
    }
    let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
    return unit.isEmpty ? number : "\(number) \(unit)"
}

private struct NutritionWidgetSourceBadge: View {
    let summary: WidgetSafeNutritionSummary
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        Text(summary.provenanceLabel ?? nutritionWidgetStateText(summary.displayState(at: date)))
            .font(.system(size: 7, weight: .semibold))
            .tracking(0.15)
            .foregroundStyle(summary.provenanceLabel == nil ? chrome.tertiary : LifeOSTokens.warning)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .accessibilityLabel("Nutrition data status")
            .accessibilityValue(summary.provenanceLabel ?? nutritionWidgetStateText(summary.displayState(at: date)))
    }
}

private struct NutritionWidgetHeader: View {
    let title: String
    let summary: WidgetSafeNutritionSummary
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        let iconColor = chrome.usesTransparentTreatment ? chrome.secondary : LifeOSTokens.Module.nutrition
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            LifeOSIcon(.grocery)
                .frame(width: 15, height: 15)
                .foregroundStyle(iconColor)
            Text(title)
                .font(LifeOSFont.widgetHeader())
                .foregroundStyle(chrome.hero)
                .lineLimit(1)
            Spacer(minLength: 4)
            NutritionWidgetSourceBadge(summary: summary, date: date)
        }
    }
}

private enum NutritionWidgetAction: String, CaseIterable, Identifiable {
    case photoImport, camera, barcode, aiProposal, search

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .photoImport: URL(string: "lifeos://fitness/nutrition/import")!
        case .camera: URL(string: "lifeos://fitness/nutrition/camera")!
        case .barcode: URL(string: "lifeos://fitness/nutrition/barcode")!
        case .aiProposal: URL(string: "lifeos://fitness/nutrition/ai-proposal")!
        case .search: URL(string: "lifeos://fitness/nutrition/search")!
        }
    }

    var label: String {
        switch self {
        case .photoImport: "Import food photo from library"
        case .camera: "Capture food photo with camera"
        case .barcode: "Scan food barcode"
        case .aiProposal: "Open disconnected AI photo proposal"
        case .search: "Search food records"
        }
    }

    var systemName: String {
        switch self {
        case .photoImport: "photo.badge.plus"
        case .camera: "camera.fill"
        case .barcode: "barcode.viewfinder"
        case .aiProposal: "sparkles"
        case .search: "magnifyingglass"
        }
    }
}

private struct NutritionWidgetQuickActions: View {
    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NutritionWidgetAction.allCases) { action in
                Link(destination: action.url) {
                    Image(systemName: action.systemName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(chrome.hero.opacity(0.82))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(action.label)
                .accessibilityHint("Opens the app capture flow")
                if action != .search {
                    Rectangle()
                        .fill(LifeOSTokens.quietBorder)
                        .frame(width: 1, height: 24)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nutrition capture actions")
    }
}

private struct NutritionDotMatrix: View {
    let title: String
    let metric: WidgetNutritionMetric
    let goal: WidgetNutritionMetric
    let date: Date
    /// Macro data semantics (§5.5): protein accent, carbs success, fat warning.
    let color: Color

    private let columns = Array(repeating: GridItem(.fixed(4), spacing: 3), count: 8)

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chrome.hero.opacity(0.82))
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<40, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? color : LifeOSTokens.quietBorder.opacity(0.55))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: 53, height: 32)
            Text(nutritionWidgetValue(metric, at: date, unit: "g"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(chrome.hero)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(nutritionWidgetValue(metric, at: date, unit: "grams")); \(nutritionWidgetStateText(nutritionWidgetMetricState(metric, at: date)))")
    }

    private var filledDots: Int {
        guard nutritionWidgetHasValue(metric, at: date),
              nutritionWidgetHasValue(goal, at: date),
              let value = metric.value,
              let target = goal.value,
              target > 0 else { return 0 }
        return min(40, max(0, Int((value / target * 40).rounded(.down))))
    }
}

private struct NutritionQualityRing: View {
    let metric: WidgetNutritionMetric
    let label: String?
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(LifeOSTokens.quietBorder, style: StrokeStyle(lineWidth: 4, dash: [2, 2]))
                if nutritionWidgetHasValue(metric, at: date), let score = metric.value {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, score / 100)))
                        .stroke(LifeOSTokens.success, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(score.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text(metric.state == .redacted ? "•" : "—")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .frame(width: 54, height: 54)
            Text(label ?? nutritionWidgetStateText(nutritionWidgetMetricState(metric, at: date)))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(label == nil ? chrome.tertiary : LifeOSTokens.warning)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 66)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Food quality")
        .accessibilityValue(nutritionWidgetValue(metric, at: date, fractionDigits: 0) + " out of 100; " + (label ?? nutritionWidgetStateText(nutritionWidgetMetricState(metric, at: date))))
    }
}

struct NutritionOverviewWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NutritionWidgetHeader(title: "Today's Food", summary: entry.snapshot.nutrition, date: entry.date)
            HStack(alignment: .center, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(nutritionWidgetValue(entry.snapshot.nutrition.caloriesEaten, at: entry.date, unit: "kcal"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("eaten")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(chrome.tertiary)
                }
                NutritionDotMatrix(title: "Fat", metric: entry.snapshot.nutrition.fatGrams, goal: entry.snapshot.nutrition.fatGoalGrams, date: entry.date, color: LifeOSTokens.warning)
                NutritionDotMatrix(title: "Carbs", metric: entry.snapshot.nutrition.carbsGrams, goal: entry.snapshot.nutrition.carbsGoalGrams, date: entry.date, color: LifeOSTokens.success)
                NutritionDotMatrix(title: "Protein", metric: entry.snapshot.nutrition.proteinGrams, goal: entry.snapshot.nutrition.proteinGoalGrams, date: entry.date, color: LifeOSTokens.accent)
                NutritionQualityRing(metric: entry.snapshot.nutrition.qualityScore, label: entry.snapshot.nutrition.qualityLabel, date: entry.date)
            }
            Divider().overlay(LifeOSTokens.quietBorder)
            NutritionWidgetQuickActions()
        }
        .padding(12)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/nutrition"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today's Nutrition, \(nutritionWidgetValue(entry.snapshot.nutrition.caloriesEaten, at: entry.date, unit: "kilocalories")); \(entry.snapshot.nutrition.provenanceLabel ?? nutritionWidgetStateText(entry.snapshot.nutritionDisplayState(at: entry.date)))")
    }
}

private struct NutritionCalorieTrack: View {
    let eaten: WidgetNutritionMetric
    let goal: WidgetNutritionMetric
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                let progress: CGFloat = {
                    guard nutritionWidgetHasValue(eaten, at: date), nutritionWidgetHasValue(goal, at: date),
                          let eaten = eaten.value, let goal = goal.value, goal > 0 else { return 0 }
                    return min(1, max(0, eaten / goal))
                }()
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { index in
                        Capsule()
                            .fill(CGFloat(index + 1) / 8 <= progress ? LifeOSTokens.accent : LifeOSTokens.quietBorder.opacity(0.68))
                            .frame(width: max(2, (proxy.size.width - 21) / 8), height: 16)
                    }
                }
            }
            .frame(height: 16)
            Text("Goal \(nutritionWidgetValue(goal, at: date, unit: "kcal"))")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(chrome.tertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories progress")
        .accessibilityValue("\(nutritionWidgetValue(eaten, at: date, unit: "kilocalories")) eaten; goal \(nutritionWidgetValue(goal, at: date, unit: "kilocalories"))")
    }
}

private struct NutritionMacroGoalCell: View {
    let title: String
    let metric: WidgetNutritionMetric
    let goal: WidgetNutritionMetric
    let date: Date
    /// Macro data semantics (§5.5): protein accent, carbs success, fat warning.
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 1)
                progressRing
            }
            Text(remainingText)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(LifeOSTokens.canvas.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(remainingText); \(nutritionWidgetStateText(nutritionWidgetMetricState(metric, at: date)))")
    }

    private var progressRing: some View {
        ZStack {
            Circle().stroke(LifeOSTokens.quietBorder, lineWidth: 2.5)
            if let ratio {
                Circle().trim(from: 0, to: ratio).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 16, height: 16)
    }

    private var ratio: Double? {
        guard nutritionWidgetHasValue(metric, at: date), nutritionWidgetHasValue(goal, at: date),
              let value = metric.value, let target = goal.value, target > 0 else { return nil }
        return min(1, max(0, value / target))
    }

    private var remainingText: String {
        guard nutritionWidgetHasValue(metric, at: date), nutritionWidgetHasValue(goal, at: date),
              let value = metric.value, let target = goal.value else { return metric.state == .redacted ? "Hidden" : "Unavailable" }
        let consumed = value.formatted(.number.precision(.fractionLength(0)))
        let targetText = target.formatted(.number.precision(.fractionLength(0)))
        return "\(consumed) / \(targetText) g"
    }
}

struct CaloriesMacrosWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        let nutrition = entry.snapshot.nutrition
        VStack(alignment: .leading, spacing: 7) {
            NutritionWidgetHeader(title: "Calories & Macros", summary: nutrition, date: entry.date)
            HStack(alignment: .center, spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calories").font(.system(size: 11, weight: .semibold))
                    Text(calorieStatus).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    NutritionCalorieTrack(eaten: nutrition.caloriesEaten, goal: nutrition.calorieGoal, date: entry.date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NutritionMacroGoalCell(title: "Fat", metric: nutrition.fatGrams, goal: nutrition.fatGoalGrams, date: entry.date, color: LifeOSTokens.warning)
                NutritionMacroGoalCell(title: "Carbs", metric: nutrition.carbsGrams, goal: nutrition.carbsGoalGrams, date: entry.date, color: LifeOSTokens.success)
                NutritionMacroGoalCell(title: "Protein", metric: nutrition.proteinGrams, goal: nutrition.proteinGoalGrams, date: entry.date, color: LifeOSTokens.accent)
            }
            Text("Goal period · today · \(nutritionWidgetStateText(entry.snapshot.nutritionDisplayState(at: entry.date)))")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(chrome.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/nutrition/goals"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calories and Macros, \(calorieStatus), goal \(nutritionWidgetValue(nutrition.calorieGoal, at: entry.date, unit: "kilocalories")); \(nutrition.provenanceLabel ?? nutritionWidgetStateText(entry.snapshot.nutritionDisplayState(at: entry.date)))")
    }

    private var calorieStatus: String {
        let nutrition = entry.snapshot.nutrition
        guard nutritionWidgetHasValue(nutrition.caloriesEaten, at: entry.date),
              nutritionWidgetHasValue(nutrition.calorieGoal, at: entry.date),
              let eaten = nutrition.caloriesEaten.value,
              let goal = nutrition.calorieGoal.value else {
            return nutrition.caloriesEaten.state == .redacted ? "Hidden" : "Goal unavailable"
        }
        let difference = goal - eaten
        return difference >= 0 ? "\(difference.formatted(.number.precision(.fractionLength(0)))) kcal left" : "\(abs(difference).formatted(.number.precision(.fractionLength(0)))) kcal over"
    }
}

private struct NutritionSignedBalanceScale: View {
    let balance: Double?
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(LifeOSTokens.quietBorder.opacity(0.75)).frame(height: 5).padding(.top, 4)
                    Rectangle().fill(LifeOSTokens.tertiaryText).frame(width: 1, height: 14).offset(x: width / 2, y: 0)
                    ForEach([-500.0, -250.0, 0.0, 250.0, 500.0], id: \.self) { tick in
                        Rectangle().fill(LifeOSTokens.quietBorder).frame(width: 1, height: 8).offset(x: max(0, min(width - 1, (tick + 500) / 1_000 * width)), y: 3)
                    }
                    if let balance, balance.isFinite {
                        let clamped = max(-500, min(500, balance))
                        Circle().fill(chrome.hero).frame(width: 11, height: 11).offset(x: max(0, min(width - 11, (clamped + 500) / 1_000 * width - 5.5)), y: 1)
                    }
                }
            }
            .frame(height: 15)
            HStack {
                Text("−500")
                Spacer()
                Text("−250")
                Spacer()
                Text("0")
                Spacer()
                Text("250")
                Spacer()
                Text("500")
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(chrome.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signed net energy scale from minus 500 to plus 500 kilocalories")
        .accessibilityValue(balance.map { "Balance \($0.formatted(.number.precision(.fractionLength(0)))) kilocalories; zero is centered" } ?? "Balance unavailable; both eaten and burned observations are required")
    }
}

struct NetEnergyWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        let nutrition = entry.snapshot.nutrition
        VStack(alignment: .leading, spacing: 6) {
            NutritionWidgetHeader(title: "Net Energy", summary: nutrition, date: entry.date)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(balanceNumberText)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text("kcal balance").font(.system(size: 9, weight: .medium)).foregroundStyle(chrome.tertiary)
                Spacer(minLength: 5)
                Text("Burned \(nutritionWidgetValue(nutrition.caloriesBurned, at: entry.date, unit: "kcal"))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("Eaten \(nutritionWidgetValue(nutrition.caloriesEaten, at: entry.date, unit: "kcal"))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            NutritionSignedBalanceScale(balance: signedBalance, date: entry.date)
            Text(provenanceText)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(chrome.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/net-energy"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Net Energy, \(balanceText); eaten and burned are independent aggregate observations; \(nutrition.provenanceLabel ?? nutritionWidgetStateText(entry.snapshot.nutritionDisplayState(at: entry.date)))")
    }

    private var signedBalance: Double? {
        let nutrition = entry.snapshot.nutrition
        guard nutritionWidgetHasValue(nutrition.caloriesEaten, at: entry.date),
              nutritionWidgetHasValue(nutrition.caloriesBurned, at: entry.date),
              let eaten = nutrition.caloriesEaten.value,
              let burned = nutrition.caloriesBurned.value else { return nil }
        return eaten - burned
    }

    private var balanceText: String {
        guard let signedBalance else { return entry.snapshot.nutrition.qualityScore.state == .redacted ? "Hidden" : "—" }
        let rounded = Int(signedBalance.rounded())
        if rounded > 0 { return "+\(rounded) kcal" }
        if rounded < 0 { return "−\(abs(rounded)) kcal" }
        return "0 kcal"
    }

    private var balanceNumberText: String {
        balanceText.replacingOccurrences(of: " kcal", with: "")
    }

    private var provenanceText: String {
        let nutrition = entry.snapshot.nutrition
        guard nutritionWidgetHasValue(nutrition.caloriesEaten, at: entry.date),
              nutritionWidgetHasValue(nutrition.caloriesBurned, at: entry.date) else {
            return "Unavailable · eaten and burned observations are independent"
        }
        return "Eaten − burned · independent observations"
    }
}

// MARK: - Fitness families 0648–0651

private func fitnessWidgetState(_ metric: WidgetFitnessMetric, at date: Date) -> WidgetAggregateAvailability {
    metric.state(at: date)
}

private func fitnessWidgetValue(_ metric: WidgetFitnessMetric, at date: Date, fractionDigits: Int = 0) -> String {
    guard metric.value != nil else {
        return fitnessWidgetState(metric, at: date) == .redacted ? "Hidden" : "—"
    }
    return metric.value!.formatted(.number.precision(.fractionLength(fractionDigits)))
}

func fitnessWidgetDurationText(_ metric: WidgetFitnessMetric, at date: Date) -> String {
    guard let value = metric.value, metric.unit == .hours,
          fitnessWidgetState(metric, at: date) == .fresh || fitnessWidgetState(metric, at: date) == .stale else {
        return fitnessWidgetValue(metric, at: date)
    }
    let totalMinutes = max(0, Int((value * 60).rounded()))
    return "\(totalMinutes / 60):\(String(format: "%02d", totalMinutes % 60))"
}

func fitnessWidgetMetricValueText(_ metric: WidgetFitnessMetric, at date: Date) -> String {
    metric.unit == .hours
        ? fitnessWidgetDurationText(metric, at: date)
        : fitnessWidgetValue(metric, at: date, fractionDigits: 1)
}

private func fitnessWidgetFreshness(_ metric: WidgetFitnessMetric, at date: Date) -> String {
    switch fitnessWidgetState(metric, at: date) {
    case .fresh:
        guard let observedAt = metric.observedAt else { return "Fresh" }
        let minutes = max(0, Int(date.timeIntervalSince(observedAt) / 60))
        return minutes == 0 ? "Just now" : "\(minutes)m ago"
    case .stale: return "Stale"
    case .redacted: return "Hidden"
    case .unavailable: return "Unavailable"
    }
}

func fitnessWidgetDemoDisclosure(_ fitness: WidgetSafeFitnessWidgetsSummary) -> String {
    fitness.isDemoFixture ? ", Demo, not live" : ""
}

private struct FitnessCompactWidgetHeader: View {
    let title: String
    let icon: LifeOSIconName
    let accent: Color

    @Environment(\.lifeOSWidgetChrome) private var chrome

    init(title: String, icon: LifeOSIconName, accent: Color = LifeOSTokens.Module.fitness) {
        self.title = title
        self.icon = icon
        self.accent = accent
    }

    var body: some View {
        let iconColor = chrome.usesTransparentTreatment ? chrome.secondary : accent
        HStack(spacing: 5) {
            LifeOSIcon(icon)
                .frame(width: 12, height: 12)
                .foregroundStyle(iconColor)
            Text(title)
                .font(LifeOSFont.widgetHeader(11))
                .foregroundStyle(chrome.hero)
            Spacer(minLength: 0)
        }
    }
}

private struct FitnessDemoBadge: View {
    let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        Text("DEMO · NOT LIVE")
            .font(.system(size: compact ? 7 : 8, weight: .bold))
            .tracking(compact ? 0.2 : 0.35)
            .foregroundStyle(LifeOSTokens.warning)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Mirrors the app-side `FitnessRingPalette.threshold` bands so widget status
/// rings read the same semantics as the Fitness screen (§5.5): ≥0.67 success,
/// ≥0.34 warning, else danger.
private func fitnessWidgetStatusColor(progress: Double) -> Color {
    if progress >= 0.67 { return LifeOSTokens.success }
    if progress >= 0.34 { return LifeOSTokens.warning }
    return LifeOSTokens.danger
}

private struct FitnessRingCell: View {
    let title: String
    let metric: WidgetFitnessMetric
    let route: String
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        Link(destination: URL(string: route)!) {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .stroke(LifeOSTokens.Ring.track, lineWidth: 4)
                    if let value = metric.value, fitnessWidgetState(metric, at: date) == .fresh || fitnessWidgetState(metric, at: date) == .stale {
                        Circle()
                            .trim(from: 0, to: min(1, max(0, value / 100)))
                            .stroke(fitnessWidgetStatusColor(progress: value / 100), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(value.formatted(.number.precision(.fractionLength(0))) + "%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    } else {
                        Text(metric.state == .redacted ? "•" : "—")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                }
                .frame(width: 37, height: 37)
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                Text(fitnessWidgetState(metric, at: date) == .fresh ? "Observed" : futureModuleStateText(fitnessWidgetState(metric, at: date)))
                    .font(.system(size: 6, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(fitnessWidgetValue(metric, at: date)) percent, \(fitnessWidgetFreshness(metric, at: date)); source \(metric.sourceLabel ?? "not connected")")
    }
}

struct DailyOverviewWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        let fitness = entry.snapshot.fitnessWidgets
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                FitnessCompactWidgetHeader(title: "Daily Overview", icon: .overview)
                if fitness.isDemoFixture { FitnessDemoBadge(compact: true) }
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                alignment: .leading,
                spacing: 3
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text("Aggregate signals")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(chrome.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                FitnessRingCell(title: "Strain", metric: fitness.strain, route: "lifeos://fitness/strain", date: entry.date)
                FitnessRingCell(title: "Recovery", metric: fitness.recovery, route: "lifeos://fitness/recovery", date: entry.date)
                FitnessRingCell(title: "Sleep", metric: fitness.sleepScore, route: "lifeos://fitness/sleep", date: entry.date)
            }
            .padding(5)
            .background(LifeOSTokens.canvas.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.7))
        }
        .padding(10)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/daily-overview"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily Overview\(fitnessWidgetDemoDisclosure(fitness)), \(entry.date.formatted(.dateTime.weekday(.wide).month(.wide).day())), strain \(fitnessWidgetValue(fitness.strain, at: entry.date)) percent, recovery \(fitnessWidgetValue(fitness.recovery, at: entry.date)) percent, sleep score \(fitnessWidgetValue(fitness.sleepScore, at: entry.date)) percent")
    }
}

private struct FitnessHealthMetricCell: View {
    let title: String
    let metric: WidgetFitnessMetric
    let route: String
    let date: Date
    let icon: LifeOSIconName

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        Link(destination: URL(string: route)!) {
            VStack(spacing: 2) {
                ZStack(alignment: .center) {
                    Capsule()
                        .stroke(LifeOSTokens.quietBorder, lineWidth: 1.5)
                        .frame(width: 8, height: 42)
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            Rectangle()
                                .fill(LifeOSTokens.quietBorder)
                                .frame(width: 13, height: 0.7)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 42)
                    if let value = metric.value, fitnessWidgetState(metric, at: date) == .fresh || fitnessWidgetState(metric, at: date) == .stale {
                        Circle()
                            .fill(chrome.hero)
                            .frame(width: 11, height: 11)
                            // Keep the marker's centre inside the track even
                            // at 0 and 100; this is position, never a score.
                            .offset(y: 15.5 - 31 * progress(for: value))
                    }
                }
                .frame(height: 42)
                Text(fitnessWidgetMetricValueText(metric, at: date))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                Text(metric.unit.displayName)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                LifeOSIcon(icon)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(chrome.tertiary)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
            .background(LifeOSTokens.canvas.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.7))
            .frame(maxWidth: .infinity, minHeight: 91)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(fitnessWidgetValue(metric, at: date)) \(metric.unit.displayName), \(fitnessWidgetFreshness(metric, at: date)); source \(metric.sourceLabel ?? "not connected")")
    }

    private func progress(for value: Double) -> CGFloat {
        // These are neutral display ranges only, not health targets: respiration
        // 0...20 rpm, heart rate 0...120 bpm, HRV 0...100 ms, SpO2 0...100%,
        // temperature 30...40 C, and sleep duration 0...8 h. The marker
        // communicates position in the documented range without implying that
        // a higher value is better.
        let fraction: Double
        switch metric.unit {
        case .breathsPerMinute: fraction = value / 20
        case .beatsPerMinute: fraction = value / 120
        case .milliseconds: fraction = value / 100
        case .oxygenPercent: fraction = value / 100
        case .celsius: fraction = (value - 30) / 10
        case .hours: fraction = value / 8
        default: fraction = value / 100
        }
        return CGFloat(min(1, max(0, fraction)))
    }
}

struct FitnessHealthMonitorWidgetView: View {
    let entry: FutureModuleWidgetEntry

    var body: some View {
        let fitness = entry.snapshot.fitnessWidgets
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FutureModuleWidgetHeader(title: "Health Monitor", icon: .health, accent: LifeOSTokens.Module.fitness)
                if fitness.isDemoFixture { FitnessDemoBadge() }
            }
            HStack(alignment: .top, spacing: 2) {
                FitnessHealthMetricCell(title: "Respiration", metric: fitness.respiration, route: "lifeos://fitness/health/respiration", date: entry.date, icon: .fitness)
                FitnessHealthMetricCell(title: "Heart rate", metric: fitness.heartRate, route: "lifeos://fitness/health/heart-rate", date: entry.date, icon: .heartRate)
                FitnessHealthMetricCell(title: "HRV", metric: fitness.hrv, route: "lifeos://fitness/health/hrv", date: entry.date, icon: .health)
                FitnessHealthMetricCell(title: "SpO₂", metric: fitness.spo2, route: "lifeos://fitness/health/spo2", date: entry.date, icon: .verified)
                FitnessHealthMetricCell(title: "Temperature", metric: fitness.temperature, route: "lifeos://fitness/health/temperature", date: entry.date, icon: .warning)
                FitnessHealthMetricCell(title: "Sleep", metric: fitness.sleepDuration, route: "lifeos://fitness/health/sleep-duration", date: entry.date, icon: .sleep)
            }
        }
        .padding(11)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/health"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Health Monitor\(fitnessWidgetDemoDisclosure(fitness)), six independent observations: respiration, heart rate, HRV, oxygen saturation, temperature, and sleep duration")
    }
}

private struct FitnessStressChart: View {
    let trend: WidgetStressTrend
    let currentValue: Double?

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { _ in
                        Divider().overlay(LifeOSTokens.quietBorder.opacity(0.65))
                        Spacer(minLength: 0)
                    }
                }
                Path { path in
                    guard trend.buckets.count > 1 else { return }
                    let width = max(proxy.size.width, 1)
                    let height = max(proxy.size.height, 1)
                    for (index, value) in trend.buckets.enumerated() {
                        let x = width * CGFloat(index) / CGFloat(trend.buckets.count - 1)
                        let y = height * (1 - CGFloat(value / 100))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(LifeOSTokens.Series.observed, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let currentValue, trend.buckets.count > 1 {
                    let normalized = CGFloat(min(1, max(0, currentValue / 100)))
                    Circle()
                        .fill(LifeOSTokens.Series.observed)
                        .frame(width: 8, height: 8)
                        .offset(x: max(0, proxy.size.width - 8), y: max(0, proxy.size.height * (1 - normalized) - 4))
                    Text(currentValue.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(LifeOSTokens.Series.observed)
                        .offset(x: max(0, proxy.size.width - 25), y: max(0, proxy.size.height * (1 - normalized) - 17))
                }
                Text("100")
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(chrome.tertiary)
                    .offset(x: 2, y: -1)
                Text("0")
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(chrome.tertiary)
                    .offset(x: 6, y: proxy.size.height - 10)
            }
        }
        .padding(.leading, 18)
        .frame(height: 58)
        .accessibilityHidden(true)
    }
}

struct FitnessStressWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        let fitness = entry.snapshot.fitnessWidgets
        let axisLabels = fitness.stressTrend.axisDates?.map {
            $0.formatted(.dateTime.hour().minute())
        } ?? Array(repeating: "—", count: 4)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 7) {
                FutureModuleWidgetHeader(title: "Stress", icon: .health, accent: LifeOSTokens.Module.fitness)
                if fitness.isDemoFixture { FitnessDemoBadge() }
                Spacer(minLength: 0)
                Text(fitnessWidgetFreshness(fitness.stressScore, at: entry.date))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
            }
            FitnessStressChart(
                trend: fitness.stressTrend,
                currentValue: fitness.stressScore.value
            )
            HStack {
                ForEach(Array(axisLabels.enumerated()), id: \.offset) { index, label in
                    if index > 0 { Spacer() }
                    Text(label)
                }
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(chrome.tertiary)
            .lineLimit(1)
        }
        .padding(10)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/stress"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stress\(fitnessWidgetDemoDisclosure(fitness)), current score \(fitnessWidgetValue(fitness.stressScore, at: entry.date)) out of 100, \(fitnessWidgetFreshness(fitness.stressScore, at: entry.date)); static intraday aggregate chart; open app to scrub")
    }
}

private struct FitnessEnergySegments: View {
    let level: Double?

    var body: some View {
        GeometryReader { proxy in
            let normalizedLevel = (level ?? 0) / 100.0
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { index in
                    let isFilled = Double(index + 1) / 20.0 <= normalizedLevel
                    Capsule()
                        .fill(isFilled ? LifeOSTokens.Series.observed : LifeOSTokens.Ring.track)
                        .frame(width: max(2, (proxy.size.width - 38) / 20), height: 8)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

struct FitnessEnergyReserveWidgetView: View {
    let entry: FutureModuleWidgetEntry

    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private var chrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    var body: some View {
        let fitness = entry.snapshot.fitnessWidgets
        let energy = fitness.energyReserve
        let state = energy.displayState(at: entry.date)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                FitnessCompactWidgetHeader(title: "Energy Reserve", icon: .fitness, accent: LifeOSTokens.Module.fitness)
                if fitness.isDemoFixture { FitnessDemoBadge(compact: true) }
                Spacer(minLength: 0)
                Text(futureModuleStateText(state))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(fitnessWidgetValue(energy.level, at: entry.date))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("% reserve")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                Spacer(minLength: 0)
                Text(lastChargedText(energy.lastChargedAt))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            FitnessEnergySegments(level: energy.level.value)
            HStack(spacing: 7) {
                FitnessEnergyChip(title: "Charged", value: energy.chargedPercent, date: entry.date)
                FitnessEnergyChip(title: "Discharged", value: energy.dischargedPercent, date: entry.date)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/energy-reserve"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Energy Reserve\(fitnessWidgetDemoDisclosure(fitness)), \(fitnessWidgetValue(energy.level, at: entry.date)) percent, \(lastChargedText(energy.lastChargedAt)), charged \(fitnessWidgetValue(energy.chargedPercent, at: entry.date)) percent, discharged \(fitnessWidgetValue(energy.dischargedPercent, at: entry.date)) percent, \(futureModuleAccessibilityState(state))")
    }

    private func lastChargedText(_ date: Date?) -> String {
        guard let date else { return "Last charged unavailable" }
        let minutes = max(0, Int(entry.date.timeIntervalSince(date) / 60))
        return minutes == 0 ? "Charged just now" : "Last charged \(minutes)m ago"
    }
}

private struct FitnessEnergyChip: View {
    let title: String
    let value: WidgetFitnessMetric
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        let state = fitnessWidgetState(value, at: date)
        let signedValue: String = {
            guard (state == .fresh || state == .stale), value.value != nil else {
                return fitnessWidgetValue(value, at: date)
            }
            let sign = title == "Charged" ? "+" : "−"
            return "\(sign)\(fitnessWidgetValue(value, at: date))%"
        }()
        HStack(spacing: 4) {
            // Neutral legend dots — charge/discharge are facts, not statuses.
            Circle().fill(chrome.tertiary).frame(width: 5, height: 5)
            Text("\(title) \(signedValue)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(LifeOSTokens.canvas.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.7))
        .accessibilityElement(children: .combine)
    }
}

struct NetWorthWidget: Widget {
    let kind = "NetWorthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            NetWorthWidgetView(entry: entry)
        }
        .configurationDisplayName("Net Worth — Trend")
        .description("Net worth trend. Not connected.")
        .supportedFamilies([.systemMedium])
    }
}

struct SpendRingWidget: Widget {
    let kind = "SpendRingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            SpendRingWidgetView(entry: entry)
        }
        .configurationDisplayName("Spend — Ring")
        .description("Budget spend ring. Not connected.")
        .supportedFamilies([.systemSmall])
    }
}

struct CashFlowWidget: Widget {
    let kind = "CashFlowWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            CashFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("Cash Flow — Sparkline")
        .description("Net cash flow trend. Not connected.")
        .supportedFamilies([.systemMedium])
    }
}

struct HealthMonitorWidget: Widget {
    let kind = "HealthMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            HealthMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("Health Monitor — Bars")
        .description("Health metric bars. Not connected.")
        .supportedFamilies([.systemMedium])
    }
}

struct RecoveryRingWidget: Widget {
    let kind = "RecoveryRingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            RecoveryRingWidgetView(entry: entry)
        }
        .configurationDisplayName("Recovery / Strain — Ring")
        .description("Recovery and strain ring. Not connected.")
        .supportedFamilies([.systemSmall])
    }
}

struct TasksWidget: Widget {
    let kind = "TasksWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Tasks")
        .description("Today's task count and checklist. Not connected.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NutritionOverviewWidget: Widget {
    let kind = "NutritionOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            NutritionOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Nutrition — Overview")
        .description("Food, macros, quality, and five safe capture actions.")
        .supportedFamilies([.systemMedium])
    }
}

struct CaloriesMacrosWidget: Widget {
    let kind = "CaloriesMacrosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            CaloriesMacrosWidgetView(entry: entry)
        }
        .configurationDisplayName("Nutrition — Calories & Macros")
        .description("Daily calorie and macro goals with honest source state.")
        .supportedFamilies([.systemMedium])
    }
}

struct NetEnergyWidget: Widget {
    let kind = "NetEnergyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            NetEnergyWidgetView(entry: entry)
        }
        .configurationDisplayName("Nutrition — Net Energy")
        .description("Signed eaten-minus-burned balance on a centered scale.")
        .supportedFamilies([.systemMedium])
    }
}

struct DailyOverviewWidget: Widget {
    let kind = "DailyOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            DailyOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Fitness — Daily Overview")
        .description("Strain, recovery, and sleep score rings with independent source state.")
        .supportedFamilies([.systemMedium])
    }
}

struct FitnessHealthMonitorWidget: Widget {
    let kind = "FitnessHealthMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            FitnessHealthMonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("Fitness — Health Monitor")
        .description("Six fixed-unit aggregate observations with independent details.")
        .supportedFamilies([.systemMedium])
    }
}

struct FitnessStressWidget: Widget {
    let kind = "FitnessStressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            FitnessStressWidgetView(entry: entry)
        }
        .configurationDisplayName("Fitness — Stress")
        .description("Static intraday stress trend. Scrubbing opens app detail.")
        .supportedFamilies([.systemMedium])
    }
}

struct FitnessEnergyReserveWidget: Widget {
    let kind = "FitnessEnergyReserveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FutureModuleTimelineProvider()) { entry in
            FitnessEnergyReserveWidgetView(entry: entry)
        }
        .configurationDisplayName("Fitness — Energy Reserve")
        .description("Reconciled reserve level and charge/discharge event aggregates.")
        .supportedFamilies([.systemMedium])
    }
}
