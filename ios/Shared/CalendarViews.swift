import SwiftUI
import Combine
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    public let onSelect: (CalendarItem) -> Void
    /// Deliberate empty-space creation and final event interval updates are
    /// emitted only after the gesture settles. The parent owns persistence.
    public let onCreate: ((Date) -> Void)?
    /// macOS-only intentional empty-grid creation. The anchor is in the
    /// CalendarView editor coordinate space so the parent can present the
    /// inspector beside the actual click rather than centering a sheet.
    public let onCreateTimedRange: ((Date, Date, CGPoint) -> Void)?
    public let timedCreationPreview: CalendarTimedCreationPreview?
    public let onUpdate: CalendarUpdateHandler?
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
                onSelect: @escaping (CalendarItem) -> Void,
                onCreate: ((Date) -> Void)? = nil,
                onCreateTimedRange: ((Date, Date, CGPoint) -> Void)? = nil,
                timedCreationPreview: CalendarTimedCreationPreview? = nil,
                onUpdate: CalendarUpdateHandler? = nil,
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
        self.onCreateTimedRange = onCreateTimedRange
        self.timedCreationPreview = timedCreationPreview
        self.onUpdate = onUpdate
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
            onCreateTimedRange: onCreateTimedRange,
            onUpdate: onUpdate,
            timedCreationPreview: timedCreationPreview,
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
                    CalendarAllDayRow(days: days, calendar: calendar, timeGutter: timeGutter, width: contentWidth)
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
                                        onUpdate: onUpdate,
                                        monthNamespace: monthNamespace,
                                        monthExpanded: monthExpanded,
                                        monthSelectedDate: monthSelectedDate,
                                        reduceMotion: reduceMotion,
                                        isInteractionEnabled: true,
                                        interactionSession: interactionSession
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
// The pager uses explicit offsets; no page-offset preference is needed. Five
// materialized pages let a fast fling carry across a page boundary before the
// strip is recentered, while still keeping the view virtualized.

/// A deliberately small virtual strip. A page is the complete timed grid,
/// including its day headers, so a swipe can never desynchronise headers and
/// events. The strip is moved by an explicit horizontal drag and recentered
/// after a committed page, avoiding nested-scroll-view arbitration and
/// asynchronous target identity issues.
private struct CalendarPagedTimeline: View {
    let days: [Date]
    let items: [CalendarItem]
    let holidays: [CalendarHoliday]
    let hourHeight: CGFloat
    let calendar: Calendar
    let onSelect: (CalendarItem) -> Void
    let onCreate: ((Date) -> Void)?
    let onCreateTimedRange: ((Date, Date, CGPoint) -> Void)?
    let timedCreationPreview: CalendarTimedCreationPreview?
    let onUpdate: CalendarUpdateHandler?
    let onPreviewDateChange: ((Date) -> Void)?
    let onCommitDateChange: ((Date) -> Void)?
    let monthNamespace: Namespace.ID?
    let monthExpanded: Bool
    let monthSelectedDate: Date?
    let reduceMotion: Bool
    let interactionSession: CalendarInteractionSession
    @State private var pageAnchor: Date
    @State private var lastPreviewDate: Date?
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var horizontalDragActive = false
    @State private var pagerGestureGeneration = 0

    init(days: [Date], items: [CalendarItem], holidays: [CalendarHoliday], hourHeight: CGFloat,
         calendar: Calendar, onSelect: @escaping (CalendarItem) -> Void,
         onCreate: ((Date) -> Void)?, onCreateTimedRange: ((Date, Date, CGPoint) -> Void)?, onUpdate: CalendarUpdateHandler?,
         timedCreationPreview: CalendarTimedCreationPreview?,
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
        self.onCreateTimedRange = onCreateTimedRange
        self.timedCreationPreview = timedCreationPreview
        self.onUpdate = onUpdate
        self.onPreviewDateChange = onPreviewDateChange
        self.onCommitDateChange = onCommitDateChange
        self.monthNamespace = monthNamespace
        self.monthExpanded = monthExpanded
        self.monthSelectedDate = monthSelectedDate
        self.reduceMotion = reduceMotion
        self.interactionSession = interactionSession
        _pageAnchor = State(initialValue: calendar.startOfDay(for: days.first ?? .now))
    }

