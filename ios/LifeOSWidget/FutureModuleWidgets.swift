import SwiftUI
import WidgetKit

/// Text colors shared by every chrome-managed widget. Accented/vibrant homescreen
/// rendering composites the widget over a system backdrop, where opaque token
/// surfaces and dark text become illegible; those modes use opaque white text
/// with typographic hierarchy over a cleared container background instead.
struct LifeOSWidgetChrome {
    let hero: Color
    let secondary: Color
    let tertiary: Color
    let usesTransparentTreatment: Bool

    // Clear/accented rendering relies on hierarchy through size and weight,
    // not stacked alpha that disappears against a mid-grey wallpaper.
    func panelFill(opacity: Double) -> Color {
        usesTransparentTreatment ? .clear : LifeOSTokens.canvas.opacity(opacity)
    }

    var separator: Color {
        usesTransparentTreatment ? .white.opacity(0.65) : LifeOSTokens.quietBorder
    }

    var supportingText: Color {
        usesTransparentTreatment ? LifeOSTokens.widgetTransparentSupporting : secondary
    }

    static func resolving(
        showsContainerBackground: Bool,
        renderingMode: WidgetRenderingMode
    ) -> Self {
        let usesTransparentTreatment = !showsContainerBackground || renderingMode != .fullColor
        return LifeOSWidgetChrome(
            hero: usesTransparentTreatment ? .white : LifeOSTokens.primaryText,
            secondary: usesTransparentTreatment ? LifeOSTokens.widgetTransparentSupporting : LifeOSTokens.secondaryText,
            tertiary: usesTransparentTreatment ? LifeOSTokens.widgetTransparentSupporting : LifeOSTokens.tertiaryText,
            usesTransparentTreatment: usesTransparentTreatment
        )
    }
}

/// Widget roles keep essential values legible inside WidgetKit's finite
/// families. They scale from the SF Pro facade, cap at a family-safe maximum,
/// and keep the numeric fallback floor at 22pt. The surrounding container
/// caps Dynamic Type at `.xxxLarge`; each view removes optional copy before it
/// considers a smaller fallback role.
enum LifeOSWidgetTypography {
    enum Role: CaseIterable, Equatable {
        case hero
        case heroFallback
        case heroMinimum
        case compactMetric
        case title
        case metadata

        var baseSize: CGFloat {
            switch self {
            case .hero: 26
            case .heroFallback: 24
            case .heroMinimum: 21
            case .compactMetric: 22
            case .title: 14
            case .metadata: 12
            }
        }

        var minimumSize: CGFloat {
            switch self {
            case .hero: 22
            case .heroFallback: 21
            case .heroMinimum, .compactMetric: 19
            case .title: 12
            case .metadata: 10
            }
        }

        var maximumSize: CGFloat {
            switch self {
            case .hero: 30
            case .heroFallback: 27
            case .heroMinimum, .compactMetric: 24
            case .title: 17
            case .metadata: 14
            }
        }

        var relativeTo: Font.TextStyle {
            switch self {
            case .hero: .largeTitle
            case .heroFallback, .heroMinimum: .title
            case .compactMetric: .title2
            case .title: .headline
            case .metadata: .footnote
            }
        }

        var weight: Font.Weight {
            switch self {
            case .hero, .heroFallback, .heroMinimum, .compactMetric, .title: .semibold
            case .metadata: .medium
            }
        }

        static func numericFallback(for size: CGFloat) -> Self {
            if size >= 28 { return .hero }
            if size >= 24 { return .heroFallback }
            return .heroMinimum
        }

        /// Compatibility aliases for the few legacy call sites that still
        /// request a `Font`. New sources use the scaled modifier above so the
        /// family-specific bounds remain in force.
        var dynamicFont: Font {
            .system(size: baseSize, weight: weight, design: .default)
        }
    }

    // Calendar, Usage, and older widget sources use these dynamic system-style
    // aliases until their call sites can adopt the modifier directly. They do
    // not embed a fixed point size or a custom font.
    static var hero: Font { Role.hero.dynamicFont }
    static var compactMetric: Font { Role.compactMetric.dynamicFont }
    static var title: Font { Role.title.dynamicFont }
    static var metadata: Font { Role.metadata.dynamicFont }

    struct RoleModifier: ViewModifier {
        let role: Role
        @ScaledMetric private var scaledSize: CGFloat

        init(role: Role) {
            self.role = role
            self._scaledSize = ScaledMetric(
                wrappedValue: role.baseSize,
                relativeTo: role.relativeTo
            )
        }

        func body(content: Content) -> some View {
            content.font(
                .system(
                    size: min(max(scaledSize, role.minimumSize), role.maximumSize),
                    weight: role.weight,
                    design: .default
                )
            )
        }
    }
}

extension View {
    func lifeOSWidgetTypography(_ role: LifeOSWidgetTypography.Role) -> some View {
        modifier(LifeOSWidgetTypography.RoleModifier(role: role))
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
            .lifeOSWidgetReadableContent(chrome)
            .containerBackground(for: .widget) {
                chrome.usesTransparentTreatment ? AnyView(Color.clear) : AnyView(background)
            }
            // Establish one inherited hero role for any metric text that does
            // not need a more specific semantic treatment. This keeps tinted,
            // vibrant, and clear widgets from falling back to system `.primary`
            // over an arbitrary wallpaper.
            .foregroundStyle(chrome.hero)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .environment(\.lifeOSWidgetChrome, chrome)
    }
}

