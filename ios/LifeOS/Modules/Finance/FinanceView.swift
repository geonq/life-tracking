import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Public route values used by callers that open a specific Finance detail.
public enum FinanceDetailRoute: String, CaseIterable, Hashable, Sendable {
    case spend
    case income
    case cashFlow
    case netWorth
}

// MARK: - Finance screen contract

/// Finance is intentionally a view over injected observations. The native app does not
/// manufacture balances when the gateway has not supplied them. Pass `usesVisualFixtures: true`
/// only from a visual-review entry point; that path is labelled throughout the screen.
public struct FinanceView: View {
    private let summary: FinanceSummary?
    private let transactions: [FinanceTransactionObservation]?
    private let usesVisualFixtures: Bool
    private let initialDetail: FinanceDetailRoute?
    private let onOpenConnections: (() -> Void)?

    @State private var selectedDetail: FinanceDetail = .spend
    @State private var selectedRange: FinanceRange = .month
    @State private var selectedSpendPoint: Int?
    @State private var selectedIncomePoint: Int?
    @State private var selectedCashFlowPoint: Int?
    @State private var selectedNetWorthPoint: Int?
    @State private var selectedCategoryID: String?
    @State private var selectedCategorySource: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A small public route value keeps deep-link callers independent from the private
    /// chart-selection model used by the view.
    public init(
        summary: FinanceSummary? = nil,
        transactions: [FinanceTransactionObservation]? = nil,
        usesVisualFixtures: Bool = false,
        initialDetail: FinanceDetailRoute? = nil,
        onOpenConnections: (() -> Void)? = nil
    ) {
        self.summary = summary
        self.transactions = transactions
        self.usesVisualFixtures = usesVisualFixtures
        self.initialDetail = initialDetail
        self.onOpenConnections = onOpenConnections
        switch initialDetail {
        case .income: _selectedDetail = State(initialValue: .income)
        case .cashFlow: _selectedDetail = State(initialValue: .cashFlow)
        case .netWorth: _selectedDetail = State(initialValue: .netWorth)
        case .spend, nil: _selectedDetail = State(initialValue: .spend)
        }
    }

    public var body: some View {
        let snapshot = FinanceDisplaySnapshot(
            summary: summary,
            transactions: transactions,
            usesVisualFixtures: usesVisualFixtures
        )

        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: 16, bottomPadding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    financeHeader(snapshot: snapshot)
                    FinanceHeroCard(snapshot: snapshot)

                    financeDetailAndCategories(snapshot: snapshot)

                    financeMetricGrid(snapshot: snapshot)
                    FinanceAccountsCard(snapshot: snapshot, onOpenConnections: onOpenConnections)
                    FinanceImportCard()
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .onAppear {
            selectLatestPoints(in: snapshot)
        }
        .onChange(of: selectedRange) { _, _ in
            selectLatestPoints(in: snapshot)
        }
        .onChange(of: initialDetail) { _, route in
            let requestedDetail = detail(for: route)
            guard selectedDetail != requestedDetail else { return }
            if reduceMotion {
                selectedDetail = requestedDetail
            } else {
                withAnimation(LifeOSMotion.snappy) {
                    selectedDetail = requestedDetail
                }
            }
            selectLatestPoints(in: snapshot)
        }
        .accessibilityIdentifier("finance-view")
    }

