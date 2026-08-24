import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The SwiftUI coordinate space shared by the macOS timed-grid pointer and
/// the native AppKit popover source view. Keeping this conversion pure makes
/// the source frame independent of hosting-view origins and stale state.
public enum CalendarEditorAnchorGeometry {
    public static let coordinateSpaceName = "calendar-editor-anchor"
    public static let sourceSize = CGSize(width: 1, height: 1)

    /// Converts a gesture location in a local day-column view into the
    /// one-point source frame used by the AppKit popover. Both inputs are
    /// expressed in the same named SwiftUI coordinate space after the local
    /// frame is applied; no window/hosting-origin fallback is valid here.
    public static func sourceFrame(
        forLocalPoint localPoint: CGPoint,
        inNamedSpace localFrame: CGRect,
        sourceSize: CGSize = CalendarEditorAnchorGeometry.sourceSize
    ) -> CGRect? {
        frame(
            forLocalRect: CGRect(origin: localPoint, size: sourceSize),
            inNamedSpace: localFrame
        )
    }

    /// Converts a rendered local event/card rect into the enclosing named
    /// calendar space. Unlike `sourceFrame(forLocalPoint:)`, this preserves
    /// the complete event rect so an existing-event editor is attached to the
    /// card the user clicked rather than to a fixed toolbar coordinate.
    public static func frame(
        forLocalRect localRect: CGRect,
        inNamedSpace localFrame: CGRect
    ) -> CGRect? {
        guard localRect.minX.isFinite,
              localRect.minY.isFinite,
              localRect.width.isFinite,
              localRect.height.isFinite,
              localRect.width > 0,
              localRect.height > 0,
              localFrame.minX.isFinite,
              localFrame.minY.isFinite,
              localFrame.width.isFinite,
              localFrame.height.isFinite,
              localFrame.width > 0,
              localFrame.height > 0 else {
            return nil
        }

        return CGRect(
            x: localFrame.minX + localRect.minX,
            y: localFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
    }
}

#if os(macOS)
public typealias CalendarTimedCreationAnchor = CGRect
public typealias CalendarEventSelectionHandler = (CalendarItem, CGRect) -> Void
#else
public typealias CalendarTimedCreationAnchor = CGPoint
public typealias CalendarEventSelectionHandler = (CalendarItem) -> Void
#endif

/// Status-only mutations (currently the to-do checkbox) share the same local
/// durability completion contract as move/resize updates while leaving the
/// item's interval untouched.
public typealias CalendarStatusUpdateHandler = (CalendarItem, CalendarProgress, @escaping CalendarUpdateCompletion) -> Void

private struct CalendarEventMovePreview: Equatable {
    let item: CalendarItem
    let start: Date
    let end: Date

    var movedItem: CalendarItem? {
        try? item.updating(start: start, end: end, at: item.updatedAt)
    }
}

@MainActor
private final class CalendarInteractionSession: ObservableObject {
    @Published var eventMoveActive = false
    @Published var eventMovePreview: CalendarEventMovePreview?
    /// A status save owns the item's complete snapshot until its local
    /// durability callback returns. This prevents a stale checkbox write from
    /// racing a move/resize save and restoring the old interval.
    @Published var statusMutationActive = false
}

#if os(macOS)
private struct CalendarMacScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
#endif

/// A reusable icon is deliberately just a bounded, sanitized asset and the
/// user-facing name they chose. No URL, filename, or picker metadata is kept.
public struct CalendarReusableIcon: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let asset: CalendarIconAsset

    public var id: String { asset.contentHash }

    public init(name: String, asset: CalendarIconAsset) throws {
        let cleaned = name
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 40 else {
            throw CalendarValidationError.invalidIconAsset
        }
        self.name = cleaned
        self.asset = asset
    }
}

/// Small, local-only icon library. The cap keeps UserDefaults bounded and the
/// payload contains only sanitized pixels plus the user's display name.
public enum CalendarIconLibrary {
    public static let maximumCount = 32
    private static let defaultsKey = "LifeOS.Calendar.ReusableIcons.v1"

    public static func load(defaults: UserDefaults = .standard) -> [CalendarReusableIcon] {
        guard let data = defaults.data(forKey: defaultsKey),
              let icons = try? JSONDecoder().decode([CalendarReusableIcon].self, from: data) else {
            return []
        }
        return Array(icons.prefix(maximumCount))
    }

    @discardableResult
    public static func upsert(_ icon: CalendarReusableIcon, defaults: UserDefaults = .standard) -> [CalendarReusableIcon] {
        var icons = load(defaults: defaults).filter { $0.id != icon.id }
        icons.insert(icon, at: 0)
        icons = Array(icons.prefix(maximumCount))
        guard let data = try? JSONEncoder().encode(icons) else { return load(defaults: defaults) }
        defaults.set(data, forKey: defaultsKey)
        return icons
    }
}

/// Privacy gate for user-selected calendar images.
///
/// ImageIO decodes the source and creates a new, small PNG from the rendered
/// pixels. Passing nil properties to the destination prevents EXIF/GPS and
/// filename metadata from crossing into the persisted CalendarIconAsset.
public enum CalendarIconAssetSanitizer {
    public static let maximumInputBytes = 16 * 1024 * 1024
    public static let maximumPixelSide = 256

    public static func sanitize(_ input: Data) throws -> CalendarIconAsset {
        guard !input.isEmpty, input.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(input as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = sourceProperties[kCGImagePropertyPixelWidth] as? Int,
              let height = sourceProperties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= 8_192, height <= 8_192,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= 16_000_000 else {
            throw CalendarValidationError.invalidIconAsset
        }

        // A second pass with smaller bounds handles photographs/illustrations
        // whose lossless PNG is still larger than the wire/storage contract.
        for side in [maximumPixelSide, 192, 160, 128, 96, 64] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CalendarValidationError.invalidIconAsset
            }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw CalendarValidationError.invalidIconAsset
            }
            // No source properties are copied: orientation has already been
            // applied by the thumbnail transform and metadata is discarded.
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), output.length <= CalendarIconAsset.maxBytes else {
                continue
            }
            let sanitized = output as Data
            guard let outputSource = CGImageSourceCreateWithData(sanitized as CFData, nil),
                  CGImageSourceGetCount(outputSource) == 1,
                  let outputProperties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any] else {
                continue
            }
            guard let outputWidth = outputProperties[kCGImagePropertyPixelWidth] as? Int,
                  let outputHeight = outputProperties[kCGImagePropertyPixelHeight] as? Int,
                  (outputProperties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
                  benignEXIFPropertiesOnly(outputProperties[kCGImagePropertyExifDictionary], width: outputWidth, height: outputHeight),
                  [
                    kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyJFIFDictionary,
                    kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyDNGDictionary,
                    kCGImagePropertyOpenEXRDictionary,
                    kCGImagePropertyHEIFDictionary,
                    kCGImagePropertyHEICSDictionary,
                    kCGImagePropertyGIFDictionary,
                    kCGImagePropertyWebPDictionary,
                    kCGImagePropertyAVISDictionary,
                    kCGImagePropertyTGADictionary,
                    kCGImagePropertyFileContentsDictionary,
                    kCGImageProperty8BIMDictionary,
                    kCGImagePropertyMakerAppleDictionary,
                    kCGImagePropertyCIFFDictionary,
                    kCGImagePropertyRawDictionary
                  ].allSatisfy({ outputProperties[$0] == nil }),
                  benignPNGPropertiesOnly(outputProperties[kCGImagePropertyPNGDictionary]) else {
                continue
            }
            return try CalendarIconAsset(format: .png, bytes: sanitized)
        }

        throw CalendarValidationError.invalidIconAsset
    }

    private static func benignEXIFPropertiesOnly(_ value: Any?, width: Int, height: Int) -> Bool {
        guard let value else { return true }
        guard let dictionary = value as? NSDictionary else { return false }
        let allowedKeys: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension"]
        var values: [String: Any] = [:]
        for key in dictionary.allKeys {
            guard let key = key as? String, allowedKeys.contains(key),
                  let nested = dictionary.object(forKey: key), values[key] == nil else { return false }
            values[key] = nested
        }
        guard Set(values.keys).isSubset(of: allowedKeys),
              exactInteger(values["PixelXDimension"]) == width,
              exactInteger(values["PixelYDimension"]) == height else { return false }
        if let colorSpace = values["ColorSpace"], exactInteger(colorSpace) != 1 { return false }
        return true
    }

    private static func benignPNGPropertiesOnly(_ value: Any?) -> Bool {
        guard let dictionary = value as? NSDictionary else { return value == nil }
        // ImageIO exposes a small structural dictionary for a fresh PNG. These
        // four values are encoder-level color/interlace facts, not user text.
        let allowedKeys: Set<String> = ["InterlaceType", "sRGBIntent", "Gamma", "Chromaticities"]
        var values: [String: Any] = [:]
        for key in dictionary.allKeys {
            guard let key = key as? String, allowedKeys.contains(key),
                  let nested = dictionary.object(forKey: key), values[key] == nil else { return false }
            values[key] = nested
        }
        guard Set(values.keys).isSubset(of: allowedKeys), exactInteger(values["InterlaceType"]) == 0 else { return false }
        if let intent = values["sRGBIntent"], exactInteger(intent) != 0 { return false }
        if let gamma = values["Gamma"], (exactDouble(gamma).map { abs($0 - 0.45455) <= 0.000001 } != true) { return false }
        if let chromaticities = values["Chromaticities"] as? NSArray {
            let expected = [0.3127, 0.329, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06]
            guard chromaticities.count == expected.count,
                  chromaticities.enumerated().allSatisfy({ index, value in
                      guard let number = exactDouble(value) else { return false }
                      return abs(number - expected[index]) <= 0.000001
                  }) else { return false }
        } else if values["Chromaticities"] != nil {
            return false
        }
        return true
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func exactDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

public struct CalendarIconView: View {
    let item: CalendarItem
    let size: CGFloat

    public init(item: CalendarItem, size: CGFloat = 28) {
        self.item = item
        self.size = size
    }

    public var body: some View {
        Group {
            if let data = item.iconAsset?.bytes {
#if os(iOS)
                if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else if let icon = item.icon { Text(icon) }
#else
                if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() } else if let icon = item.icon { Text(icon) }
#endif
            } else if let systemIconName = item.systemIconName,
                      CalendarSystemIconSupport.isAvailable(systemIconName) {
                Image(systemName: systemIconName)
                    .font(.system(size: size * 0.72, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            } else if let icon = item.icon {
                Text(icon)
            }
        }
        .frame(width: item.hasIcon ? size : 0, height: item.hasIcon ? size : 0)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.21), style: .continuous))
    }
}

public extension CalendarProgress {
    var label: String {
        switch self {
        case .planned: "Planned"
        case .inProgress: "In progress"
        case .done: "Done"
        case .aborted: "Aborted"
        }
    }

    var color: Color {
        switch self {
        case .planned: LifeOSTokens.accent
        case .inProgress: .orange
        case .done: .green
        case .aborted: .red
        }
    }

    var iconName: LifeOSIconName {
        switch self {
        case .planned: .planned
        case .inProgress: .inProgress
        case .done: .done
        case .aborted: .aborted
        }
    }
}

private enum CalendarEventVisuals {
    static let accent = LifeOSTokens.Hue.green.base
    static let today = Color.lifeOSCalendarRed
    static let fillOpacity = 0.24
    static let leadingBarOpacity = 0.92
    static let borderOpacity = 0.38
    static let hoverOpacity = 0.72
    static let pressOpacity = 0.84
}

private struct CalendarEventButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? CalendarEventVisuals.pressOpacity : 1)
    }
}

public struct CalendarItemRow: View {
    public let item: CalendarItem
    private static let time: Date.FormatStyle = .dateTime.hour().minute()

    public init(item: CalendarItem) { self.item = item }