private struct LifeOSWidgetReadableContentModifier: ViewModifier {
    let chrome: LifeOSWidgetChrome

    func body(content: Content) -> some View {
        content
            .padding(chrome.usesTransparentTreatment ? 8 : 0)
            .background(
                chrome.usesTransparentTreatment ? LifeOSTokens.widgetTransparentBacking : .clear,
                in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.widget, style: .continuous)
            )
    }
}

extension View {
    func lifeOSWidgetContainer(@ViewBuilder background: () -> some View) -> some View {
        modifier(LifeOSWidgetContainerModifier(background: background))
    }

    /// Applies the approved inner backing used by clear/accented widgets. The
    /// container remains clear so WidgetKit can composite it over the wallpaper;
    /// the content still has a stable local contrast surface.
    func lifeOSWidgetReadableContent(_ chrome: LifeOSWidgetChrome) -> some View {
        modifier(LifeOSWidgetReadableContentModifier(chrome: chrome))
    }
}

/// Bounded projection of the existing, persisted Calendar to-dos. Never treats
/// missing storage as an observed empty day. Summary permission allows counts and
/// generic status labels only; Calendar titles never enter widget rows.
struct TasksWidgetData {
    struct Row: Identifiable {
        let id: UUID
        let done: Bool

        // Computed from status so neither visible nor accessibility text can
        // accidentally retain a private Calendar title. Details stay in the app.
        var title: String { done ? "Completed task" : "Pending task" }
    }
    let state: WidgetAggregateAvailability
    let pendingCount: Int?
    let rows: [Row]
    var refreshAt: Date? = nil
    static let destination = URL(string: "lifeos://calendar")!

    static func readSnapshot(at url: URL) throws -> CalendarSnapshot {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: CalendarSnapshot.maximumEncodedBytes + 1) ?? Data()
        guard bytes.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        return try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: bytes)
    }

    static func project(_ snapshot: CalendarSnapshot?, savedAt: Date?,
                        privacy: WidgetPrivacyMode, at date: Date,
                        calendar: Calendar = .current) -> Self {
        guard privacy == .summaryAllowed else {
            return Self(state: .redacted, pendingCount: nil, rows: [])
        }
        guard let snapshot, let savedAt, savedAt.timeIntervalSince1970.isFinite,
              date.timeIntervalSince(savedAt) >= -5,
              snapshot.items.count <= CalendarSnapshot.maximumItemCount else {
            return Self(state: .unavailable, pendingCount: nil, rows: [])
        }
        let tasks = CalendarWidgetData.items(on: date, in: snapshot, calendar: calendar)
            .filter { $0.kind == .todo && $0.status != .aborted }
        let expiry = savedAt.addingTimeInterval(futureWidgetFreshnessWindow + 1)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(900)
        return Self(
            state: date.timeIntervalSince(savedAt) > futureWidgetFreshnessWindow ? .stale : .fresh,
            pendingCount: tasks.filter { $0.status != .done }.count,
            rows: tasks.sorted {
                if ($0.status == .done) != ($1.status == .done) { return $0.status != .done }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(3).map { Row(id: $0.id, done: $0.status == .done) },
            refreshAt: expiry > date ? min(expiry, midnight) : midnight
        )
    }

    var detail: String {
        switch state {
        case .redacted: return "Tasks hidden"
        case .unavailable: return "Open Calendar to connect"
        case .stale: return "Saved tasks · stale"
        case .fresh: return pendingCount == 0 ? "No pending tasks today" : "Pending today"
        }
    }
}

struct FutureModuleWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: FutureWidgetSnapshot
    let tasks: TasksWidgetData

    init(date: Date = .now, snapshot: FutureWidgetSnapshot? = nil,
         tasks: TasksWidgetData? = nil) {
        self.date = date
        self.snapshot = snapshot ?? .unavailable(at: date)
        self.tasks = self.snapshot.privacyMode == .redacted
            ? .project(nil, savedAt: nil, privacy: .redacted, at: date)
            : tasks ?? .project(nil, savedAt: nil, privacy: self.snapshot.privacyMode, at: date)
    }
}

