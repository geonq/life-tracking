import Foundation
import SwiftUI

// MARK: - Chart mode (RF-08)
//
// A detail chart (spend/income) can be viewed as a line, a weekly bar chart,
// or a category ring. This is a display preference only; the scene-owned
// Finance presentation state decides when a point selection is still valid.

/// `public` because `FinanceView`'s public initializer exposes an
/// `initialChartMode` deep-link/testing seam (mirroring `initialDetail`).
public enum FinanceChartMode: String, CaseIterable, Identifiable, Hashable {
    case line
    case bar
    case ring

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "Line"
        case .bar: "Bar"
        case .ring: "Ring"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .line: "Line chart"
        case .bar: "Weekly bar chart"
        case .ring: "Category ring"
        }
    }
}

/// Uses the shared selector recipe so range and chart-mode controls have the
/// same sizing, hover, focus, unavailable, and menu fallback behavior.
struct FinanceChartModeSwitcher: View {
    @Binding var selection: FinanceChartMode

    var body: some View {
        LifeOSSelector(
            options: FinanceChartMode.allCases.map {
                LifeOSSelectorOption(id: $0, title: $0.title)
            },
            selection: $selection
        )
        .accessibilityLabel("Chart mode")
        .accessibilityValue(selection.accessibilityTitle)
    }
}

// MARK: - Selection codec (RF-14)
//
// Both `FinanceChartPoint.id` (line mode) and the bar-mode selection id below
// are encoded as "<seriesTitle>|<timeIntervalSinceReferenceDate>". A renderer
// resolves an inspection only by exact id; a mode or model transition must not
// snap it to a different observation.

enum FinanceChartSelectionCodec {
    static func id(seriesID: String, date: Date) -> String {
        "\(seriesID)|\(date.timeIntervalSinceReferenceDate)"
    }

    static func date(fromID id: String) -> Date? {
        guard let last = id.split(separator: "|").last,
              let interval = TimeInterval(last) else { return nil }
        return Date(timeIntervalSinceReferenceDate: interval)
    }
}

// MARK: - Bar chart rendering (RF-08)
//
// Pure rendering over `Shared/LifeOSBarChart.swift`'s already-computed
// buckets. This file draws; it does not bucket, normalize, or select — that
// logic lives in `LifeOSBarChartKit` and is not duplicated here.

struct FinanceBarChartView: View {
    /// A `Capsule` has no intrinsic size — without an explicit width it fills
    /// whatever width its column offers, which (with only a handful of weekly
    /// columns in a wide window) renders as a giant blob rather than a bar.
    fileprivate static let barWidth: CGFloat = 28