    public var body: some View {
        HStack(spacing: 12) {
            if item.hasIcon {
                CalendarIconView(item: item).accessibilityLabel(item.icon.map { "Icon \($0)" } ?? "Icon")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text("\(item.start, format: Self.time) – \(item.end, format: Self.time)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(CalendarEventVisuals.accent).frame(width: 9, height: 9)
                .accessibilityLabel(item.status.label)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.icon ?? "No icon") \(item.title), \(item.status.label), \(item.start, format: Self.time) to \(item.end, format: Self.time)")
    }
}

public struct CalendarProgressPicker: View {
    @Binding public var progress: CalendarProgress
    public init(progress: Binding<CalendarProgress>) { _progress = progress }
    public var body: some View {
        Picker("Status", selection: $progress) {
            ForEach(CalendarProgress.allCases, id: \.self) { status in
                Label {
                    Text(status.label)
                } icon: {
                    LifeOSIcon(status.iconName)
                }
                .tag(status)
            }
        }
        .pickerStyle(.menu)
    }
}

/// The selected interval remains visible behind a contextual Mac editor until
/// the popover is cancelled or the save completes.
public struct CalendarTimedCreationPreview: Equatable, Sendable {
    public let day: Date
    public let start: Date
    public let end: Date

    public init(day: Date, start: Date, end: Date) {
        self.day = day
        self.start = start
        self.end = end
    }
}

public struct CalendarTimelineView: View {
    public let days: [Date]
    public let items: [CalendarItem]
    public let holidays: [CalendarHoliday]
    public let hourHeight: CGFloat
    public let calendar: Calendar
    public let onSelect: CalendarEventSelectionHandler
    /// Deliberate empty-space creation and final event interval updates are
    /// emitted only after the gesture settles. The parent owns persistence.
    public let onCreate: ((Date) -> Void)?
    /// Double-tapping the trailing all-day cell emits its local day. The
    /// parent owns editor presentation and persistence.
    public let onCreateAllDay: ((Date) -> Void)?
    /// macOS-only intentional empty-grid creation. The source frame is in the
    /// shared named CalendarEditorAnchorGeometry coordinate space so the
    /// parent can present the inspector beside the actual click rather than
    /// resolving through a hosting-view origin.
    public let onCreateTimedRange: ((Date, Date, CalendarTimedCreationAnchor) -> Void)?
    public let timedCreationPreview: CalendarTimedCreationPreview?
    /// Live press-and-drag creation drafts from the iOS empty grid. Called
    /// continuously while the finger moves and once more with `nil` when the
    /// gesture fails or finishes; the parent owns the ghost state.
    public let onTimedCreationDraft: ((CalendarTimedCreationPreview?) -> Void)?
    public let onUpdate: CalendarUpdateHandler?
    public let onStatusUpdate: CalendarStatusUpdateHandler?
    /// Called while the iOS pager is in flight so the compact header can track
    /// the date that is actually under the user's finger. It is intentionally
    /// separate from the settled date callback below.
    public let onPreviewDateChange: ((Date) -> Void)?
    /// Called once a page settles. The parent recenters the virtual strip on
    /// this date, keeping only previous/current/next windows materialized.
    public let onCommitDateChange: ((Date) -> Void)?
    public let monthNamespace: Namespace.ID?
    public let monthExpanded: Bool
    public let monthSelectedDate: Date?
    public let reduceMotion: Bool
    @StateObject private var interactionSession = CalendarInteractionSession()
#if os(macOS)
    @State private var macScrollOffset: CGFloat = 0
#endif

    private let timeGutter: CGFloat = 52
#if os(macOS)
    private let minimumDayWidth: CGFloat = 112
#else
    private let minimumDayWidth: CGFloat = 96
#endif

    public init(days: [Date], items: [CalendarItem], holidays: [CalendarHoliday] = [], hourHeight: CGFloat, calendar: Calendar = .current,
                onSelect: @escaping CalendarEventSelectionHandler,
                onCreate: ((Date) -> Void)? = nil,
                onCreateAllDay: ((Date) -> Void)? = nil,
                onCreateTimedRange: ((Date, Date, CalendarTimedCreationAnchor) -> Void)? = nil,
                timedCreationPreview: CalendarTimedCreationPreview? = nil,
                onTimedCreationDraft: ((CalendarTimedCreationPreview?) -> Void)? = nil,
                onUpdate: CalendarUpdateHandler? = nil,
                onStatusUpdate: CalendarStatusUpdateHandler? = nil,
                onPreviewDateChange: ((Date) -> Void)? = nil,
                onCommitDateChange: ((Date) -> Void)? = nil,
                monthNamespace: Namespace.ID? = nil,
                monthExpanded: Bool = false,
                monthSelectedDate: Date? = nil,
                reduceMotion: Bool = false) {
        self.days = days
        self.items = items
        self.holidays = holidays
        self.hourHeight = hourHeight
        self.calendar = calendar
        self.onSelect = onSelect
        self.onCreate = onCreate
        self.onCreateAllDay = onCreateAllDay
        self.onCreateTimedRange = onCreateTimedRange
        self.timedCreationPreview = timedCreationPreview
        self.onTimedCreationDraft = onTimedCreationDraft
        self.onUpdate = onUpdate
        self.onStatusUpdate = onStatusUpdate
        self.onPreviewDateChange = onPreviewDateChange
        self.onCommitDateChange = onCommitDateChange
        self.monthNamespace = monthNamespace
        self.monthExpanded = monthExpanded
        self.monthSelectedDate = monthSelectedDate
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        Group {
#if os(iOS)
        CalendarPagedTimeline(
            days: days,
            items: items,
            holidays: holidays,
            hourHeight: hourHeight,
            calendar: calendar,
            onSelect: onSelect,
            onCreate: onCreate,
            onCreateAllDay: onCreateAllDay,
            onCreateTimedRange: onCreateTimedRange,
            onUpdate: onUpdate,
            onStatusUpdate: onStatusUpdate,
            timedCreationPreview: timedCreationPreview,
            onTimedCreationDraft: onTimedCreationDraft,
            onPreviewDateChange: onPreviewDateChange,
            onCommitDateChange: onCommitDateChange,
            monthNamespace: monthNamespace,
            monthExpanded: monthExpanded,
            monthSelectedDate: monthSelectedDate,
            reduceMotion: reduceMotion,
            interactionSession: interactionSession
        )
#else
        GeometryReader { viewport in
            let contentWidth = max(viewport.size.width, timeGutter + CGFloat(days.count) * minimumDayWidth)
            let timelineHeight = CGFloat(CalendarInteractionLayout.timelineHeight(
                days: days,
                hourHeight: Double(hourHeight),
                calendar: calendar
            ))
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    dayHeader(width: contentWidth)
                    CalendarAllDayRow(
                        days: days,
                        items: items,
                        calendar: calendar,
                        timeGutter: timeGutter,
                        width: contentWidth,
                        onSelect: nil
                    )
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                hourLabels(timelineHeight: timelineHeight)
                                    .frame(width: timeGutter)
                                ForEach(days, id: \.self) { day in
                                    CalendarDayTimeline(
                                        day: day,
                                        items: items,
                                        hourHeight: hourHeight,
                                        calendar: calendar,
                                        onSelect: onSelect,
                                        onCreate: onCreate,
                                        onCreateTimedRange: onCreateTimedRange,
                                        timedCreationPreview: timedCreationPreview,
                                        onTimedCreationDraft: nil,
                                        onUpdate: onUpdate,
                                        onStatusUpdate: onStatusUpdate,
                                        monthNamespace: monthNamespace,
                                        monthExpanded: monthExpanded,
                                        monthSelectedDate: monthSelectedDate,
                                        reduceMotion: reduceMotion,
                                        isInteractionEnabled: true,
                                        interactionSession: interactionSession,
                                        onVerticalPan: nil
                                    )
                                    .frame(width: (contentWidth - timeGutter) / CGFloat(max(days.count, 1)))
                            }
                            .overlay {
                                CalendarNowLine(
                                    days: days,
                                    calendar: calendar,
                                    timeGutter: timeGutter,
                                    totalHeight: timelineHeight,
                                    contentWidth: contentWidth,
                                    reduceMotion: reduceMotion
                                )
                            }
                        }
                        }
                        .task(id: days.first) {
                            scrollProxy.scrollTo(initialVisibleHour, anchor: .top)
                        }
                    }
                }
                .frame(width: contentWidth)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(
                            key: CalendarMacScrollOffsetKey.self,
                            value: content.frame(in: .named("calendar-mac-timeline-scroll")).minX
                        )
                    }
                }
            }
            .coordinateSpace(name: "calendar-mac-timeline-scroll")
            .scrollDisabled(!CalendarGestureArbitration.parentHorizontalScrollEnabled(
                eventMutationActive: interactionSession.eventMoveActive,
                hasProvisionalPreview: interactionSession.eventMovePreview != nil
            ))
            .onPreferenceChange(CalendarMacScrollOffsetKey.self) { offset in
                guard abs(macScrollOffset - offset) > 0.5 else { return }
                macScrollOffset = offset
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar timeline, \(days.count) days")
        .accessibilityIdentifier("calendar-visible-range")
        .accessibilityValue(
            "\(days.map(calendarISODate).joined(separator: ",")); offset=\(Int(macScrollOffset.rounded()))"
        )
#endif
        }
        .onChange(of: items) { _, updatedItems in
            guard let preview = interactionSession.eventMovePreview,
                  let committed = updatedItems.first(where: { $0.id == preview.item.id }),
                  committed.start == preview.start,
                  committed.end == preview.end else { return }
            interactionSession.eventMovePreview = nil
        }
    }

    private func dayHeader(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeGutter, height: 58)
            ForEach(days, id: \.self) { day in
                let dayHolidays = holidays.filter { calendar.isDate($0.date, inSameDayAs: day) }
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    CalendarDayHeaderNumber(
                        day: day,
                        calendar: calendar,
                        namespace: monthNamespace,
                        isSelected: monthSelectedDate.map { calendar.isDate(day, inSameDayAs: $0) } ?? false,
                        isSource: !monthExpanded,
                        reduceMotion: reduceMotion
                    )
                    if let holiday = dayHolidays.first {
                        Text(holiday.name)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(LifeOSTokens.accent)
                            .lineLimit(1)
                    }
                }
                .frame(width: (width - timeGutter) / CGFloat(max(days.count, 1)), height: 58)
                .background(calendar.isDateInToday(day) ? CalendarEventVisuals.today.opacity(0.08) : .clear)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
            }
        }
        .background(LifeOSTokens.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
    }

    private func calendarISODate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func hourLabels(timelineHeight: CGFloat) -> some View {
        let scale = CalendarInteractionLayout.timelineScale(
            day: days.first ?? .now,
            hourHeight: Double(hourHeight),
            calendar: calendar
        )
        let marks = Array(stride(from: 0, to: scale?.dayMinutes ?? 1_440, by: 60))
        return ZStack(alignment: .topTrailing) {
            ForEach(marks, id: \.self) { minute in
                let date = scale.flatMap {
                    $0.date(for: Double(minute) / 60 * Double(hourHeight), calendar: calendar, snappingTo: 1)
                }
                Text(date.map { String(format: "%02d:00", calendar.component(.hour, from: $0)) } ?? "")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .offset(y: CGFloat(scale?.y(for: date ?? .now, calendar: calendar) ?? Double(minute) / 60 * Double(hourHeight)))
                    .id(minute / 60)
            }
        }
        .frame(height: timelineHeight)
    }

    /// Starts near the first useful daytime event instead of an empty midnight grid.
    /// Overnight events remain available by scrolling upward.
    private var initialVisibleHour: Int {
        let visibleDayStarts = Set(days.map { calendar.startOfDay(for: $0) })
        let firstDaytimeEventHour = items
            .filter { item in
                visibleDayStarts.contains(calendar.startOfDay(for: item.start)) &&
                    item.end.timeIntervalSince(item.start) <= 12 * 60 * 60
            }
            .map { calendar.component(.hour, from: $0.start) }
            .filter { $0 >= 6 }
            .min()
        return max(0, min(8, (firstDaytimeEventHour ?? 9) - 1))
    }
}

#if os(iOS)
/// Reports the live horizontal position of the sliding day strip. The strip
/// moves under the finger and under the settle animation; sampling its
/// rendered frame is what keeps the header preview continuous across both,
/// because an animated `@State` value changes once while its render changes
/// every frame.
private struct CalendarStripOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CalendarPagerPendingSettle: Equatable {
    let generation: Int
    let dayDelta: Int
    let targetOffset: CGFloat
    let nextAnchor: Date
    let normalizedVelocity: Double
}

/// Clips a moving strip layer to the day area (everything right of the
/// pinned hour gutter). Virtual neighbour columns are mounted to the left of
/// the anchor so a rightward swipe reveals them "as if they were already
/// there"; without this mask their trailing edge sits visibly inside the
/// gutter zone at rest. The mask is layout-neutral, so probes and hit
/// testing keep their existing geometry.
private extension View {
    func calendarDayAreaMask(totalWidth: CGFloat, gutter: CGFloat) -> some View {
        mask(alignment: .leading) {
            Rectangle()
                .frame(width: max(0, totalWidth - gutter))
                .offset(x: gutter)
        }
    }
}

/// A continuous iPhone day strip, Notion-style. Instead of paging whole
/// three-day windows, the strip materializes single-day columns around the
/// anchor (two spare days on each side of the visible window) and slides them
/// under the finger 1:1. One swipe therefore reveals exactly one new day AS IF
/// IT WAS ALREADY THERE: every column shifts by one column width, the hour
/// gutter stays pinned, and the settle snaps critically damped without
/// overshoot. Only the visible window owns event interactions and vertical
/// scrolling; neighbouring columns are pre-mounted visuals.
private struct CalendarPagedTimeline: View {
    let days: [Date]
    let items: [CalendarItem]
    let holidays: [CalendarHoliday]
    let hourHeight: CGFloat
    let calendar: Calendar
    let onSelect: CalendarEventSelectionHandler
    let onCreate: ((Date) -> Void)?
    let onCreateAllDay: ((Date) -> Void)?
    let onCreateTimedRange: ((Date, Date, CalendarTimedCreationAnchor) -> Void)?
    let timedCreationPreview: CalendarTimedCreationPreview?
    let onTimedCreationDraft: ((CalendarTimedCreationPreview?) -> Void)?
    let onUpdate: CalendarUpdateHandler?
    let onStatusUpdate: CalendarStatusUpdateHandler?
    let onPreviewDateChange: ((Date) -> Void)?
    let onCommitDateChange: ((Date) -> Void)?
    let monthNamespace: Namespace.ID?
    let monthExpanded: Bool
    let monthSelectedDate: Date?
    let reduceMotion: Bool
    let interactionSession: CalendarInteractionSession
    @State private var pageAnchor: Date
    @State private var lastPreviewCallbackDate: Date?
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var horizontalDragActive = false
    @State private var pagerDragAxisIsHorizontal: Bool?
    @State private var pagerGeneration = 0
    @State private var pendingSettle: CalendarPagerPendingSettle?
    /// Finger-space reference for 1:1 tracking. The strip position maps as
    /// `referenceOffset + (translation - referenceTranslation)` so locking the
    /// horizontal axis (and interrupting a settle) never snaps the strip to
    /// the raw translation of the new gesture.
    @State private var dragReferenceTranslation: CGFloat = 0
    @State private var dragReferenceOffset: CGFloat = 0
    /// Most recent geometry-sampled strip displacement from rest. This is the
    /// live animated position while a settle is in flight and is what a new
    /// grab adopts, so interrupting a settle continues from the rendered
    /// pixels instead of jumping.
    @State private var liveStripDragOffset: CGFloat = 0
    @State private var fingerVelocity = CalendarPagerFingerVelocity()
    /// One-time vertical positioning. Re-running the auto-scroll on every
    /// settled swipe yanked the timeline back to the morning hours and broke
    /// the "the next day was already there" illusion vertically.
    @State private var didInitialVerticalScroll = false
    /// Fallback scroll anchor used only when a vertical pan starts over an
    /// event-owned interaction surface. Native ScrollView scrolling remains
    /// the default; this state makes those rows deterministic when SwiftUI's
    /// nested long-press recognizers delay the ancestor pan.
    // The first over-event pan advances from the midnight fallback to the
    // 09:00 viewport; subsequent pans advance in four-hour steps. 09:00 is
    // far enough to move 24:00 while retaining the source event on-screen.
    @State private var manualVerticalScrollHour = 5
    @State private var lastManualVerticalPanAt: Date?

    init(days: [Date], items: [CalendarItem], holidays: [CalendarHoliday], hourHeight: CGFloat,
         calendar: Calendar, onSelect: @escaping CalendarEventSelectionHandler,
         onCreate: ((Date) -> Void)?, onCreateAllDay: ((Date) -> Void)?, onCreateTimedRange: ((Date, Date, CalendarTimedCreationAnchor) -> Void)?, onUpdate: CalendarUpdateHandler?,
         onStatusUpdate: CalendarStatusUpdateHandler?,
         timedCreationPreview: CalendarTimedCreationPreview?,
         onTimedCreationDraft: ((CalendarTimedCreationPreview?) -> Void)?,
         onPreviewDateChange: ((Date) -> Void)?, onCommitDateChange: ((Date) -> Void)?,
         monthNamespace: Namespace.ID?, monthExpanded: Bool, monthSelectedDate: Date?, reduceMotion: Bool,
         interactionSession: CalendarInteractionSession) {
        self.days = days
        self.items = items
        self.holidays = holidays
        self.hourHeight = hourHeight
        self.calendar = calendar
        self.onSelect = onSelect
        self.onCreate = onCreate
        self.onCreateAllDay = onCreateAllDay
        self.onCreateTimedRange = onCreateTimedRange
        self.onUpdate = onUpdate
        self.onStatusUpdate = onStatusUpdate
        self.timedCreationPreview = timedCreationPreview
        self.onTimedCreationDraft = onTimedCreationDraft
        self.onPreviewDateChange = onPreviewDateChange
        self.onCommitDateChange = onCommitDateChange
        self.monthNamespace = monthNamespace
        self.monthExpanded = monthExpanded
        self.monthSelectedDate = monthSelectedDate
        self.reduceMotion = reduceMotion
        self.interactionSession = interactionSession
        _pageAnchor = State(initialValue: calendar.startOfDay(for: days.first ?? .now))
    }

    private var visibleDayCount: Int { max(1, days.count) }
    private let timeGutter: CGFloat = 52
    private let dayHeaderHeight: CGFloat = 58
    /// Spare pre-mounted days on each side of the visible window. The drag is
    /// clamped well below one spare column, so a swipe can never expose
    /// unmounted space.
    private let leadingVirtualDays = 2
    private let trailingSpareDays = 2

    private var virtualDayOffsets: [Int] {
        Array(-(leadingVirtualDays)..<(visibleDayCount + trailingSpareDays))
    }

    private var anchorIndex: Int { leadingVirtualDays }

    private var virtualDays: [Date] {
        virtualDayOffsets.compactMap { calendar.date(byAdding: .day, value: $0, to: pageAnchor) }
    }

    private var visibleWindow: [Date] {
        let all = virtualDays
        guard all.count >= visibleDayCount else { return Array(all.prefix(visibleDayCount)) }
        return Array(all[anchorIndex..<(anchorIndex + visibleDayCount)])
    }

    static func columnWidth(forAvailableWidth available: CGFloat, visibleDays: Int) -> CGFloat {
        guard available.isFinite, available > 0, visibleDays > 0 else { return 1 }
        return max(1, available / CGFloat(visibleDays))
    }

    /// Screen x of virtual column zero when the strip is idle: the leading
    /// visible column must begin exactly where the hour gutter ends.
    private func stripBaseX(columnWidth: CGFloat) -> CGFloat {
        timeGutter - CGFloat(anchorIndex) * columnWidth
    }