struct FutureModuleTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FutureModuleWidgetEntry {
        FutureModuleWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (FutureModuleWidgetEntry) -> Void) {
        Task { completion(await loadEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FutureModuleWidgetEntry>) -> Void) {
        Task {
        let entry = await loadEntry()
        // WidgetKit does not re-evaluate a persisted entry as it ages. Schedule
        // the next read at the bounded freshness boundary so the widget can
        // honestly transition from fresh to stale (or unavailable) without
        // requiring the app process to be running.
        completion(Timeline(
            entries: [entry],
            policy: .after(min(nextRefreshDate(for: entry.snapshot, loadedAt: entry.date),
                               entry.tasks.refreshAt.flatMap { $0 > entry.date ? $0 : nil } ?? entry.date.addingTimeInterval(900)))
        ))
        }
    }

    private func nextRefreshDate(for snapshot: FutureWidgetSnapshot, loadedAt: Date) -> Date {
        let boundaries = [snapshot.finance.observedAt, snapshot.fitness.observedAt,
                          snapshot.fitnessWidgets.observedAt, snapshot.nutrition.observedAt]
            .compactMap { $0?.addingTimeInterval(futureWidgetFreshnessWindow) }
            .filter { $0 > loadedAt }
        return boundaries.min() ?? loadedAt.addingTimeInterval(futureWidgetFreshnessWindow)
    }

    private func loadEntry(at date: Date = .now) async -> FutureModuleWidgetEntry {
        guard let snapshot = FutureWidgetSnapshotStore.read(
            now: date,
            policy: FutureWidgetSnapshotStore.readPolicy()
        ) else {
            return FutureModuleWidgetEntry(date: date)
        }
        // TimelineEntry.date is the load time, never an old observation time.
        var tasks = TasksWidgetData.project(nil, savedAt: nil, privacy: snapshot.privacyMode, at: date)
        if snapshot.privacyMode == .summaryAllowed,
           let identifier = AppGroupConfiguration.identifier(bundle: .main),
           let url = try? CalendarStoreURL.appGroupURL(identifier: identifier),
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let savedAt = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? NSNumber,
           size.intValue <= CalendarSnapshot.maximumEncodedBytes,
           let stored = try? TasksWidgetData.readSnapshot(at: url) {
            tasks = .project(stored, savedAt: savedAt, privacy: snapshot.privacyMode, at: date)
        }
        return FutureModuleWidgetEntry(date: date, snapshot: snapshot, tasks: tasks)
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

func futureModuleStateText(_ state: WidgetAggregateAvailability) -> String {
    switch state {
    case .fresh: return "Aggregate"
    case .stale: return "Stale summary"
    case .unavailable: return "No data"
    case .redacted: return "Summary hidden"
    }
}

private func futureModuleAccessibilityState(_ state: WidgetAggregateAvailability) -> String {
    switch state {
    case .fresh: return "aggregate summary"
    case .stale: return "stale aggregate summary"
    case .unavailable: return "no data"
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
                .lifeOSWidgetTypography(.title)
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
    let unavailableText: String

    init(state: WidgetAggregateAvailability = .unavailable, unavailableText: String = "No data") {
        self.state = state
        self.unavailableText = unavailableText
    }

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        HStack(spacing: LifeOSTokens.Space.xs) {
            Image(systemName: state == .redacted ? "lock.fill" : "minus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.tertiary)
                .frame(width: 18, height: 18)
            Text(state == .redacted ? "Summary hidden" : unavailableText)
                .lifeOSWidgetTypography(.title)
                .foregroundStyle(chrome.hero)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(futureModuleCurrency(netWorth, maximumFractionDigits: 2))
                        .lifeOSWidgetTypography(.hero)
                        .foregroundStyle(chrome.hero)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 4)
                    Text(futureModuleStateText(entry.snapshot.financeDisplayState(at: entry.date)))
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(chrome.tertiary)
                        .lineLimit(1)
                }
                Text("Account total")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.financeDisplayState(at: entry.date),
                    hasValue: entry.snapshot.finance.netWorthCents != nil
                ))
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            FutureModuleWidgetHeader(title: "Spend", icon: .spending, accent: LifeOSTokens.Module.finance)

            if let spend = entry.snapshot.finance.spendCents,
               entry.snapshot.financeDisplayState(at: entry.date) == .fresh || entry.snapshot.financeDisplayState(at: entry.date) == .stale {
                Text(futureModuleCurrency(spend))
                    .lifeOSWidgetTypography(.compactMetric)
                    .foregroundStyle(chrome.hero)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                HStack(spacing: 5) {
                    Text("Spent")
                    Text("·")
                    Text(futureModuleStateText(entry.snapshot.financeDisplayState(at: entry.date)))
                }
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.financeDisplayState(at: entry.date),
                    hasValue: entry.snapshot.finance.spendCents != nil
                ))
            }
        }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(futureModuleCurrency(cashFlow, maximumFractionDigits: 2))
                        .lifeOSWidgetTypography(.hero)
                        .foregroundStyle(chrome.hero)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 4)
                    Text(futureModuleStateText(entry.snapshot.financeDisplayState(at: entry.date)))
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(chrome.tertiary)
                        .lineLimit(1)
                }
                Text("Net movement")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.financeDisplayState(at: entry.date),
                    hasValue: entry.snapshot.finance.cashFlowCents != nil
                ))
            }
        }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(futureModuleScore(health))
                        .lifeOSWidgetTypography(.hero)
                        .foregroundStyle(chrome.hero)
                        .monospacedDigit()
                    Text("score")
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(chrome.tertiary)
                    Spacer(minLength: 4)
                    Text(futureModuleStateText(entry.snapshot.fitnessDisplayState(at: entry.date)))
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(chrome.tertiary)
                        .lineLimit(1)
                }
                Text("Source-backed health aggregate")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.fitnessDisplayState(at: entry.date),
                    hasValue: entry.snapshot.fitness.healthScore != nil
                ))
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                LifeOSIcon(.heartRate)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(chrome.usesTransparentTreatment ? chrome.secondary : LifeOSTokens.Module.fitness)
                Text("Recovery")
                    .lifeOSWidgetTypography(.title)
                    .foregroundStyle(chrome.hero)
                    .lineLimit(1)
            }

            if let recovery = entry.snapshot.fitness.recoveryScore,
               entry.snapshot.fitnessDisplayState(at: entry.date) == .fresh || entry.snapshot.fitnessDisplayState(at: entry.date) == .stale {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        FutureModuleProgressRing(diameter: 52, lineWidth: 6, progress: recovery / 100)
                        Text(futureModuleScore(recovery))
                            .lifeOSWidgetTypography(.compactMetric)
                            .foregroundStyle(chrome.hero)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Readiness")
                            .lifeOSWidgetTypography(.title)
                            .foregroundStyle(chrome.hero)
                        Text(futureModuleStateText(futureModuleMetricState(
                            entry.snapshot.fitnessDisplayState(at: entry.date),
                            hasValue: true
                        )))
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(chrome.tertiary)
                    }
                }
            } else {
                FutureModuleUnavailableHero(state: futureModuleMetricState(
                    entry.snapshot.fitnessDisplayState(at: entry.date),
                    hasValue: entry.snapshot.fitness.recoveryScore != nil
                ))
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            FutureModuleWidgetHeader(title: "Today's Tasks", icon: .tasks, accent: LifeOSTokens.Module.tasks)
            TasksWidgetSummary(data: entry.tasks)
        }
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(TasksWidgetData.destination)
    }
}