    private var dayCount: Int { max(1, days.count) }

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(-2...2, id: \.self) { offset in
                        CalendarTimelinePage(
                            days: pageDays(offset: offset),
                            items: items,
                            holidays: holidays,
                            hourHeight: hourHeight,
                            calendar: calendar,
                            onSelect: onSelect,
                            onCreate: onCreate,
                            onCreateTimedRange: onCreateTimedRange,
                            timedCreationPreview: timedCreationPreview,
                            onUpdate: onUpdate,
                            monthNamespace: monthNamespace,
                            monthExpanded: monthExpanded,
                            monthSelectedDate: monthSelectedDate,
                            reduceMotion: reduceMotion,
                            isInteractionEnabled: offset == 0,
                            interactionSession: interactionSession
                        )
                        .frame(width: viewport.size.width)
                        .accessibilityElement(children: offset == 0 ? .contain : .ignore)
                        .accessibilityHidden(offset != 0)
                    }
                }
                .frame(width: viewport.size.width * 5, alignment: .leading)
                .offset(x: -viewport.size.width * 2 + horizontalDragOffset)
                .frame(width: viewport.size.width, alignment: .leading)
            }
            .frame(width: viewport.size.width)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(pagerDragGesture(width: viewport.size.width))
            .onChange(of: days.first) { _, firstDay in
                guard let firstDay else { return }
                let nextAnchor = calendar.startOfDay(for: firstDay)
                guard !calendar.isDate(nextAnchor, inSameDayAs: pageAnchor) else { return }
                var transaction = Transaction()
                transaction.animation = nil
                transaction.disablesAnimations = true
                pagerGestureGeneration += 1
                withTransaction(transaction) {
                    pageAnchor = nextAnchor
                    lastPreviewDate = nextAnchor
                    horizontalDragOffset = 0
                    horizontalDragActive = false
                }
            }
            .onChange(of: interactionSession.eventMoveActive) { _, isActive in
                guard isActive else { return }
                // A long-press move can win after the pager has already
                // previewed a neighboring day. Recenter immediately so the
                // event owns the horizontal gesture and the header reflects
                // the settled page, even if the pager receives no further
                // callbacks before the move commits.
                resetPagerForEventOwnership()
            }
            .overlay {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Calendar timeline, \(days.count) days. Swipe horizontally to change days.")
                    .accessibilityIdentifier("calendar-pager")
                    .allowsHitTesting(false)
            }
        }
    }

    private func pageDays(offset: Int) -> [Date] {
        let anchor = calendar.date(byAdding: .day, value: offset * dayCount, to: pageAnchor) ?? pageAnchor
        return CalendarDateRange.days(containing: anchor, count: dayCount, calendar: calendar)
    }

    private func resetPagerForEventOwnership() {
        let wasPreviewing = horizontalDragActive || horizontalDragOffset != 0 ||
            (lastPreviewDate.map { !calendar.isDate($0, inSameDayAs: pageAnchor) } ?? false)
        horizontalDragActive = false
        horizontalDragOffset = 0
        pagerGestureGeneration += 1
        lastPreviewDate = pageAnchor
        // Restore the compact header even if the pager had already settled
        // its offset but its final preview callback was still in flight.
        if wasPreviewing || onPreviewDateChange != nil {
            onPreviewDateChange?(CalendarGestureArbitration.headerDateAfterEventOwnership(
                settledPage: pageAnchor,
                calendar: calendar
            ))
        }
    }

    private func pagerDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard !interactionSession.eventMoveActive,
                      interactionSession.eventMovePreview == nil else {
                    resetPagerForEventOwnership()
                    return
                }
                let translation = value.translation
                if !horizontalDragActive {
                    guard abs(translation.width) > abs(translation.height) else { return }
                    horizontalDragActive = true
                    pagerGestureGeneration += 1
                }
                guard horizontalDragActive, width > 0 else { return }
                horizontalDragOffset = max(-width * 2, min(width * 2, translation.width))
                let candidate = dateByFractionalDays(
                    -Double(horizontalDragOffset / width) * Double(dayCount),
                    from: pageAnchor
                )
                let day = calendar.startOfDay(for: candidate)
                // The header is a live projection of the page under the
                // finger. Do not wait for a day-boundary callback or settle;
                // the month/week labels must follow a fast in-flight swipe.
                lastPreviewDate = day
                onPreviewDateChange?(day)
            }
            .onEnded { value in
                guard !interactionSession.eventMoveActive,
                      interactionSession.eventMovePreview == nil else {
                    resetPagerForEventOwnership()
                    return
                }
                guard horizontalDragActive, width > 0 else {
                    horizontalDragActive = false
                    horizontalDragOffset = 0
                    return
                }

                horizontalDragActive = false
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    horizontalDragActive = false
                    if reduceMotion {
                        horizontalDragOffset = 0
                    } else {
                        withAnimation(LifeOSMotion.pagerSettle) {
                            horizontalDragOffset = 0
                        }
                    }
                    let anchor = pageAnchor
                    lastPreviewDate = anchor
                    onPreviewDateChange?(anchor)
                    return
                }

                let pageDelta = CalendarInteractionLayout.pagerPageDelta(
                    translation: Double(value.translation.width),
                    predictedTranslation: Double(value.predictedEndTranslation.width),
                    pageWidth: Double(width),
                    maximumPages: 2
                )

                guard pageDelta != 0 else {
                    if reduceMotion {
                        horizontalDragOffset = 0
                    } else {
                        withAnimation(LifeOSMotion.pagerSettle) {
                            horizontalDragOffset = 0
                        }
                    }
                    let anchor = pageAnchor
                    lastPreviewDate = anchor
                    onPreviewDateChange?(anchor)
                    return
                }

                let targetOffset = -width * CGFloat(pageDelta)
                let nextAnchor = calendar.date(byAdding: .day, value: pageDelta * dayCount, to: pageAnchor) ?? pageAnchor
                let commitGeneration = pagerGestureGeneration
                if reduceMotion {
                    var transaction = Transaction()
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        pageAnchor = nextAnchor
                        lastPreviewDate = nextAnchor
                        horizontalDragOffset = 0
                    }
                    onCommitDateChange?(nextAnchor)
                } else {
                    withAnimation(LifeOSMotion.pagerSettle) {
                        horizontalDragOffset = targetOffset
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        guard pagerGestureGeneration == commitGeneration else { return }
                        var transaction = Transaction()
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            pageAnchor = nextAnchor
                            lastPreviewDate = nextAnchor
                            horizontalDragOffset = 0
                        }
                        onCommitDateChange?(nextAnchor)
                    }
                }
            }
    }

    private func dateByFractionalDays(_ value: Double, from date: Date) -> Date {
        guard value.isFinite else { return date }
        let whole = Int(value.rounded(.towardZero))
        let anchor = calendar.date(byAdding: .day, value: whole, to: date) ?? date
        let fractional = value - Double(whole)
        guard abs(fractional) > 0.0001,
              let interval = CalendarInteractionLayout.dayInterval(containing: anchor, calendar: calendar) else {
            return anchor
        }
        let minutes = CalendarInteractionLayout.calendarMinutes(from: interval.start, to: interval.end, calendar: calendar)
        return calendar.date(byAdding: .minute, value: Int((fractional * Double(minutes)).rounded()), to: anchor) ?? anchor
    }
}