    var body: some View {
        GeometryReader { viewport in
            let columnWidth = Self.columnWidth(
                forAvailableWidth: viewport.size.width - timeGutter,
                visibleDays: visibleDayCount
            )
            let stripDays = virtualDays
            let virtualWidth = columnWidth * CGFloat(stripDays.count)
            let timelineAxisHeight = CGFloat(CalendarInteractionLayout.timelineHeight(
                days: days,
                hourHeight: Double(hourHeight),
                calendar: calendar
            ))
            let contentHeight = CGFloat(CalendarInteractionLayout.timelineContentHeight(
                days: days,
                hourHeight: Double(hourHeight),
                calendar: calendar,
                viewportHeight: Double(viewport.size.height)
            ))
            let allDayHeight = CGFloat(CalendarAllDayLayout.height(
                items: items,
                days: visibleWindow,
                calendar: calendar
            ))
            let timedViewportHeight = CGFloat(CalendarInteractionLayout.timedViewportHeight(
                containerHeight: Double(viewport.size.height),
                dayHeaderHeight: Double(dayHeaderHeight),
                allDayHeight: Double(allDayHeight)
            ))
            VStack(spacing: 0) {
                dayHeaderStrip(days: stripDays, columnWidth: columnWidth, containerWidth: viewport.size.width)
                CalendarAllDayLaneStrip(
                    days: stripDays,
                    visibleDays: visibleWindow,
                    items: items,
                    calendar: calendar,
                    columnWidth: columnWidth,
                    slideOffset: stripBaseX(columnWidth: columnWidth) + horizontalDragOffset,
                    timeGutter: timeGutter,
                    onSelect: { item in onSelect(item) },
                    onCreateAllDay: onCreateAllDay
                )
                .simultaneousGesture(pagerDragGesture(columnWidth: columnWidth), including: .all)
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            // The sliding day columns live in a masked
                            // overlay container: pre-mounted leading
                            // neighbours slide under the pinned hour gutter
                            // instead of showing through it at rest.
                            Color.clear
                                .frame(width: viewport.size.width, height: contentHeight, alignment: .topLeading)
                                .overlay(alignment: .topLeading) {
                                    HStack(alignment: .top, spacing: 0) {
                                        ForEach(stripDays, id: \.self) { day in
                                            CalendarDayTimeline(
                                                day: day,
                                                items: items,
                                                hourHeight: hourHeight,
                                                calendar: calendar,
                                                onSelect: onSelect,
                                                onCreate: onCreate,
                                                onCreateTimedRange: onCreateTimedRange,
                                                timedCreationPreview: timedCreationPreview,
                                                onTimedCreationDraft: onTimedCreationDraft,
                                                onUpdate: onUpdate,
                                                onStatusUpdate: onStatusUpdate,
                                                monthNamespace: monthNamespace,
                                                monthExpanded: monthExpanded,
                                                monthSelectedDate: monthSelectedDate,
                                                reduceMotion: reduceMotion,
                                                isInteractionEnabled: isVisibleDay(day, window: visibleWindow),
                                                interactionSession: interactionSession,
                                                onVerticalPan: { translation in
                                                    let now = Date.now
                                                    if let lastManualVerticalPanAt,
                                                       now.timeIntervalSince(lastManualVerticalPanAt) < 0.25 {
                                                        // The handle and its parent event
                                                        // can both observe one physical
                                                        // swipe. One timeline gesture
                                                        // must advance only one step.
                                                        return
                                                    }
                                                    self.lastManualVerticalPanAt = now
                                                    let direction = translation < 0 ? 1 : -1
                                                    manualVerticalScrollHour = min(
                                                        23,
                                                        max(0, manualVerticalScrollHour + direction * 4)
                                                    )
                                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                                                        scrollProxy.scrollTo(
                                                            CalendarTimelineScrollAnchor.id(for: manualVerticalScrollHour),
                                                            anchor: .top
                                                        )
                                                    }
                                                }
                                            )
                                            .frame(width: columnWidth)
                                        }
                                    }
                                    .frame(width: virtualWidth, height: contentHeight, alignment: .topLeading)
                                    .overlay {
                                        CalendarNowLine(
                                            days: stripDays,
                                            calendar: calendar,
                                            timeGutter: timeGutter,
                                            totalHeight: timelineAxisHeight,
                                            contentWidth: virtualWidth,
                                            columnWidthOverride: columnWidth,
                                            reduceMotion: reduceMotion
                                        )
                                    }
                                    .offset(x: stripBaseX(columnWidth: columnWidth) + horizontalDragOffset)
                                }
                                .calendarDayAreaMask(totalWidth: viewport.size.width, gutter: timeGutter)
                            hourLabels(contentHeight: contentHeight)
                                // Top-aligned: the labels are absolutely
                                // offset inside a naturally short ZStack, so
                                // the default center alignment would shove
                                // the whole hour axis halfway down the grid.
                                .frame(width: timeGutter, height: contentHeight, alignment: .top)
                                .zIndex(1)
                                .allowsHitTesting(false)
                            CalendarTimelineHourAnchors(
                                hourHeight: hourHeight,
                                totalHeight: timelineAxisHeight
                            )
                            .frame(width: 1, height: timelineAxisHeight, alignment: .top)
                            .offset(x: -1)
                            .allowsHitTesting(false)
                        }
                        .frame(width: viewport.size.width, height: contentHeight, alignment: .topLeading)
                        .clipped()
                    }
                    // The pager's axis lock owns horizontal movement while
                    // the finger is down; a settle in flight is owned by its
                    // animation and a new horizontal grab interrupts it, so
                    // vertical scrolling never needs to be frozen here.
                    .simultaneousGesture(pagerDragGesture(columnWidth: columnWidth), including: .all)
                    .accessibilityIdentifier("calendar-vertical-timeline-scroll")
                    .task {
                        guard !didInitialVerticalScroll else { return }
                        didInitialVerticalScroll = true
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        // An immediate scrollTo can land before the ScrollView
                        // knows its final content size and clamp to offset 0.
                        // Re-assert across the first layout passes instead of
                        // re-running on every settled swipe (which yanked the
                        // reader back to the morning hours after each swipe).
                        for delay in [0.0, 0.15, 0.4] {
                            if delay > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            }
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(
                                    CalendarTimelineScrollAnchor.id(for: initialVisibleHour),
                                    anchor: .top
                                )
                            }
                        }
                    }
                    .frame(height: timedViewportHeight)
                    .coordinateSpace(name: "calendar-timeline-viewport")
                    .overlay {
                        Color.clear
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Active calendar timeline viewport")
                            .accessibilityIdentifier("calendar-vertical-timeline")
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: viewport.size.width)
            .clipped()
            .coordinateSpace(name: "calendar-horizontal-pager")
            .onPreferenceChange(CalendarStripOffsetPreferenceKey.self) { stripX in
                updatePreviewAndCompletion(stripX: stripX, columnWidth: columnWidth)
            }
            .onChange(of: days.first) { _, firstDay in
                guard let firstDay else { return }
                let target = calendar.startOfDay(for: firstDay)
                guard !calendar.isDate(target, inSameDayAs: pageAnchor) else { return }
                cancelStripImmediately(to: target)
            }
            .onChange(of: interactionSession.eventMoveActive) { _, isActive in
                guard isActive else { return }
                // A long-press move can win while the strip is mid-drag or
                // mid-settle. Recenter immediately so the event owns the
                // horizontal gesture and the header reflects the settled page.
                resetStripForEventOwnership()
            }
            .overlay(alignment: .top) {
                // Stable semantic probe for the pinned header. It is
                // non-hit-testing so the physical swipe falls through to the
                // header's direct pager gesture below.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: dayHeaderHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Calendar timeline, \(days.count) days. Swipe horizontally to change days.")
                    .accessibilityValue("Committed page \(commitAccessibilityDate(pageAnchor))")
                    .accessibilityIdentifier("calendar-pager")
                    .allowsHitTesting(false)
            }
        }
    }

    private func isVisibleDay(_ day: Date, window: [Date]) -> Bool {
        window.contains(where: { calendar.isDate($0, inSameDayAs: day) })
    }

    private func commitAccessibilityDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func cancelStripImmediately(to target: Date) {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pagerGeneration += 1
            pendingSettle = nil
            pageAnchor = target
            lastPreviewCallbackDate = target
            horizontalDragOffset = 0
            horizontalDragActive = false
            pagerDragAxisIsHorizontal = nil
            dragReferenceTranslation = 0
            dragReferenceOffset = 0
            liveStripDragOffset = 0
            fingerVelocity.reset()
        }
    }

    private func resetStripForEventOwnership() {
        let wasPreviewing = horizontalDragActive || abs(horizontalDragOffset) > 0.5 ||
            (lastPreviewCallbackDate.map { !calendar.isDate($0, inSameDayAs: pageAnchor) } ?? false)
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pagerGeneration += 1
            pendingSettle = nil
            horizontalDragOffset = 0
            horizontalDragActive = false
            pagerDragAxisIsHorizontal = nil
            dragReferenceTranslation = 0
            dragReferenceOffset = 0
            liveStripDragOffset = 0
            fingerVelocity.reset()
            lastPreviewCallbackDate = pageAnchor
        }
        // Restore the compact header even if an event long-press wins while
        // the strip is still settling. The event owns the horizontal axis.
        if wasPreviewing {
            onPreviewDateChange?(CalendarGestureArbitration.headerDateAfterEventOwnership(
                settledPage: pageAnchor,
                calendar: calendar
            ))
        }
    }

    private func pagerDragGesture(columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard CalendarInteractionLayout.isPagerStartInDaySurface(
                    startX: Double(value.startLocation.x),
                    timeGutter: Double(timeGutter)
                ) else {
                    pagerDragAxisIsHorizontal = nil
                    return
                }
                handlePagerChanged(translation: value.translation, columnWidth: columnWidth)
            }
            .onEnded { value in
                guard CalendarInteractionLayout.isPagerStartInDaySurface(
                    startX: Double(value.startLocation.x),
                    timeGutter: Double(timeGutter)
                ) else {
                    pagerDragAxisIsHorizontal = nil
                    return
                }
                handlePagerEnded(
                    translation: value.translation.width,
                    predictedTranslation: value.predictedEndTranslation.width,
                    columnWidth: columnWidth
                )
            }
    }

    private func handlePagerChanged(translation: CGSize, columnWidth: CGFloat) {
        guard !interactionSession.eventMoveActive,
              interactionSession.eventMovePreview == nil,
              columnWidth > 0 else {
            if interactionSession.eventMoveActive || interactionSession.eventMovePreview != nil {
                resetStripForEventOwnership()
            }
            return
        }

        if pagerDragAxisIsHorizontal == nil {
            let axis = CalendarInteractionLayout.pagerDragAxis(
                horizontalTranslation: Double(translation.width),
                verticalTranslation: Double(translation.height)
            )
            // Keep the undecided state alive through near-diagonal samples.
            // The first sample is not allowed to permanently classify a
            // 10x9 movement as vertical when a later 12x10 sample is clearly
            // horizontal. Once an axis is actually dominant, lock it.
            switch axis {
            case .undecided:
                return
            case .horizontal:
                pagerDragAxisIsHorizontal = true
            case .vertical:
                pagerDragAxisIsHorizontal = false
            }
        }
        guard pagerDragAxisIsHorizontal == true else { return }
        if !horizontalDragActive {
            horizontalDragActive = true
            pagerGeneration += 1
            fingerVelocity.reset()
            if pendingSettle != nil {
                // A new grab interrupts an in-flight settle. Adopt the last
                // geometry-sampled position so the strip continues from the
                // exact pixels on screen — the Notion "the strip is always
                // under my finger" contract — instead of snapping to the
                // fresh gesture's raw translation.
                let adopted = max(-columnWidth * 1.6, min(columnWidth * 1.6, liveStripDragOffset))
                var transaction = Transaction()
                transaction.animation = nil
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pendingSettle = nil
                    horizontalDragOffset = adopted
                }
            }
            dragReferenceTranslation = translation.width
            dragReferenceOffset = horizontalDragOffset
        }
        guard horizontalDragActive else { return }
        fingerVelocity.sample(
            x: Double(translation.width),
            timeSeconds: Date.now.timeIntervalSinceReferenceDate
        )
        // 1:1 finger tracking relative to the gesture's own start position,
        // with slack for a rubber-band feel, but never past the pre-mounted
        // spare columns.
        let dragLimit = columnWidth * 1.6
        let mapped = dragReferenceOffset + (translation.width - dragReferenceTranslation)
        horizontalDragOffset = max(-dragLimit, min(dragLimit, mapped))
    }

    private func handlePagerEnded(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        columnWidth: CGFloat
    ) {
        switch CalendarInteractionLayout.pagerEndDisposition(
            hasPendingSettle: pendingSettle != nil,
            eventMutationActive: interactionSession.eventMoveActive,
            hasProvisionalEventPreview: interactionSession.eventMovePreview != nil,
            horizontalDragActive: horizontalDragActive
        ) {
        case .resetForEventOwnership:
            resetStripForEventOwnership()
            return
        case .preservePendingSettle:
            return
        case .cancelNonOwnedDrag:
            pagerDragAxisIsHorizontal = nil
            return
        case .settleHorizontalPage:
            guard columnWidth > 0 else {
                pagerDragAxisIsHorizontal = nil
                return
            }
        }

        horizontalDragActive = false
        pagerDragAxisIsHorizontal = nil
        // Release decisions use the strip's true displacement from the
        // anchored page, not the raw gesture translation: after interrupting
        // a settle the strip may already sit most of a column away from rest,
        // and releasing there must complete (or cancel) from THAT position.
        let stripTranslation = Double(horizontalDragOffset)
        let stripPredictedTranslation = Double(
            dragReferenceOffset + (predictedTranslation - dragReferenceTranslation)
        )
        let projection = CalendarInteractionLayout.pagerSettleProjection(
            translation: stripTranslation,
            predictedTranslation: stripPredictedTranslation,
            pageWidth: Double(columnWidth),
            // geonq spec: a swipe slides by exactly one day, and even a hard
            // flick may advance at most to the adjacent day.
            maximumPages: 1
        )
        let settleVelocity = CalendarInteractionLayout.pagerSettleVelocity(
            normalizedTrackerVelocity: columnWidth > 0
                ? fingerVelocity.pixelsPerSecond / Double(columnWidth)
                : 0,
            hasTrackerMomentum: fingerVelocity.hasEstimate,
            projectionVelocity: projection.normalizedVelocity
        )
        let dayDelta = projection.pageDelta
        let nextAnchor = calendar.date(byAdding: .day, value: dayDelta, to: pageAnchor) ?? pageAnchor
        beginSettle(
            dayDelta: dayDelta,
            targetOffset: -columnWidth * CGFloat(dayDelta),
            nextAnchor: nextAnchor,
            normalizedVelocity: settleVelocity,
            columnWidth: columnWidth
        )
    }

    private func beginSettle(
        dayDelta: Int,
        targetOffset: CGFloat,
        nextAnchor: Date,
        normalizedVelocity: Double,
        columnWidth: CGFloat
    ) {
        pagerGeneration += 1
        let settle = CalendarPagerPendingSettle(
            generation: pagerGeneration,
            dayDelta: dayDelta,
            targetOffset: targetOffset,
            nextAnchor: nextAnchor,
            normalizedVelocity: normalizedVelocity
        )
        pendingSettle = settle
        if reduceMotion {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                horizontalDragOffset = targetOffset
            }
            completeSettle(settle)
        } else {
            // Critically damped duration-based spring (bounce = 0): native
            // feel with zero overshoot at the stop. A hard flick shortens
            // the travel instead of adding momentum past the one-day target.
            // The geometry probe completes the recenter at the exact final
            // frame; the timer below is only a dropped-preference safety net.
            let duration = CalendarInteractionLayout.pagerSettleDuration(
                normalizedVelocity: settle.normalizedVelocity
            )
            withAnimation(.spring(duration: duration, bounce: 0)) {
                horizontalDragOffset = targetOffset
            }
            let generation = settle.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) {
                guard let pendingSettle, pendingSettle.generation == generation else { return }
                completeSettle(pendingSettle)
            }
        }
    }

    private func updatePreviewAndCompletion(stripX: CGFloat, columnWidth: CGFloat) {
        guard columnWidth > 0, columnWidth.isFinite, stripX.isFinite else { return }
        // Idle frames carry no information. At rest the strip always sits at
        // its base offset (candidate == pageAnchor by construction), and
        // preference delivery outside an owned gesture is unreliable: the
        // key's default (0) arrives before the probe's real frame and once
        // masqueraded as a two-column drag, previewing a phantom day on
        // first layout with no correcting sample afterwards. Preview and
        // settle completion are only meaningful while a drag owns the strip
        // or a settle animation is in flight.
        guard horizontalDragActive || pendingSettle != nil else { return }
        let effectiveDrag = stripX - stripBaseX(columnWidth: columnWidth)

        // Defense in depth for mid-gesture layout transients. A one-day
        // strip can never physically exceed the drag clamp (1.6 columns),
        // so out-of-reach samples are geometry noise and must not drive the
        // header preview or complete a settle at a bogus offset.
        let physicalReach = columnWidth * 1.6 + 1
        guard abs(effectiveDrag) <= physicalReach else { return }
        // Keep the live rendered displacement fresh: an interrupting grab
        // adopts exactly this value so the strip never jumps.
        liveStripDragOffset = effectiveDrag

        let candidate = CalendarInteractionLayout.pagerPreviewDate(
            pageAnchor: pageAnchor,
            horizontalOffset: Double(effectiveDrag),
            pageWidth: Double(columnWidth),
            dayCount: 1,
            calendar: calendar
        )
        // Only semantic day/month/week boundary changes cross into the parent
        // header, avoiding a parent rebuild for every 1/120-second sample.
        if CalendarInteractionLayout.pagerPreviewBoundaryChanged(
            from: lastPreviewCallbackDate,
            to: candidate,
            calendar: calendar
        ) {
            lastPreviewCallbackDate = candidate
            onPreviewDateChange?(candidate)
        }

        guard let settle = pendingSettle,
              abs(effectiveDrag - settle.targetOffset) <= max(0.75, columnWidth * 0.002) else { return }
        completeSettle(settle)
    }

    private func completeSettle(_ settle: CalendarPagerPendingSettle) {
        guard pendingSettle?.generation == settle.generation,
              pagerGeneration == settle.generation else { return }
        pendingSettle = nil

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // The strip's pixels at the settled offset are identical after
            // re-anchoring, so this swap cannot produce a visible jump.
            horizontalDragOffset = 0
            pageAnchor = calendar.startOfDay(for: settle.nextAnchor)
        }
        if settle.dayDelta == 0 {
            // A cancelled short drag may finish between geometry callbacks;
            // explicitly restore the committed header rather than leaving a
            // fractional in-flight preview behind.
            onPreviewDateChange?(pageAnchor)
            return
        }
        onPreviewDateChange?(pageAnchor)
        onCommitDateChange?(pageAnchor)
    }

    private func dayHeaderStrip(days: [Date], columnWidth: CGFloat, containerWidth: CGFloat) -> some View {
        // Cells only: the shared strip base offset positions the leading
        // visible column right after the pinned gutter, exactly like the
        // timed columns and the all-day chips beneath it. The overlay
        // container owns the day-area mask so pre-mounted leading neighbours
        // slide under the gutter edge instead of showing through it.
        Color.clear
            .frame(width: max(0, containerWidth), height: dayHeaderHeight, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayHeaderCell(day: day, width: columnWidth)
                    }
                }
                .frame(width: CGFloat(days.count) * columnWidth, alignment: .leading)
                // Live strip-position probe for preview/completion sampling.
                // This MUST wrap the offset frame itself: measured here, minX
                // reports the strip's true visual position (base offset +
                // drag/settle). A probe attached outside the full-width
                // container would read a constant layout origin instead and
                // corrupt every derived drag value.
                .background {
                    GeometryReader { probe in
                        Color.clear.preference(
                            key: CalendarStripOffsetPreferenceKey.self,
                            value: probe.frame(in: .named("calendar-horizontal-pager")).minX
                        )
                    }
                }
                .offset(x: stripBaseX(columnWidth: columnWidth) + horizontalDragOffset)
            }
            .calendarDayAreaMask(totalWidth: containerWidth, gutter: timeGutter)
            // Explicit-width pin: a flexible maxWidth frame cannot shrink a
            // fixed-width child, so without this the oversized virtual strip
            // would be CENTERED by the parent stack instead of leading-aligned,
            // shifting every header cell by (strip - viewport) / 2.
            .frame(width: max(0, containerWidth), alignment: .leading)
            .frame(height: dayHeaderHeight, alignment: .leading)
            .background(alignment: .bottom) {
                // Full-width canvas + hairline continue through the gutter zone.
                Rectangle().fill(LifeOSTokens.canvas)
                Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipped()
            .contentShape(Rectangle())
            // The composite surface gesture is intentionally supplemented here.
            // XCTest and VoiceOver can start a swipe from the semantic header
            // probe, while SwiftUI may otherwise route that non-hit-testing probe
            // past the composite recognizer. Both recognizers share the same
            // settle gate, so one physical swipe can only commit once.
            .simultaneousGesture(pagerDragGesture(columnWidth: columnWidth), including: .all)
    }

    private func dayHeaderCell(day: Date, width: CGFloat) -> some View {
        let dayHolidays = holidays.filter { calendar.isDate($0.date, inSameDayAs: day) }
        return VStack(spacing: 2) {
            Text(day, format: .dateTime.weekday(.abbreviated))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            CalendarDayHeaderNumber(
                day: day,
                calendar: calendar,
                namespace: monthNamespace,
                isSelected: monthSelectedDate.map { calendar.isDate(day, inSameDayAs: $0) } ?? false,
                isSource: !monthExpanded,
                reduceMotion: reduceMotion
            )
            if let holiday = dayHolidays.first {
                Text(holiday.name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(LifeOSTokens.accent)
                    .lineLimit(1)
            }
        }
        .frame(width: width, height: dayHeaderHeight)
        .background(calendar.isDateInToday(day) ? CalendarEventVisuals.today.opacity(0.08) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
    }

    private func hourLabels(contentHeight: CGFloat) -> some View {
        let scale = CalendarInteractionLayout.timelineScale(
            day: pageAnchor,
            hourHeight: Double(hourHeight),
            calendar: calendar
        )
        let dayMinutes = scale?.dayMinutes ?? 1_440
        let marks = Array(stride(from: 0, through: dayMinutes, by: 60))
        return ZStack(alignment: .topTrailing) {
            ForEach(marks, id: \.self) { minute in
                let date = scale.flatMap {
                    $0.date(for: Double(minute) / 60 * Double(hourHeight), calendar: calendar, snappingTo: 1)
                }
                Text(CalendarInteractionLayout.timelineHourLabel(
                    minute: minute,
                    dayMinutes: dayMinutes,
                    date: date,
                    calendar: calendar
                ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .offset(y: CGFloat(scale?.y(for: date ?? .now, calendar: calendar) ?? Double(minute) / 60 * Double(hourHeight)))
                    .id(minute / 60)
                    // Keep the real 24:00 label as the UI probe for the
                    // trailing endpoint. It does not add height or alter the
                    // finite viewport.
                    .accessibilityIdentifier(minute == dayMinutes ? "calendar-timeline-end" : "")
            }
        }
    }

    /// Starts near the first useful daytime event instead of an empty midnight
    /// grid. Overnight events remain available by scrolling upward. Runs once
    /// per strip lifetime so settled swipes preserve the reader's position.
    private var initialVisibleHour: Int {
        let visibleDayStarts = Set(visibleWindow.map { calendar.startOfDay(for: $0) })
        let firstDaytimeEventHour = items
            .filter { visibleDayStarts.contains(calendar.startOfDay(for: $0.start)) && $0.end.timeIntervalSince($0.start) <= 12 * 60 * 60 }
            .map { calendar.component(.hour, from: $0.start) }
            .filter { $0 >= 6 }
            .min()
        return max(0, min(8, (firstDaytimeEventHour ?? 9) - 1))
    }
}

/// The sliding all-day lane for the iPhone day strip. Entries are laid out
/// across the virtual day range so multi-day bars stay continuous while the
/// strip slides; the localized label stays pinned over the gutter.
private struct CalendarAllDayLaneStrip: View {
    let days: [Date]
    let visibleDays: [Date]
    let items: [CalendarItem]
    let calendar: Calendar
    let columnWidth: CGFloat
    let slideOffset: CGFloat
    let timeGutter: CGFloat
    let onSelect: ((CalendarItem) -> Void)?
    let onCreateAllDay: ((Date) -> Void)?

    /// Virtual neighbours are mounted so a multi-day bar can track the pager,
    /// but events that live only in those neighbours must not consume rows in
    /// the settled visible lane. The row contract is defined by the visible
    /// day window; an event crossing into that window remains included.
    private var visibleLayoutItems: [CalendarItem] {
        guard let firstDay = visibleDays.first,
              let lastDay = visibleDays.last,
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) else {
            return []
        }
        let start = calendar.startOfDay(for: firstDay)
        return items.filter { item in
            !item.isDeleted && item.start < end && item.end > start
        }
    }

    private var placements: [CalendarAllDayLayout.Placement] {
        CalendarAllDayLayout.placements(items: visibleLayoutItems, days: days, calendar: calendar)
    }

    private var rowCount: Int {
        CalendarAllDayLayout.rowCount(items: visibleLayoutItems, days: days, calendar: calendar)
    }

    private var laneHeight: CGFloat {
        CGFloat(CalendarAllDayLayout.height(items: visibleLayoutItems, days: days, calendar: calendar))
    }

    private var accessibilitySummary: String {
        let count = placements.count
        let eventWord = count == 1 ? "event" : "events"
        let rowWord = rowCount == 1 ? "row" : "rows"
        return "\(count) \(eventWord), \(rowCount) \(rowWord)"
    }

    private struct VisibleEmptyCell: Identifiable {
        let day: Date
        let frame: CGRect

        var id: Date { day }
    }

    /// Empty-cell semantics belong only to the settled visible window. The
    /// virtual strip still supplies the rendered background and event rows,
    /// but its neighbouring columns must never leak stale/offscreen AX frames.
    private var visibleEmptyCells: [VisibleEmptyCell] {
        visibleDays.compactMap { day in
            guard let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: day) }),
                  let frame = CalendarAllDayLayout.trailingEmptyCellFrame(
                      dayIndex: index,
                      dayWidth: Double(columnWidth),
                      items: visibleLayoutItems,
                      days: days,
                      calendar: calendar
                  ) else {
                return nil
            }
            return VisibleEmptyCell(day: day, frame: frame)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The moving strip lives in a masked overlay container: virtual
            // neighbour columns slide under the pinned gutter edge instead
            // of bleeding into it at rest.
            Color.clear
                .frame(width: CGFloat(days.count) * columnWidth, height: laneHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(LifeOSTokens.canvas)
                        ForEach(days.indices, id: \.self) { index in
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 1, height: laneHeight)
                                .offset(x: CGFloat(index + 1) * columnWidth - 1)
                        }
                        ForEach(placements, id: \.renderID) { placement in
                            CalendarAllDayEventChip(
                                item: placement.item,
                                calendar: calendar,
                                action: onSelect.map { handler in { handler(placement.item) } }
                            )
                            .frame(
                                width: max(1, columnWidth * CGFloat(placement.dayCount) - 2),
                                height: CalendarAllDayLayout.rowHeight - 4,
                                alignment: .leading
                            )
                            .offset(
                                x: CGFloat(placement.firstDayIndex) * columnWidth + 1,
                                y: CGFloat(placement.row) * (CalendarAllDayLayout.rowHeight + CGFloat(CalendarAllDayLayout.rowSpacing)) + 2
                            )
                        }
                        ForEach(visibleEmptyCells) { cell in
                            CalendarAllDayEmptyCell(
                                day: cell.day,
                                calendar: calendar,
                                onCreate: onCreateAllDay
                            )
                            .frame(width: cell.frame.width, height: cell.frame.height)
                            .offset(x: cell.frame.minX, y: cell.frame.minY)
                            .allowsHitTesting(onCreateAllDay != nil)
                            .accessibilityHidden(onCreateAllDay == nil)
                        }
                    }
                    .frame(width: CGFloat(days.count) * columnWidth, height: laneHeight, alignment: .topLeading)
                    .offset(x: slideOffset)
                }
                .calendarDayAreaMask(
                    totalWidth: timeGutter + columnWidth * CGFloat(max(1, visibleDays.count)),
                    gutter: timeGutter
                )
            Text(Locale.current.identifier.hasPrefix("de") ? "Ganztägig" : "All-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: timeGutter - 8, height: laneHeight, alignment: .trailing)
                .padding(.trailing, 8)
                .background(LifeOSTokens.canvas)
        }
        // Pin the lane to the actual viewport width. Without an explicit
        // width, the oversized virtual strip participates in the flexible
        // ZStack's ideal-size calculation and SwiftUI shifts the whole lane
        // left; the header and timed strip then disagree about the visible
        // day columns (and AX frames inherit that shift).
        .frame(
            width: timeGutter + columnWidth * CGFloat(max(1, visibleDays.count)),
            height: laneHeight,
            alignment: .leading
        )
        .background(LifeOSTokens.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All-day events")
        .accessibilityIdentifier("calendar-all-day-lane")
        .accessibilityValue(accessibilitySummary)
    }

}