    private func financeHeader(snapshot: FinanceDisplaySnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LifeOSTokens.success.opacity(0.14))
                LifeOSIcon(.finance)
                    .foregroundStyle(LifeOSTokens.success)
                    .frame(width: 21, height: 21)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text("Finance")
                    .font(LifeOSFont.headerLarge(27))
                Text("Private overview")
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }

            Spacer(minLength: 6)

            FinanceStatusBadge(snapshot: snapshot)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance")
        .accessibilityValue(snapshot.accessibilityStatus)
    }

    @ViewBuilder
    private func financeDetailAndCategories(snapshot: FinanceDisplaySnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                financeDetailPanel(snapshot: snapshot)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                FinanceCategoriesCard(
                    snapshot: snapshot,
                    selectedCategoryID: $selectedCategoryID,
                    selectedSourceID: $selectedCategorySource,
                    selectedRange: selectedRange
                )
                .frame(minWidth: 300, maxWidth: 390, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 16) {
                financeDetailPanel(snapshot: snapshot)
                FinanceCategoriesCard(
                    snapshot: snapshot,
                    selectedCategoryID: $selectedCategoryID,
                    selectedSourceID: $selectedCategorySource,
                    selectedRange: selectedRange
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func financeDetailPanel(snapshot: FinanceDisplaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FinanceSectionHeader(title: "Details", subtitle: "Trend context for this period")
            SpringPillSelector(
                options: FinanceDetail.allCases,
                selection: $selectedDetail
            ) { detail, isSelected in
                Text(detail.title)
                    .font(LifeOSFont.inter(12, weight: isSelected ? .semiBold : .medium))
                    .foregroundStyle(isSelected ? .primary : LifeOSTokens.tertiaryText)
                    .frame(maxWidth: .infinity)
            }
            .padding(4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            .accessibilityLabel("Finance detail")
            .accessibilityValue(selectedDetail.title)

            FinanceRangePills(
                selection: $selectedRange,
                availableRanges: snapshot.availableRanges(for: selectedDetail)
            )
            detailCard(snapshot: snapshot)
        }
    }

    private func financeMetricGrid(snapshot: FinanceDisplaySnapshot) -> some View {
        let columns: [GridItem] = {
#if os(macOS)
            Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: 4)
#else
            [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 12)]
#endif
        }()
        return LazyVGrid(
            columns: columns,
            spacing: 10
        ) {
            FinanceMetricCard(
                title: "Spent",
                value: snapshot.spent.valueText,
                detail: snapshot.spent.detail,
                icon: .budget,
                hue: .blue,
                progress: snapshot.spendProgress,
                isUnavailable: snapshot.spent.isUnavailable
            )
            FinanceMetricCard(
                title: "Cash flow",
                value: snapshot.cashFlow.valueText,
                detail: snapshot.cashFlow.detail,
                icon: .revenue,
                hue: .green,
                progress: snapshot.cashFlow.progress,
                isUnavailable: snapshot.cashFlow.isUnavailable
            )
            FinanceMetricCard(
                title: "Income",
                value: snapshot.income.valueText,
                detail: snapshot.income.detail,
                icon: .revenue,
                hue: .teal,
                progress: nil,
                isUnavailable: snapshot.income.isUnavailable
            )
            FinanceMetricCard(
                title: "Saved",
                value: snapshot.saved.valueText,
                detail: snapshot.saved.detail,
                icon: .savings,
                hue: .violet,
                progress: snapshot.savingsProgress,
                isUnavailable: snapshot.saved.isUnavailable
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailCard(snapshot: FinanceDisplaySnapshot) -> some View {
        switch selectedDetail {
        case .spend:
            FinanceDetailChartCard(
                title: "Spend",
                subtitle: "Across connected accounts",
                metric: snapshot.spent,
                points: snapshot.points(for: .spend, range: selectedRange),
                accent: .blue,
                selectedPoint: $selectedSpendPoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Spend history will appear after a reviewed account connection is available."
            )
        case .income:
            FinanceDetailChartCard(
                title: "Income",
                subtitle: "Deposits across connected accounts",
                metric: snapshot.income,
                points: snapshot.points(for: .income, range: selectedRange),
                accent: .teal,
                selectedPoint: $selectedIncomePoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Income history will appear after a reviewed account connection is available."
            )
        case .cashFlow:
            FinanceDetailChartCard(
                title: "Cash flow",
                subtitle: "Money in minus money out",
                metric: snapshot.cashFlow,
                points: snapshot.points(for: .cashFlow, range: selectedRange),
                accent: .green,
                selectedPoint: $selectedCashFlowPoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Cash-flow history needs a connected source with transaction history."
            )
        case .netWorth:
            FinanceDetailChartCard(
                title: "Net worth",
                subtitle: "Balance trend",
                metric: snapshot.netWorth,
                points: snapshot.points(for: .netWorth, range: selectedRange),
                accent: .violet,
                selectedPoint: $selectedNetWorthPoint,
                isDemo: snapshot.isDemo,
                emptyDetail: "Net-worth history is not available from the current Finance contract."
            )
        }
    }

    private func selectLatestPoints(in snapshot: FinanceDisplaySnapshot) {
        selectedSpendPoint = snapshot.points(for: .spend, range: selectedRange).indices.last
        selectedIncomePoint = snapshot.points(for: .income, range: selectedRange).indices.last
        selectedCashFlowPoint = snapshot.points(for: .cashFlow, range: selectedRange).indices.last
        selectedNetWorthPoint = snapshot.points(for: .netWorth, range: selectedRange).indices.last
    }

    private func detail(for route: FinanceDetailRoute?) -> FinanceDetail {
        switch route {
        case .income: .income
        case .cashFlow: .cashFlow
        case .netWorth: .netWorth
        case .spend, nil: .spend
        }
    }

    /// A small, data-only acceptance seam for the production display model.
    /// It keeps account-only truth testable without exposing the private
    /// SwiftUI view hierarchy or any fixture-only entry point.
    internal static func displayTruth(
        summary: FinanceSummary?,
        transactions: [FinanceTransactionObservation]? = nil,
        usesVisualFixtures: Bool = false
    ) -> FinanceDisplayTruth {
        let snapshot = FinanceDisplaySnapshot(
            summary: summary,
            transactions: transactions,
            usesVisualFixtures: usesVisualFixtures
        )
        return FinanceDisplayTruth(
            statusLabel: snapshot.statusLabel,
            sourceDisclosure: snapshot.sourceDisclosure,
            netWorthCents: snapshot.netWorth.cents,
            accountsCount: snapshot.accounts.count,
            hasObservedValue: snapshot.hasObservedValue,
            transactionTotalsAvailable: snapshot.transactionTotalsAvailable
        )
    }
}

internal struct FinanceDisplayTruth: Equatable {
    let statusLabel: String
    let sourceDisclosure: String
    let netWorthCents: Int?
    let accountsCount: Int
    let hasObservedValue: Bool
    let transactionTotalsAvailable: Bool
}

// MARK: - Header and honest states

private struct FinanceStatusBadge: View {
    let snapshot: FinanceDisplaySnapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(snapshot.statusColor)
                .frame(width: 7, height: 7)
            Text(snapshot.statusLabel)
                .font(LifeOSFont.inter(10, weight: .bold))
                .tracking(snapshot.isDemo ? 0.35 : 0)
        }
        .foregroundStyle(snapshot.statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(snapshot.statusColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(snapshot.statusColor.opacity(0.22), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finance data status")
        .accessibilityValue(snapshot.statusLabel)
    }
}

private struct FinanceHeroCard: View {
    let snapshot: FinanceDisplaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Net worth")
                        .font(LifeOSFont.inter(14, weight: .semiBold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Text(snapshot.netWorth.valueText)
                        .font(LifeOSFont.spaceGrotesk(40, weight: .bold))
                        .monospacedDigit()
                        .numericTransition()
                    Text(snapshot.netWorth.detail)
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(snapshot.netWorth.isUnavailable ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                }

                Spacer(minLength: 10)

                if snapshot.netWorth.isUnavailable {
                    UnavailableMetricMark(label: "Not available")
                } else {
                    FinanceMiniSparkline(points: snapshot.netWorthPoints, hue: .violet)
                        .frame(width: 132, height: 62)
                }
            }

            HStack(spacing: 0) {
                FinanceHeroFact(title: "Accounts", value: snapshot.accounts.isEmpty ? "Not available" : "\(snapshot.accounts.count) connected")
                Divider().frame(height: 28)
                FinanceHeroFact(title: "Updated", value: snapshot.updatedLabel)
                Divider().frame(height: 28)
                FinanceHeroFact(title: "Currency", value: "EUR")
            }

            Text(snapshot.sourceDisclosure)
                .font(LifeOSFont.inter(10, weight: .medium))
                .foregroundStyle(snapshot.isDemo ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Finance source and freshness")
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(featured: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Net worth")
        .accessibilityValue("\(snapshot.netWorth.accessibilityValue). Accounts \(snapshot.accounts.isEmpty ? "not available" : "\(snapshot.accounts.count) connected"). Updated \(snapshot.updatedLabel).")
    }
}

private struct FinanceHeroFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(LifeOSFont.inter(10, weight: .medium))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .font(LifeOSFont.inter(12, weight: .semiBold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct UnavailableMetricMark: View {
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text("—")
                .font(LifeOSFont.spaceGrotesk(32, weight: .bold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(label)
                .font(LifeOSFont.inter(10, weight: .semiBold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

// MARK: - Metric cards

private struct FinanceMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: LifeOSIconName
    let hue: LifeOSTokens.Hue
    let progress: Double?
    let isUnavailable: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    Circle()
                        .fill(hue.base.opacity(0.15))
                    LifeOSIcon(icon)
                        .foregroundStyle(hue.base)
                        .frame(width: 17, height: 17)
                }
                .frame(width: 34, height: 34)
                Spacer()
                if let progress {
                    Circle()
                        .trim(from: 0, to: animatedProgress)
                        .stroke(hue.base, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 23, height: 23)
                        .rotationEffect(.degrees(-90))
                        .accessibilityHidden(true)
                        .task(id: "\(progress)-\(reduceMotion)") {
                            let target = min(max(progress, 0), 1)
                            if reduceMotion {
                                animatedProgress = target
                            } else {
                                withAnimation(LifeOSMotion.ringReveal) { animatedProgress = target }
                            }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LifeOSFont.inter(12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                Text(value)
                    .font(LifeOSFont.spaceGrotesk(25, weight: .bold))
                    .monospacedDigit()
                    .numericTransition()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(LifeOSFont.inter(10, weight: .medium))
                    .foregroundStyle(isUnavailable ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value). \(detail)")
    }
}

// MARK: - Detail charts

private struct FinanceDetailChartCard: View {
    let title: String
    let subtitle: String
    let metric: FinanceDisplayMetric
    let points: [FinanceChartPoint]
    let accent: LifeOSTokens.Hue
    @Binding var selectedPoint: Int?
    let isDemo: Bool
    let emptyDetail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LifeOSFont.header(17))
                    Text(subtitle)
                        .font(LifeOSFont.inter(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 10)
                Text(metric.valueText)
                    .font(LifeOSFont.spaceGrotesk(23, weight: .bold))
                    .monospacedDigit()
                    .numericTransition()
            }

            if points.isEmpty {
                FinanceUnavailableChart(detail: emptyDetail)
            } else {
                FinanceLineChart(
                    points: points,
                    accent: accent,
                    selectedPoint: $selectedPoint,
                    isDemo: isDemo
                )
                FinanceChartSelectionDetail(
                    points: points,
                    selectedPoint: $selectedPoint,
                    accent: accent,
                    isDemo: isDemo
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-detail-chart-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct FinanceUnavailableChart: View {
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 58, height: 2)
                }
            HStack(spacing: 8) {
                LifeOSIcon(.security)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 15, height: 15)
                Text("Not available")
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Text(detail)
                .font(LifeOSFont.inter(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chart not available")
        .accessibilityValue(detail)
    }
}

/// The chart is embedded in the Finance route's vertical `ScrollView`. A chart drag
/// must therefore be classified before it changes the selected point: a primarily
/// vertical gesture belongs to the parent scroll view, while a primarily horizontal
/// gesture belongs to chart scrubbing. Keeping this classifier independent of SwiftUI
/// makes the boundary easy to regression-test without relying on simulator gesture
/// timing.
enum FinanceChartGestureAxis: Equatable {
    case undecided
    case horizontal
    case vertical
    case ambiguous
}

enum FinanceChartGestureClassifier {
    /// Translation must clear this distance before a touch is considered a directional
    /// drag. Below it, the recognizer remains unresolved and the separate tap path
    /// handles point selection.
    static let directionThreshold: CGFloat = 8

    /// A direction needs a modest 15% dominance over the other axis. Near-diagonal
    /// movement remains ambiguous so it cannot churn chart selection while a user is
    /// trying to move the surrounding page.
    static let dominanceRatio: CGFloat = 1.15

    static func axis(
        for translation: CGSize,
        threshold: CGFloat = FinanceChartGestureClassifier.directionThreshold,
        dominanceRatio: CGFloat = FinanceChartGestureClassifier.dominanceRatio
    ) -> FinanceChartGestureAxis {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= threshold else { return .undecided }

        if horizontal >= vertical * dominanceRatio {
            return .horizontal
        }
        if vertical >= horizontal * dominanceRatio {
            return .vertical
        }
        return .ambiguous
    }
}

#if os(iOS)
/// UIKit's directional failure decision is important here: SwiftUI's child
/// `DragGesture` can still starve the enclosing `UIScrollView` even when marked
/// simultaneous. This recognizer fails before beginning for vertical movement,
/// so the ancestor's native pan recognizer receives the same touch sequence.
private struct FinanceDirectionalScrubOverlay: UIViewRepresentable {
    let onTap: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onChanged: onChanged)
    }

    func makeUIView(context: Context) -> FinanceDirectionalScrubView {
        let view = FinanceDirectionalScrubView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.scrubPan = pan
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: FinanceDirectionalScrubView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onChanged = onChanged
        view.installScrollFailureRelationshipIfNeeded()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGFloat) -> Void
        var onChanged: (CGFloat) -> Void

        init(onTap: @escaping (CGFloat) -> Void, onChanged: @escaping (CGFloat) -> Void) {
            self.onTap = onTap
            self.onChanged = onChanged
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            onTap(recognizer.location(in: view).x)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            onChanged(recognizer.location(in: view).x)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // The same delegate owns the tap recognizer; it should always be
            // allowed to begin. Directional arbitration applies only to the pan.
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return true }
            let translation = pan.translation(in: view)
            return FinanceChartGestureClassifier.axis(
                for: CGSize(width: translation.x, height: translation.y)
            ) == .horizontal
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The explicit failure relationship below makes horizontal scrubbing
            // win when the ancestor is a UIScrollView. Keep the fallback permissive
            // for SwiftUI wrappers that do not expose that relationship in time;
            // vertical motion still fails this recognizer before it begins.
            otherGestureRecognizer.view is UIScrollView
        }
    }
}

private final class FinanceDirectionalScrubView: UIView {
    weak var scrubPan: UIPanGestureRecognizer?
    private weak var attachedScrollView: UIScrollView?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        installScrollFailureRelationshipIfNeeded()
    }

    func installScrollFailureRelationshipIfNeeded() {
        guard let scrubPan else { return }

        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                guard attachedScrollView !== scrollView else { return }
                // The native scroll waits for direction arbitration. A vertical
                // gesture makes scrubPan fail at 8pt, then the scroll can begin;
                // a horizontal gesture starts scrubPan and leaves the parent failed.
                scrollView.panGestureRecognizer.require(toFail: scrubPan)
                attachedScrollView = scrollView
                return
            }
            ancestor = current.superview
        }
    }
}
#endif

private struct FinanceLineChart: View {
    let points: [FinanceChartPoint]
    let accent: LifeOSTokens.Hue
    @Binding var selectedPoint: Int?
    let isDemo: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @FocusState private var chartIsFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let selected = selectedPoint.map { min(max($0, 0), max(points.count - 1, 0)) }
            let geometry = FinanceChartGeometry(points: points, size: size)

            ZStack(alignment: .topLeading) {
                FinanceChartGrid(zeroY: geometry.zeroY)

                chartArea(using: geometry)
                    .opacity(0.92)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(size.width * drawn, 1), height: size.height)
                    }

                geometry.smoothPath()
                    .trim(from: 0, to: drawn)
                    .stroke(
                        LinearGradient(
                            colors: [accent.glow, accent.base],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                if let selected, points.indices.contains(selected) {
                    let position = geometry.coordinate(for: selected)
                    Path { path in
                        path.move(to: CGPoint(x: position.x, y: 9))
                        path.addLine(to: CGPoint(x: position.x, y: size.height - 20))
                    }
                    .stroke(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    Circle()
                        .fill(LifeOSTokens.surface)
                        .overlay(Circle().stroke(accent.base, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(position)

                    ScrubBubble(
                        x: min(max(position.x, 44), size.width - 44),
                        y: min(max(position.y - 30, 25), size.height - 26)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(points[selected].valueText)
                                .foregroundStyle(.primary)
                            Text(points[selected].dateLabel)
                                .font(LifeOSFont.inter(9, weight: .medium))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Text(isDemo ? "Demo · not live" : points[selected].sourceDisclosure)
                                .font(LifeOSFont.inter(9, weight: .medium))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
#if os(iOS)
            // SwiftUI DragGesture competes with the UIKit-backed ScrollView even
            // when attached through simultaneousGesture. A small UIKit recognizer
            // below fails before beginning for vertical/ambiguous movement, leaving
            // the native route scroll in charge; it begins only for horizontal scrub.
            .overlay(alignment: .topLeading) {
                FinanceDirectionalScrubOverlay(
                    onTap: { x in updateSelection(at: x, in: size) },
                    onChanged: { x in updateSelection(at: x, in: size) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
#else
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = nearestIndex(for: value.location.x, in: size)
                        if selectedPoint != index {
                            ScrubBubble<EmptyView>.snapHaptic()
                        }
                        selectedPoint = index
                    }
            )
#endif
            .focusable(true)
            .focused($chartIsFocused)
#if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let index = nearestIndex(for: location.x, in: size)
                    if selectedPoint != index {
                        ScrubBubble<EmptyView>.snapHaptic()
                    }
                    selectedPoint = index
                case .ended:
                    break
                }
            }
            .onMoveCommand { direction in
                guard !points.isEmpty else { return }
                switch direction {
                case .left:
                    selectedPoint = max((selectedPoint ?? points.count - 1) - 1, 0)
                case .right:
                    selectedPoint = min((selectedPoint ?? 0) + 1, points.count - 1)
                default:
                    break
                }
            }
#endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(points.first?.seriesTitle ?? "Finance") chart")
            .accessibilityValue(selected.map { points[$0].accessibilityValue } ?? "Swipe to inspect values")
            .onAppear {
                drawn = reduceMotion ? 1 : 0
                guard !reduceMotion else { return }
                withAnimation(LifeOSMotion.chartDraw) {
                    drawn = 1
                }
            }
        }
        .frame(height: 166)
    }

    private func chartArea(using geometry: FinanceChartGeometry) -> some View {
        FinanceAreaShape(geometry: geometry)
        .fill(
            LinearGradient(
                colors: [accent.base.opacity(0.24), accent.base.opacity(0.01)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func nearestIndex(for x: CGFloat, in size: CGSize) -> Int {
        guard points.count > 1 else { return 0 }
        let horizontalInset: CGFloat = 10
        let width = max(size.width - horizontalInset * 2, 1)
        let fraction = min(max((x - horizontalInset) / width, 0), 1)
        return min(max(Int((fraction * CGFloat(points.count - 1)).rounded()), 0), points.count - 1)
    }

    private func updateSelection(at x: CGFloat, in size: CGSize) {
        let index = nearestIndex(for: x, in: size)
        if selectedPoint != index {
            ScrubBubble<EmptyView>.snapHaptic()
        }
        selectedPoint = index
    }
}

private struct FinanceChartGrid: View {
    let zeroY: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        Rectangle()
                            .fill(Color.primary.opacity(index == 2 ? 0.14 : 0.07))
                            .frame(height: index == 2 ? 1 : 0.5)
                        if index < 2 { Spacer() }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 23)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: zeroY))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: zeroY))
                }
                .stroke(Color.primary.opacity(0.26), lineWidth: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct FinanceAreaShape: Shape {
    let geometry: FinanceChartGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !geometry.points.isEmpty else { return path }
        let firstPoint = geometry.coordinate(for: 0)
        let lastPoint = geometry.coordinate(for: geometry.points.count - 1)
        path.move(to: CGPoint(x: firstPoint.x, y: geometry.zeroY))
        path.addLine(to: firstPoint)
        geometry.appendSmoothSegments(to: &path)
        path.addLine(to: CGPoint(x: lastPoint.x, y: geometry.zeroY))
        path.closeSubpath()
        return path
    }
}

private struct FinanceChartGeometry {
    let points: [FinanceChartPoint]
    let size: CGSize

    private let horizontalInset: CGFloat = 10
    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 23

    private var values: [Double] { points.map { Double($0.value) } }
    private var minimum: Double { min(values.min() ?? 0, 0) }
    private var maximum: Double { max(values.max() ?? 0, 0) }
    private var spread: Double { max(maximum - minimum, 1) }

    var zeroY: CGFloat { coordinate(for: 0).y }

    func coordinate(for index: Int, value: Double? = nil) -> CGPoint {
        let width = max(size.width - horizontalInset * 2, 1)
        let height = max(size.height - topInset - bottomInset, 1)
        let x = horizontalInset + width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
        let rawValue = value ?? (points.indices.contains(index) ? Double(points[index].value) : 0)
        let normalized = min(max((rawValue - minimum) / spread, 0), 1)
        return CGPoint(x: x, y: topInset + height * (1 - CGFloat(normalized)))
    }

    func smoothPath() -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: coordinate(for: 0))
        appendSmoothSegments(to: &path)
        if points.count == 1 {
            path.addLine(to: coordinate(for: 0, value: Double(first.value)))
        }
        return path
    }

    func appendSmoothSegments(to path: inout Path) {
        guard points.count > 1 else { return }
        for index in 0..<(points.count - 1) {
            let previous = coordinate(for: max(index - 1, 0))
            let current = coordinate(for: index)
            let next = coordinate(for: index + 1)
            let following = coordinate(for: min(index + 2, points.count - 1))
            let control1 = CGPoint(
                x: current.x + (next.x - previous.x) / 6,
                y: clamped(
                    current.y + (next.y - previous.y) / 6,
                    lowerBound: min(current.y, next.y),
                    upperBound: max(current.y, next.y)
                )
            )
            let control2 = CGPoint(
                x: next.x - (following.x - current.x) / 6,
                y: clamped(
                    next.y - (following.y - current.y) / 6,
                    lowerBound: min(current.y, next.y),
                    upperBound: max(current.y, next.y)
                )
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
    }

    private func clamped(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }
}

private struct FinanceChartSelectionDetail: View {
    let points: [FinanceChartPoint]
    @Binding var selectedPoint: Int?
    let accent: LifeOSTokens.Hue
    let isDemo: Bool

    private var safeIndex: Int {
        min(max(selectedPoint ?? max(points.count - 1, 0), 0), max(points.count - 1, 0))
    }

    var body: some View {
        let point = points[safeIndex]
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent.base)
                .frame(width: 4, height: 35)
            VStack(alignment: .leading, spacing: 3) {
                Text(point.seriesTitle)
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                    .foregroundStyle(accent.glow)
                Text(point.valueText)
                    .font(LifeOSFont.spaceGrotesk(17, weight: .bold))
                    .monospacedDigit()
                    .numericTransition()
                Text("\(point.dateLabel) · \(isDemo ? "Demo · not live" : point.sourceDisclosure)")
                    .font(LifeOSFont.inter(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected \(point.seriesTitle) value")
        .accessibilityValue(point.accessibilityValue)
    }
}

// MARK: - Accounts and categories

private struct FinanceAccountsCard: View {
    let snapshot: FinanceDisplaySnapshot
    let onOpenConnections: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            FinanceSectionHeader(title: "Accounts", subtitle: "Where your money is held")
            if snapshot.accounts.isEmpty {
                FinanceEmptyModuleRow(
                    icon: .bankConnections,
                    title: "No accounts connected",
                    detail: "Connect a reviewed bank source before account balances appear.",
                    actionTitle: onOpenConnections == nil ? nil : "Manage connections",
                    action: onOpenConnections
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.accounts) { account in
                        FinanceAccountRow(account: account)
                        if account.id != snapshot.accounts.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-accounts")
    }
}

private struct FinanceAccountRow: View {
    let account: FinanceAccount

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(account.hue.base.opacity(0.17))
                LifeOSIcon(account.icon)
                    .foregroundStyle(account.hue.base)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                Text(account.detail)
                    .font(LifeOSFont.inter(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(account.balanceText)
                .font(LifeOSFont.spaceGrotesk(16, weight: .bold))
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(account.name)
        .accessibilityValue("\(account.balanceText). \(account.detail)")
    }
}

private struct FinanceCategoriesCard: View {
    let snapshot: FinanceDisplaySnapshot
    @Binding var selectedCategoryID: String?
    @Binding var selectedSourceID: String?
    let selectedRange: FinanceRange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FinanceSectionHeader(title: "By category", subtitle: "How spending is distributed")
            if snapshot.categories.isEmpty {
                FinanceEmptyModuleRow(
                    icon: .budget,
                    title: snapshot.hasTransactionSource ? "No categories in this period" : "Categories unavailable",
                    detail: snapshot.hasTransactionSource
                        ? "No spending transactions were supplied by the connected source."
                        : "Category totals appear once transaction history is connected."
                )
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        FinanceCategoryRing(categories: snapshot.categories)
                            .frame(width: 126, height: 126)
                        categoryLegend
                            .frame(minWidth: 176, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .center, spacing: 15) {
                        FinanceCategoryRing(categories: snapshot.categories)
                            .frame(width: 126, height: 126)
                        categoryLegend
                    }
                }

                if let selectedCategoryID,
                   let selectedCategory = snapshot.categories.first(where: { $0.id == selectedCategoryID }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(selectedCategory.name) transactions")
                                    .font(LifeOSFont.inter(12, weight: .semiBold))
                                let filteredTransactions = snapshot.filteredTransactions(
                                    category: selectedCategory.name,
                                    source: selectedSourceID,
                                    range: selectedRange
                                )
                                let filteredSpendCents = (try? FinanceTransactionTotals(transactions: filteredTransactions))?.spendingCents
                                let filteredSpendLabel = filteredSpendCents.map { FinanceCurrencyFormatter.euro(cents: $0) } ?? "Unavailable"
                                Text("\(filteredTransactions.count) · \(filteredSpendLabel) · \(selectedRange.accessibilityTitle)")
                                    .font(LifeOSFont.inter(10, weight: .medium))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                    .monospacedDigit()
                                    .numericTransition()
                            }
                            Spacer(minLength: 8)
                            if selectedCategory.contributingSources.count > 1 {
                                Menu {
                                    Button("All sources") { selectedSourceID = nil }
                                    ForEach(selectedCategory.contributingSources, id: \.self) { source in
                                        Button(FinanceSourceLabel.display(source)) { selectedSourceID = source }
                                    }
                                } label: {
                                    Text(selectedSourceID.map(FinanceSourceLabel.display) ?? "All sources")
                                        .font(LifeOSFont.inter(10, weight: .semiBold))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(Color.primary.opacity(0.07), in: Capsule())
                                }
                                .accessibilityLabel("Category source filter")
                                .accessibilityValue(selectedSourceID.map(FinanceSourceLabel.display) ?? "All sources")
                            }
                        }
                        let filteredTransactions = snapshot.filteredTransactions(
                            category: selectedCategory.name,
                            source: selectedSourceID,
                            range: selectedRange
                        )
                        if filteredTransactions.isEmpty {
                            FinanceEmptyModuleRow(
                                icon: .finance,
                                title: "No matching transactions",
                                detail: "Try another source or date range."
                            )
                        } else {
                            ForEach(filteredTransactions) { transaction in
                                FinanceTransactionRow(transaction: transaction)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-categories")
    }

    @ViewBuilder
    private var categoryLegend: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.categories) { category in
                Button {
                    selectCategory(category.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(category.hue.base)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name)
                                .font(LifeOSFont.inter(11, weight: .medium))
                            Text("\(category.transactionCount) transaction\(category.transactionCount == 1 ? "" : "s") · \(category.sourceDisclosure)")
                                .font(LifeOSFont.inter(9))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(category.amountText)
                                .font(LifeOSFont.inter(11, weight: .semiBold))
                                .monospacedDigit()
                            Text("\(Int(category.fraction * 100))%")
                                .font(LifeOSFont.inter(9))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .monospacedDigit()
                        }
                        if selectedCategoryID == category.id {
                            LifeOSIcon(.chevronRight)
                                .rotationEffect(.degrees(90))
                                .frame(width: 13, height: 13)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(category.name)
                .accessibilityValue("\(category.amountText), \(Int(category.fraction * 100)) percent, \(category.transactionCount) transactions, \(category.sourceDisclosure)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectCategory(_ categoryID: String) {
        let update = {
            if selectedCategoryID == categoryID {
                selectedCategoryID = nil
                selectedSourceID = nil
            } else {
                selectedCategoryID = categoryID
                selectedSourceID = nil
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(LifeOSMotion.snappy) { update() }
        }
    }
}

private struct FinanceCategoryRing: View {
    let categories: [FinanceCategory]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealProgress: Double = 0
    @State private var revealHaloOpacity: Double = 0

    private var categoryID: String {
        categories.map { "\($0.id):\($0.fraction)" }.joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(LifeOSTokens.Ring.track, lineWidth: 14)

            // Optional reveal halo. Exists only while the initial arc-draw-on is settling and
            // is fully removed afterward — no persistent glow at rest.
            if revealHaloOpacity > 0 {
                categoryArcs
                    .blur(radius: LifeOSTokens.Glow.blurRadius)
                    .opacity(revealHaloOpacity)
            }

            categoryArcs

            VStack(spacing: 1) {
                Text("Spend")
                    .font(LifeOSFont.inter(10, weight: .medium))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text("100%")
                    .font(LifeOSFont.spaceGrotesk(18, weight: .bold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending category ring")
        .accessibilityValue(categories.map { "\($0.name) \(Int($0.fraction * 100)) percent" }.joined(separator: ", "))
        .task(id: "\(categoryID)-\(reduceMotion)") {
            if reduceMotion {
                revealHaloOpacity = 0
                revealProgress = 1
                return
            }

            revealProgress = 0
            revealHaloOpacity = LifeOSTokens.Glow.opacity * 0.42
            withAnimation(LifeOSMotion.ringReveal) { revealProgress = 1 }

            do {
                try await Task.sleep(nanoseconds: 720_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                revealHaloOpacity = 0
            }
        }
    }

    /// The per-category arc segments, trimmed by `revealProgress` so the whole ring sweeps
    /// on together during the one-shot reveal rather than each segment appearing pre-drawn.
    private var categoryArcs: some View {
        ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
            let start = categories.prefix(index).reduce(0.0) { $0 + $1.fraction }
            let end = start + category.fraction
            let revealedEnd = start + (end - start) * revealProgress
            Circle()
                .trim(from: start + 0.006, to: max(revealedEnd - 0.006, start + 0.01))
                .stroke(
                    LifeOSTokens.Ring.progress(category.hue),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct FinanceTransactionRow: View {
    let transaction: FinanceTransactionObservation

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LifeOSTokens.success.opacity(0.14))
                .overlay(LifeOSIcon(.finance).foregroundStyle(LifeOSTokens.success).padding(5))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                    .font(LifeOSFont.inter(11, weight: .medium))
                Text("\(transaction.title) · \(transaction.account) · \(FinanceSourceLabel.display(transaction.source)) · \(FinanceFreshnessLabel.text(transaction.provenance.freshness))")
                    .font(LifeOSFont.inter(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceCurrencyFormatter.signedEuro(cents: transaction.signedAmountCents))
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                    .monospacedDigit()
                Text(FinanceDateFormatter.point(transaction.timestamp))
                    .font(LifeOSFont.inter(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(transaction.merchant)
        .accessibilityValue("\(FinanceCurrencyFormatter.signedEuro(cents: transaction.signedAmountCents)), \(transaction.account), \(FinanceSourceLabel.display(transaction.source)), \(FinanceFreshnessLabel.text(transaction.provenance.freshness))")
    }
}

private struct FinanceEmptyModuleRow: View {
    let icon: LifeOSIconName
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: LifeOSIconName,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LifeOSIcon(icon)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 21, height: 21)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LifeOSFont.inter(13, weight: .semiBold))
                    Text(detail)
                        .font(LifeOSFont.inter(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .buttonStyle(.bordered)
                    .tint(LifeOSTokens.accent)
                    .accessibilityIdentifier("finance-open-connections")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

// MARK: - Range controls and reusable chrome

private struct FinanceRangePills: View {
    @Binding var selection: FinanceRange
    let availableRanges: Set<FinanceRange>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 3) {
            ForEach(FinanceRange.allCases, id: \.self) { range in
                let enabled = availableRanges.contains(range)
                Button {
                    guard enabled else { return }
                    if reduceMotion {
                        selection = range
                    } else {
                        withAnimation(LifeOSMotion.snappy) { selection = range }
                    }
                } label: {
                    Text(range.title)
                        .font(LifeOSFont.inter(11, weight: selection == range ? .semiBold : .medium))
                        .foregroundStyle(selection == range ? .primary : (enabled ? LifeOSTokens.tertiaryText : LifeOSTokens.tertiaryText.opacity(0.42)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selection == range {
                                Capsule()
                                    .fill(LifeOSTokens.surface)
                                    .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                                    .matchedGeometryEffect(id: "finance.range.highlight", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(range.accessibilityTitle)
                .accessibilityValue(enabled ? (selection == range ? "Selected" : "Available") : "Needs more history")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finance date range")
        .accessibilityValue(selection.accessibilityTitle)
    }
}

private struct FinanceSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(LifeOSFont.header(18))
            Text(subtitle)
                .font(LifeOSFont.inter(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }
}

private struct FinanceMiniSparkline: View {
    let points: [FinanceChartPoint]
    let hue: LifeOSTokens.Hue

    var body: some View {
        GeometryReader { proxy in
                let geometry = FinanceChartGeometry(points: points, size: proxy.size)
            geometry.smoothPath()
                .stroke(hue.base, style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Display models

private struct FinanceDisplaySnapshot {
    let isDemo: Bool
    let transactions: [FinanceTransactionObservation]
    let hasTransactionSource: Bool
    let transactionTotalsAvailable: Bool
    let netWorth: FinanceDisplayMetric
    let spent: FinanceDisplayMetric
    let spendBudget: FinanceDisplayMetric
    let cashFlow: FinanceDisplayMetric
    let income: FinanceDisplayMetric
    let fixedCosts: FinanceDisplayMetric
    let saved: FinanceDisplayMetric
    let savingsGoal: FinanceDisplayMetric
    let accounts: [FinanceAccount]
    let categories: [FinanceCategory]
    let netWorthPoints: [FinanceChartPoint]
    let spendPoints: [FinanceChartPoint]
    let incomePoints: [FinanceChartPoint]
    let cashFlowPoints: [FinanceChartPoint]
    let updatedLabel: String
    let sourceDisclosure: String
    let overallFreshness: FinancePayloadFreshness

    init(
        summary: FinanceSummary?,
        transactions suppliedTransactions: [FinanceTransactionObservation]?,
        usesVisualFixtures: Bool
    ) {
        if usesVisualFixtures {
            self = .demo
            return
        }

        let transactionSourceAvailable = suppliedTransactions.map { !$0.isEmpty }
            ?? (summary?.transactions?.availability == .observed
                && !(summary?.transactions?.transactions ?? []).isEmpty)
        let transactionRows = suppliedTransactions ?? summary?.transactions?.transactions ?? []
        let transactionTotals = transactionSourceAvailable
            ? try? FinanceTransactionTotals(transactions: transactionRows)
            : nil
        let accountObservations = Self.usableObservedAccounts(from: summary)
        let observed = summary != nil && [
            summary?.monthlyIncomeCents,
            summary?.fixedCostsCents,
            summary?.spentCents,
            summary?.savedCents
        ].contains(where: { $0 != nil }) || transactionSourceAvailable
            || !accountObservations.isEmpty

        isDemo = false
        transactions = transactionRows
        hasTransactionSource = transactionSourceAvailable
        transactionTotalsAvailable = transactionTotals != nil
        spent = transactionTotals.map {
            FinanceDisplayMetric(cents: $0.spendingCents, detail: "\($0.transactionCount) transactions")
        } ?? FinanceDisplayMetric(cents: summary?.spentCents, detail: summary == nil ? "Not connected" : "Observed total")
        spendBudget = FinanceDisplayMetric(cents: summary?.spendableBudgetCents, detail: summary == nil ? "Not connected" : "Available budget")
        cashFlow = transactionTotals.map {
            FinanceDisplayMetric(
                cents: $0.netCashFlowCents,
                detail: "Income \(FinanceCurrencyFormatter.euro(cents: $0.incomeCents)) · Spend \(FinanceCurrencyFormatter.euro(cents: $0.spendingCents))"
            )
        } ?? .unavailable(summary == nil ? "Not connected" : "Not available")
        income = transactionTotals.map {
            FinanceDisplayMetric(
                cents: $0.incomeCents,
                detail: "\(transactionRows.filter(\.isIncome).count) deposits"
            )
        } ?? FinanceDisplayMetric(cents: summary?.monthlyIncomeCents, detail: summary == nil ? "Not connected" : "Observed total")
        fixedCosts = FinanceDisplayMetric(cents: summary?.fixedCostsCents, detail: summary == nil ? "Not connected" : "Observed total")
        saved = FinanceDisplayMetric(cents: summary?.savedCents, detail: summary == nil ? "Not connected" : "Observed total")
        savingsGoal = FinanceDisplayMetric(cents: summary?.savingsGoalCents, detail: summary == nil ? "Not connected" : "Savings goal")
        accounts = accountObservations.map { observation in
            FinanceAccount(
                id: observation.id,
                name: observation.name,
                detail: observation.detail,
                balanceCents: observation.balanceCents,
                icon: .bankConnections,
                hue: observation.source.localizedCaseInsensitiveContains("revolut") ? .blue : .teal
            )
        }
        netWorth = Self.overflowCheckedAccountTotal(accountObservations).map {
            FinanceDisplayMetric(cents: $0, detail: "Observed account balances")
        } ?? .unavailable("Not available")
        categories = transactionTotals?.categoryObservations.map(FinanceCategory.init) ?? []
        netWorthPoints = []
        spendPoints = []
        incomePoints = transactionTotals.flatMap { _ in
            Self.transactionPoints(transactionRows, title: "Income", series: .income)
        } ?? []
        cashFlowPoints = transactionTotals.flatMap { _ in
            Self.transactionPoints(transactionRows, title: "Cash flow", series: .cashFlow)
        } ?? []
        overallFreshness = Self.overallFreshness(
            summary: summary,
            transactionSourceAvailable: transactionSourceAvailable,
            transactionRows: transactionRows,
            accountObservations: accountObservations
        )
        updatedLabel = observed ? summary.map { FinanceDateFormatter.short($0.generatedAt) } ?? "Not available" : "Not available"
        let sourceIDs = Array(Set(transactionRows.map(\.source) + accountObservations.map(\.source))).sorted()
        if !sourceIDs.isEmpty {
            sourceDisclosure = "\(FinanceSourceLabel.join(sourceIDs)) · \(FinanceFreshnessLabel.text(overallFreshness)) · Updated \(updatedLabel)"
        } else if let metric = summary?.spent {
            sourceDisclosure = "\(FinanceSourceLabel.display(metric.provenance.source)) · \(FinanceFreshnessLabel.text(metric.provenance.freshness)) · Updated \(updatedLabel)"
        } else {
            sourceDisclosure = "No authorized source · Not available"
        }
    }

    private static let maximumFinanceCents = 9_007_199_254_740_991
    private static let financeStaleAfter: TimeInterval = 15 * 60

    private static func usableObservedAccounts(from summary: FinanceSummary?) -> [FinanceAccountObservation] {
        guard let snapshot = summary?.accounts,
              snapshot.availability == .observed,
              isUsableObservedProvenance(snapshot.provenance),
              let accounts = snapshot.accounts,
              !accounts.isEmpty else {
            return []
        }
        return accounts.filter { isUsableObservedProvenance($0.provenance) }
    }

    private static func overflowCheckedAccountTotal(_ accounts: [FinanceAccountObservation]) -> Int? {
        guard !accounts.isEmpty else { return nil }
        var total = 0
        for account in accounts {
            let (next, overflowed) = total.addingReportingOverflow(account.balanceCents)
            guard !overflowed,
                  next >= -maximumFinanceCents,
                  next <= maximumFinanceCents else {
                return nil
            }
            total = next
        }
        return total
    }

    private static func isUsableObservedProvenance(_ provenance: FinancePayloadProvenance) -> Bool {
        provenance.quality == .observed
            && provenance.freshness != .unknown
            && (provenance.connectorState == .healthy || provenance.connectorState == .refreshDue)
    }

    private static func overallFreshness(
        summary: FinanceSummary?,
        transactionSourceAvailable: Bool,
        transactionRows: [FinanceTransactionObservation],
        accountObservations: [FinanceAccountObservation]
    ) -> FinancePayloadFreshness {
        if let summary,
           Date.now.timeIntervalSince(summary.generatedAt) >= financeStaleAfter {
            return .stale
        }
        var provenances: [FinancePayloadProvenance] = []
        if transactionSourceAvailable {
            if let transactionProvenance = summary?.transactions?.provenance {
                provenances.append(transactionProvenance)
            }
            provenances.append(contentsOf: transactionRows.map(\.provenance))
        }
        if !accountObservations.isEmpty {
            if let accountProvenance = summary?.accounts?.provenance {
                provenances.append(accountProvenance)
            }
            provenances.append(contentsOf: accountObservations.map(\.provenance))
        }
        if let summary {
            let metrics = [
                summary.monthlyIncome,
                summary.fixedCosts,
                summary.discretionaryBuffer,
                summary.spent,
                summary.savingsGoal,
                summary.saved
            ]
            provenances.append(contentsOf: metrics.compactMap { metric in
                guard metric.availability == .observed,
                      metric.amountCents != nil,
                      isUsableObservedProvenance(metric.provenance) else { return nil }
                return metric.provenance
            })
        }
        return FinanceFreshnessLabel.value(for: provenances)
    }

    private init(
        isDemo: Bool,
        transactions: [FinanceTransactionObservation],
        hasTransactionSource: Bool,
        transactionTotalsAvailable: Bool,
        netWorth: FinanceDisplayMetric,
        spent: FinanceDisplayMetric,
        spendBudget: FinanceDisplayMetric,
        cashFlow: FinanceDisplayMetric,
        income: FinanceDisplayMetric,
        fixedCosts: FinanceDisplayMetric,
        saved: FinanceDisplayMetric,
        savingsGoal: FinanceDisplayMetric,
        accounts: [FinanceAccount],
        categories: [FinanceCategory],
        netWorthPoints: [FinanceChartPoint],
        spendPoints: [FinanceChartPoint],
        incomePoints: [FinanceChartPoint],
        cashFlowPoints: [FinanceChartPoint],
        updatedLabel: String,
        sourceDisclosure: String,
        overallFreshness: FinancePayloadFreshness
    ) {
        self.isDemo = isDemo
        self.transactions = transactions
        self.hasTransactionSource = hasTransactionSource
        self.transactionTotalsAvailable = transactionTotalsAvailable
        self.netWorth = netWorth
        self.spent = spent
        self.spendBudget = spendBudget
        self.cashFlow = cashFlow
        self.income = income
        self.fixedCosts = fixedCosts
        self.saved = saved
        self.savingsGoal = savingsGoal
        self.accounts = accounts
        self.categories = categories
        self.netWorthPoints = netWorthPoints
        self.spendPoints = spendPoints
        self.incomePoints = incomePoints
        self.cashFlowPoints = cashFlowPoints
        self.updatedLabel = updatedLabel
        self.sourceDisclosure = sourceDisclosure
        self.overallFreshness = overallFreshness
    }

    static let demo: FinanceDisplaySnapshot = {
        let now = Date.now
        let transactions = Self.demoTransactions(now: now)
        guard let totals = try? FinanceTransactionTotals(transactions: transactions) else {
            return FinanceDisplaySnapshot(
                isDemo: true,
                transactions: [],
                hasTransactionSource: false,
                transactionTotalsAvailable: false,
                netWorth: .unavailable("Not available"),
                spent: .unavailable("Not available"),
                spendBudget: .unavailable("Not available"),
                cashFlow: .unavailable("Not available"),
                income: .unavailable("Not available"),
                fixedCosts: .unavailable("Not available"),
                saved: .unavailable("Not available"),
                savingsGoal: .unavailable("Not available"),
                accounts: [],
                categories: [],
                netWorthPoints: [],
                spendPoints: [],
                incomePoints: [],
                cashFlowPoints: [],
                updatedLabel: "Not available",
                sourceDisclosure: "Demo fixture · aggregate unavailable",
                overallFreshness: .unknown
            )
        }
        let calendar = Calendar.current
        let dayStarts = (0..<12).compactMap { calendar.date(byAdding: .day, value: -11 + $0, to: now) }
        let netValues = [772_000, 782_000, 779_000, 798_000, 804_000, 811_000, 818_000, 826_000, 831_000, 842_000, 850_000, 856_000]
        let points: ([Int], String) -> [FinanceChartPoint] = { values, title in
            zip(dayStarts, values).map { date, value in
                FinanceChartPoint(date: date, value: value, seriesTitle: title)
            }
        }
        let accounts = [
            FinanceAccount(name: "Revolut Personal", detail: "Main account · synced today", balanceCents: 562_000, icon: .finance, hue: .blue),
            FinanceAccount(name: "Revolut Savings", detail: "Vault · synced today", balanceCents: 244_000, icon: .savings, hue: .violet),
            FinanceAccount(name: "Sparkasse", detail: "Checking · synced today", balanceCents: 50_000, icon: .bankConnections, hue: .teal)
        ]
        let accountBalanceCents = accounts.reduce(0) { $0 + $1.balanceCents }
        return FinanceDisplaySnapshot(
            isDemo: true,
            transactions: transactions,
            hasTransactionSource: true,
            transactionTotalsAvailable: true,
            netWorth: FinanceDisplayMetric(cents: accountBalanceCents, detail: "Observed account balances"),
            spent: FinanceDisplayMetric(cents: totals.spendingCents, detail: "\(totals.transactionCount) transactions", progress: 0.64),
            spendBudget: FinanceDisplayMetric(cents: 200_000, detail: "Monthly budget"),
            cashFlow: FinanceDisplayMetric(
                cents: totals.netCashFlowCents,
                detail: "Income \(FinanceCurrencyFormatter.euro(cents: totals.incomeCents)) · Spend \(FinanceCurrencyFormatter.euro(cents: totals.spendingCents))",
                progress: 0.72
            ),
            income: FinanceDisplayMetric(cents: totals.incomeCents, detail: "\(transactions.filter(\.isIncome).count) deposits"),
            fixedCosts: FinanceDisplayMetric(cents: 182_000, detail: "Recurring"),
            saved: FinanceDisplayMetric(cents: 64_000, detail: "This month", progress: 0.64),
            savingsGoal: FinanceDisplayMetric(cents: 100_000, detail: "Monthly goal"),
            accounts: accounts,
            categories: totals.categoryObservations.map(FinanceCategory.init),
            netWorthPoints: points(netValues, "Net worth"),
            spendPoints: Self.transactionPoints(transactions, title: "Spend", series: .spending) ?? [],
            incomePoints: Self.transactionPoints(transactions, title: "Income", series: .income) ?? [],
            cashFlowPoints: Self.transactionPoints(transactions, title: "Cash flow", series: .cashFlow) ?? [],
            updatedLabel: "Just now",
            sourceDisclosure: "Demo fixture · not live · Revolut Personal · Fresh",
            overallFreshness: .fresh
        )
    }()

    private static func demoTransactions(now: Date) -> [FinanceTransactionObservation] {
        let calendar = Calendar.current
        let observedAt = now
        let provenance = FinancePayloadProvenance(
            source: "revolut_personal-demo-fixture",
            observedAt: observedAt,
            freshness: .fresh,
            quality: .observed,
            connectorState: .healthy
        )
        func date(_ day: Int) -> Date {
            calendar.date(byAdding: .day, value: day - 11, to: now) ?? now
        }
        func row(
            _ id: String,
            _ merchant: String,
            _ title: String,
            _ cents: Int,
            _ day: Int,
            _ category: String
        ) -> FinanceTransactionObservation {
            FinanceTransactionObservation(
                id: id,
                merchant: merchant,
                title: title,
                signedAmountCents: cents,
                timestamp: date(day),
                account: "Revolut Personal",
                source: "revolut_personal",
                category: category,
                provenance: provenance
            )
        }
        return [
            row("salary-1", "Salary", "Monthly salary", 180_000, 0, "Income"),
            row("home-1", "Rent", "Apartment", -20_000, 0, "Home"),
            row("food-1", "REWE", "Groceries", -5_000, 1, "Food"),
            row("transport-1", "BVG", "Transit", -8_000, 2, "Transport"),
            row("salary-2", "Salary", "Freelance deposit", 104_000, 3, "Income"),
            row("lifestyle-1", "Gym", "Membership", -7_000, 3, "Lifestyle"),
            row("other-1", "Apple", "Hardware", -4_000, 4, "Other"),
            row("home-2", "IKEA", "Household", -22_000, 5, "Home"),
            row("food-2", "REWE", "Groceries", -12_000, 6, "Food"),
            row("transport-2", "DB", "Train", -6_000, 7, "Transport"),
            row("lifestyle-2", "Restaurant", "Dinner", -12_000, 8, "Lifestyle"),
            row("salary-3", "Salary", "Side project", 40_000, 9, "Income"),
            row("other-2", "Amazon", "Supplies", -11_400, 9, "Other"),
            row("food-3", "REWE", "Groceries", -13_000, 10, "Food"),
            row("transport-3", "BVG", "Transit", -8_000, 11, "Transport")
        ]
    }

    private static func transactionPoints(
        _ transactions: [FinanceTransactionObservation],
        title: String,
        series: FinanceTransactionSeries
    ) -> [FinanceChartPoint]? {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions) { calendar.startOfDay(for: $0.timestamp) }
        var points: [FinanceChartPoint] = []
        points.reserveCapacity(grouped.count)
        for date in grouped.keys.sorted() {
            let rows = grouped[date, default: []]
            guard let totals = try? FinanceTransactionTotals(transactions: rows) else {
                return nil
            }
            let value: Int
            switch series {
            case .income:
                value = totals.incomeCents
            case .spending:
                value = totals.spendingCents
            case .cashFlow:
                value = totals.netCashFlowCents
            }
            points.append(FinanceChartPoint(
                date: date,
                value: value,
                seriesTitle: title,
                sourceLabel: FinanceSourceLabel.join(Array(Set(rows.map(\.source))).sorted()),
                freshness: FinanceFreshnessLabel.value(for: rows)
            ))
        }
        return points
    }

    func filteredTransactions(
        category: String,
        source: String?,
        range: FinanceRange
    ) -> [FinanceTransactionObservation] {
        guard let latest = transactions.map(\.timestamp).max() else { return [] }
        let calendar = Calendar.current
        let start: Date?
        switch range {
        case .week: start = calendar.date(byAdding: .day, value: -7, to: latest)
        case .month: start = calendar.date(byAdding: .day, value: -31, to: latest)
        case .halfYear: start = calendar.date(byAdding: .day, value: -180, to: latest)
        case .year: start = calendar.date(byAdding: .day, value: -365, to: latest)
        case .max: start = nil
        }
        return FinanceTransactionFilter(
            category: category,
            source: source,
            startDate: start,
            endDate: latest,
            spendingOnly: true
        ).applying(to: transactions)
    }

    var spendProgress: Double? {
        guard let spent = spent.cents, let budget = spendBudget.cents, budget > 0 else { return nil }
        return min(Double(spent) / Double(budget), 1)
    }

    var savingsProgress: Double? {
        guard let saved = saved.cents, let goal = savingsGoal.cents, goal > 0 else { return nil }
        return min(Double(saved) / Double(goal), 1)
    }

    var statusLabel: String {
        if isDemo { return "Demo · not live" }
        guard hasObservedValue else { return "Not connected" }
        return overallFreshness == .stale ? "Stale" : "Observed"
    }
    var statusColor: Color {
        if isDemo { return LifeOSTokens.warning }
        guard hasObservedValue else { return LifeOSTokens.tertiaryText }
        return overallFreshness == .stale ? LifeOSTokens.warning : LifeOSTokens.success
    }
    var accessibilityStatus: String { statusLabel }
    var hasObservedValue: Bool {
        hasTransactionSource || [netWorth, spent, income, fixedCosts, saved].contains(where: { !$0.isUnavailable })
    }

    func points(for detail: FinanceDetail, range: FinanceRange) -> [FinanceChartPoint] {
        let source: [FinanceChartPoint]
        switch detail {
        case .spend: source = spendPoints
        case .income: source = incomePoints
        case .cashFlow: source = cashFlowPoints
        case .netWorth: source = netWorthPoints
        }
        guard source.count > 1 else { return [] }
        switch range {
        case .week: return hasDistinctHistory(source, days: 7) ? Array(source.suffix(min(source.count, 7))) : []
        case .month: return source
        case .halfYear: return hasDistinctHistory(source, days: 180) ? source : []
        case .year: return hasDistinctHistory(source, days: 365) ? source : []
        case .max: return hasDistinctHistory(source, days: 365) ? source : []
        }
    }

    func availableRanges(for detail: FinanceDetail) -> Set<FinanceRange> {
        Set(FinanceRange.allCases.filter { !points(for: detail, range: $0).isEmpty })
    }

    private func hasDistinctHistory(_ points: [FinanceChartPoint], days: Int) -> Bool {
        guard let first = points.first?.date, let last = points.last?.date else { return false }
        return last.timeIntervalSince(first) >= TimeInterval(days * 24 * 60 * 60)
    }
}

private struct FinanceDisplayMetric {
    let cents: Int?
    let detail: String
    let progress: Double?

    init(cents: Int?, detail: String, progress: Double? = nil) {
        self.cents = cents
        self.detail = detail
        self.progress = progress
    }

    static func unavailable(_ detail: String) -> FinanceDisplayMetric {
        FinanceDisplayMetric(cents: nil, detail: detail)
    }

    var isUnavailable: Bool { cents == nil }
    var valueText: String { FinanceCurrencyFormatter.euro(cents: cents) }
    var accessibilityValue: String { isUnavailable ? "not available" : valueText }
}

private struct FinanceChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Int
    let seriesTitle: String
    let sourceLabel: String
    let freshness: FinancePayloadFreshness

    init(
        date: Date,
        value: Int,
        seriesTitle: String,
        sourceLabel: String = "Not available",
        freshness: FinancePayloadFreshness = .unknown
    ) {
        self.date = date
        self.value = value
        self.seriesTitle = seriesTitle
        self.sourceLabel = sourceLabel
        self.freshness = freshness
    }

    var valueText: String { FinanceCurrencyFormatter.euro(cents: value) }
    var dateLabel: String { FinanceDateFormatter.point(date) }
    var accessibilityValue: String { "\(valueText), \(dateLabel), \(sourceDisclosure)" }
    var sourceDisclosure: String { "\(sourceLabel) · \(FinanceFreshnessLabel.text(freshness))" }
}

private struct FinanceAccount: Identifiable {
    let id: String
    let name: String
    let detail: String
    let balanceCents: Int
    let icon: LifeOSIconName
    let hue: LifeOSTokens.Hue

    init(
        id: String = UUID().uuidString,
        name: String,
        detail: String,
        balanceCents: Int,
        icon: LifeOSIconName,
        hue: LifeOSTokens.Hue
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.balanceCents = balanceCents
        self.icon = icon
        self.hue = hue
    }

    var balanceText: String { FinanceCurrencyFormatter.euro(cents: balanceCents) }
}

private struct FinanceCategory: Identifiable {
    let id: String
    let name: String
    let amountCents: Int
    let transactionCount: Int
    let fraction: Double
    let hue: LifeOSTokens.Hue
    let contributingSources: [String]
    let provenanceFreshness: FinancePayloadFreshness

    init(_ observation: FinanceCategoryObservation) {
        id = observation.id
        name = observation.name
        amountCents = observation.amountCents
        transactionCount = observation.transactionCount
        fraction = observation.fraction
        contributingSources = observation.contributingSources
        provenanceFreshness = observation.provenance.freshness
        switch observation.name.lowercased() {
        case "home", "rent": hue = .violet
        case "food", "groceries": hue = .orange
        case "transport": hue = .blue
        case "lifestyle", "entertainment": hue = .pink
        default: hue = .teal
        }
    }

    var amountText: String { FinanceCurrencyFormatter.euro(cents: amountCents) }

    var sourceDisclosure: String {
        "\(FinanceSourceLabel.join(contributingSources)) · \(FinanceFreshnessLabel.text(provenanceFreshness))"
    }
}

private enum FinanceDetail: String, CaseIterable, Hashable {
    case spend
    case income
    case cashFlow
    case netWorth

    var title: String {
        switch self {
        case .spend: "Spend"
        case .income: "Income"
        case .cashFlow: "Cash flow"
        case .netWorth: "Net worth"
        }
    }
}

private enum FinanceTransactionSeries {
    case income
    case spending
    case cashFlow
}

private enum FinanceRange: String, CaseIterable, Hashable {
    case week
    case month
    case halfYear
    case year
    case max

    var title: String {
        switch self {
        case .week: "1W"
        case .month: "1M"
        case .halfYear: "6M"
        case .year: "1Y"
        case .max: "Max"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .week: "One week"
        case .month: "One month"
        case .halfYear: "Six months"
        case .year: "One year"
        case .max: "Max"
        }
    }
}

private enum FinanceCurrencyFormatter {
    static func euro(cents: Int?) -> String {
        guard let cents else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "€\(cents / 100)"
    }

    static func signedEuro(cents: Int) -> String {
        let sign = cents > 0 ? "+" : ""
        return "\(sign)\(euro(cents: cents))"
    }
}

private enum FinanceSourceLabel {
    static func display(_ source: String) -> String {
        switch source {
        case "sparkasse_leipzig": "Sparkasse Leipzig"
        case "revolut_personal": "Revolut Personal"
        case "revolut_business": "Revolut Business"
        case "trade_republic": "Trade Republic"
        case "manual": "Manual import"
        case "derived-transaction-rollup": "Derived rollup"
        case "no-authorized-finance-source": "No authorized source"
        default:
            source
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    static func join(_ sources: [String]) -> String {
        let labels = sources.map(display)
        if labels.isEmpty { return "Not available" }
        return labels.joined(separator: " + ")
    }
}

private enum FinanceFreshnessLabel {
    static func text(_ freshness: FinancePayloadFreshness) -> String {
        switch freshness {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .unknown: "Freshness unknown"
        }
    }

    static func value(for rows: [FinanceTransactionObservation]) -> FinancePayloadFreshness {
        guard !rows.isEmpty else { return .unknown }
        if rows.contains(where: { $0.provenance.freshness == .unknown }) { return .unknown }
        if rows.contains(where: { $0.provenance.freshness == .stale || $0.provenance.connectorState == .refreshDue }) {
            return .stale
        }
        return .fresh
    }

    static func value(for provenances: [FinancePayloadProvenance]) -> FinancePayloadFreshness {
        guard !provenances.isEmpty else { return .unknown }
        if provenances.contains(where: {
            $0.quality != .observed || $0.freshness == .unknown
        }) {
            return .unknown
        }
        if provenances.contains(where: {
            $0.freshness == .stale || $0.connectorState == .refreshDue
        }) {
            return .stale
        }
        return .fresh
    }

    static func text(for rows: [FinanceTransactionObservation]) -> String {
        text(value(for: rows))
    }
}

private enum FinanceDateFormatter {
    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    static func point(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }
}