private struct CalendarTimelinePage: View {
    let days: [Date]
    let items: [CalendarItem]
    let holidays: [CalendarHoliday]
    let hourHeight: CGFloat
    let calendar: Calendar
    let onSelect: (CalendarItem) -> Void
    let onCreate: ((Date) -> Void)?
    let onCreateTimedRange: ((Date, Date, CGPoint) -> Void)?
    let timedCreationPreview: CalendarTimedCreationPreview?
    let onUpdate: CalendarUpdateHandler?
    let monthNamespace: Namespace.ID?
    let monthExpanded: Bool
    let monthSelectedDate: Date?
    let reduceMotion: Bool
    let isInteractionEnabled: Bool
    let interactionSession: CalendarInteractionSession
    private let timeGutter: CGFloat = 52

    var body: some View {
        GeometryReader { viewport in
            let contentWidth = viewport.size.width
            let timelineHeight = CGFloat(CalendarInteractionLayout.timelineHeight(
                days: days,
                hourHeight: Double(hourHeight),
                calendar: calendar
            ))
            VStack(spacing: 0) {
                dayHeader(width: contentWidth)
                CalendarAllDayRow(days: days, calendar: calendar, timeGutter: timeGutter, width: contentWidth)
                ScrollViewReader { scrollProxy in
                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
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
                                        onUpdate: onUpdate,
                                    monthNamespace: monthNamespace,
                                    monthExpanded: monthExpanded,
                                    monthSelectedDate: monthSelectedDate,
                                    reduceMotion: reduceMotion,
                                    isInteractionEnabled: isInteractionEnabled,
                                    interactionSession: interactionSession
                                        )
                                        .frame(width: max(1, (contentWidth - timeGutter) / CGFloat(max(days.count, 1))))
                                }
                                CalendarTimelineHourAnchors(
                                    hourHeight: hourHeight,
                                    totalHeight: timelineHeight
                                )
                                .frame(width: 1, height: timelineHeight, alignment: .top)
                                .allowsHitTesting(false)
                            }
                            .frame(width: contentWidth, alignment: .leading)
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
                        .frame(height: timelineHeight)
                        .overlay {
                            Color.clear
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Active calendar timeline viewport")
                                .accessibilityIdentifier("calendar-vertical-timeline")
                                .accessibilityHidden(!isInteractionEnabled)
                                .allowsHitTesting(false)
                        }
                    }
                    .task(id: days.first) {
                        scrollProxy.scrollTo(
                            CalendarTimelineScrollAnchor.id(for: initialVisibleHour),
                            anchor: .top
                        )
                    }
                }
            }
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

    private var initialVisibleHour: Int {
        let visibleDayStarts = Set(days.map { calendar.startOfDay(for: $0) })
        let firstDaytimeEventHour = items
            .filter { visibleDayStarts.contains(calendar.startOfDay(for: $0.start)) && $0.end.timeIntervalSince($0.start) <= 12 * 60 * 60 }
            .map { calendar.component(.hour, from: $0.start) }
            .filter { $0 >= 6 }
            .min()
        return max(0, min(8, (firstDaytimeEventHour ?? 9) - 1))
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
    let days: [Date]
    let calendar: Calendar
    let timeGutter: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("All-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: timeGutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
            ForEach(days, id: \.self) { day in
                Color.clear
                    .frame(width: max(1, (width - timeGutter) / CGFloat(max(days.count, 1))), height: 26)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
            }
        }
        .frame(width: width, height: 26, alignment: .leading)
        .background(LifeOSTokens.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }
}