private struct CalendarAllDayEmptyCell: View {
    let day: Date
    let calendar: Calendar
    let onCreate: ((Date) -> Void)?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                createAllDayEvent()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Empty all-day cell")
            .accessibilityValue(calendarISODate(day))
            .accessibilityHint("Double-tap to create an all-day event")
            .accessibilityIdentifier(
                CalendarAllDayLayout.trailingEmptyCellAccessibilityIdentifier(
                    for: day,
                    calendar: calendar
                )
            )
            .accessibilityAction(named: "Create all-day event") {
                createAllDayEvent()
            }
    }

    private func createAllDayEvent() {
        guard let interval = CalendarAllDayLayout.creationInterval(for: day, calendar: calendar) else { return }
        CalendarInteractionHaptics.grab()
        onCreate?(interval.start)
    }

    private func calendarISODate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private enum CalendarTimelineScrollAnchor {
    static func id(for hour: Int) -> String {
        "calendar-timeline-hour-\(max(0, hour))"
    }
}

/// Real vertical layout targets for ScrollViewReader. The previous targets
/// were offset hour-label Text views inside a ZStack, which could resolve to
/// the label's unscrolled layout frame rather than the timed grid coordinate.
private struct CalendarTimelineHourAnchors: View {
    let hourHeight: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Color.clear
                    .frame(width: 1, height: hourHeight)
                    .id(CalendarTimelineScrollAnchor.id(for: hour))
            }
        }
        .frame(width: 1, height: totalHeight, alignment: .top)
        .accessibilityHidden(true)
    }
}
#endif

private struct CalendarAllDayRow: View {
    static let minimumHeight = CGFloat(CalendarAllDayLayout.rowHeight)

    let days: [Date]
    let items: [CalendarItem]
    let calendar: Calendar
    let timeGutter: CGFloat
    let width: CGFloat
    let onSelect: ((CalendarItem) -> Void)?

    private var placements: [CalendarAllDayLayout.Placement] {
        CalendarAllDayLayout.placements(items: items, days: days, calendar: calendar)
    }

    private var laneHeight: CGFloat {
        CGFloat(CalendarAllDayLayout.height(items: items, days: days, calendar: calendar))
    }

    private var rowCount: Int {
        CalendarAllDayLayout.rowCount(items: items, days: days, calendar: calendar)
    }

    private var accessibilitySummary: String {
        let eventWord = placements.count == 1 ? "event" : "events"
        let rowWord = rowCount == 1 ? "row" : "rows"
        return "\(placements.count) \(eventWord), \(rowCount) \(rowWord)"
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(Locale.current.identifier.hasPrefix("de") ? "Ganztägig" : "All-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: timeGutter - 8, height: laneHeight, alignment: .trailing)
                .padding(.trailing, 8)
            ZStack(alignment: .topLeading) {
                ForEach(days.indices, id: \.self) { index in
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: laneHeight)
                        .offset(x: CGFloat(index + 1) * dayWidth - 1)
                }
                ForEach(placements, id: \.renderID) { placement in
                    CalendarAllDayEventChip(
                        item: placement.item,
                        calendar: calendar,
                        action: onSelect.map { handler in { handler(placement.item) } }
                    )
                    .frame(
                        width: max(1, dayWidth * CGFloat(placement.dayCount) - 2),
                        height: Self.minimumHeight - 4,
                        alignment: .leading
                    )
                    .offset(
                        x: CGFloat(placement.firstDayIndex) * dayWidth + 1,
                        y: CGFloat(placement.row) * (Self.minimumHeight + CGFloat(CalendarAllDayLayout.rowSpacing)) + 2
                    )
                }
            }
            .frame(width: max(0, width - timeGutter), height: laneHeight, alignment: .topLeading)
        }
        .frame(width: width, height: laneHeight, alignment: .leading)
        .background(LifeOSTokens.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All-day events")
        .accessibilityIdentifier("calendar-all-day-lane")
        .accessibilityValue(accessibilitySummary)
    }

    private var dayWidth: CGFloat {
        max(1, (width - timeGutter) / CGFloat(max(days.count, 1)))
    }
}

private struct CalendarAllDayEventChip: View {
    let item: CalendarItem
    let calendar: Calendar
    let action: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(CalendarEventVisuals.accent)
                .frame(width: 3)
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .background(CalendarEventVisuals.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), all day")
        .accessibilityValue(
            "\(calendarISODate(item.start)) to \(calendarISODate(item.end))"
        )
        .accessibilityIdentifier("calendar-all-day-event-\(CalendarAllDayLayout.renderIdentity(for: item))")
    }

    private func calendarISODate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private struct CalendarDayTimeline: View {
    let day: Date
    let items: [CalendarItem]
    let hourHeight: CGFloat
    let calendar: Calendar
    let onSelect: CalendarEventSelectionHandler
    let onCreate: ((Date) -> Void)?
    let onCreateTimedRange: ((Date, Date, CalendarTimedCreationAnchor) -> Void)?
    let timedCreationPreview: CalendarTimedCreationPreview?
    let onTimedCreationDraft: ((CalendarTimedCreationPreview?) -> Void)?
    let onUpdate: CalendarUpdateHandler?
    let onStatusUpdate: CalendarStatusUpdateHandler?
    let monthNamespace: Namespace.ID?
    let monthExpanded: Bool
    let monthSelectedDate: Date?
    let reduceMotion: Bool
    let isInteractionEnabled: Bool
    let interactionSession: CalendarInteractionSession
    let onVerticalPan: ((CGFloat) -> Void)?
#if os(iOS)
    @State private var pressCreationActive = false
    @State private var pressCreationSnapMinutes: Int?
#endif

    private var interval: DateInterval {
        let start = calendar.startOfDay(for: day)
        return calendar.dateInterval(of: .day, for: start) ?? DateInterval(start: start, end: start)
    }

    private var timedItems: [CalendarItem] {
        items.filter { !CalendarAllDayLayout.isAllDay($0, calendar: calendar) }
    }

    private var basePlacements: [CalendarEventPlacement] {
        CalendarOverlapLayout.layout(items: timedItems, interval: interval)
    }

    private var provisionalPlacements: [CalendarEventPlacement] {
        guard let preview = interactionSession.eventMovePreview else { return basePlacements }
        return CalendarOverlapLayout.layoutWithProvisionalMove(
            items: timedItems,
            movingItemID: preview.item.id,
            provisionalStart: preview.start,
            provisionalEnd: preview.end,
            interval: interval
        )
    }

    private var renderedPlacements: [CalendarEventPlacement] {
        guard let preview = interactionSession.eventMovePreview else { return basePlacements }
        return provisionalPlacements.filter { $0.id != preview.item.id }
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = CalendarInteractionLayout.timelineScale(
                day: day,
                hourHeight: Double(hourHeight),
                calendar: calendar
            ) ?? CalendarTimelineScale(interval: interval, hourHeight: Double(hourHeight))
            let totalHeight = CGFloat(scale.totalHeight)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0...24, id: \.self) { hour in
                        Rectangle()
                            .fill(Color.primary.opacity(0.075))
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                            .offset(y: CGFloat(hour) * hourHeight)
                    }
                }
                .frame(height: totalHeight, alignment: .top)

                Color.clear
                    .contentShape(Rectangle())