    let buckets: [LifeOSBarNormalizedBucket]
    let seriesID: String
    @Binding var selectedBucketID: String?
    let isDemo: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }
    @State private var drawn: CGFloat = 0
    @State private var hasPresented = false

    var body: some View {
        GeometryReader { proxy in
            let trackHeight = max(proxy.size.height - 20, 40)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(buckets) { bucket in
                    barColumn(bucket: bucket, trackHeight: trackHeight)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            // Motion §C: the reveal is a left-to-right WIPE (a mask), never a
            // vertical grow — a bar growing from zero height would display a
            // false (too-low) number mid-animation for every frame before it
            // finishes, exactly what §C forbids.
            .mask(alignment: .leading) {
                Rectangle().frame(width: proxy.size.width * (reduceMotion ? 1 : drawn))
            }
        }
        .frame(height: 220)
        .task {
            let reveal = LifeOSChartMotionPolicy.shouldReveal(hasPresented: hasPresented, interacting: selectedBucketID != nil, reduceMotion: reduceMotion)
            hasPresented = true
            guard reveal else {
                LifeOSMotion.withoutAnimation { drawn = 1 }
                return
            }
            withAnimation(LifeOSMotion.chartDraw) { drawn = 1 }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { LifeOSMotion.withoutAnimation { drawn = 1 } }
        }
    }

    @ViewBuilder
    private func barColumn(bucket: LifeOSBarNormalizedBucket, trackHeight: CGFloat) -> some View {
        let id = FinanceChartSelectionCodec.id(seriesID: seriesID, date: bucket.weekStart)
        let isSelected = selectedBucketID == id

        Button {
            if selectedBucketID != id {
                ScrubBubble<EmptyView>.snapHaptic()
            }
            LifeOSMotion.withoutAnimation {
                drawn = 1
                selectedBucketID = id
            }
        } label: {
            Group {
                if bucket.isGap {
                    // Honesty contract: no coverage here at all. A visible, but
                    // clearly non-value, dashed outline slot — never nothing
                    // (which would look identical to a hidden bar) and never a
                    // filled bar (which would look like an observed zero).
                    Capsule()
                        .stroke(LifeOSTokens.tertiaryText.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: FinanceBarChartView.barWidth, height: max(trackHeight * 0.16, 12))
                } else {
                    let barHeight = max(CGFloat(bucket.height ?? 0) * trackHeight, bucket.totalCents == 0 ? 2 : 3)
                    Capsule()
                        .fill(LifeOSTokens.Series.observed.opacity(bucket.isComplete ? 1 : 0.5))
                        .frame(width: FinanceBarChartView.barWidth, height: barHeight)
                        .overlay {
                            // The still-accumulating current week reads as
                            // partial (dashed outline), never as a genuine decline.
                            if !bucket.isComplete {
                                Capsule()
                                    .stroke(LifeOSTokens.Series.observed, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                    .frame(width: FinanceBarChartView.barWidth, height: barHeight)
                            }
                        }
                }
            }
            .overlay {
                if isSelected {
                    Capsule().stroke(LifeOSTokens.primaryText, lineWidth: 1.5)
                        .padding(-2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: trackHeight, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(FinanceMotionControlStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(accessibilityLabel(for: bucket))
        .accessibilityValue(accessibilityValue(for: bucket))
    }

    private func accessibilityLabel(for bucket: LifeOSBarNormalizedBucket) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Week of \(formatter.string(from: bucket.weekStart))"
    }

    private func accessibilityValue(for bucket: LifeOSBarNormalizedBucket) -> String {
        guard let totalCents = bucket.totalCents else { return "No data" }
        let amount = FinanceCurrencyFormatter.euro(cents: totalCents)
        return bucket.isComplete ? amount : "\(amount), still accumulating"
    }
}

/// Mirrors `FinanceChartSelectionDetail`'s look for bar mode. Reads the raw
/// (un-normalized) buckets so it can distinguish an honest zero from a gap by
/// `totalCents == nil` — the exact same check the renderer above uses.
struct FinanceBarSelectionDetail: View {
    let buckets: [LifeOSBarBucket]
    let seriesTitle: String
    @Binding var selectedBucketID: String?
    let isDemo: Bool

    private var orderedBuckets: [LifeOSBarBucket] {
        // `FinanceDisplaySnapshot.barBuckets` is emitted chronologically by
        // `LifeOSBarChartKit.weeklyBuckets`; keep selection linear here.
        buckets
    }

    private var bucket: LifeOSBarBucket? {
        guard let selectedBucketID else { return nil }
        return orderedBuckets.first(where: {
            FinanceChartSelectionCodec.id(seriesID: seriesTitle, date: $0.weekStart) == selectedBucketID
        })
    }

    var body: some View {
        if let bucket {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(bucket.isUnavailable ? LifeOSTokens.tertiaryText.opacity(0.4) : LifeOSTokens.Series.observed)
                    .frame(width: 4, height: 35)
                VStack(alignment: .leading, spacing: 3) {
                    Text(seriesTitle)
                        .lifeOSTypography(.metadata, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    if bucket.isUnavailable {
                        Text("No data")
                            .lifeOSTypography(.body, weight: .semibold)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    } else {
                        Text(FinanceCurrencyFormatter.euro(cents: bucket.totalCents))
                            .lifeOSTypography(.body, weight: .semibold).monospacedDigit()
                            .numericTransition()
                    }
                    Text("\(weekRangeLabel(bucket)) · \(weekStatusLabel(bucket))")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected \(seriesTitle) week")
            .accessibilityValue(
                bucket.isUnavailable
                    ? "No data, \(weekRangeLabel(bucket))"
                    : "\(FinanceCurrencyFormatter.euro(cents: bucket.totalCents)), \(weekRangeLabel(bucket)), \(weekStatusLabel(bucket))"
            )
        }
    }

    /// Whether the data is a demo fixture and whether the week is finished are
    /// independent facts, so both are stated. Returning early on `isDemo` hid
    /// the coverage label exactly where it matters most: the current week reads
    /// as a plain "0 €" with nothing marking it as still filling up.
    private func weekStatusLabel(_ bucket: LifeOSBarBucket) -> String {
        var parts: [String] = []
        if bucket.isUnavailable {
            parts.append("Outside observed history")
        } else {
            parts.append(bucket.isComplete ? "Full week" : "Still accumulating")
        }
        if isDemo { parts.append("Demo · not live") }
        return parts.joined(separator: " · ")
    }

    private func weekRangeLabel(_ bucket: LifeOSBarBucket) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let end = bucket.weekEnd.addingTimeInterval(-1)
        return "\(formatter.string(from: bucket.weekStart)) – \(formatter.string(from: end))"
    }
}

/// Layout-neutral feedback for existing compact chart controls.
struct FinanceMotionControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var systemReduced
        @Environment(\.lifeOSReduceMotion) private var requestedReduced
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background((enabled && (hovered || focused) ? LifeOSTokens.primaryText.opacity(0.06) : .clear), in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.5)
                .overlay { if enabled && focused { Capsule().stroke(LifeOSTokens.accent, lineWidth: 1) } }
                .onHover { hovered = $0 }
                .onDisappear { hovered = false }
                .onChange(of: enabled) { _, value in if !value { hovered = false } }
                .animation(LifeOSMotion.curve(for: .hover, reduceMotion: systemReduced || requestedReduced)?.animation, value: hovered || focused)
                .animation(LifeOSMotion.curve(for: configuration.isPressed ? .press : .release, reduceMotion: systemReduced || requestedReduced)?.animation, value: configuration.isPressed)
        }
    }
}