private struct CalendarDayTimeline: View {
    let day: Date
    let items: [CalendarItem]
    let hourHeight: CGFloat
    let calendar: Calendar
    let onSelect: (CalendarItem) -> Void
    let onCreate: ((Date) -> Void)?
    let onCreateTimedRange: ((Date, Date, CGPoint) -> Void)?
    let timedCreationPreview: CalendarTimedCreationPreview?
    let onUpdate: CalendarUpdateHandler?
    let monthNamespace: Namespace.ID?
    let monthExpanded: Bool
    let monthSelectedDate: Date?
    let reduceMotion: Bool
    let isInteractionEnabled: Bool
    let interactionSession: CalendarInteractionSession

    private var interval: DateInterval {
        let start = calendar.startOfDay(for: day)
        return calendar.dateInterval(of: .day, for: start) ?? DateInterval(start: start, end: start)
    }

    private var basePlacements: [CalendarEventPlacement] {
        CalendarOverlapLayout.layout(items: items, interval: interval)
    }

    private var provisionalPlacements: [CalendarEventPlacement] {
        guard let preview = interactionSession.eventMovePreview else { return basePlacements }
        return CalendarOverlapLayout.layoutWithProvisionalMove(
            items: items,
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
#else
                    .simultaneousGesture(macDoubleClickGesture(proxy: proxy))
                    .simultaneousGesture(macCreationDragGesture(proxy: proxy))
#endif
                    .accessibilityIdentifier("calendar-empty-timed-grid-\(calendarISODate(day))")
                    .accessibilityHidden(!isInteractionEnabled)

                ForEach(renderedPlacements) { placement in
                    eventLayer(placement: placement, item: placement.item, scale: scale, width: proxy.size.width, interactive: true)
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
                        interactive: true
                    )
                    // A cross-day source remains the gesture owner, but the
                    // destination ghost is the only visible provisional card.
                    .opacity(renderState == .destinationOnly ? 0 : 1)
                    .accessibilityHidden(renderState == .destinationOnly)
                    .allowsHitTesting(isInteractionEnabled)
                    .zIndex(8)
                }

                if let creationPreview, let creationPreviewEnd {
                    CalendarCreationRangeGhost(
                        start: creationPreview,
                        end: creationPreviewEnd,
                        day: day,
                        hourHeight: hourHeight,
                        calendar: calendar
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zIndex(6)
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
        let selection: () -> Void = interactive ? { onSelect(item) } : {}
        CalendarInteractiveTimelineEvent(
            item: item,
            compact: rawHeight < 44,
            narrow: layerWidth < 82,
            availableHeight: max(24, rawHeight - 2),
            hidesSecondaryMetadata: placement.depth == 0 && placement.columnCount > 1,
            timeZone: calendar.timeZone,
            cornerRadii: placement.cornerRadii,
            day: day,
            hourHeight: hourHeight,
            dayWidth: width,
            calendar: calendar,
            reduceMotion: reduceMotion,
            isInteractionEnabled: interactive && isInteractionEnabled,
            interactionSession: interactionSession,
            onSelect: selection,
            onUpdate: interactive ? onUpdate : nil
        )
        .frame(width: layerWidth, alignment: .topLeading)
        .offset(x: CGFloat(layerFrame.leading), y: y + 1)
        .zIndex(Double(placement.depth) + 1)
        .accessibilityHidden(!(interactive && isInteractionEnabled))
        .allowsHitTesting(interactive && isInteractionEnabled)
    }

    @State private var creationPreview: Date?
    @State private var creationPreviewEnd: Date?
    @State private var creationStartLocation: CGPoint?
    @State private var creationLatestLocation: CGPoint?
    @State private var creationRecognized = false
    @State private var creationCancelled = false

    /// Deliberate empty-space creation is one gesture contract. The sequenced
    /// long press owns recognition and only then hands the same touch to the
    /// zero-distance drag, so a tap/swipe can never reach the commit path. A
    /// composed `onEnded` also gives release one deterministic callback instead
    /// of racing independent drag/long-press callbacks.
    private var creationGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { phase in
                guard isInteractionEnabled else { return }

                switch phase {
                case .first(true):
                    // Keep the recognizer alive while the hold is in flight.
                    // No preview or mutation is armed in this phase.
                    break
                case .second(true, let drag?):
                    creationLatestLocation = drag.location
                    if !creationRecognized {
                        creationRecognized = true
                        creationStartLocation = drag.startLocation
                        CalendarInteractionHaptics.grab()
                    }

                    // Once recognized, a dominant horizontal movement belongs
                    // to the pager. It must cancel creation rather than let a
                    // pager swipe accidentally create an event on release.
                    let horizontal = abs(drag.translation.width)
                    let vertical = abs(drag.translation.height)
                    if horizontal > 18, horizontal > vertical {
                        creationCancelled = true
                        creationPreview = nil
                        creationPreviewEnd = nil
                    } else if !creationCancelled {
                        updateCreationPreview(at: drag.location)
                    }
                default:
                    break
                }
            }
            .onEnded { phase in
                guard isInteractionEnabled else {
                    resetCreationState()
                    return
                }

                // A successful hold may end without another drag sample. Use
                // the last sequenced drag location in that case; the composed
                // gesture still owns this single release callback.
                var finalLocation = creationLatestLocation
                if case .second(true, let drag?) = phase {
                    creationLatestLocation = drag.location
                    finalLocation = drag.location
                    if !creationRecognized {
                        creationRecognized = true
                        creationStartLocation = drag.startLocation
                    }
                }
                if creationRecognized, !creationCancelled, let finalLocation {
                    updateCreationPreview(at: finalLocation)
                }

                let range = creationRecognized && !creationCancelled
                    ? (creationPreview.flatMap { start in
                        creationPreviewEnd.map { (start: start, end: $0) }
                    })
                    : nil
                resetCreationState()
                if let range {
                    onCreateTimedRange?(range.start, range.end, .zero)
                }
            }
    }

    private func updateCreationPreview(at location: CGPoint) {
        guard creationRecognized, !creationCancelled,
              let startLocation = creationStartLocation,
              let interval = CalendarInteractionLayout.creationInterval(
                  day: day,
                  verticalStart: Double(startLocation.y),
                  verticalEnd: Double(location.y),
                  hourHeight: Double(hourHeight),
                  calendar: calendar,
                  defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
              ) else {
            creationPreview = nil
            creationPreviewEnd = nil
            return
        }
        if let creationPreview,
           let creationPreviewEnd,
           creationPreview != interval.start || creationPreviewEnd != interval.end {
            CalendarInteractionHaptics.snap()
        }
        creationPreview = interval.start
        creationPreviewEnd = interval.end
    }

    private func resetCreationState() {
        creationPreview = nil
        creationPreviewEnd = nil
        creationStartLocation = nil
        creationLatestLocation = nil
        creationRecognized = false
        creationCancelled = false
    }

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
                onCreateTimedRange?(interval.start, interval.end, editorAnchor(for: value.location, in: proxy))
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
                onCreateTimedRange?(interval.start, interval.end, editorAnchor(for: value.startLocation, in: proxy))
            }
    }

    private func editorAnchor(for location: CGPoint, in proxy: GeometryProxy) -> CGPoint {
        let frame = proxy.frame(in: .named("calendar-editor-anchor"))
        return CGPoint(x: frame.minX + location.x, y: frame.minY + location.y)
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

private struct CalendarCreationGhost: View {
    let start: Date
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
            let end = calendar.date(byAdding: .minute, value: CalendarInteractionLayout.creationDurationMinutes, to: start) ?? start
            let startY = scale?.y(for: start, calendar: calendar) ?? 0
            let endY = scale.map { startY + $0.height(from: start, to: end, calendar: calendar) } ?? startY
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CalendarEventVisuals.accent.opacity(0.20))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(CalendarEventVisuals.accent.opacity(0.66), lineWidth: 1)
                }
                .frame(width: max(0, proxy.size.width - 2), height: max(1, CGFloat(endY - startY)))
                .offset(x: 1, y: CGFloat(startY) + 1)
        }
        .frame(height: hourHeight * 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New 60 minute event preview")
        .accessibilityValue(start.formatted(date: .omitted, time: .shortened))
        .accessibilityIdentifier("calendar-creation-ghost")
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
    let calendar: Calendar
    let reduceMotion: Bool
    let isInteractionEnabled: Bool
    let interactionSession: CalendarInteractionSession
    let onSelect: () -> Void
    let onUpdate: CalendarUpdateHandler?

    @State private var moveMinutes = 0
    @State private var moveDays = 0
    @State private var resizeMinutes = 0
    @State private var isMoving = false
    @State private var isResizing = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @State private var suppressTap = false
    @State private var lastMoveSnap: Int?
    @State private var lastResizeSnap: Int?

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
            accessibilityID: eventAccessibilityID
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
        .highPriorityGesture(moveGesture)
#else
        .highPriorityGesture(tapGesture)
        .simultaneousGesture(moveGesture)
#endif
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
    }

    private var tapGesture: some Gesture {
        TapGesture().onEnded {
            guard !suppressTap, !isInteracting else { return }
            // Let a control button finish its action before the card's tap
            // recognizer is allowed to select the event.  Two turns also
            // covers AppKit's Button/action delivery order on macOS.
            DispatchQueue.main.async {
                guard !suppressTap, !isInteracting else { return }
                DispatchQueue.main.async {
                    guard !suppressTap, !isInteracting else { return }
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
                .accessibilityIdentifier("calendar-event-move-previous-day-\(item.id.uuidString)")

                Button { performHoverControlAction { commitMove(dayDelta: 1) } } label: {
                    Image(systemName: "arrow.right")
                }
                .accessibilityLabel("Move event to next day")
                .help("Move event to next day")
                .accessibilityIdentifier("calendar-event-move-next-day-\(item.id.uuidString)")

                Button { performHoverControlAction { commitResize(minutes: -15) } } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("Resize event shorter 15 minutes")
                .help("Resize event shorter by 15 minutes")
                .accessibilityIdentifier("calendar-event-resize-shorter-\(item.id.uuidString)")

                Button { performHoverControlAction { commitResize(minutes: 15) } } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Resize event longer 15 minutes")
                .help("Resize event longer by 15 minutes")
                .accessibilityIdentifier("calendar-event-resize-longer-\(item.id.uuidString)")
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
        isInteractionEnabled
            ? "calendar-event-\(item.id.uuidString)"
            : "calendar-offscreen-event-\(item.id.uuidString)"
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
        resizeHandleSurface
#endif
    }

    private var resizeHandleSurface: some View {
        Capsule(style: .continuous)
            .fill(CalendarEventVisuals.accent.opacity(0.82))
            .frame(width: 28, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 18, alignment: .bottom)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize event")
            .accessibilityValue("15 minute resize actions available")
            .accessibilityHint("Use resize shorter or resize longer actions in 15 minute steps")
            .accessibilityIdentifier(isInteractionEnabled
                ? "calendar-event-resize-\(item.id.uuidString)"
                : "calendar-offscreen-event-resize-\(item.id.uuidString)")
            .accessibilityAction(named: "Resize shorter 15 minutes") { commitResize(minutes: -15) }
            .accessibilityAction(named: "Resize longer 15 minutes") { commitResize(minutes: 15) }
            .highPriorityGesture(resizeGesture)
    }

    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { phase in
                if case .first(true) = phase {
                    // Claim the pointer before the hold threshold completes.
                    // This keeps the parent macOS horizontal ScrollView from
                    // consuming the first horizontal drag sample.
                    interactionSession.eventMoveActive = true
                }
                guard case .second(true, let drag?) = phase else { return }
                guard drag.startLocation.y < max(0, availableHeight - 18) else { return }
                if !isMoving {
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
                    interactionSession.eventMoveActive = false
                    interactionSession.eventMovePreview = nil
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
                if case .first(true) = phase {
                    // Resize is also an event-owned mutation: the parent
                    // horizontal timeline must yield while it is committed.
                    interactionSession.eventMoveActive = true
                }
                guard case .second(true, let drag?) = phase else { return }
                if !isResizing {
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
                    interactionSession.eventMoveActive = false
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
        let interval = proposedMoveInterval(dayDelta: dayDelta, minutes: minutes)
        guard let interval else {
            if resetTap { suppressTap = false }
            interactionSession.eventMoveActive = false
            interactionSession.eventMovePreview = nil
            return
        }
        if interval.start == item.start, interval.end == item.end {
            if resetTap { suppressTap = false }
            interactionSession.eventMoveActive = false
            interactionSession.eventMovePreview = nil
            return
        }
        if emitHaptic, minutes != 0 || dayDelta != 0 { CalendarInteractionHaptics.snap() }
        if let onUpdate {
            // Keep the owner and provisional render alive until the local save
            // completion. Both success and failure then take the same cleanup
            // path; a failed save re-renders the unchanged coordinator snapshot.
            onUpdate(item, interval.start, interval.end) { _ in
                // Local durability, whether success or failure, ends the
                // provisional render. A failed save leaves the coordinator's
                // original snapshot untouched and exposes its error state.
                let cleanup = CalendarGestureArbitration.cleanupAfterCompletedMutation(
                    settledPage: day,
                    calendar: calendar
                )
                interactionSession.eventMovePreview = nil
                interactionSession.eventMoveActive = cleanup.eventMoveActive
                if resetTap { suppressTap = false }
            }
        }
        if onUpdate == nil {
            interactionSession.eventMovePreview = nil
            interactionSession.eventMoveActive = false
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
        let translation = Double(minutes) / 60 * Double(hourHeight)
        guard let interval = CalendarInteractionLayout.resizedInterval(
            item: item,
            edge: .end,
            translation: translation,
            hourHeight: Double(hourHeight),
            day: day,
            calendar: calendar
        ) else {
            if resetTap { suppressTap = false }
            return
        }
        if emitHaptic, minutes != 0 { CalendarInteractionHaptics.snap() }
        guard let onUpdate else {
            interactionSession.eventMoveActive = false
            if resetTap { suppressTap = false }
            return
        }
        onUpdate(item, interval.start, interval.end) { _ in
            let cleanup = CalendarGestureArbitration.cleanupAfterCompletedMutation(
                settledPage: day,
                calendar: calendar
            )
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
                        .frame(width: max(0, contentWidth - timeGutter - 7), height: 2)
                }
                .offset(y: y - 1)
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
        return "\(item.icon ?? "No icon") \(item.title), \(item.status.label), " +
            "\(CalendarTimelineScale.localizedTimeLabel(for: item.start, calendar: displayCalendar)) to " +
            "\(CalendarTimelineScale.localizedTimeLabel(for: item.end, calendar: displayCalendar))"
    }

    var body: some View {
        Group {
            if narrow {
                HStack(spacing: 4) {
                    LifeOSIcon(item.status.iconName)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .truncationMode(.tail)
                }
            } else {
                HStack(alignment: .top, spacing: 5) {
                    LifeOSIcon(item.status.iconName)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.white.opacity(0.78))
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
        .accessibilityIdentifier("calendar-month-cell-\(calendarISODate(day))")
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
            "\(item.start.formatted(date: .numeric, time: .shortened)) to " +
            "\(item.end.formatted(date: .numeric, time: .shortened)); long press and drag to move"
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
    public let month: Date
    public let selectedDate: Date
    public let selectedRange: [Date]
    public let calendar: Calendar
    public let namespace: Namespace.ID?
    public let reduceMotion: Bool
    public let onSelectDate: (Date) -> Void

    public init(
        month: Date,
        selectedDate: Date,
        selectedRange: [Date],
        calendar: Calendar = .current,
        namespace: Namespace.ID? = nil,
        reduceMotion: Bool = false,
        onSelectDate: @escaping (Date) -> Void
    ) {
        self.month = month
        self.selectedDate = selectedDate
        self.selectedRange = selectedRange
        self.calendar = calendar
        self.namespace = namespace
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
            Color.clear.frame(height: 20)
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
            }

            ForEach(Array(days.chunked(into: 7).enumerated()), id: \.offset) { row, week in
                Text(weekNumber(for: week.first))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                ForEach(Array(week.enumerated()), id: \.offset) { index, day in
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
                        namespace: namespace,
                        reduceMotion: reduceMotion,
                        action: { onSelectDate(day) }
                    )
                }
                .id(row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
    let namespace: Namespace.ID?
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
                        isSource: true
                    )
                } else {
                    label
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(isSelected ? "Selected" : (isInSelectedRange ? "Visible range" : ""))
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