#if os(iOS)
                    .simultaneousGesture(creationGesture)
                    // A quick vertical pan must remain native ScrollView
                    // scrolling. The press sequence still claims an
                    // intentional creation after its hold threshold.
                    .simultaneousGesture(creationPressDragGesture(proxy: proxy))
                    .simultaneousGesture(emptyGridVerticalTimelinePanGesture(proxy: proxy))
#else
                    .simultaneousGesture(macDoubleClickGesture(proxy: proxy))
                    .simultaneousGesture(macCreationDragGesture(proxy: proxy))
#endif
                    .accessibilityIdentifier("calendar-empty-timed-grid-\(calendarISODate(day))")
                    .accessibilityHidden(!isInteractionEnabled)

                ForEach(renderedPlacements, id: \.renderID) { placement in
                    eventLayer(
                        placement: placement,
                        item: placement.item,
                        scale: scale,
                        width: proxy.size.width,
                        namedSpaceFrame: proxy.frame(in: .named(CalendarEditorAnchorGeometry.coordinateSpaceName)),
                        interactive: true
                    )
                }

                if let preview = interactionSession.eventMovePreview,
                   let movedItem = preview.movedItem,
                   let targetPlacement = provisionalPlacements.first(where: { $0.id == movedItem.id }),
                   CalendarInteractionLayout.provisionalRenderState(
                       sourceDate: preview.item.start,
                       destinationDate: movedItem.start,
                       calendar: calendar
                   ) == .destinationOnly {
                    // The destination is a visual-only ghost. Its placement
                    // participates in overlap calculation, but it cannot
                    // steal the source drag or expose a duplicate AX event.
                    eventLayer(
                        placement: targetPlacement,
                        item: movedItem,
                        scale: scale,
                        width: proxy.size.width,
                        namedSpaceFrame: proxy.frame(in: .named(CalendarEditorAnchorGeometry.coordinateSpaceName)),
                        interactive: false
                    )
                    .opacity(0.78)
                    .zIndex(Double(targetPlacement.depth) + 1)
                }

                if let preview = interactionSession.eventMovePreview,
                   calendar.isDate(preview.item.start, inSameDayAs: day),
                   let sourcePlacement = basePlacements.first(where: { $0.id == preview.item.id }) {
                    // Keep the source card as the sole interactive drag
                    // surface. Its existing move offset carries it toward the
                    // destination while source siblings use provisional lanes.
                    let renderState = CalendarInteractionLayout.provisionalRenderState(
                        sourceDate: preview.item.start,
                        destinationDate: preview.movedItem?.start ?? preview.item.start,
                        calendar: calendar
                    )
                    eventLayer(
                        placement: sourcePlacement,
                        item: preview.item,
                        scale: scale,
                        width: proxy.size.width,
                        namedSpaceFrame: proxy.frame(in: .named(CalendarEditorAnchorGeometry.coordinateSpaceName)),
                        interactive: true
                    )
                    // A cross-day source remains the gesture owner, but the
                    // destination ghost is the only visible provisional card.
                    .opacity(renderState == .destinationOnly ? 0 : 1)
                    .accessibilityHidden(renderState == .destinationOnly)
                    .allowsHitTesting(isInteractionEnabled)
                    .zIndex(8)
                }

                if let timedPreview = timedCreationPreview,
                   calendar.isDate(timedPreview.day, inSameDayAs: day),
                   calendar.isDate(timedPreview.start, inSameDayAs: day) {
                    CalendarCreationRangeGhost(
                        start: timedPreview.start,
                        end: timedPreview.end,
                        day: day,
                        hourHeight: hourHeight,
                        calendar: calendar
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zIndex(7)
                }

            }
            .frame(height: totalHeight)
            .background(calendar.isDateInToday(day) ? CalendarEventVisuals.today.opacity(0.025) : .clear)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
        }
        .frame(height: CGFloat(CalendarInteractionLayout.timelineScale(
            day: day,
            hourHeight: Double(hourHeight),
            calendar: calendar
        )?.totalHeight ?? Double(hourHeight * 24)))
    }

    @ViewBuilder
    private func eventLayer(
        placement: CalendarEventPlacement,
        item: CalendarItem,
        scale: CalendarTimelineScale,
        width: CGFloat,
        namedSpaceFrame: CGRect,
        interactive: Bool
    ) -> some View {
        let layerFrame = placement.layerFrame(containerWidth: Double(width), edgeInset: 1)
        let layerWidth = CGFloat(layerFrame.width)
        let y = CGFloat(scale.y(for: placement.visibleStart, calendar: calendar))
        let rawHeight = CGFloat(scale.height(
            from: placement.visibleStart,
            to: placement.visibleEnd,
            calendar: calendar
        ))
        let renderedHeight = max(24, rawHeight - 2)
        let eventRect = CGRect(
            x: CGFloat(layerFrame.leading),
            y: y + 1,
            width: layerWidth,
            height: renderedHeight
        )
#if os(macOS)
        let selection: () -> Void = interactive ? {
            guard let sourceFrame = CalendarEditorAnchorGeometry.frame(
                forLocalRect: eventRect,
                inNamedSpace: namedSpaceFrame
            ) else { return }
            onSelect(item, sourceFrame)
        } : {}
#else
        let selection: () -> Void = interactive ? { onSelect(item) } : {}
#endif
        CalendarInteractiveTimelineEvent(
            item: item,
            compact: rawHeight < 44,
            narrow: layerWidth < 82,
            availableHeight: renderedHeight,
            hidesSecondaryMetadata: placement.depth == 0 && placement.columnCount > 1,
            timeZone: item.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone,
            cornerRadii: placement.cornerRadii,
            day: day,
            hourHeight: hourHeight,
            dayWidth: width,
            eventWidth: layerWidth,
            calendar: calendar,
            reduceMotion: reduceMotion,
            isInteractionEnabled: interactive && isInteractionEnabled,
            interactionSession: interactionSession,
            onSelect: selection,
            onUpdate: interactive ? onUpdate : nil,
            onStatusUpdate: interactive ? onStatusUpdate : nil,
            onVerticalPan: interactive ? onVerticalPan : nil
        )
        .frame(width: layerWidth, alignment: .topLeading)
        .offset(x: CGFloat(layerFrame.leading), y: y + 1)
        .zIndex(Double(placement.depth) + 1)
        .accessibilityHidden(!(interactive && isInteractionEnabled))
        .allowsHitTesting(interactive && isInteractionEnabled)
    }

    /// iOS empty-space creation is intentionally a double tap. A single tap
    /// and every ordinary vertical scroll remain inert; only the two-tap
    /// recognizer creates a default timed range.
    private var creationGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                guard isInteractionEnabled,
                      let interval = CalendarInteractionLayout.creationInterval(
                          day: day,
                          verticalStart: Double(value.location.y),
                          verticalEnd: Double(value.location.y),
                          hourHeight: Double(hourHeight),
                          calendar: calendar,
                          defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
                      ) else { return }
                CalendarInteractionHaptics.grab()
                onCreateTimedRange?(interval.start, interval.end, .zero)
            }
    }

    /// Notion-style press-and-drag creation on the empty grid. A hold claims
    /// both pager axes exactly like an event move, every finger sample maps
    /// through one pure layout function so the live ghost and the committed
    /// range can never disagree, and release commits either the drafted range
    /// or the anchor's default block. Double-tap creation remains available.
#if os(iOS)
    private func creationPressDragGesture(proxy: GeometryProxy) -> some Gesture {
            LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { phase in
                guard case .second(true, let drag?) = phase else { return }
                guard !isTimedEventPoint(drag.startLocation, in: proxy) else { return }
                guard isInteractionEnabled,
                      let sample = CalendarInteractionLayout.creationPressDragSample(
                        day: day,
                        anchorY: Double(drag.startLocation.y),
                        currentY: Double(drag.location.y),
                        hourHeight: Double(hourHeight),
                        calendar: calendar
                      ) else { return }
                if !pressCreationActive {
                    // A pending creation hold must not block ordinary
                    // vertical scrolling. Claim the shared session only once
                    // the hold has produced a valid creation sample.
                    interactionSession.eventMoveActive = true
                    pressCreationActive = true
                    CalendarInteractionHaptics.grab()
                    pressCreationSnapMinutes = 0
                }
                let snapped = CalendarInteractionLayout.snappedMinuteDelta(
                    translation: Double(drag.translation.height),
                    hourHeight: Double(hourHeight)
                )
                if pressCreationSnapMinutes != snapped {
                    CalendarInteractionHaptics.snap()
                    pressCreationSnapMinutes = snapped
                }
                onTimedCreationDraft?(creationDraftPreview(for: sample.interval))
            }
            .onEnded { phase in
                let ownedCreation = pressCreationActive
                defer {
                    pressCreationActive = false
                    pressCreationSnapMinutes = nil
                    if ownedCreation {
                        interactionSession.eventMoveActive = false
                    }
                }
                guard isInteractionEnabled,
                      case .second(_, let drag?) = phase,
                      !isTimedEventPoint(drag.startLocation, in: proxy),
                      let sample = CalendarInteractionLayout.creationPressDragSample(
                        day: day,
                        anchorY: Double(drag.startLocation.y),
                        currentY: Double(drag.location.y),
                        hourHeight: Double(hourHeight),
                        calendar: calendar
                      ) else {
                    onTimedCreationDraft?(nil)
                    return
                }
                // The commit overwrites the live draft with the authoritative
                // range; the parent keeps it mounted behind the editor sheet.
                onCreateTimedRange?(sample.interval.start, sample.interval.end, .zero)
            }
    }

    private func creationDraftPreview(for interval: DateInterval) -> CalendarTimedCreationPreview {
        CalendarTimedCreationPreview(day: interval.start, start: interval.start, end: interval.end)
    }

    /// The empty grid's sequenced creation recognizer can delay the ancestor
    /// ScrollView pan until its hold threshold. Keep a narrow fallback for a
    /// deliberate quick vertical drag, matching the event-row fallback while
    /// leaving event points and press-created ranges to their own owners.
    private func emptyGridVerticalTimelinePanGesture(proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onEnded { value in
                guard isInteractionEnabled,
                      !interactionSession.eventMoveActive,
                      !isTimedEventPoint(value.startLocation, in: proxy),
                      abs(value.translation.height) > abs(value.translation.width),
                      abs(value.translation.height) >= 12 else { return }
                onVerticalPan?(value.translation.height)
            }
    }

    private func isTimedEventPoint(_ point: CGPoint, in proxy: GeometryProxy) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        guard let scale = CalendarInteractionLayout.timelineScale(
            day: day,
            hourHeight: Double(hourHeight),
            calendar: calendar
        ) else { return false }

        return basePlacements.contains { placement in
            let layerFrame = placement.layerFrame(
                containerWidth: Double(proxy.size.width),
                edgeInset: 1
            )
            let startY = CGFloat(scale.y(for: placement.visibleStart, calendar: calendar))
            let rawHeight = CGFloat(scale.height(
                from: placement.visibleStart,
                to: placement.visibleEnd,
                calendar: calendar
            ))
            let eventFrame = CGRect(
                x: CGFloat(layerFrame.leading),
                y: startY + 1,
                width: CGFloat(layerFrame.width),
                height: max(24, rawHeight - 2)
            )
            return eventFrame.contains(point)
        }
    }
#endif

#if os(macOS)
    private func macDoubleClickGesture(proxy: GeometryProxy) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                guard isInteractionEnabled,
                      let interval = CalendarInteractionLayout.creationInterval(
                          day: day,
                          verticalStart: Double(value.location.y),
                          verticalEnd: Double(value.location.y),
                          hourHeight: Double(hourHeight),
                          calendar: calendar,
                          defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
                      ) else { return }
                guard let sourceFrame = editorAnchorFrame(for: value.location, in: proxy) else { return }
                onCreateTimedRange?(interval.start, interval.end, sourceFrame)
            }
    }

    /// A drag is considered a creation gesture only after it has moved far
    /// enough to express a duration. A single click therefore remains inert,
    /// while a 15-minute-or-longer vertical selection creates the exact range
    /// under the pointer.
    private func macCreationDragGesture(proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onEnded { value in
                guard isInteractionEnabled,
                      CalendarInteractionLayout.isIntentionalCreationDrag(
                          verticalTranslation: Double(value.translation.height),
                          horizontalTranslation: Double(value.translation.width),
                          horizontalLimit: max(28, Double(proxy.size.width * 0.45))
                      ),
                      let interval = CalendarInteractionLayout.creationInterval(
                          day: day,
                          verticalStart: Double(value.startLocation.y),
                          verticalEnd: Double(value.location.y),
                          hourHeight: Double(hourHeight),
                          calendar: calendar
                      ) else { return }
                guard let sourceFrame = editorAnchorFrame(for: value.startLocation, in: proxy) else { return }
                onCreateTimedRange?(interval.start, interval.end, sourceFrame)
            }
    }

    private func editorAnchorFrame(for location: CGPoint, in proxy: GeometryProxy) -> CGRect? {
        CalendarEditorAnchorGeometry.sourceFrame(
            forLocalPoint: location,
            inNamedSpace: proxy.frame(in: .named(CalendarEditorAnchorGeometry.coordinateSpaceName))
        )
    }
#endif

    private func calendarISODate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int, to width: Int) -> String {
            let raw = String(value)
            return String(repeating: "0", count: max(0, width - raw.count)) + raw
        }
        return "\(padded(parts.year ?? 0, to: 4))-\(padded(parts.month ?? 0, to: 2))-\(padded(parts.day ?? 0, to: 2))"
    }
}

private enum CalendarInteractionHaptics {
    static func grab() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
#endif
    }

    static func snap() {
#if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
#endif
    }
}

private struct CalendarCreationRangeGhost: View {
    let start: Date
    let end: Date
    let day: Date
    let hourHeight: CGFloat
    let calendar: Calendar

    var body: some View {
        GeometryReader { proxy in
            let scale = CalendarInteractionLayout.timelineScale(
                day: day,
                hourHeight: Double(hourHeight),
                calendar: calendar
            )
            let startY = scale?.y(for: start, calendar: calendar) ?? 0
            let endY = scale.map { startY + $0.height(from: start, to: end, calendar: calendar) } ?? startY
            let rangeHeight = max(1, CGFloat(endY - startY))
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CalendarEventVisuals.accent.opacity(0.20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CalendarEventVisuals.accent.opacity(0.66), lineWidth: 1)
                    }
                VStack(spacing: 0) {
                    CalendarCreationHandle()
                    Spacer(minLength: 0)
                    CalendarCreationHandle()
                }
                .padding(.vertical, 3)
            }
            .frame(width: max(0, proxy.size.width - 2), height: rangeHeight)
            .offset(x: 1, y: CGFloat(startY) + 1)
        }
        .frame(height: hourHeight * 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New event selection")
        .accessibilityValue(
            "\(CalendarTimelineScale.localizedTimeLabel(for: start, calendar: calendar)) to " +
            CalendarTimelineScale.localizedTimeLabel(for: end, calendar: calendar)
        )
        .accessibilityIdentifier("calendar-creation-range-ghost")
    }
}

private struct CalendarCreationHandle: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(CalendarEventVisuals.accent.opacity(0.80))
            .frame(width: 30, height: 4)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            }
    }
}

private struct CalendarInteractiveTimelineEvent: View {
    let item: CalendarItem
    let compact: Bool
    let narrow: Bool
    let availableHeight: CGFloat
    let hidesSecondaryMetadata: Bool
    let timeZone: TimeZone
    let cornerRadii: CalendarEventCornerRadii
    let day: Date
    let hourHeight: CGFloat
    let dayWidth: CGFloat
    let eventWidth: CGFloat
    let calendar: Calendar
    let reduceMotion: Bool
    let isInteractionEnabled: Bool
    let interactionSession: CalendarInteractionSession
    let onSelect: () -> Void
    let onUpdate: CalendarUpdateHandler?
    let onStatusUpdate: CalendarStatusUpdateHandler?
    let onVerticalPan: ((CGFloat) -> Void)?