private struct TasksWidgetSummary: View {
    let data: TasksWidgetData
    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(data.pendingCount.map(String.init) ?? (data.state == .redacted ? "Hidden" : "—"))
                .lifeOSWidgetTypography(.compactMetric)
                .foregroundStyle(chrome.hero)
            Text(data.detail)
                .lifeOSWidgetTypography(.metadata)
                .foregroundStyle(chrome.secondary)
        }
    }
}

struct TasksMediumWidgetView: View {
    let entry: FutureModuleWidgetEntry
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var chrome: LifeOSWidgetChrome {
        .resolving(showsContainerBackground: showsBackground, renderingMode: renderingMode)
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                FutureModuleWidgetHeader(title: "Today's Tasks", icon: .tasks, accent: LifeOSTokens.Module.tasks)
                TasksWidgetSummary(data: entry.tasks)
            }
            .frame(maxWidth: 132, alignment: .leading)
            Divider().overlay(chrome.separator)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.tasks.rows) { row in
                    Link(destination: TasksWidgetData.destination) {
                        HStack(spacing: 6) {
                            LifeOSIcon(row.done ? .done : .planned)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(row.done ? LifeOSTokens.success : chrome.secondary)
                            Text(row.title).lineLimit(1)
                        }
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(chrome.hero)
                    }
                    .accessibilityIdentifier("tasks-widget-row-\(row.id.uuidString)")
                    .accessibilityLabel("\(row.title), \(row.done ? "completed" : "pending"), open Calendar")
                }
            }
            Spacer(minLength: 0)
        }
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(TasksWidgetData.destination)
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

/// Distinct observed metrics from the approved brand ramps. Transparent hosts
/// use the brighter stops independent of the system's light/dark appearance.
enum NutritionWidgetPalette {
    static func calories(transparent: Bool) -> Color {
        transparent ? .lifeOSOrange400 : .lifeOSTasksOrange
    }
    static func protein(transparent: Bool) -> Color {
        transparent ? .lifeOSTeal400 : .lifeOSTealInfo
    }
    static func carbohydrates(transparent: Bool) -> Color {
        transparent ? .lifeOSViolet400 : .lifeOSFitnessViolet
    }
    static func fat(transparent: Bool) -> Color {
        transparent ? LifeOSTokens.widgetTransparentSupporting : LifeOSTokens.metadataText
    }
}


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
    case .unavailable: return "No data"
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

/// Privacy states stay explicit in the provenance badge and accessibility
/// values. The visual value remains compact so a redacted metric cannot force
/// a narrow widget cell to truncate or collide with its unit label.
private func nutritionWidgetDisplayValue(
    _ metric: WidgetNutritionMetric,
    at date: Date,
    fractionDigits: Int = 0
) -> String {
    guard nutritionWidgetHasValue(metric, at: date), let value = metric.value else {
        return "—"
    }
    return value.formatted(.number.precision(.fractionLength(fractionDigits)))
}

/// The calorie number is the primary value in the medium nutrition widgets.
/// WidgetKit can propose less width than the nominal medium family, so keep
/// every candidate intrinsic and stop at the approved 22-point floor.
private struct NutritionWidgetPrimaryValue: View {
    let metric: WidgetNutritionMetric
    let date: Date
    let color: Color

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        ViewThatFits(in: .horizontal) {
            value(size: 28)
            value(size: 24)
            value(size: 22)
        }
    }

    @ViewBuilder
    private func value(size: CGFloat) -> some View {
        Text(nutritionWidgetDisplayValue(metric, at: date))
            .lifeOSWidgetTypography(LifeOSWidgetTypography.Role.numericFallback(for: size))
            .monospacedDigit()
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var valueColor: Color {
        switch nutritionWidgetMetricState(metric, at: date) {
        case .fresh, .stale:
            return color
        case .unavailable, .redacted:
            return chrome.hero
        }
    }
}

private struct NutritionWidgetSourceBadge: View {
    let summary: WidgetSafeNutritionSummary
    let date: Date

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        Text(summary.provenanceLabel ?? nutritionWidgetStateText(summary.displayState(at: date)))
            .lifeOSWidgetTypography(.metadata)
            .fontWeight(.semibold)
            .tracking(0.15)
            .foregroundStyle(chrome.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chrome.panelFill(opacity: 0.36), in: Capsule())
            .overlay(Capsule().stroke(chrome.separator, lineWidth: 0.6))
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
                .lifeOSWidgetTypography(.title)
                .foregroundStyle(chrome.hero)
                .lineLimit(1)
            Spacer(minLength: 4)
            NutritionWidgetSourceBadge(summary: summary, date: date)
        }
    }
}