    @State private var moveMinutes = 0
    @State private var moveDays = 0
    @State private var resizeMinutes = 0
    @State private var isMoving = false
    @State private var isResizing = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @State private var suppressTap = false
    @State private var moveStartIsBody = false
    @State private var moveStartCaptured = false
    @State private var lastMoveSnap: Int?
    @State private var lastResizeSnap: Int?
    /// Covers the interval between handing move/resize to the coordinator and
    /// its local durability completion. Accessibility actions do not always
    /// leave a provisional preview mounted, so this local flag is part of the
    /// arbitration contract as well.
    @State private var mutationCommitInFlight = false

    private var isInteracting: Bool { isMoving || isResizing }
    var body: some View {
        CalendarTimelineEvent(
            item: item,
            compact: compact,
            narrow: narrow,
            availableHeight: availableHeight,
            hidesSecondaryMetadata: hidesSecondaryMetadata,
            timeZone: timeZone,
            cornerRadii: cornerRadii,
            accessibilityID: eventAccessibilityID,
            // The card owns only selection/move rendering. The interactive
            // Todo control is installed as an outer sibling below, after the
            // card gestures, so the parent card cannot shield its hit test.
        )
        .frame(height: max(24, availableHeight + CGFloat(resizeMinutes) / 60 * hourHeight), alignment: .top)
        .accessibilityIdentifier(eventAccessibilityID)
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: "Move earlier 15 minutes") { commitMove(minutes: -15) }
        .accessibilityAction(named: "Move later 15 minutes") { commitMove(minutes: 15) }
        .accessibilityAction(named: "Move to previous day") { commitMove(dayDelta: -1) }
        .accessibilityAction(named: "Move to next day") { commitMove(dayDelta: 1) }
        .overlay(alignment: .bottom) { resizeHandle }
#if os(macOS)
        .overlay(alignment: .topTrailing) {
            macHoverControls
        }
#endif
        .offset(
            x: CGFloat(moveDays) * dayWidth,
            y: CGFloat(moveMinutes) / 60 * hourHeight
        )
        .scaleEffect(isInteracting && !reduceMotion ? 1.03 : 1)
        .shadow(color: .black.opacity(isInteracting && !reduceMotion ? 0.24 : 0), radius: isInteracting ? 8 : 0, y: isInteracting ? 4 : 0)
        .contentShape(Rectangle())
#if os(macOS)
        .simultaneousGesture(tapGesture)
        .highPriorityGesture(moveGesture, including: .gesture)
#else
        // The sequenced long-press move must own an event-body drag before
        // the surrounding vertical timeline/pager consumes it. A quick
        // vertical drag fails the bounded long press and is handled by the
        // explicit vertical fallback below; an intentional hold therefore
        // cannot be reinterpreted as timeline scrolling.
        .simultaneousGesture(tapGesture)
        .highPriorityGesture(moveGesture, including: .gesture)
        .simultaneousGesture(verticalTimelinePanGesture)
#endif
        .simultaneousGesture(moveStartClassifier)
        .animation(reduceMotion ? nil : LifeOSMotion.primary, value: item.start)
        .accessibilityHidden(!isInteractionEnabled)
#if os(macOS)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .onMoveCommand { direction in
            switch direction {
            case .left: commitMove(dayDelta: -1)
            case .right: commitMove(dayDelta: 1)
            case .up: commitMove(minutes: -15)
            case .down: commitMove(minutes: 15)
            @unknown default: break
            }
        }
#endif
        .overlay(alignment: .topLeading) {
            if showsTodoToggle {
                todoToggleOverlay
            }
        }
    }

    private var showsTodoToggle: Bool {
        isInteractionEnabled && item.kind == .todo && onStatusUpdate != nil
    }

    private var todoHitTargetHeight: CGFloat {
        min(44, max(24, availableHeight))
    }

    private var todoHitTargetWidth: CGFloat {
        min(44, max(0, eventWidth))
    }

    private var todoTapRect: CGRect {
        CGRect(x: 0, y: 0, width: todoHitTargetWidth, height: todoHitTargetHeight)
    }

    private var todoGlyphSize: CGFloat {
        min(18, todoHitTargetWidth, todoHitTargetHeight)
    }

    private var todoToggleOverlay: some View {
        Button(action: toggleTodo) {
            ZStack(alignment: .topLeading) {
                Image(systemName: item.status == .done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: todoGlyphSize, height: todoGlyphSize)
            }
            .frame(width: todoHitTargetWidth, height: todoHitTargetHeight, alignment: .center)
        }
        .buttonStyle(.plain)
        .frame(width: todoHitTargetWidth, height: todoHitTargetHeight)
        .contentShape(Rectangle())
        .disabled(!canToggleTodo)
        .accessibilityLabel(item.status == .done ? "Mark to-do incomplete" : "Mark to-do complete")
        .accessibilityValue(canToggleTodo ? item.status.label : "Temporarily unavailable")
        .accessibilityIdentifier("calendar-todo-toggle-\(CalendarAllDayLayout.renderIdentity(for: item))")
        .zIndex(20)
        // Physical taps are routed through the card's spatial recognizer;
        // this stable Button remains the accessibility target without
        // shielding that recognizer from the underlying event surface.
        .allowsHitTesting(false)
    }

    private func toggleTodo() {
        guard canToggleTodo, let onStatusUpdate else { return }
        suppressTap = true
        interactionSession.statusMutationActive = true
        let nextStatus: CalendarProgress = item.status == .done ? .planned : .done
        onStatusUpdate(item, nextStatus) { _ in
            DispatchQueue.main.async {
                interactionSession.statusMutationActive = false
                // A tap can leave the sequenced long-press recognizer in its
                // first phase while the status save is in flight. Recover the
                // complete non-moving session after either save result so the
                // persisted status cannot remain permanently unavailable.
                clearEventMutationSession(resetTap: true)
            }
        }
    }

    private var canToggleTodo: Bool {
        isInteractionEnabled &&
            item.kind == .todo &&
            onStatusUpdate != nil &&
            !interactionSession.eventMoveActive &&
            interactionSession.eventMovePreview == nil &&
            !interactionSession.statusMutationActive &&
            !mutationCommitInFlight
    }

    private func clearEventMutationSession(resetTap: Bool = false) {
        let cleanup = CalendarGestureArbitration.cleanupAfterCancelledMutation(
            settledPage: day,
            calendar: calendar
        )
        interactionSession.eventMoveActive = cleanup.eventMoveActive
        interactionSession.eventMovePreview = nil
        if resetTap { suppressTap = false }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .local).onEnded { value in
            guard !suppressTap, !isInteracting, !mutationCommitInFlight else { return }
            if showsTodoToggle, todoTapRect.contains(value.location) {
                // LongPressGesture may have claimed the shared session in its
                // first phase before this spatial tap wins. A plain Todo tap
                // is not a move, so release that stale claim before the
                // status guard evaluates.
                clearEventMutationSession()
                toggleTodo()
                return
            }
            // Let a control button finish its action before the card's tap
            // recognizer is allowed to select the event.  Two turns also
            // covers AppKit's Button/action delivery order on macOS.
            DispatchQueue.main.async {
                guard !suppressTap, !isInteracting, !mutationCommitInFlight else { return }
                DispatchQueue.main.async {
                    guard !suppressTap, !isInteracting, !mutationCommitInFlight else { return }
                    // LongPressGesture can claim the shared session in its
                    // first phase before a normal tap wins. If presentation
                    // removes the sequenced gesture before onEnded, release
                    // that non-moving claim before opening the editor. A
                    // real move is already covered by isInteracting or
                    // suppressTap and therefore cannot take this path.
                    clearEventMutationSession()
                    onSelect()
                }
            }
        }
    }

#if os(macOS)
    private func performHoverControlAction(_ action: @escaping () -> Void) {
        suppressTap = true
        action()
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                suppressTap = false
            }
        }
    }
#endif

#if os(macOS)
    @ViewBuilder
    private var macHoverControls: some View {
        if isHovering || isFocused {
            HStack(spacing: 2) {
                Button { performHoverControlAction { commitMove(dayDelta: -1) } } label: {
                    Image(systemName: "arrow.left")
                }
                .accessibilityLabel("Move event to previous day")
                .help("Move event to previous day")
                .accessibilityIdentifier("calendar-event-move-previous-day-\(CalendarAllDayLayout.renderIdentity(for: item))")

                Button { performHoverControlAction { commitMove(dayDelta: 1) } } label: {
                    Image(systemName: "arrow.right")
                }
                .accessibilityLabel("Move event to next day")
                .help("Move event to next day")
                .accessibilityIdentifier("calendar-event-move-next-day-\(CalendarAllDayLayout.renderIdentity(for: item))")

                Button { performHoverControlAction { commitResize(minutes: -15) } } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("Resize event shorter 15 minutes")
                .help("Resize event shorter by 15 minutes")
                .accessibilityIdentifier("calendar-event-resize-shorter-\(CalendarAllDayLayout.renderIdentity(for: item))")

                Button { performHoverControlAction { commitResize(minutes: 15) } } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Resize event longer 15 minutes")
                .help("Resize event longer by 15 minutes")
                .accessibilityIdentifier("calendar-event-resize-longer-\(CalendarAllDayLayout.renderIdentity(for: item))")
            }
            .font(.system(size: 9, weight: .semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(.black.opacity(0.42), in: Capsule(style: .continuous))
            .padding(4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar-event-hover-affordance-\(eventAccessibilityID)")
        }
    }
#endif

    private var eventAccessibilityID: String {
        let renderIdentity = CalendarAllDayLayout.renderIdentity(for: item)
        return isInteractionEnabled
            ? "calendar-event-\(renderIdentity)"
            : "calendar-offscreen-event-\(renderIdentity)"
    }

    private var accessibilityValue: String {
        let style = Date.FormatStyle.dateTime.hour().minute().locale(.current)
        return "\(calendarISODate(item.start)) \(item.start.formatted(style)) to \(calendarISODate(item.end)) \(item.end.formatted(style)); move actions available"
    }

    @ViewBuilder
    private var resizeHandle: some View {
#if os(macOS)
        if isHovering || isFocused {
            resizeHandleSurface
        }
#else
        // Keep the semantic/hit target mounted at rest so the affordance is
        // reachable by touch, XCTest, and VoiceOver. Its visual capsule stays
        // hidden until the long-press actually claims a resize, preserving
        // the clean idle card while retaining the interaction surface.
        ZStack(alignment: .bottom) {
            // The semantic target is also the physical gesture owner. Keeping
            // the hit region aligned with the exposed AX frame means a swipe
            // beginning at the handle's midpoint cannot fall into the card's
            // nested long-press recognizer by accident.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Resize event")
                .accessibilityValue("15 minute resize actions available")
                .accessibilityHint("Use resize shorter or resize longer actions in 15 minute steps")
                .accessibilityIdentifier(isInteractionEnabled
                    ? "calendar-event-resize-\(CalendarAllDayLayout.renderIdentity(for: item))"
                    : "calendar-offscreen-event-resize-\(CalendarAllDayLayout.renderIdentity(for: item))")
                .accessibilityAction(named: "Resize shorter 15 minutes") { commitResize(minutes: -15) }
                .accessibilityAction(named: "Resize longer 15 minutes") { commitResize(minutes: 15) }
                .contentShape(Rectangle())
                .gesture(resizeOrVerticalGesture)
                .simultaneousGesture(verticalTimelinePanGesture)

            // The visual affordance stays compact while the invisible control
            // above provides the forgiving touch target.
            Capsule(style: .continuous)
                .fill(CalendarEventVisuals.accent.opacity(isResizing ? 0.82 : 0))
                .frame(width: 28, height: 4)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18, alignment: .bottom)
        .contentShape(Rectangle())
#endif
    }

    private var resizeHandleSurface: some View {
        Capsule(style: .continuous)
            .fill(CalendarEventVisuals.accent.opacity(isResizing ? 0.82 : 0))
            .frame(width: 28, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 18, alignment: .bottom)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize event")
            .accessibilityValue("15 minute resize actions available")
            .accessibilityHint("Use resize shorter or resize longer actions in 15 minute steps")
            .accessibilityIdentifier(isInteractionEnabled
                ? "calendar-event-resize-\(CalendarAllDayLayout.renderIdentity(for: item))"
                : "calendar-offscreen-event-resize-\(CalendarAllDayLayout.renderIdentity(for: item))")
            .accessibilityAction(named: "Resize shorter 15 minutes") { commitResize(minutes: -15) }
            .accessibilityAction(named: "Resize longer 15 minutes") { commitResize(minutes: 15) }
            .highPriorityGesture(resizeGesture)
    }

    private var moveStartClassifier: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !moveStartCaptured else { return }
                moveStartCaptured = true
                moveStartIsBody = value.startLocation.y < max(0, availableHeight - 18)
            }
            .onEnded { _ in
                moveStartCaptured = false
                moveStartIsBody = false
            }
    }

#if os(iOS)
    private var resizeOrVerticalGesture: some Gesture {
        resizeGesture.exclusively(before: verticalTimelinePanGesture)
    }

    private var verticalTimelinePanGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width),
                      abs(value.translation.height) >= 12,
                      !isMoving,
                      !isResizing,
                      !mutationCommitInFlight else { return }
                onVerticalPan?(value.translation.height)
            }
    }

#endif

    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { phase in
                if case .first(true) = phase {
                    guard !interactionSession.statusMutationActive,
                          !mutationCommitInFlight,
                          moveStartIsBody else { return }
                    // Reserve the event surface while the deliberate hold is
                    // pending. Without this early reservation, the parent
                    // vertical/horizontal scroll containers can cancel the
                    // sequenced drag before its first horizontal sample.
                    interactionSession.eventMoveActive = true
                }
                guard case .second(true, let drag?) = phase else { return }
                guard !interactionSession.statusMutationActive,
                      !mutationCommitInFlight,
                      moveStartIsBody else { return }
                if !isMoving {
                    // A pending long press must not starve a quick vertical
                    // timeline swipe. Claim the shared session only after the
                    // deliberate move gesture has actually begun.
                    interactionSession.eventMoveActive = true
                    isMoving = true
                    suppressTap = true
                    CalendarInteractionHaptics.grab()
                    lastMoveSnap = 0
                    updateMovePreview(dayDelta: 0, minutes: 0)
                }
                let snapped = CalendarInteractionLayout.snappedMinuteDelta(
                    translation: Double(drag.translation.height),
                    hourHeight: Double(hourHeight)
                )
                if lastMoveSnap != snapped {
                    CalendarInteractionHaptics.snap()
                    lastMoveSnap = snapped
                }
                let snappedDay = CalendarInteractionLayout.snappedDayDelta(
                    translation: Double(drag.translation.width),
                    dayWidth: Double(dayWidth)
                )
                if moveDays != snappedDay {
                    CalendarInteractionHaptics.snap()
                    moveDays = snappedDay
                }
                moveMinutes = snapped
                updateMovePreview(dayDelta: snappedDay, minutes: snapped)
            }
            .onEnded { _ in
                guard isMoving else {
                    clearEventMutationSession(resetTap: true)
                    return
                }
                let minutes = moveMinutes
                let days = moveDays
                moveMinutes = 0
                moveDays = 0
                isMoving = false
                lastMoveSnap = nil
                commitMove(dayDelta: days, minutes: minutes, resetTap: true, emitHaptic: false)
            }
    }

    private var resizeGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { phase in
                guard case .second(true, let drag?) = phase else { return }
                guard !interactionSession.statusMutationActive,
                      !mutationCommitInFlight else { return }
                if !isResizing {
                    // Do not claim the shared session while the long press is
                    // still pending: a quick vertical swipe must remain free
                    // to scroll the timeline. Once the long press succeeds,
                    // resize owns the interaction just like event move.
                    interactionSession.eventMoveActive = true
                    isResizing = true
                    suppressTap = true
                    CalendarInteractionHaptics.grab()
                    lastResizeSnap = 0
                }
                let snapped = CalendarInteractionLayout.snappedMinuteDelta(
                    translation: Double(drag.translation.height),
                    hourHeight: Double(hourHeight)
                )
                if lastResizeSnap != snapped {
                    CalendarInteractionHaptics.snap()
                    lastResizeSnap = snapped
                }
                resizeMinutes = snapped
            }
            .onEnded { _ in
                guard isResizing else {
                    clearEventMutationSession(resetTap: true)
                    return
                }
                let minutes = resizeMinutes
                resizeMinutes = 0
                isResizing = false
                lastResizeSnap = nil
                commitResize(minutes: minutes, resetTap: true, emitHaptic: false)
            }
    }

    private func commitMove(dayDelta: Int = 0, minutes: Int = 0, resetTap: Bool = false, emitHaptic: Bool = true) {
        guard !mutationCommitInFlight else { return }
        let interval = proposedMoveInterval(dayDelta: dayDelta, minutes: minutes)
        guard let interval else {
            mutationCommitInFlight = false
            clearEventMutationSession(resetTap: resetTap)
            return
        }
        if interval.start == item.start, interval.end == item.end {
            mutationCommitInFlight = false
            clearEventMutationSession(resetTap: resetTap)
            return
        }
        if emitHaptic, minutes != 0 || dayDelta != 0 { CalendarInteractionHaptics.snap() }
        if let onUpdate {
            // Keep the owner and provisional render alive until the local save
            // completion. Both success and failure then take the same cleanup
            // path; a failed save re-renders the unchanged coordinator snapshot.
            mutationCommitInFlight = true
            onUpdate(item, interval.start, interval.end) { _ in
                // Local durability, whether success or failure, ends the
                // provisional render. A failed save leaves the coordinator's
                // original snapshot untouched and exposes its error state.
                let cleanup = CalendarGestureArbitration.cleanupAfterCompletedMutation(
                    settledPage: day,
                    calendar: calendar
                )
                mutationCommitInFlight = false
                interactionSession.eventMovePreview = nil
                interactionSession.eventMoveActive = cleanup.eventMoveActive
                if resetTap { suppressTap = false }
            }
        }
        if onUpdate == nil {
            mutationCommitInFlight = false
            clearEventMutationSession(resetTap: resetTap)
        }
        // A real update owns `suppressTap` and interaction cleanup above.
    }

    private func proposedMoveInterval(dayDelta: Int, minutes: Int) -> DateInterval? {
        let verticalTranslation = Double(minutes) / 60 * Double(hourHeight)
        let horizontalTranslation = Double(dayDelta) * Double(dayWidth)
        if dayDelta == 0 {
            return CalendarInteractionLayout.movedInterval(
                item: item,
                translation: verticalTranslation,
                hourHeight: Double(hourHeight),
                day: day,
                calendar: calendar
            )
        }
        return CalendarInteractionLayout.movedInterval(
            item: item,
            verticalTranslation: verticalTranslation,
            horizontalTranslation: horizontalTranslation,
            dayWidth: Double(dayWidth),
            hourHeight: Double(hourHeight),
            calendar: calendar
        )
    }

    private func updateMovePreview(dayDelta: Int, minutes: Int) {
        guard let interval = proposedMoveInterval(dayDelta: dayDelta, minutes: minutes) else { return }
        interactionSession.eventMovePreview = CalendarEventMovePreview(
            item: item,
            start: interval.start,
            end: interval.end
        )
    }

    private func calendarISODate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func commitResize(minutes: Int, resetTap: Bool = false, emitHaptic: Bool = true) {
        guard !mutationCommitInFlight else { return }
        let translation = Double(minutes) / 60 * Double(hourHeight)
        guard let interval = CalendarInteractionLayout.resizedInterval(
            item: item,
            edge: .end,
            translation: translation,
            hourHeight: Double(hourHeight),
            day: day,
            calendar: calendar
        ) else {
            // A resize can be cancelled by an invalid/clamped endpoint after
            // the long-press already claimed the gesture. Always release the
            // shared arbitration session on this path.
            mutationCommitInFlight = false
            clearEventMutationSession(resetTap: resetTap)
            return
        }
        if emitHaptic, minutes != 0 { CalendarInteractionHaptics.snap() }
        guard let onUpdate else {
            mutationCommitInFlight = false
            clearEventMutationSession(resetTap: resetTap)
            return
        }
        mutationCommitInFlight = true
        onUpdate(item, interval.start, interval.end) { _ in
            let cleanup = CalendarGestureArbitration.cleanupAfterCompletedMutation(
                settledPage: day,
                calendar: calendar
            )
            mutationCommitInFlight = false
            interactionSession.eventMovePreview = nil
            interactionSession.eventMoveActive = cleanup.eventMoveActive
            if resetTap { suppressTap = false }
        }
    }
}

private struct CalendarNowLine: View {
    let days: [Date]
    let calendar: Calendar
    let timeGutter: CGFloat
    let totalHeight: CGFloat
    let contentWidth: CGFloat
    /// The iOS day strip passes its virtual column width explicitly because
    /// its layer spans more days than the visible window; the Mac week grid
    /// keeps the derived `(contentWidth - gutter) / days` behavior.
    var columnWidthOverride: CGFloat? = nil
    let reduceMotion: Bool

    var body: some View {
        if days.contains(where: calendar.isDateInToday) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let day = calendar.startOfDay(for: context.date)
                let scale = CalendarInteractionLayout.timelineScale(
                    day: day,
                    hourHeight: Double(totalHeight) / 24,
                    calendar: calendar
                )
                let y = min(totalHeight - 1, max(0, CGFloat(scale?.y(for: context.date, calendar: calendar) ?? 0)))
                // The rule spans only today's column (Notion parity); the
                // gutter label + dot stay pinned to the left edge.
                let dayColumnWidth = columnWidthOverride ??
                    (days.isEmpty ? 0 : max(0, (contentWidth - timeGutter) / CGFloat(days.count)))
                let todayIndex = days.firstIndex(where: { calendar.isDateInToday($0) }) ?? 0
                HStack(spacing: 0) {
                    Text(CalendarTimelineScale.localizedTimeLabel(for: context.date, calendar: calendar))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                        // The trailing padding is part of the label's
                        // footprint; keep label + dot + rule exactly within
                        // the available content width.
                        .frame(width: max(0, timeGutter - 5), alignment: .trailing)
                        .padding(.trailing, 5)
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 7, height: 7)
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: max(0, dayColumnWidth - 7), height: 2)
                }
                .offset(x: CGFloat(todayIndex) * dayColumnWidth, y: y - 1)
                .frame(width: contentWidth, alignment: .leading)
                .animation(reduceMotion ? nil : .linear(duration: 0.3), value: y)
                .zIndex(4)
            }
        }
    }
}

private struct CalendarDayHeaderNumber: View {
    let day: Date
    let calendar: Calendar
    let namespace: Namespace.ID?
    let isSelected: Bool
    let isSource: Bool
    let reduceMotion: Bool

    var body: some View {
        let isToday = calendar.isDateInToday(day)
        let label = Text(day, format: .dateTime.day())
            .font(.title3.weight(isToday ? .bold : .medium))
            .foregroundStyle(isToday ? Color.white : Color.primary)
            .frame(width: 30, height: 28)
            .background(isToday ? CalendarEventVisuals.today : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        if isSelected, let namespace, !reduceMotion {
            label.matchedGeometryEffect(
                id: "calendar-selected-date",
                in: namespace,
                properties: .frame,
                anchor: .center,
                isSource: isSource
            )
        } else {
            label
        }
    }
}

private struct CalendarTimelineEvent: View {
    let item: CalendarItem
    let compact: Bool
    let narrow: Bool
    let availableHeight: CGFloat
    let hidesSecondaryMetadata: Bool
    let timeZone: TimeZone
    let cornerRadii: CalendarEventCornerRadii
    let accessibilityID: String
    @State private var isHovering = false

    private var showsSecondaryMetadata: Bool {
        // A trailing layer visually covers the base card's lower content;
        // keeping only its title avoids a half-visible time row at the seam.
        !hidesSecondaryMetadata && !compact && !narrow && availableHeight >= 62
    }

    private var displayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    private var eventTimeRangeLabel: String {
        "\(CalendarTimelineScale.localizedTimeLabel(for: item.start, calendar: displayCalendar))–" +
            "\(CalendarTimelineScale.localizedTimeLabel(for: item.end, calendar: displayCalendar))"
    }

    private var eventAccessibilityLabel: String {
        let kindLabel = item.kind == .todo ? "To-do, \(item.status.label)" : item.status.label
        return "\(item.icon ?? "No icon") \(item.title), \(kindLabel), " +
            "\(CalendarTimelineScale.localizedTimeLabel(for: item.start, calendar: displayCalendar)) to " +
            "\(CalendarTimelineScale.localizedTimeLabel(for: item.end, calendar: displayCalendar))"
    }

    @ViewBuilder
    private var leadingStatusControl: some View {
        LifeOSIcon(item.status.iconName)
            .frame(width: 14, height: 14)
            .foregroundStyle(.white.opacity(0.78))
    }

    var body: some View {
        Group {
            if narrow {
                HStack(spacing: 4) {
                    leadingStatusControl
                        .frame(width: 14, height: 14)
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .truncationMode(.tail)
                }
            } else {
                HStack(alignment: .top, spacing: 5) {
                    leadingStatusControl
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .truncationMode(.tail)
                        if showsSecondaryMetadata {
                            Text(eventTimeRangeLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.70)
                                .allowsTightening(true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, narrow ? 5 : 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .background(
            UnevenRoundedRectangle(cornerRadii: cornerRadii.shapeRadii, style: .continuous)
                .fill(CalendarEventVisuals.accent.opacity(CalendarEventVisuals.fillOpacity))
        )
        // An opaque canvas underlay prevents text from an earlier full-width
        // event bleeding through the translucent shared-green surface.
        .background(
            UnevenRoundedRectangle(cornerRadii: cornerRadii.shapeRadii, style: .continuous)
                .fill(LifeOSTokens.canvas)
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(cornerRadii: cornerRadii.leadingBarShapeRadii, style: .continuous)
                .fill(CalendarEventVisuals.accent.opacity(CalendarEventVisuals.leadingBarOpacity))
                .frame(width: 3)
                .padding(.vertical, 3)
        }
        .overlay(
            UnevenRoundedRectangle(cornerRadii: cornerRadii.shapeRadii, style: .continuous)
                .stroke(CalendarEventVisuals.accent.opacity(CalendarEventVisuals.borderOpacity))
        )
        .opacity(isHovering ? CalendarEventVisuals.hoverOpacity : 1)
        .onHover { isHovering = $0 }
        // The card has no interactive Todo child. Its checkbox is an outer
        // sibling owned by CalendarInteractiveTimelineEvent.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(eventAccessibilityLabel)
        .accessibilityHint("Hover or focus to reveal move and resize affordances")
        .accessibilityIdentifier(accessibilityID)
    }

}

private extension CalendarEventCornerRadii {
    var shapeRadii: RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: CGFloat(topLeading),
            bottomLeading: CGFloat(bottomLeading),
            bottomTrailing: CGFloat(bottomTrailing),
            topTrailing: CGFloat(topTrailing)
        )
    }

    /// The leading bar follows the event's outer leading edge and remains
    /// square against the event body so it cannot introduce a second hue or
    /// an accidental gap at an overlap seam.
    var leadingBarShapeRadii: RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: CGFloat(topLeading),
            bottomLeading: CGFloat(bottomLeading),
            bottomTrailing: 0,
            topTrailing: 0
        )
    }
}

private struct CalendarMonthCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Date: CGRect] = [:]

    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private enum CalendarMonthMoveStatus: Equatable {
    case success
    case failure(String)

    var message: String {
        switch self {
        case .success: "Event moved locally"
        case let .failure(message): "Move failed; event returned to its original position. \(message)"
        }
    }
}

public struct CalendarMonthGrid: View {
    public let month: Date
    public let selectedDate: Date
    public let items: [CalendarItem]
    public let holidays: [CalendarHoliday]
    public let calendar: Calendar
    public let onSelectDate: (Date) -> Void
    public let onSelectItem: (CalendarItem) -> Void
    public let onUpdate: CalendarUpdateHandler?
    public let reduceMotion: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var monthCellFrames: [Date: CGRect] = [:]
    @State private var movePreview: CalendarEventMovePreview?
    @State private var draggingItemID: UUID?
    @State private var moveTargetDay: Date?
    @State private var moveCommitInFlight = false
    @State private var moveStatus: CalendarMonthMoveStatus?

    public init(month: Date, selectedDate: Date, items: [CalendarItem], holidays: [CalendarHoliday] = [], calendar: Calendar = .current,
                onSelectDate: @escaping (Date) -> Void, onSelectItem: @escaping (CalendarItem) -> Void,
                onUpdate: CalendarUpdateHandler? = nil, reduceMotion: Bool = false) {
        self.month = month
        self.selectedDate = selectedDate
        self.items = items
        self.holidays = holidays
        self.calendar = calendar
        self.onSelectDate = onSelectDate
        self.onSelectItem = onSelectItem
        self.onUpdate = onUpdate
        self.reduceMotion = reduceMotion
    }

    private var days: [Date] { CalendarDateRange.monthGrid(containing: month, calendar: calendar) }
    private var monthComponent: Int { calendar.component(.month, from: month) }
    private var usesCompactCells: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    public var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                // Single-letter weekday symbols repeat (S/T). Index identity keeps
                // all seven columns instead of SwiftUI coalescing duplicate IDs.
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                ForEach(days, id: \.self) { day in
                    monthCell(day)
                }
            }
        }
        .background(LifeOSTokens.canvas)
        .coordinateSpace(name: "calendar-month-grid")
        .onPreferenceChange(CalendarMonthCellFramePreferenceKey.self) { monthCellFrames = $0 }
#if os(macOS)
        .onExitCommand { cancelMonthMove() }