private enum NutritionWidgetAction: String, CaseIterable, Identifiable {
    case photoImport, camera

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .photoImport: URL(string: "lifeos://fitness/nutrition/import")!
        case .camera: URL(string: "lifeos://fitness/nutrition/camera")!
        }
    }

    var label: String {
        switch self {
        case .photoImport: "Import food photo from library"
        case .camera: "Capture food photo with camera"
        }
    }

    var shortLabel: String {
        switch self {
        case .photoImport: "Photo"
        case .camera: "Camera"
        }
    }

    var systemName: String {
        switch self {
        case .photoImport: "photo.badge.plus"
        case .camera: "camera.fill"
        }
    }
}

private struct NutritionWidgetQuickActions: View {
    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        HStack(spacing: 8) {
            ForEach(NutritionWidgetAction.allCases) { action in
                Link(destination: action.url) {
                    HStack(spacing: 5) {
                        Image(systemName: action.systemName)
                            .font(.system(size: 14, weight: .medium))
                        Text(action.shortLabel)
                            .lifeOSWidgetTypography(.metadata)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .foregroundStyle(chrome.hero)
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                    .background(chrome.panelFill(opacity: 0.36), in: Capsule())
                    .overlay(Capsule().stroke(chrome.separator, lineWidth: 0.6))
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                .accessibilityLabel(action.label)
                .accessibilityHint("Opens the app capture flow")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nutrition capture actions")
    }
}

private struct NutritionMacroMetric: View {
    let title: String
    let metric: WidgetNutritionMetric
    let goal: WidgetNutritionMetric
    let date: Date
    let color: Color

    @Environment(\.lifeOSWidgetChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .lifeOSWidgetTypography(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(chrome.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(nutritionWidgetValue(metric, at: date))
                    .lifeOSWidgetTypography(.compactMetric)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("g")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(nutritionWidgetValue(metric, at: date, unit: "grams")); goal \(nutritionWidgetValue(goal, at: date, unit: "grams")); \(nutritionWidgetStateText(nutritionWidgetMetricState(metric, at: date)))")
    }

    private var valueColor: Color {
        switch nutritionWidgetMetricState(metric, at: date) {
        case .fresh, .stale:
            return color
        case .unavailable, .redacted:
            return chrome.hero
        }
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
        let nutrition = entry.snapshot.nutrition
        VStack(alignment: .leading, spacing: 4) {
            NutritionWidgetHeader(title: "Today's Food", summary: entry.snapshot.nutrition, date: entry.date)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Calories")
                    .lifeOSWidgetTypography(.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(chrome.secondary)
                    .lineLimit(1)
                NutritionWidgetPrimaryValue(
                    metric: nutrition.caloriesEaten,
                    date: entry.date,
                    color: NutritionWidgetPalette.calories(transparent: chrome.usesTransparentTreatment)
                )
                Text("kcal")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                Spacer(minLength: 4)
                Text("Goal \(nutritionWidgetValue(nutrition.calorieGoal, at: entry.date, unit: "kcal"))")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                NutritionMacroMetric(title: "Protein", metric: nutrition.proteinGrams, goal: nutrition.proteinGoalGrams, date: entry.date, color: NutritionWidgetPalette.protein(transparent: chrome.usesTransparentTreatment))
                NutritionMacroMetric(title: "Carbs", metric: nutrition.carbsGrams, goal: nutrition.carbsGoalGrams, date: entry.date, color: NutritionWidgetPalette.carbohydrates(transparent: chrome.usesTransparentTreatment))
                NutritionMacroMetric(title: "Fat", metric: nutrition.fatGrams, goal: nutrition.fatGoalGrams, date: entry.date, color: NutritionWidgetPalette.fat(transparent: chrome.usesTransparentTreatment))
            }
            NutritionWidgetQuickActions()
        }
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/nutrition"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today's Nutrition, \(nutritionWidgetValue(entry.snapshot.nutrition.caloriesEaten, at: entry.date, unit: "kilocalories")); \(entry.snapshot.nutrition.provenanceLabel ?? nutritionWidgetStateText(entry.snapshot.nutritionDisplayState(at: entry.date)))")
    }
}

/// Geometry contract for the medium Calories & Macros widget.
///
/// The helper is shared by the production layout and the snapshot gate. That
/// keeps the proof about the actual three-column composition instead of testing
/// an unrelated approximation of the view tree.
struct NutritionCaloriesMacrosLayout: Equatable {
    static let headerHeight: CGFloat = 20
    static let headerContentSpacing: CGFloat = 6
    static let columnSpacing: CGFloat = 10
    static let macroSpacing: CGFloat = 6
    static let macroCellHeight: CGFloat = 68
    static let minimumCalorieWidth: CGFloat = 84
    static let minimumMacroCellWidth: CGFloat = 44
    static let valueFallbackSizes: [CGFloat] = [28, 24, 22]

    let contentBounds: CGRect
    let headerFrame: CGRect
    let contentFrame: CGRect
    let calorieFrame: CGRect
    let macroFrame: CGRect
    let macroFrames: [CGRect]

    init(
        containerSize: CGSize,
        contentMargins: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    ) {
        let width = max(0, containerSize.width)
        let height = max(0, containerSize.height)
        let contentWidth = max(0, width - contentMargins.leading - contentMargins.trailing)
        let contentHeight = max(0, height - contentMargins.top - contentMargins.bottom)
        let bounds = CGRect(
            x: contentMargins.leading,
            y: contentMargins.top,
            width: contentWidth,
            height: contentHeight
        )
        let resolvedHeaderHeight = min(Self.headerHeight, bounds.height)
        let header = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: resolvedHeaderHeight
        )
        let resolvedSpacing = min(
            Self.headerContentSpacing,
            max(0, bounds.maxY - header.maxY)
        )
        let contentOriginY = min(bounds.maxY, header.maxY + resolvedSpacing)
        let content = CGRect(
            x: bounds.minX,
            y: contentOriginY,
            width: bounds.width,
            height: max(0, bounds.maxY - contentOriginY)
        )

        let availableColumnsWidth = max(0, content.width - Self.columnSpacing)
        let minimumMacroRailWidth = (Self.minimumMacroCellWidth * 3) + (Self.macroSpacing * 2)
        let maximumCalorieWidth = max(0, availableColumnsWidth - minimumMacroRailWidth)
        let preferredCalorieWidth = max(
            Self.minimumCalorieWidth,
            availableColumnsWidth * 0.34
        )
        let calorieWidth = min(preferredCalorieWidth, maximumCalorieWidth)
        let macroWidth = max(0, availableColumnsWidth - calorieWidth)
        let macroCellWidth = max(0, (macroWidth - (Self.macroSpacing * 2)) / 3)
        let cellHeight = min(Self.macroCellHeight, content.height)
        let calorie = CGRect(
            x: content.minX,
            y: content.minY,
            width: calorieWidth,
            height: cellHeight
        )
        let macroRail = CGRect(
            x: calorie.maxX + Self.columnSpacing,
            y: content.minY,
            width: macroWidth,
            height: content.height
        )
        let cells = (0..<3).map { index in
            CGRect(
                x: macroRail.minX + CGFloat(index) * (macroCellWidth + Self.macroSpacing),
                y: macroRail.minY,
                width: macroCellWidth,
                height: cellHeight
            )
        }

        self.contentBounds = bounds
        self.headerFrame = header
        self.contentFrame = content
        self.calorieFrame = calorie
        self.macroFrame = macroRail
        self.macroFrames = cells
    }

    var essentialFrames: [CGRect] {
        [headerFrame, calorieFrame] + macroFrames
    }

    var essentialFramesAreInBounds: Bool {
        guard contentBounds.width > 0, contentBounds.height > 0,
              macroFrames.count == 3 else { return false }
        return essentialFrames.allSatisfy { frame in
            frame.width > 0 && frame.height > 0 &&
            frame.minX >= contentBounds.minX - 0.01 &&
            frame.minY >= contentBounds.minY - 0.01 &&
            frame.maxX <= contentBounds.maxX + 0.01 &&
            frame.maxY <= contentBounds.maxY + 0.01
        }
    }
}

private struct NutritionMacroGoalCell: View {
    @Environment(\.lifeOSWidgetChrome) private var chrome
    let title: String
    let metric: WidgetNutritionMetric
    let goal: WidgetNutritionMetric
    let date: Date
    /// Each macro uses its own approved brand ramp; macro values do not reuse
    /// the blue observed-series color.
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lifeOSWidgetTypography(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(chrome.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    value(size: 28)
                    value(size: 24)
                    value(size: 22)
                }
                Text("g")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(chrome.panelFill(opacity: 0.45), in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous).stroke(chrome.separator, lineWidth: 0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(remainingText); \(nutritionWidgetStateText(nutritionWidgetMetricState(metric, at: date)))")
    }

    private var valueColor: Color {
        switch nutritionWidgetMetricState(metric, at: date) {
        case .fresh, .stale:
            return color
        case .unavailable, .redacted:
            return chrome.hero
        }
    }

    @ViewBuilder
    private func value(size: CGFloat) -> some View {
        Text(compactValueText)
            .lifeOSWidgetTypography(LifeOSWidgetTypography.Role.numericFallback(for: size))
            .monospacedDigit()
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var remainingText: String {
        guard nutritionWidgetHasValue(metric, at: date), nutritionWidgetHasValue(goal, at: date),
              let value = metric.value, let target = goal.value else { return metric.state == .redacted ? "Hidden" : "Unavailable" }
        let consumed = value.formatted(.number.precision(.fractionLength(0)))
        let targetText = target.formatted(.number.precision(.fractionLength(0)))
        return "\(consumed) / \(targetText) g"
    }

    private var compactValueText: String {
        nutritionWidgetDisplayValue(metric, at: date)
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
        GeometryReader { proxy in
            let layout = NutritionCaloriesMacrosLayout(containerSize: proxy.size)
            VStack(alignment: .leading, spacing: NutritionCaloriesMacrosLayout.headerContentSpacing) {
                NutritionWidgetHeader(title: "Calories & Macros", summary: nutrition, date: entry.date)
                    .frame(width: layout.headerFrame.width, height: layout.headerFrame.height, alignment: .leading)

                HStack(alignment: .top, spacing: NutritionCaloriesMacrosLayout.columnSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calories")
                            .lifeOSWidgetTypography(.metadata)
                            .fontWeight(.semibold)
                            .foregroundStyle(chrome.secondary)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            NutritionWidgetPrimaryValue(
                                metric: nutrition.caloriesEaten,
                                date: entry.date,
                                color: NutritionWidgetPalette.calories(transparent: chrome.usesTransparentTreatment)
                            )
                            Text("kcal")
                                .lifeOSWidgetTypography(.metadata)
                                .foregroundStyle(chrome.tertiary)
                        }
                    }
                    .frame(width: layout.calorieFrame.width, height: layout.calorieFrame.height, alignment: .topLeading)

                    HStack(alignment: .top, spacing: NutritionCaloriesMacrosLayout.macroSpacing) {
                        NutritionMacroGoalCell(title: "Fat", metric: nutrition.fatGrams, goal: nutrition.fatGoalGrams, date: entry.date, color: NutritionWidgetPalette.fat(transparent: chrome.usesTransparentTreatment))
                            .frame(width: layout.macroFrames[0].width, height: layout.macroFrames[0].height, alignment: .topLeading)
                        NutritionMacroGoalCell(title: "Carbs", metric: nutrition.carbsGrams, goal: nutrition.carbsGoalGrams, date: entry.date, color: NutritionWidgetPalette.carbohydrates(transparent: chrome.usesTransparentTreatment))
                            .frame(width: layout.macroFrames[1].width, height: layout.macroFrames[1].height, alignment: .topLeading)
                        NutritionMacroGoalCell(title: "Protein", metric: nutrition.proteinGrams, goal: nutrition.proteinGoalGrams, date: entry.date, color: NutritionWidgetPalette.protein(transparent: chrome.usesTransparentTreatment))
                            .frame(width: layout.macroFrames[2].width, height: layout.macroFrames[2].height, alignment: .topLeading)
                    }
                    .frame(width: layout.macroFrame.width, height: layout.contentFrame.height, alignment: .topLeading)
                }
                .frame(width: layout.contentFrame.width, height: layout.contentFrame.height, alignment: .topLeading)
            }
            .frame(width: layout.contentBounds.width, height: layout.contentBounds.height, alignment: .topLeading)
        }
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
            .lifeOSWidgetTypography(.metadata)
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
                    .lifeOSWidgetTypography(.hero)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("kcal balance").lifeOSWidgetTypography(.metadata).foregroundStyle(chrome.tertiary)
                Spacer(minLength: 5)
                Text("Burned \(nutritionWidgetValue(nutrition.caloriesBurned, at: entry.date, unit: "kcal"))")
                    .lifeOSWidgetTypography(.metadata).fontWeight(.semibold).monospacedDigit()
                Text("Eaten \(nutritionWidgetValue(nutrition.caloriesEaten, at: entry.date, unit: "kcal"))")
                    .lifeOSWidgetTypography(.metadata).fontWeight(.semibold).monospacedDigit()
            }
            NutritionSignedBalanceScale(balance: signedBalance, date: entry.date)
            Text(provenanceText)
                .lifeOSWidgetTypography(.metadata)
                .foregroundStyle(chrome.tertiary)
                .lineLimit(1)
        }
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
                .frame(width: 16, height: 16)
                .foregroundStyle(iconColor)
            Text(title)
                .lifeOSWidgetTypography(.title)
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
            .lifeOSWidgetTypography(.metadata)
            .fontWeight(.bold)
            .tracking(compact ? 0.2 : 0.35)
            .foregroundStyle(LifeOSTokens.warning)
            .lineLimit(1)
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
        let state = fitnessWidgetState(metric, at: date)
        let hasValue = metric.value != nil && (state == .fresh || state == .stale)
        Link(destination: URL(string: route)!) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lifeOSWidgetTypography(.metadata, weight: .semibold)
                    .foregroundStyle(chrome.secondary)
                    .lineLimit(1)
                HStack(alignment: .center, spacing: 6) {
                    if let value = metric.value, hasValue {
                        ZStack {
                            Circle()
                                .stroke(LifeOSTokens.Ring.track, lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: min(1, max(0, value / 100)))
                                .stroke(fitnessWidgetStatusColor(progress: value / 100), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(value.formatted(.number.precision(.fractionLength(0))) + "%")
                                .lifeOSWidgetTypography(.metadata)
                                .fontWeight(.bold)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: state == .redacted ? "lock.fill" : "minus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(chrome.tertiary)
                            .frame(width: 36, height: 36)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hasValue ? metric.unit.displayName : (state == .redacted ? "Hidden" : "No data"))
                            .lifeOSWidgetTypography(.metadata)
                            .foregroundStyle(hasValue ? chrome.tertiary : chrome.secondary)
                            .lineLimit(2)
                        if hasValue {
                            Text(state == .fresh ? "Observed" : "Stale")
                                .lifeOSWidgetTypography(.metadata)
                                .foregroundStyle(chrome.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .lifeOSWidgetTypography(.metadata, weight: .semibold)
                    .foregroundStyle(chrome.hero)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("Source-backed")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                FitnessRingCell(title: "Strain", metric: fitness.strain, route: "lifeos://fitness/strain", date: entry.date)
                Divider().overlay(chrome.separator).frame(height: 56)
                FitnessRingCell(title: "Recovery", metric: fitness.recovery, route: "lifeos://fitness/recovery", date: entry.date)
                Divider().overlay(chrome.separator).frame(height: 56)
                FitnessRingCell(title: "Sleep", metric: fitness.sleepScore, route: "lifeos://fitness/sleep", date: entry.date)
            }
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
        }
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
                .lifeOSWidgetTypography(.compactMetric)
                .monospacedDigit()
                .lineLimit(1)
                Text(metric.unit.displayName)
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                LifeOSIcon(icon)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(chrome.tertiary)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
            .background(chrome.panelFill(opacity: 0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(chrome.separator, lineWidth: 0.7))
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

private struct FitnessHealthMetricDescriptor: Identifiable {
    let id: String
    let title: String
    let metric: WidgetFitnessMetric
    let route: String
    let icon: LifeOSIconName
}

private func fitnessHealthMetricDescriptors(_ fitness: WidgetSafeFitnessWidgetsSummary) -> [FitnessHealthMetricDescriptor] {
    [
        FitnessHealthMetricDescriptor(id: "respiration", title: "Respiration", metric: fitness.respiration, route: "lifeos://fitness/health/respiration", icon: .fitness),
        FitnessHealthMetricDescriptor(id: "heart-rate", title: "Resting heart rate", metric: fitness.heartRate, route: "lifeos://fitness/health/heart-rate", icon: .heartRate),
        FitnessHealthMetricDescriptor(id: "hrv", title: "HRV", metric: fitness.hrv, route: "lifeos://fitness/health/hrv", icon: .health),
        FitnessHealthMetricDescriptor(id: "spo2", title: "SpO₂", metric: fitness.spo2, route: "lifeos://fitness/health/spo2", icon: .verified),
        FitnessHealthMetricDescriptor(id: "temperature", title: "Temperature", metric: fitness.temperature, route: "lifeos://fitness/health/temperature", icon: .warning),
        FitnessHealthMetricDescriptor(id: "sleep-duration", title: "Sleep", metric: fitness.sleepDuration, route: "lifeos://fitness/health/sleep-duration", icon: .sleep)
    ]
}

struct FitnessHealthMonitorWidgetView: View {
    let entry: FutureModuleWidgetEntry

    var body: some View {
        let fitness = entry.snapshot.fitnessWidgets
        let availableMetrics = fitnessHealthMetricDescriptors(fitness).filter { descriptor in
            guard descriptor.metric.value != nil else { return false }
            let state = fitnessWidgetState(descriptor.metric, at: entry.date)
            return state == .fresh || state == .stale
        }
        let visibleMetrics = Array(availableMetrics.prefix(3))
        let additionalCount = max(0, availableMetrics.count - visibleMetrics.count)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FutureModuleWidgetHeader(title: "Health Monitor", icon: .health, accent: LifeOSTokens.Module.fitness)
                if fitness.isDemoFixture { FitnessDemoBadge() }
            }
            if visibleMetrics.isEmpty {
                FutureModuleUnavailableHero(
                    state: entry.snapshot.fitnessDisplayState(at: entry.date) == .redacted ? .redacted : .unavailable,
                    unavailableText: "No reviewed health observations"
                )
            } else {
                HStack(alignment: .top, spacing: 5) {
                    ForEach(visibleMetrics) { descriptor in
                        FitnessHealthMetricCell(
                            title: descriptor.title,
                            metric: descriptor.metric,
                            route: descriptor.route,
                            date: entry.date,
                            icon: descriptor.icon
                        )
                    }
                }
                if additionalCount > 0 {
                    Text("+\(additionalCount) more source metrics in LifeOS")
                        .lifeOSWidgetTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .lifeOSWidgetContainer { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://fitness/health"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Health Monitor\(fitnessWidgetDemoDisclosure(fitness)), \(availableMetrics.count) source-backed observations shown or available in LifeOS")
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
                        .lifeOSWidgetTypography(.metadata)
                        .monospacedDigit()
                        .foregroundStyle(LifeOSTokens.Series.observed)
                        .offset(x: max(0, proxy.size.width - 25), y: max(0, proxy.size.height * (1 - normalized) - 17))
                }
                Text("100")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                    .offset(x: 2, y: -1)
                Text("0")
                    .lifeOSWidgetTypography(.metadata)
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
                    .lifeOSWidgetTypography(.metadata)
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
            .lifeOSWidgetTypography(.metadata)
            .monospacedDigit()
            .foregroundStyle(chrome.tertiary)
            .lineLimit(1)
        }
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
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(fitnessWidgetValue(energy.level, at: entry.date))
                    .lifeOSWidgetTypography(.hero)
                    .monospacedDigit()
                Text("% reserve")
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                Spacer(minLength: 0)
                Text(lastChargedText(energy.lastChargedAt))
                    .lifeOSWidgetTypography(.metadata)
                    .foregroundStyle(chrome.tertiary)
                    .lineLimit(1)
            }
            FitnessEnergySegments(level: energy.level.value)
            HStack(spacing: 7) {
                FitnessEnergyChip(title: "Charged", value: energy.chargedPercent, date: entry.date)
                FitnessEnergyChip(title: "Discharged", value: energy.dischargedPercent, date: entry.date)
                Spacer(minLength: 0)
            }
        }
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
                .lifeOSWidgetTypography(.metadata)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(chrome.panelFill(opacity: 0.45), in: Capsule())
        .overlay(Capsule().stroke(chrome.separator, lineWidth: 0.7))
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