#endif
        .accessibilityAction(named: "Cancel move") { cancelMonthMove() }
        .overlay(alignment: .bottomLeading) {
            if let moveStatus {
                Text(moveStatus.message)
                    .font(.caption)
                    .foregroundStyle(moveStatus == .success ? .green : .orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule(style: .continuous))
                    .accessibilityIdentifier("calendar-month-move-status")
                    .accessibilityLabel(moveStatus.message)
                    .padding(8)
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[index...] + symbols[..<index])
    }

    private func monthCell(_ day: Date) -> some View {
        let dayItems = displayedItems(on: day)
        let dayHolidays = holidays.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let isCurrentMonth = calendar.component(.month, from: day) == monthComponent
        let visibleEventLimit = CalendarMonthCellPresentation.visibleEventLimit(isCompact: usesCompactCells)
        let overflowCount = CalendarMonthCellPresentation.overflowCount(total: dayItems.count, visible: visibleEventLimit)
        let visibleItems = visibleMonthItems(dayItems, limit: visibleEventLimit)
        let isMoveTarget = moveTargetDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let renderState: (CalendarItem) -> CalendarMonthMoveRenderState = { item in
            guard let preview = movePreview, preview.item.id == item.id else { return .normal }
            return CalendarInteractionLayout.monthMoveRenderState(
                item: preview.item,
                previewStart: preview.start,
                previewEnd: preview.end,
                day: day,
                calendar: calendar
            )
        }
        return VStack(alignment: .leading, spacing: 4) {
            Button { onSelectDate(day) } label: {
                Text(day, format: .dateTime.day())
                    .font(.caption.weight(calendar.isDateInToday(day) ? .bold : .medium))
                    .foregroundStyle(calendar.isDateInToday(day) ? .white : (isCurrentMonth ? Color.primary : Color.secondary))
                    .frame(width: 25, height: 25)
                    .background(calendar.isDateInToday(day) ? CalendarEventVisuals.today : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            // Keep the day-cell target on the date control itself. Applying
            // this identifier to the containing VStack makes SwiftUI replace
            // every descendant event chip's identifier with the cell ID,
            // which breaks direct manipulation and assistive navigation.
            .accessibilityIdentifier("calendar-month-cell-\(calendarISODate(day))")

            if let holiday = dayHolidays.first {
                if usesCompactCells {
                    Circle()
                        .fill(LifeOSTokens.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Holiday: \(holiday.name)")
                } else {
                    Text(holiday.name)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LifeOSTokens.accent)
                        .lineLimit(1)
                        .help(holiday.name)
                }
            }

            ForEach(visibleItems) { item in
                CalendarMonthEventChip(
                    item: item,
                    compact: usesCompactCells,
                    calendar: calendar,
                    isGhost: renderState(item) == .destinationGhost,
                    isSourceOwner: renderState(item) == .sourceOwner,
                    onSelect: { if renderState(item) == .normal { onSelectItem(item) } },
                    onBeginMove: { beginMonthMove(item) },
                    onMoveChanged: { updateMonthMove(at: $0) },
                    onEndMove: { finishMonthMove(at: $0) },
                    onKeyboardMove: { keyboardMove(item, dayDelta: $0) }
                )
            }
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: usesCompactCells ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(overflowCount) more events")
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .opacity(isCurrentMonth ? 1 : 0.45)
        .background {
            if isMoveTarget {
                LifeOSTokens.accent.opacity(0.10)
            } else if calendar.isDate(day, inSameDayAs: selectedDate) {
                LifeOSTokens.accent.opacity(0.08)
            } else {
                Color.clear
            }
        }
        .overlay {
            Rectangle().stroke(
                isMoveTarget ? CalendarEventVisuals.accent.opacity(0.60) : Color.primary.opacity(0.075),
                lineWidth: isMoveTarget ? 1.25 : 0.5
            )
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CalendarMonthCellFramePreferenceKey.self,
                    value: [day: proxy.frame(in: .named("calendar-month-grid"))]
                )
            }
        }
    }

    private func displayedItems(on day: Date) -> [CalendarItem] {
        var displayed = CalendarSnapshot(items: items).items(on: day, calendar: calendar)
        guard let preview = movePreview, let moved = preview.movedItem else { return displayed }
        // Keep the original source chip in its original cell for the whole
        // gesture lifetime. Its view owns the LongPress→Drag recognizer; the
        // destination receives a separate, noninteractive ghost. Removing the
        // source when the pointer crosses a cell would tear down that owner
        // before onEnded and make a drop/cancel nondeterministic.
        if calendar.isDate(day, inSameDayAs: preview.item.start) {
            return displayed
        }
        displayed.removeAll { $0.id == preview.item.id }
        if CalendarSnapshot(items: [moved]).items(on: day, calendar: calendar).contains(where: { $0.id == moved.id }) {
            displayed.append(moved)
        }
        return displayed.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func visibleMonthItems(_ dayItems: [CalendarItem], limit: Int) -> [CalendarItem] {
        guard let draggingItemID, dayItems.count > limit,
              dayItems.contains(where: { $0.id == draggingItemID }) else {
            return Array(dayItems.prefix(limit))
        }
        let withoutGhost = dayItems.filter { $0.id != draggingItemID }
        let ghost = dayItems.first { $0.id == draggingItemID }
        return Array(withoutGhost.prefix(max(0, limit - 1))) + (ghost.map { [$0] } ?? [])
    }

    private func beginMonthMove(_ item: CalendarItem) {
        guard !moveCommitInFlight else { return }
        draggingItemID = item.id
        moveTargetDay = calendar.startOfDay(for: item.start)
        movePreview = CalendarEventMovePreview(item: item, start: item.start, end: item.end)
        moveStatus = nil
        CalendarInteractionHaptics.grab()
    }

    private func updateMonthMove(at location: CGPoint) {
        guard !moveCommitInFlight, let draggingItemID,
              let preview = movePreview, preview.item.id == draggingItemID else { return }

        // A drag can leave the month grid, or land on a local day whose wall
        // clock cannot represent the event (the spring-forward gap). Do not
        // leave the last valid preview armed in either case: if the gesture
        // ends here, the drop must cancel and restore the source event.
        guard let targetDay = monthCellFrames.first(where: { $0.value.contains(location) })?.key,
              let interval = CalendarInteractionLayout.monthMovedInterval(
                  item: preview.item,
                  targetDay: targetDay,
                  calendar: calendar
              ) else {
            invalidateMonthMovePreview()
            return
        }
        let changedDay = moveTargetDay.map { !calendar.isDate($0, inSameDayAs: targetDay) } ?? true
        if changedDay { CalendarInteractionHaptics.snap() }
        moveTargetDay = calendar.startOfDay(for: targetDay)
        movePreview = CalendarEventMovePreview(item: preview.item, start: interval.start, end: interval.end)
    }

    private func finishMonthMove(at location: CGPoint?) {
        guard !moveCommitInFlight, let draggingItemID,
              let preview = movePreview, preview.item.id == draggingItemID else { return }
        if let location { updateMonthMove(at: location) }
        // `moveTargetDay` is the explicit validity marker. It is cleared as
        // soon as the pointer leaves the grid or the target cannot represent
        // the source wall time, so this cannot commit a stale last-valid drop.
        guard moveTargetDay != nil,
              let finalPreview = movePreview,
              finalPreview.start != finalPreview.item.start || finalPreview.end != finalPreview.item.end else {
            cancelMonthMove()
            return
        }
        commitMonthMove(item: finalPreview.item, start: finalPreview.start, end: finalPreview.end)
    }

    private func invalidateMonthMovePreview() {
        guard let preview = movePreview else { return }
        moveTargetDay = nil
        // Keep the source recognizer mounted, but remove any destination ghost
        // from the stale preview while the pointer is outside a valid target.
        movePreview = CalendarEventMovePreview(item: preview.item, start: preview.item.start, end: preview.item.end)
    }

    private func commitMonthMove(item: CalendarItem, start: Date, end: Date) {
        guard !moveCommitInFlight else { return }
        guard start != item.start || end != item.end else {
            cancelMonthMove()
            return
        }
        moveCommitInFlight = true
        guard let onUpdate else {
            clearMonthMove()
            moveStatus = .failure("Calendar updates are unavailable.")
            return
        }
        onUpdate(item, start, end) { result in
            clearMonthMove()
            switch result {
            case .success:
                moveStatus = .success
            case let .failure(message):
                moveStatus = .failure(message)
            }
        }
    }

    private func keyboardMove(_ item: CalendarItem, dayDelta: Int) {
        guard !moveCommitInFlight,
              let target = calendar.date(byAdding: .day, value: dayDelta, to: item.start),
              let interval = CalendarInteractionLayout.monthMovedInterval(item: item, targetDay: target, calendar: calendar) else { return }
        commitMonthMove(item: item, start: interval.start, end: interval.end)
    }

    private func cancelMonthMove() {
        guard draggingItemID != nil || movePreview != nil else { return }
        clearMonthMove()
        moveStatus = nil
    }

    private func clearMonthMove() {
        movePreview = nil
        draggingItemID = nil
        moveTargetDay = nil
        moveCommitInFlight = false
    }

    private func calendarISODate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private struct CalendarMonthEventChip: View {
    let item: CalendarItem
    let compact: Bool
    let calendar: Calendar
    let isGhost: Bool
    let isSourceOwner: Bool
    let onSelect: () -> Void
    let onBeginMove: () -> Void
    let onMoveChanged: (CGPoint) -> Void
    let onEndMove: (CGPoint?) -> Void
    let onKeyboardMove: (Int) -> Void
    @State private var isHovering = false
    @State private var moveActive = false
    @State private var lastMoveLocation: CGPoint?
    @State private var suppressTap = false

    var body: some View {
        Button {
            guard !suppressTap else { return }
            onSelect()
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(CalendarEventVisuals.accent)
                    .frame(width: 4, height: 4)
                if item.hasIcon {
                    CalendarIconView(item: item, size: compact ? 11 : 14)
                }
                if !compact {
                    Text(item.title).lineLimit(1)
                }
            }
            .font(.caption2)
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                CalendarEventVisuals.accent.opacity(CalendarEventVisuals.fillOpacity),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .background(
                LifeOSTokens.canvas,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .opacity(isSourceOwner ? 0 : (isGhost ? 0.46 : (isHovering ? CalendarEventVisuals.hoverOpacity : 1)))
        }
        .buttonStyle(CalendarEventButtonStyle())
        .onHover { isHovering = $0 }
        .highPriorityGesture(monthMoveGesture)
        .allowsHitTesting(!isGhost)
        .accessibilityHidden(isGhost || isSourceOwner)
        .accessibilityLabel(
            "\(item.icon ?? "No icon") \(item.title), \(item.status.label), " +
            "\(item.start.formatted(date: .omitted, time: .shortened)) to " +
            "\(item.end.formatted(date: .omitted, time: .shortened))"
        )
        .accessibilityValue(
            "\(calendarISODate(item.start)), " +
            "\(item.start.formatted(date: .omitted, time: .shortened)) to " +
            "\(calendarISODate(item.end)), " +
            "\(item.end.formatted(date: .omitted, time: .shortened)); long press and drag to move"
        )
        .accessibilityIdentifier("calendar-month-event-\(item.id.uuidString)")
        .accessibilityHint("Long press and drag to move this event between month days")
        .accessibilityAction(named: "Move to previous day") { onKeyboardMove(-1) }
        .accessibilityAction(named: "Move to next day") { onKeyboardMove(1) }
        .accessibilityAction(named: "Move to previous week") { onKeyboardMove(-7) }
        .accessibilityAction(named: "Move to next week") { onKeyboardMove(7) }
#if os(macOS)
        .focusable(!isGhost && !isSourceOwner)
        .onMoveCommand { direction in
            switch direction {
            case .left: onKeyboardMove(-1)
            case .right: onKeyboardMove(1)
            case .up: onKeyboardMove(-7)
            case .down: onKeyboardMove(7)
            @unknown default: break
            }
        }
#endif
    }

    private func calendarISODate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var monthMoveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.42, maximumDistance: 16)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("calendar-month-grid")))
            .onChanged { phase in
                guard !isGhost, case .second(true, let drag?) = phase else { return }
                if !moveActive {
                    moveActive = true
                    suppressTap = true
                    onBeginMove()
                }
                lastMoveLocation = drag.location
                onMoveChanged(drag.location)
            }
            .onEnded { phase in
                guard moveActive else { return }
                let location: CGPoint?
                if case .second(_, let drag?) = phase {
                    location = drag.location
                } else {
                    location = lastMoveLocation
                }
                moveActive = false
                lastMoveLocation = nil
                onEndMove(location)
                DispatchQueue.main.async {
                    suppressTap = false
                }
            }
    }
}

/// The in-place month panel used by the iOS calendar header. It intentionally
/// keeps the week-number gutter visible: that small bit of structure is what
/// makes the selected three-day window legible while the user swipes below it.
public struct CalendarExpandedMonthGrid: View {
    /// Stable mobile panel height for the six-week reference grid.
    public static let preferredHeight: CGFloat = 364

    public let month: Date
    public let selectedDate: Date
    public let selectedRange: [Date]
    public let calendar: Calendar
    public let namespace: Namespace.ID?
    public let isSource: Bool
    public let reduceMotion: Bool
    public let onSelectDate: (Date) -> Void

    public init(
        month: Date,
        selectedDate: Date,
        selectedRange: [Date],
        calendar: Calendar = .current,
        namespace: Namespace.ID? = nil,
        isSource: Bool = true,
        reduceMotion: Bool = false,
        onSelectDate: @escaping (Date) -> Void
    ) {
        self.month = month
        self.selectedDate = selectedDate
        self.selectedRange = selectedRange
        self.calendar = calendar
        self.namespace = namespace
        self.isSource = isSource
        self.reduceMotion = reduceMotion
        self.onSelectDate = onSelectDate
    }

    private var days: [Date] { CalendarDateRange.monthGrid(containing: month, calendar: calendar) }
    private var monthComponent: Int { calendar.component(.month, from: month) }
    private var columns: [GridItem] {
        [GridItem(.fixed(30), spacing: 0)] + Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[index...] + symbols[..<index])
    }
    private var selectedDays: Set<Date> {
        Set(selectedRange.map { calendar.startOfDay(for: $0) })
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            Color.clear.frame(height: 24)
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
            }

            ForEach(Array(days.chunked(into: 7).enumerated()), id: \.offset) { _, week in
                Text(weekNumber(for: week.first))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54)
                // Date is the stable identity. Using the weekday index here
                // repeated IDs 0...6 for every row in the LazyVGrid; SwiftUI
                // then dropped most/all day cells on device while leaving
                // the week-number gutter visible.
                ForEach(Array(week.enumerated()), id: \.element) { index, day in
                    let inRange = selectedDays.contains(calendar.startOfDay(for: day))
                    let startsRange = inRange && (index == 0 || !selectedDays.contains(calendar.startOfDay(for: week[index - 1])))
                    let endsRange = inRange && (index == week.count - 1 || !selectedDays.contains(calendar.startOfDay(for: week[index + 1])))
                    CalendarExpandedDateCell(
                        day: day,
                        isCurrentMonth: calendar.component(.month, from: day) == monthComponent,
                        isToday: calendar.isDateInToday(day),
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
                        isInSelectedRange: inRange,
                        isRangeStart: startsRange,
                        isRangeEnd: endsRange,
                        calendar: calendar,
                        namespace: namespace,
                        isSource: isSource,
                        reduceMotion: reduceMotion,
                        action: { onSelectDate(day) }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: Self.preferredHeight, alignment: .top)
        .background(LifeOSTokens.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Expanded month calendar")
    }

    private func weekNumber(for date: Date?) -> String {
        guard let date else { return "" }
        return String(calendar.component(.weekOfYear, from: date))
    }
}

private struct CalendarExpandedDateCell: View {
    let day: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isInSelectedRange: Bool
    let isRangeStart: Bool
    let isRangeEnd: Bool
    let calendar: Calendar
    let namespace: Namespace.ID?
    let isSource: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isInSelectedRange {
                    UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: isRangeStart ? 8 : 0,
                            bottomLeading: isRangeStart ? 8 : 0,
                            bottomTrailing: isRangeEnd ? 8 : 0,
                            topTrailing: isRangeEnd ? 8 : 0
                        ),
                        style: .continuous
                    )
                        .fill(Color.primary.opacity(0.11))
                        .padding(.vertical, 2)
                }
                let label = Text(day, format: .dateTime.day())
                    .font(.system(size: 15, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.white : (isCurrentMonth ? Color.primary : Color.secondary.opacity(0.50)))
                    .frame(width: 32, height: 32)
                    .background(isToday ? CalendarEventVisuals.today : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if isSelected, let namespace, !reduceMotion {
                    label.matchedGeometryEffect(
                        id: "calendar-selected-date",
                        in: namespace,
                        properties: .frame,
                        anchor: .center,
                        isSource: isSource
                    )
                } else {
                    label
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar-expanded-date-\(calendarISODate(day))")
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(isSelected ? "Selected" : (isInSelectedRange ? "Visible range" : ""))
    }

    private func calendarISODate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

public struct CalendarCompactMonth: View {
    @Binding public var selectedDate: Date
    public let calendar: Calendar
    public let items: [CalendarItem]
    @State private var visibleMonth: Date

    public init(
        selectedDate: Binding<Date>,
        calendar: Calendar = .current,
        items: [CalendarItem] = []
    ) {
        _selectedDate = selectedDate
        self.calendar = calendar
        self.items = items
        _visibleMonth = State(initialValue: selectedDate.wrappedValue)
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(visibleMonth, format: .dateTime.month(.wide).year())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                monthButton(direction: -1, icon: .chevronLeft)
                monthButton(direction: 1, icon: .chevronRight)
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(monthDays, id: \.self) { day in
                    CalendarCompactDayButton(
                        day: day,
                        visibleMonth: visibleMonth,
                        selectedDate: selectedDate,
                        hasEvents: items.contains { calendar.isDate($0.start, inSameDayAs: day) },
                        calendar: calendar
                    ) {
                        selectedDate = day
                    }
                }
            }
        }
        .onChange(of: selectedDate) { _, date in
            guard !calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month) else { return }
            visibleMonth = date
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini calendar")
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var monthDays: [Date] {
        CalendarDateRange.monthGrid(containing: visibleMonth, calendar: calendar)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func monthButton(direction: Int, icon: LifeOSIconName) -> some View {
        Button {
            guard let month = calendar.date(byAdding: .month, value: direction, to: visibleMonth) else { return }
            withAnimation(LifeOSMotion.easeNavigate) { visibleMonth = month }
        } label: {
            LifeOSIcon(icon)
                .frame(width: 11, height: 11)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(direction < 0 ? "Previous month" : "Next month")
    }
}

private struct CalendarCompactDayButton: View {
    let day: Date
    let visibleMonth: Date
    let selectedDate: Date
    let hasEvents: Bool
    let calendar: Calendar
    let action: () -> Void
    @State private var isHovering = false

    private var isSelected: Bool { calendar.isDate(day, inSameDayAs: selectedDate) }
    private var isToday: Bool { calendar.isDateInToday(day) }
    private var isInMonth: Bool { calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Text(day, format: .dateTime.day())
                    .font(.system(size: 11, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(dayForeground)
                    .frame(width: 26, height: 26)
                    .background(dayBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        if isToday && !isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(LifeOSTokens.accent.opacity(0.65), lineWidth: 1)
                        }
                    }

                if hasEvents {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.9) : LifeOSTokens.accent.opacity(isInMonth ? 0.9 : 0.35))
                        .frame(width: 2.5, height: 2.5)
                        .padding(.bottom, 2.5)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(isSelected ? "Selected" : (hasEvents ? "Has events" : ""))
    }

    private var dayForeground: Color {
        if isSelected || isToday { return .white }
        return isInMonth ? .primary : LifeOSTokens.tertiaryText.opacity(0.55)
    }

    private var dayBackground: Color {
        if isToday { return CalendarEventVisuals.today }
        if isSelected { return LifeOSTokens.accent }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

public struct CalendarEmojiPicker: View {
    @Binding public var selection: String
    private let emojis = [
        "📅", "✅", "💼", "💻", "📱", "🧠", "❤️", "🏃", "🏋️", "🧘", "😴", "🍽️",
        "☕️", "🎯", "📚", "✍️", "🎨", "🎬", "🎵", "🎮", "✈️", "🚗", "🏠", "💰",
        "📈", "🧾", "🛒", "🎁", "🎉", "👥", "📞", "💬", "⚡️", "🔥", "🌙", "☀️"
    ]

    public init(selection: Binding<String>) { _selection = selection }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 7), count: 6), spacing: 7) {
            ForEach(emojis, id: \.self) { emoji in
                Button { selection = emoji } label: {
                    Text(emoji).font(.title3).frame(width: 34, height: 34)
                        .background(selection == emoji ? LifeOSTokens.accent.opacity(0.20) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == emoji ? LifeOSTokens.accent : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(emoji) icon")
            }
        }
        .padding(10)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
