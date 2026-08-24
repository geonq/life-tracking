import SwiftUI
import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

private enum CalendarDisplayMode: Hashable {
    case timeline
    case month
    #if os(iOS)
    case week
    #endif
}

private struct CalendarEditorPresentation: Identifiable {
    let id = UUID()
    let item: CalendarItem?
    let date: Date
    let endDate: Date?

    init(item: CalendarItem?, date: Date, endDate: Date? = nil) {
        self.item = item
        self.date = date
        self.endDate = endDate
    }
}

#if os(macOS)
/// A concrete AppKit source view for the contextual editor popover.
///
/// Keeping a real NSView at the named-space source frame makes AppKit's source
/// geometry unambiguous while leaving presentation and dismissal owned by
/// SwiftUI. The source view has no implicit hosting-origin fallback.
private struct CalendarPopoverAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

typealias CalendarEditorCompletion = (CalendarLocalSaveResult) -> Void
typealias CalendarEditorMutationHandler = (CalendarItem, @escaping CalendarEditorCompletion) -> Void
typealias CalendarEditorRetryHandler = (@escaping CalendarEditorCompletion) -> Void

public struct CalendarView: View {
    @ObservedObject private var coordinator: CalendarCoordinator
    @State private var selectedDate: Date
    @State private var headerDate: Date
    @State private var displayMode: CalendarDisplayMode = .timeline
    @State private var monthExpanded = false
    @State private var editorPresentation: CalendarEditorPresentation?
    @State private var anchoredEditorPresentation: CalendarEditorPresentation?
    @State private var timedCreationPreview: CalendarTimedCreationPreview?
    @State private var isSearchPresented = false
#if os(macOS)
    @State private var editorAnchorFrame: CGRect?
    @State private var editorPresentationGeneration = 0
#endif
    @State private var hourHeight: CGFloat = 54
    @State private var gestureStartHourHeight: CGFloat?
    @Binding private var requestNewEvent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var calendarMonthNamespace
    private let externalSelectedDate: Date?
    private let calendar: Calendar

    public init(
        selectedDate: Date? = nil,
        calendar: Calendar = .current,
        coordinator: CalendarCoordinator,
        startsInMonthMode: Bool = false,
        requestNewEvent: Binding<Bool> = .constant(false)
    ) {
        let initialDate = selectedDate ?? .now
        _selectedDate = State(initialValue: initialDate)
        _headerDate = State(initialValue: initialDate)
        _displayMode = State(initialValue: startsInMonthMode ? .month : .timeline)
        _requestNewEvent = requestNewEvent
        self.externalSelectedDate = selectedDate
        self.calendar = calendar
        self.coordinator = coordinator
    }

    private var visibleItems: [CalendarItem] {
        coordinator.snapshot.items.filter { !$0.isDeleted }
    }

    /// The window every surface renders from: base items plus their derived
    /// recurring occurrences. One year back and two ahead covers search of
    /// recent history and any reachable month grid; the engine cap bounds the
    /// expansion regardless.
    private var displayItems: [CalendarItem] {
        let now = Date.now
        let window = DateInterval(
            start: calendar.date(byAdding: .year, value: -1, to: now) ?? now,
            end: calendar.date(byAdding: .year, value: 2, to: now) ?? now
        )
        return visibleItems.flatMap { CalendarRecurrence.occurrences(of: $0, overlapping: window, calendar: calendar) }
    }

    private var visibleHolidays: [CalendarHoliday] {
        let selectedYear = calendar.component(.year, from: selectedDate)
        return (selectedYear - 1...selectedYear + 1).flatMap {
            CalendarHolidayCatalog.holidays(year: $0, regions: [.berlin, .unitedStates], calendar: calendar)
        }
    }

    private var timelineDays: [Date] {
#if os(macOS)
        CalendarDateRange.week(containing: selectedDate, calendar: calendar)
#else
        switch displayMode {
        case .week:
            CalendarDateRange.week(containing: selectedDate, calendar: calendar)
        case .timeline, .month:
            CalendarDateRange.days(containing: selectedDate, count: 3, calendar: calendar)
        }
#endif
    }

    private var selectedDayItems: [CalendarItem] {
        displayItems
            .filter { calendar.isDate($0.start, inSameDayAs: selectedDate) }
            .sorted { $0.start < $1.start }
    }

    private var sidebarDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return style
    }

    private var sidebarTimeStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = calendar.timeZone
        return style
    }

    public var body: some View {
        Group {
#if os(macOS)
            macLayout
#else
            mobileLayout
#endif
        }
        .onChange(of: requestNewEvent, initial: true) { _, requested in
            guard requested else { return }
            create()
            requestNewEvent = false
        }
        .onChange(of: selectedDate) { _, date in
            headerDate = date
        }
        .onChange(of: externalSelectedDate) { _, date in
            guard let date else { return }
            retargetSelectedDate(date)
        }
        .onChange(of: anchoredEditorPresentation?.id) { _, presentationID in
            if presentationID == nil {
                timedCreationPreview = nil
#if os(macOS)
                editorAnchorFrame = nil
#endif
            }
        }
        .onChange(of: editorPresentation?.id) { _, presentationID in
            // iOS presents the editor as a sheet, so there is no anchored
            // presentation change to clear the range ghost on Cancel or
            // after a successful save.
            if presentationID == nil {
                timedCreationPreview = nil
            }
        }
        .sheet(isPresented: $isSearchPresented) {
            CalendarSearchView(
                items: displayItems,
                calendar: calendar,
                onSelect: openSearchResult(_:)
            )
        }
    }

#if os(macOS)
    private var macLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CalendarCompactMonth(
                    selectedDate: $selectedDate,
                    calendar: calendar,
                    items: displayItems
                )
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(LifeOSTokens.hairlineBorder)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schedule")
                            .font(LifeOSFont.spaceGrotesk(12, weight: .medium))
                        Text(selectedDate, format: sidebarDateStyle)
                            .font(LifeOSFont.inter(10, weight: .medium))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }

                    if selectedDayItems.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No events")
                                .font(LifeOSFont.inter(12, weight: .medium))
                                .foregroundStyle(Color.secondary)
                            Text("The day is clear.")
                                .font(LifeOSFont.inter(10, weight: .regular))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        .padding(.top, 2)
                    } else {
                        ForEach(selectedDayItems.prefix(5)) { item in
                            Button { edit(item) } label: {
                                compactSidebarEvent(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)

                Spacer(minLength: 0)
            }
            .frame(width: 248)
            .background(LifeOSTokens.surface.opacity(0.44))
            .overlay(alignment: .trailing) { Rectangle().fill(LifeOSTokens.hairlineBorder).frame(width: 1) }

            calendarContent
        }
        .background(LifeOSTokens.canvas)
#if os(macOS)
        // macOS creation and edits use the contextual inspector below. The
        // toolbar/sidebar paths land at a safe top-left anchor; empty-grid
        // gestures provide their actual pointer location.
#else
        .sheet(item: $editorPresentation) { presentation in
            CalendarEditor(item: presentation.item, date: presentation.date, endDate: presentation.endDate, calendar: calendar, onSave: save, onDelete: delete, onRetry: retrySave)
                .frame(width: 540, height: 600)
        }
#endif
    }

    private func compactSidebarEvent(_ item: CalendarItem) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LifeOSTokens.Hue.green.base)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text("\(item.start, format: sidebarTimeStyle) – \(item.end, format: sidebarTimeStyle)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 0)
            if item.hasIcon {
                CalendarIconView(item: item, size: 17)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
#else
    private var mobileLayout: some View {
        calendarContent
            .overlay(alignment: .bottom) {
                calendarQuickActions
            }
            .refreshable { await coordinator.manualRefresh() }
            .background(LifeOSTokens.canvas)
            .sheet(item: $editorPresentation) { presentation in
                CalendarEditor(item: presentation.item, date: presentation.date, endDate: presentation.endDate, calendar: calendar, onSave: save, onDelete: delete, onRetry: retrySave)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
    }
#endif

#if os(iOS)
    private var calendarQuickActions: some View {
        HStack(spacing: 12) {
            if let next = nextUpcomingTimedItem {
                CalendarNextEventPill(item: next, calendar: calendar) { edit(next) }
            }
            Spacer(minLength: 0)
            CalendarQuickCreateButton(action: quickCreate)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var nextUpcomingTimedItem: CalendarItem? {
        let now = Date.now
        return displayItems
            .filter { !CalendarAllDayLayout.isAllDay($0, calendar: calendar) && $0.start > now }
            .min { lhs, rhs in
                lhs.start == rhs.start ? lhs.id.uuidString < rhs.id.uuidString : lhs.start < rhs.start
            }
    }

    private var isTimedGridVisible: Bool {
        switch displayMode {
        case .timeline, .week: true
        case .month: false
        }
    }

    private func quickCreate() {
        create(at: quickCreationDate())
    }

    private func quickCreationDate() -> Date {
        let fallback = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        guard isTimedGridVisible else { return fallback }
        let now = Date.now
        guard calendar.isDate(now, inSameDayAs: selectedDate) else { return fallback }
        let dayStart = calendar.startOfDay(for: now)
        let elapsedMinutes = calendar.dateComponents([.minute], from: dayStart, to: now).minute ?? 0
        return calendar.date(byAdding: .minute, value: ((elapsedMinutes / 30) + 1) * 30, to: dayStart) ?? fallback
    }
#endif

    private var calendarContent: some View {
        VStack(spacing: 0) {
            if let message = coordinator.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") {
                        Task { _ = await coordinator.retryLastSave() }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(LifeOSTokens.warning)
                .background(LifeOSTokens.warning.opacity(0.10))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("calendar-persistence-error")
            } else if let warning = coordinator.syncWarning {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(warning)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.08))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("calendar-sync-warning")
            }
            calendarHeader
            Group {
                switch displayMode {
                case .timeline:
                    timedGridContent
#if os(iOS)
                case .week:
                    timedGridContent
#endif
                case .month:
                    ScrollView {
                        CalendarMonthGrid(
                            month: selectedDate,
                            selectedDate: selectedDate,
                            items: displayItems,
                            holidays: visibleHolidays,
                            calendar: calendar,
                            onSelectDate: { date in
                                selectedDate = date
#if os(iOS)
                                withAnimation(reduceMotion ? nil : LifeOSMotion.easeNavigate) { displayMode = .timeline }
#endif
                            },
                            onSelectItem: edit,
                            onUpdate: update,
                            reduceMotion: reduceMotion
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
            .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.995)))
        }
        .background(LifeOSTokens.canvas)
        .animation(reduceMotion ? nil : LifeOSMotion.easeNavigate, value: displayMode)
        .coordinateSpace(name: CalendarEditorAnchorGeometry.coordinateSpaceName)
#if os(macOS)
        .overlay(alignment: .topLeading) {
            if let sourceFrame = editorAnchorFrame {
                CalendarPopoverAnchor()
                    .frame(width: sourceFrame.width, height: sourceFrame.height)
                    // The source frame is already in the enclosing named
                    // space. Alignment guides perform actual SwiftUI layout,
                    // so AppKit receives the same frame rather than a render
                    // offset or an old pointer position.
                    .alignmentGuide(.leading) { _ in -sourceFrame.minX }
                    .alignmentGuide(.top) { _ in -sourceFrame.minY }
                    .popover(
                        item: $anchoredEditorPresentation,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .leading
                    ) { presentation in
                        CalendarEditor(
                            item: presentation.item,
                            date: presentation.date,
                            endDate: presentation.endDate,
                            calendar: calendar,
                            onSave: save,
                            onDelete: delete,
                            onRetry: retrySave,
                            onCancel: cancelMacEditor
                        )
                        .frame(width: 540, height: 600)
                    }
            }
        }
#endif
    }

    @ViewBuilder
    private var timedGridContent: some View {
        VStack(spacing: 0) {
            CalendarExpandedMonthGrid(
                month: headerDate,
                selectedDate: headerDate,
                selectedRange: CalendarDateRange.days(
                    containing: headerDate,
                    count: timelineDays.count,
                    calendar: calendar
                ),
                calendar: calendar,
                namespace: reduceMotion ? nil : calendarMonthNamespace,
                isSource: monthExpanded,
                reduceMotion: reduceMotion,
                onSelectDate: selectExpandedDate
            )
            // Notion grows the month panel in place below the
            // header. Keeping its layout alive at zero height lets
            // the selected cell's matched geometry morph while
            // the day grid below follows the same height change.
            .frame(maxWidth: .infinity)
            .frame(
                height: monthExpanded ? CalendarExpandedMonthGrid.preferredHeight : 0,
                alignment: .top
            )
            .clipped()
            .opacity(monthExpanded ? 1 : 0)
            // Reduced motion keeps the matched-geometry namespace
            // disabled, but still gives the month panel a short,
            // opacity-led cross-fade instead of an abrupt reveal.
            .animation(
                reduceMotion
                    ? .easeInOut(duration: CalendarInteractionLayout.reducedMotionMonthCrossfadeDuration)
                    : LifeOSMotion.heroMorph,
                value: monthExpanded
            )
            .allowsHitTesting(monthExpanded)
            .accessibilityHidden(!monthExpanded)
            CalendarTimelineView(
                days: timelineDays,
                items: displayItems,
                holidays: visibleHolidays,
                hourHeight: hourHeight,
                calendar: calendar,
                onSelect: calendarEventSelectionHandler,
                onCreate: create(at:),
                onCreateAllDay: createAllDay(at:),
                onCreateTimedRange: createTimedRange(start:end:anchor:),
                timedCreationPreview: timedCreationPreview,
                onTimedCreationDraft: updateTimedCreationDraft,
                onUpdate: update,
                onStatusUpdate: updateStatus,
                onPreviewDateChange: previewDate,
                onCommitDateChange: commitPreviewDate,
                monthNamespace: reduceMotion ? nil : calendarMonthNamespace,
                monthExpanded: monthExpanded,
                monthSelectedDate: headerDate,
                reduceMotion: reduceMotion
            )
        }
        #if os(iOS)
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if gestureStartHourHeight == nil { gestureStartHourHeight = hourHeight }
                    hourHeight = min(110, max(38, (gestureStartHourHeight ?? hourHeight) * scale))
                }
                .onEnded { _ in gestureStartHourHeight = nil }
        )
        .accessibilityHint("Pinch vertically to change hour spacing")
        #endif
    }

    private var calendarHeader: some View {
        Group {
#if os(iOS)
            HStack(spacing: 12) {
                Button(action: toggleMonthExpansion) {
                    HStack(spacing: 5) {
                        Text(headerDate, format: .dateTime.month(.wide))
                            .font(LifeOSFont.headerLarge(20))
                            .lineLimit(1)
                        LifeOSIcon(.chevronRight)
                            .rotationEffect(.degrees(monthExpanded ? -90 : 90))
                            .frame(width: 12, height: 12)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, monthExpanded ? 10 : 0)
                    .frame(height: 38)
                    .background(
                        monthExpanded ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(monthExpanded ? "Collapse month" : "Expand month")
                .accessibilityIdentifier("calendar-month-toggle")
                .accessibilityValue(calendarISODate(headerDate))

                Text("Week \(calendar.component(.weekOfYear, from: headerDate))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button {
                    isSearchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search events")
                .accessibilityIdentifier("calendar-search")

                Button {
                    Task { _ = await coordinator.undo() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(coordinator.canUndo ? Color.primary : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.canUndo)
                .accessibilityLabel("Undo last calendar change")
                .accessibilityHint("Restores the calendar before the most recent saved change")
                .accessibilityIdentifier("calendar-undo")

                Menu {
                    Button("Timeline") { setDisplayMode(.timeline) }
                    #if os(iOS)
                    Button("Week") { setDisplayMode(.week) }
                    #endif
                    Button("Month view") { setDisplayMode(.month) }
                } label: {
                    LifeOSIcon(.calendar)
                        .frame(width: 17, height: 17)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Calendar view")
                .accessibilityIdentifier("calendar-view-picker")

                Button(action: goToToday) {
                    Text(Date.now, format: todayDayStyle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.lifeOSCalendarRed, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Today")
                .accessibilityIdentifier("calendar-today")

                Button(action: create) {
                    LifeOSIcon(.add)
                        .frame(width: 17, height: 17)
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("calendar-add")
                .accessibilityLabel("New event")
            }
#else
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedDate, format: .dateTime.month(.wide).year())
                            .font(LifeOSFont.headerLarge(22))
                            .accessibilityIdentifier("calendar-header-date")
                            .accessibilityValue(calendarISODate(selectedDate))
                        Text(displayMode == .month ? "Month" : timelineSubtitle)
                            .font(LifeOSFont.caption())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Search events")
                    .accessibilityIdentifier("calendar-search")
                    Button {
                        Task { _ = await coordinator.undo() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Undo")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel("Undo last calendar change")
                    .accessibilityHint("Restores the calendar before the most recent saved change")
                    .accessibilityIdentifier("calendar-undo")
                    Button("Today") { selectedDate = .now }
                        .buttonStyle(.bordered)
                    Button { move(by: -1) } label: {
                        LifeOSIcon(.chevronLeft).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Previous \(displayMode == .month ? "month" : timelinePeriodName)")
                    .accessibilityIdentifier("calendar-previous-period")
                    .keyboardShortcut("[", modifiers: .command)
                    Button { move(by: 1) } label: {
                        LifeOSIcon(.chevronRight).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Next \(displayMode == .month ? "month" : timelinePeriodName)")
                    .accessibilityIdentifier("calendar-next-period")
                    .keyboardShortcut("]", modifiers: .command)
                    Button { create() } label: {
                        HStack(spacing: 6) {
                            LifeOSIcon(.add).frame(width: 15, height: 15)
                            Text("New")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("calendar-add")
                    .accessibilityLabel("New event")
                    .accessibilityHint("Create a calendar event")
                }

                HStack {
                    Picker("Calendar view", selection: $displayMode) {
                        Text(timelinePickerLabel).tag(CalendarDisplayMode.timeline)
                        Text("Month").tag(CalendarDisplayMode.month)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("calendar-view-picker")
                    .frame(maxWidth: 260)
                    Spacer()
                    if displayMode == .timeline {
                        Slider(value: $hourHeight, in: 38...110, step: 2)
                            .frame(width: 110)
                            .accessibilityLabel("Hour height")
                    }
                }
            }
#endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(LifeOSTokens.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

#if os(iOS)
    private func calendarModeButton(_ mode: CalendarDisplayMode, label: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : LifeOSMotion.easeNavigate) { displayMode = mode }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(displayMode == mode ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    displayMode == mode ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(displayMode == mode ? .isSelected : [])
    }

    private func navigationButton(direction: Int, icon: LifeOSIconName) -> some View {
        Button { move(by: direction) } label: {
            LifeOSIcon(icon).frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(LifeOSTokens.accent)
        .frame(width: 32, height: 30)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("\(direction < 0 ? "Previous" : "Next") \(displayMode == .month ? "month" : timelinePeriodName)")
    }
#endif

    private var timelinePickerLabel: String {
#if os(macOS)
        "Week"
#else
        "3 Days"
#endif
    }

    private var timelinePeriodName: String {
#if os(macOS)
        "week"
#else
        switch displayMode {
        case .month: "month"
        case .week: "week"
        case .timeline: "three days"
        }
#endif
    }

    private var timelineSubtitle: String {
#if os(macOS)
        "Week view"
#else
        "Three-day view"
#endif
    }

    private var todayDayStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.day()
        style.timeZone = calendar.timeZone
        return style
    }

    /// The compact header's accessibility value follows the date being previewed
    /// during a pager drag and the date committed after it settles. Components
    /// come from the view's calendar so the value remains date-only and stable
    /// across the device's display locale and time zone.
    private func calendarISODate(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }

        func padded(_ value: Int, to width: Int) -> String {
            let raw = String(value)
            return String(repeating: "0", count: max(0, width - raw.count)) + raw
        }

        return padded(year, to: 4) + "-" + padded(month, to: 2) + "-" + padded(day, to: 2)
    }

    private func move(by direction: Int) {
        let component: Calendar.Component = displayMode == .month ? .month : .day
#if os(macOS)
        let amount = displayMode == .month ? direction : direction * 7
#else
        let amount: Int
        switch displayMode {
        case .month: amount = direction
        case .week: amount = direction * 7
        // The strip slides exactly one day per step, matching the swipe
        // contract; chevrons and keyboard navigation stay in sync with it.
        case .timeline: amount = direction
        }
#endif
        selectedDate = calendar.date(byAdding: component, value: amount, to: selectedDate) ?? selectedDate
    }

    private func setDisplayMode(_ mode: CalendarDisplayMode) {
        let update = { displayMode = mode }
        if reduceMotion {
            update()
        } else {
            withAnimation(LifeOSMotion.easeNavigate, update)
        }
    }

    private func toggleMonthExpansion() {
        let update = { monthExpanded.toggle() }
        switch CalendarInteractionLayout.monthExpansionMotionPolicy(reduceMotion: reduceMotion) {
        case .opacityCrossfade(let duration):
            withAnimation(.easeInOut(duration: duration), update)
        case .matchedGeometryMorph:
            withAnimation(LifeOSMotion.heroMorph, update)
        }
    }

    private func goToToday() {
        let today = calendar.startOfDay(for: .now)
        retargetSelectedDate(today)
    }

    private func previewDate(_ date: Date) {
        // During a pager drag only the compact header moves. Keeping the
        // selected date settled avoids rebuilding the three virtual pages
        // under the user's finger.
        // Preserve the live projection's time component so month/week labels
        // cross their boundaries in the same frame as the day columns. The
        // timeline remains anchored to selectedDate until the settle commit.
        headerDate = date
    }

    private func commitPreviewDate(_ date: Date) {
        let settled = calendar.startOfDay(for: date)
        // The pager already supplied the visible page transition. Commit the
        // settled date without a second animation so recentering page 0 stays
        // invisible and cannot produce a reverse/jump.
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            headerDate = settled
            selectedDate = settled
        }
    }

    private func retargetSelectedDate(_ date: Date) {
        let target = calendar.startOfDay(for: date)
        let current = calendar.startOfDay(for: selectedDate)
        let distance = abs(calendar.dateComponents([.day], from: current, to: target).day ?? Int.max)
        let isNear = distance <= 3

        if reduceMotion || !isNear {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                headerDate = target
                selectedDate = target
            }
        } else {
            withAnimation(LifeOSMotion.easeNavigate) {
                headerDate = target
                selectedDate = target
            }
        }
    }

    private func selectExpandedDate(_ date: Date) {
        let update = {
            selectedDate = calendar.startOfDay(for: date)
            monthExpanded = false
            displayMode = .timeline
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(LifeOSMotion.heroMorph, update)
        }
    }

    private func create() {
        let date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDate) ?? selectedDate
#if os(macOS)
        create(at: date, sourceFrame: toolbarEditorSourceFrame)
#else
        create(at: date, anchor: CGPoint(x: 300, y: 100))
#endif
    }

    private func create(at date: Date) {
#if os(macOS)
        create(at: date, sourceFrame: toolbarEditorSourceFrame)
#else
        create(at: date, anchor: CGPoint(x: 300, y: 100))
#endif
    }

    private func createAllDay(at day: Date) {
        guard let interval = CalendarAllDayLayout.creationInterval(for: day, calendar: calendar) else { return }
        timedCreationPreview = nil
#if os(macOS)
        presentMacEditor(
            CalendarEditorPresentation(item: nil, date: interval.start, endDate: interval.end),
            sourceFrame: toolbarEditorSourceFrame
        )
#else
        editorPresentation = CalendarEditorPresentation(item: nil, date: interval.start, endDate: interval.end)
#endif
    }

#if os(macOS)
    private func create(at date: Date, sourceFrame: CGRect) {
        timedCreationPreview = nil
        presentMacEditor(
            CalendarEditorPresentation(item: nil, date: date),
            sourceFrame: sourceFrame
        )
    }
#else
    private func create(at date: Date, anchor: CGPoint) {
        timedCreationPreview = nil
        editorPresentation = CalendarEditorPresentation(item: nil, date: date)
    }
#endif

    private func createTimedRange(start: Date, end: Date, anchor: CalendarTimedCreationAnchor) {
        timedCreationPreview = CalendarTimedCreationPreview(day: start, start: start, end: end)
#if os(macOS)
        presentMacEditor(
            CalendarEditorPresentation(item: nil, date: start, endDate: end),
            sourceFrame: anchor
        )
#else
        // Preserve the exact selected interval. The range ghost remains
        // mounted behind the sheet until Cancel or local save completion.
        editorPresentation = CalendarEditorPresentation(item: nil, date: start, endDate: end)
#endif
    }

    /// Live ghost state for the iOS press-and-drag creation gesture. Passing
    /// `nil` clears a stale draft when the gesture fails before commit; the
    /// commit path overwrites the draft with the authoritative range.
    private func updateTimedCreationDraft(_ preview: CalendarTimedCreationPreview?) {
        timedCreationPreview = preview
    }

#if os(macOS)
    private var calendarEventSelectionHandler: CalendarEventSelectionHandler {
        { item, sourceFrame in edit(item, sourceFrame: sourceFrame) }
    }
#else
    private var calendarEventSelectionHandler: CalendarEventSelectionHandler {
        { item in edit(item) }
    }
#endif

    /// A derived occurrence is never edited directly: selection opens the
    /// anchor item so every change is a series-level change.
    private func resolveAnchor(for item: CalendarItem) -> CalendarItem {
        guard let sourceID = item.occurrenceSourceID else { return item }
        return visibleItems.first { $0.id == sourceID } ?? item
    }

    private func edit(_ item: CalendarItem) {
        timedCreationPreview = nil
        let target = resolveAnchor(for: item)
#if os(macOS)
        presentMacEditor(
            CalendarEditorPresentation(item: target, date: selectedDate),
            sourceFrame: toolbarEditorSourceFrame
        )
#else
        editorPresentation = CalendarEditorPresentation(item: target, date: selectedDate)
#endif
    }

    /// A search result jumps to the item's day and opens its editor. The
    /// editor presentation waits one runloop turn so the search sheet's
    /// dismissal transaction never races the new presentation.
    private func openSearchResult(_ item: CalendarItem) {
        isSearchPresented = false
        retargetSelectedDate(item.start)
        DispatchQueue.main.async {
            edit(item)
        }
    }

#if os(macOS)
    /// Pointer-selected events carry their rendered card rect from the day
    /// timeline. This path intentionally cannot fall back to the toolbar
    /// anchor used by sidebar and command-palette entry points.
    private func edit(_ item: CalendarItem, sourceFrame: CGRect) {
        timedCreationPreview = nil
        presentMacEditor(
            CalendarEditorPresentation(item: item, date: selectedDate),
            sourceFrame: sourceFrame
        )
    }

    /// Toolbar/sidebar entry points use this explicit named-space frame. It
    /// is a stable control anchor; pointer-created editors never use this
    /// value.
    private var toolbarEditorSourceFrame: CGRect {
        // This is an explicit control anchor in the named CalendarView
        // coordinate space. Pointer-created editors never use this value.
        CGRect(x: 300, y: 100, width: 1, height: 1)
    }

    private func presentMacEditor(_ presentation: CalendarEditorPresentation, sourceFrame: CGRect) {
        guard sourceFrame.minX.isFinite,
              sourceFrame.minY.isFinite,
              sourceFrame.width > 0,
              sourceFrame.height > 0 else {
            cancelMacEditor()
            return
        }
        editorPresentationGeneration += 1
        let generation = editorPresentationGeneration
        anchoredEditorPresentation = nil
        editorAnchorFrame = nil
        // A native popover snapshots its source rect at presentation time.
        // Yield one layout pass after moving that named-space frame. Install
        // the frame first, then present on the following turn so the observer
        // that clears dismissed anchors cannot erase a replacement frame.
        DispatchQueue.main.async {
            guard editorPresentationGeneration == generation else { return }
            editorAnchorFrame = sourceFrame
            DispatchQueue.main.async {
                guard editorPresentationGeneration == generation,
                      editorAnchorFrame == sourceFrame else { return }
                anchoredEditorPresentation = presentation
            }
        }
    }

    private func cancelMacEditor() {
        editorPresentationGeneration += 1
        anchoredEditorPresentation = nil
        editorAnchorFrame = nil
        timedCreationPreview = nil
    }
#endif

    private func save(_ item: CalendarItem, completion: @escaping CalendarEditorCompletion) {
        Task { @MainActor in
            completion(await coordinator.save(item))
        }
    }

    private func update(_ item: CalendarItem, start: Date, end: Date, completion: @escaping CalendarUpdateCompletion) {
        guard start != item.start || end != item.end else {
            completion(.success)
            return
        }
        // Moving or resizing any occurrence shifts the whole series by the
        // same delta: recurring items are series-owned in this version.
        let resolved: CalendarItem?
        if let sourceID = item.occurrenceSourceID,
           let anchor = visibleItems.first(where: { $0.id == sourceID }) {
            let startDelta = start.timeIntervalSince(item.start)
            let endDelta = end.timeIntervalSince(item.end)
            resolved = try? anchor.updating(
                start: anchor.start.addingTimeInterval(startDelta),
                end: max(anchor.start.addingTimeInterval(startDelta), anchor.end.addingTimeInterval(endDelta)),
                at: .now
            )
        } else {
            resolved = try? item.updating(start: start, end: end, at: .now)
        }
        guard let updated = resolved else {
            completion(.success)
            return
        }
        Task { @MainActor in
            let result = await coordinator.save(updated)
            completion(result)
        }
    }

    private func updateStatus(_ item: CalendarItem, status: CalendarProgress, completion: @escaping CalendarUpdateCompletion) {
        guard item.kind == .todo else {
            completion(.failure("Only to-do items have an interactive completion checkbox."))
            return
        }
        // A recurring to-do completes as a series; its occurrences all share
        // the anchor's durable progress.
        let target = resolveAnchor(for: item)
        guard let updated = try? target.updating(status: status, at: .now) else {
            completion(.failure("Only to-do items have an interactive completion checkbox."))
            return
        }
        Task { @MainActor in
            completion(await coordinator.save(updated))
        }
    }

    private func delete(_ item: CalendarItem, completion: @escaping CalendarEditorCompletion) {
        Task { @MainActor in
            completion(await coordinator.delete(item))
        }
    }

    private func retrySave(completion: @escaping CalendarEditorCompletion) {
        Task { @MainActor in
            completion(await coordinator.retryLastSave())
        }
    }
}

#if os(iOS)
private struct CalendarNextEventPill: View {
    let item: CalendarItem
    let calendar: Calendar
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lifeOSCalendarRed)
                Text("Next: \(item.title) · \(timeLabel)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next event, \(item.title), \(timeLabel)")
        .accessibilityIdentifier("calendar-next-event-pill")
    }

    private var timeLabel: String {
        var zoned = calendar
        zoned.timeZone = itemTimeZone
        return String(
            format: "%02d:%02d",
            zoned.component(.hour, from: item.start),
            zoned.component(.minute, from: item.start)
        )
    }

    private var itemTimeZone: TimeZone {
        item.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
    }
}

private struct CalendarQuickCreateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LifeOSIcon(.add)
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.lifeOSCalendarRed, in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New event")
        .accessibilityIdentifier("calendar-fab-create")
    }
}

private struct CalendarEditorTimeZoneChip: View {
    @Binding var identifier: String?
    private let deviceIdentifier = TimeZone.current.identifier
    private static let commonZoneIdentifiers = ["UTC", "Europe/Berlin"]

    var body: some View {
        Menu {
            Button {
                identifier = nil
            } label: {
                choiceLabel(deviceIdentifier, isSelected: identifier == nil)
            }
            ForEach(Self.commonZoneIdentifiers, id: \.self) { candidate in
                Button {
                    identifier = TimeZone(identifier: candidate)?.identifier ?? candidate
                } label: {
                    choiceLabel(candidate, isSelected: identifier == candidate)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(shortName(effectiveIdentifier))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .accessibilityLabel("Timezone")
        .accessibilityValue(effectiveIdentifier)
        .accessibilityIdentifier("calendar-event-timezone")
    }

    private var effectiveIdentifier: String {
        identifier ?? deviceIdentifier
    }

    private func choiceLabel(_ zoneIdentifier: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(zoneIdentifier)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func shortName(_ zoneIdentifier: String) -> String {
        zoneIdentifier.split(separator: "/").last.map(String.init) ?? zoneIdentifier
    }
}
#endif

/// Pure date translation used by the editor when its day property changes.
/// Translating the existing interval, rather than rebuilding the end from its
/// wall-clock components, preserves both duration and overnight placement.
struct CalendarEditorDateBounds: Equatable {
    let start: Date
    let end: Date
}

enum CalendarEditorDateAdjustmentError: Error, Equatable {
    case invalidInterval
    case unavailableLocalTime
}

struct CalendarEditorDateAdjustment {
    static func translatedBounds(
        start: Date,
        end: Date,
        to date: Date,
        calendar: Calendar
    ) -> Result<CalendarEditorDateBounds, CalendarEditorDateAdjustmentError> {
        let duration = end.timeIntervalSince(start)
        guard duration.isFinite, duration > 0 else { return .failure(.invalidInterval) }

        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: start)
        let day = calendar.startOfDay(for: date)
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        var target = DateComponents()
        target.calendar = calendar
        target.timeZone = calendar.timeZone
        target.year = dayComponents.year
        target.month = dayComponents.month
        target.day = dayComponents.day
        target.hour = components.hour
        target.minute = components.minute
        target.second = components.second
        target.nanosecond = components.nanosecond

        guard let firstOccurrence = calendar.date(from: target) else {
            return .failure(.unavailableLocalTime)
        }
        func wallSignature(_ value: Date) -> [Int] {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: value)
            return [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second, parts.nanosecond]
                .map { $0 ?? 0 }
        }
        let requestedWall = [target.year, target.month, target.day, target.hour, target.minute, target.second, target.nanosecond]
            .map { $0 ?? 0 }
        guard wallSignature(firstOccurrence) == requestedWall else {
            // Calendar normalizes a spring-forward gap such as 02:30 to 03:30.
            // Changing the event's visible time silently is never acceptable.
            return .failure(.unavailableLocalTime)
        }

        var translatedStart = firstOccurrence
        if let sourceEarlier = calendar.date(byAdding: .hour, value: -1, to: start),
           wallSignature(sourceEarlier) == wallSignature(start),
           let targetLater = calendar.date(byAdding: .hour, value: 1, to: firstOccurrence),
           wallSignature(targetLater) == wallSignature(firstOccurrence) {
            // The source is the later occurrence of a repeated fall-back hour;
            // preserve that fold choice when the target has the same ambiguity.
            translatedStart = targetLater
        }

        let translatedEnd = translatedStart.addingTimeInterval(duration)
        guard translatedEnd > translatedStart,
              translatedEnd.timeIntervalSince(translatedStart) == duration else {
            return .failure(.invalidInterval)
        }
        return .success(CalendarEditorDateBounds(start: translatedStart, end: translatedEnd))
    }
}

/// The sheet owns dismissal. The coordinator completion is the only authority
/// that can close it; failures stay in the editor with a retryable message.
struct CalendarEditorMutationResolution: Equatable {
    let shouldDismiss: Bool
    let retryAvailable: Bool
    let message: String?

    init(result: CalendarLocalSaveResult) {
        switch result {
        case .success:
            shouldDismiss = true
            retryAvailable = false
            message = nil
        case .failure(let message):
            shouldDismiss = false
            retryAvailable = true
            self.message = message.isEmpty
                ? "Unable to save the calendar locally. Keep editing and retry."
                : message
        }
    }
}

struct CalendarEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title: String
    @State private var kind: CalendarItemKind
    @State private var icon: String?
    @State private var status: CalendarProgress
    @State private var start: Date
    @State private var end: Date
    @State private var eventDate: Date
    @State private var allDay: Bool
    @State private var showTimezone: Bool
    @State private var timeZoneIdentifier: String?
    @State private var repeatFrequency: CalendarRecurrenceFrequency?
    @State private var repeatInterval: Int
    @State private var repeatUntilEnabled: Bool
    @State private var repeatUntil: Date
    @State private var validationMessage: String?
    @State private var retryAvailable = false
    @State private var showingIconPicker = false
    @State private var iconAsset: CalendarIconAsset?
    @State private var systemIconName: String?
    @FocusState private var titleFocused: Bool
    @State private var isSaveHovered = false
    @State private var isMoreHovered = false
    @State private var isCloseHovered = false
    @State private var isIconHovered = false
    @State private var isScheduleHovered = false
    @State private var isStatusHovered = false
    let existing: CalendarItem?
    let calendar: Calendar
    let onSave: CalendarEditorMutationHandler
    let onDelete: CalendarEditorMutationHandler
    let onRetry: CalendarEditorRetryHandler
    let onCancel: (() -> Void)?

    init(
        item: CalendarItem?,
        date: Date = .now,
        endDate: Date? = nil,
        calendar: Calendar = .current,
        onSave: @escaping CalendarEditorMutationHandler,
        onDelete: @escaping CalendarEditorMutationHandler,
        onRetry: @escaping CalendarEditorRetryHandler = { completion in completion(.failure("Retry is unavailable for this editor.")) },
        onCancel: (() -> Void)? = nil
    ) {
        existing = item
        self.calendar = calendar
        self.onSave = onSave
        self.onDelete = onDelete
        self.onRetry = onRetry
        self.onCancel = onCancel
        _title = State(initialValue: item?.title ?? "")
        _kind = State(initialValue: item?.kind ?? .event)
        _icon = State(initialValue: item?.icon)
        _iconAsset = State(initialValue: item?.iconAsset)
        _systemIconName = State(initialValue: item?.systemIconName)
        _status = State(initialValue: item?.status ?? .planned)
        let roundedStart = item?.start ?? date
        _start = State(initialValue: roundedStart)
        _end = State(initialValue: item?.end ?? endDate ?? roundedStart.addingTimeInterval(3600))
        _eventDate = State(initialValue: calendar.startOfDay(for: roundedStart))
        _allDay = State(initialValue: Self.inferredAllDay(
            item: item,
            start: roundedStart,
            endDate: endDate,
            calendar: calendar
        ))
        _showTimezone = State(initialValue: false)
        _timeZoneIdentifier = State(initialValue: item?.timeZoneIdentifier)
        _repeatFrequency = State(initialValue: item?.recurrence?.frequency)
        _repeatInterval = State(initialValue: item?.recurrence?.interval ?? 1)
        _repeatUntilEnabled = State(initialValue: item?.recurrence?.until != nil)
        _repeatUntil = State(
            initialValue: item?.recurrence?.until
                ?? (calendar.date(byAdding: .day, value: 30, to: roundedStart) ?? roundedStart)
        )
    }

    static func inferredAllDay(
        item: CalendarItem?,
        start: Date,
        endDate: Date?,
        calendar: Calendar
    ) -> Bool {
        let startDay = calendar.startOfDay(for: start)
        guard start == startDay,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay) else {
            return false
        }
        if let item {
            return item.start == startDay && item.end == nextDay
        }
        return endDate == nextDay
    }

    var body: some View {
        Group {
#if os(macOS)
            macEditor
#else
            mobileEditor
#endif
        }
        .accessibilityIdentifier("calendar-event-editor")
        .alert("Unable to update event", isPresented: Binding(get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })) {
            if retryAvailable {
                Button("Retry") { retryLastMutation() }
            }
            Button("Keep editing", role: .cancel) { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "Please check the event details.")
        }
        .sheet(isPresented: $showingIconPicker) {
            CalendarIconPicker(icon: $icon, systemIconName: $systemIconName, iconAsset: $iconAsset)
#if os(iOS)
                .presentationBackground(LifeOSTokens.canvas)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
#else
                .frame(width: 680, height: 700)
#endif
        }
        .onChange(of: eventDate) { _, date in
            if allDay {
                setAllDayBounds(for: date)
            } else {
                let previousDate = calendar.startOfDay(for: start)
                let result = CalendarEditorDateAdjustment.translatedBounds(
                    start: start,
                    end: end,
                    to: date,
                    calendar: calendar
                )
                switch result {
                case .success(let translated):
                    start = translated.start
                    end = translated.end
                case .failure:
                    retryAvailable = false
                    validationMessage = "That local time does not exist on the selected date. The previous date was kept."
                    if !calendar.isDate(eventDate, inSameDayAs: previousDate) {
                        eventDate = previousDate
                    }
                }
            }
        }
        .onChange(of: allDay) { _, enabled in
            if enabled {
                setAllDayBounds(for: eventDate)
            } else if calendar.startOfDay(for: start) == start,
                      let nextDay = calendar.date(byAdding: .day, value: 1, to: start), end == nextDay {
                start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: eventDate) ?? start
                end = start.addingTimeInterval(3600)
            }
        }
    }

#if os(macOS)
    private var macEditor: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            editorContent
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 520, height: 520)
        .background(
            LinearGradient(
                colors: [LifeOSTokens.surface, LifeOSTokens.canvas.opacity(0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LifeOSTokens.quietBorder, lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            if existing == nil { titleFocused = true }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Text("Event")
                .font(LifeOSFont.spaceGrotesk(16, weight: .bold))
            Spacer(minLength: 0)
            Button(action: commit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start ? Color.secondary : LifeOSTokens.Hue.green.base)
                    .frame(width: 28, height: 28)
                    .background(
                        isSaveHovered ? Color.primary.opacity(0.11) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .scaleEffect(reduceMotion ? 1 : (isSaveHovered ? 1.03 : 1))
            }
            .buttonStyle(.plain)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
            .help("Save event")
            .accessibilityLabel("Save event")
            .accessibilityIdentifier("calendar-event-save")
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) { isSaveHovered = hovering }
            }

            Menu {
                if let existing {
                    Button("Delete event", role: .destructive) { requestDelete(existing) }
                        .accessibilityIdentifier("calendar-event-delete")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(
                        isMoreHovered ? Color.primary.opacity(0.11) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .scaleEffect(reduceMotion ? 1 : (isMoreHovered ? 1.03 : 1))
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .help("More event actions")
            .accessibilityLabel("More event actions")
            .accessibilityIdentifier("calendar-event-more")
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) { isMoreHovered = hovering }
            }

            Button {
                onCancel?()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(
                        isCloseHovered ? Color.primary.opacity(0.11) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .scaleEffect(reduceMotion ? 1 : (isCloseHovered ? 1.03 : 1))
            }
            .buttonStyle(.plain)
            .help("Close event editor")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("calendar-event-cancel")
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) { isCloseHovered = hovering }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
#else
    private var mobileEditor: some View {
        NavigationStack {
            ScrollView {
                editorContent
                    .padding(20)
            }
            .background(LifeOSTokens.canvas)
            .navigationTitle(existing == nil ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("calendar-event-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
                        .accessibilityIdentifier("calendar-event-save")
                }
            }
        }
    }
#endif

    @ViewBuilder
    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorIdentity
            Divider().padding(.vertical, 12)
            editorKindRow
            Divider().padding(.vertical, 12)
            editorSchedule
            Divider().padding(.vertical, 12)
            editorRecurrenceRow
            Divider().padding(.vertical, 12)
            editorStatusRow
#if os(iOS)
            if let existing {
                Button("Delete event", role: .destructive) { requestDelete(existing) }
                    .padding(.top, 18)
                    .accessibilityIdentifier("calendar-event-delete")
            }
#endif
        }
    }

    private var editorIdentity: some View {
        HStack(spacing: 11) {
            Button { showingIconPicker = true } label: {
                CalendarEditorIcon(icon: icon, systemIconName: systemIconName, asset: iconAsset)
                    .frame(width: hasIcon ? 38 : 88, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasIcon ? "Change event icon" : "Add event icon")
            .accessibilityHint("Choose an emoji or reusable custom icon")
            .accessibilityValue(hasIcon ? "Selected" : "No icon")
            .accessibilityIdentifier("calendar-event-icon-button")
#if os(macOS)
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) { isIconHovered = hovering }
            }
            .scaleEffect(reduceMotion ? 1 : (isIconHovered ? 1.025 : 1))
#endif

            TextField("Event title", text: $title)
                .font(.system(size: 21, weight: .semibold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .accessibilityLabel("Calendar event title")
                .accessibilityIdentifier("calendar-event-title")
        }
    }

    private var hasIcon: Bool {
        icon != nil || systemIconName != nil || iconAsset != nil
    }

    private var editorKindRow: some View {
        HStack(spacing: 10) {
            Image(systemName: kind == .todo ? "checkmark.square" : (kind == .dailySchedule ? "calendar.badge.clock" : "calendar"))
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
            Text("Type")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            Menu {
                ForEach(CalendarItemKind.allCases, id: \.self) { candidate in
                    Button {
                        kind = candidate
                        if candidate == .todo, status == .inProgress || status == .aborted {
                            status = .planned
                        }
                    } label: {
                        Label(candidate.label, systemImage: candidate == .todo ? "checkmark.square" : (candidate == .dailySchedule ? "calendar.badge.clock" : "calendar"))
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(kind.label)
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calendar item type, \(kind.label)")
            .accessibilityIdentifier("calendar-item-kind-picker")
        }
    }

    private var editorSchedule: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LifeOSIcon(allDay ? .calendar : .inProgress)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                if allDay {
                    Text("All day")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Text(durationLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("calendar-event-all-day-summary")
                } else {
                    Text("Time")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
#if os(macOS)
                    CalendarEditorTimePill(
                        label: "Start",
                        date: start,
                        calendar: calendar,
                        accessibilityIdentifier: "calendar-event-start"
                    ) {
                        CalendarEditorTimePopover(
                            title: "Start time",
                            date: $start,
                            calendar: calendar,
                            minimumDate: nil
                        )
                    }
                    LifeOSIcon(.chevronRight)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)
                    CalendarEditorTimePill(
                        label: "End",
                        date: end,
                        calendar: calendar,
                        accessibilityIdentifier: "calendar-event-end"
                    ) {
                        CalendarEditorTimePopover(
                            title: "End time",
                            date: $end,
                            calendar: calendar,
                            minimumDate: start,
                            quickDurations: [15, 30, 60, 120],
                            quickDurationBase: start
                        )
                    }
#else
                    DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("calendar-event-start")
                    LifeOSIcon(.chevronRight)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)
                    DatePicker("End", selection: $end, in: start..., displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("calendar-event-end")
#endif
                    Text(durationLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                LifeOSIcon(.calendar)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text("Date")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
#if os(macOS)
                CalendarEditorDatePill(date: $eventDate, calendar: calendar)
#else
                DatePicker("Date", selection: $eventDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("calendar-event-date")
#endif
            }

            HStack(spacing: 10) {
                Spacer().frame(width: 26)
#if os(macOS)
                CalendarEditorInlineToggle(title: "All day", isOn: $allDay, identifier: "calendar-event-all-day")
                CalendarEditorInlineToggle(title: "Timezone", isOn: $showTimezone, identifier: "calendar-event-timezone")
                if showTimezone {
                    Text(TimeZone.current.identifier)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
#else
                Toggle("All day", isOn: $allDay)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .accessibilityIdentifier("calendar-event-all-day")
                CalendarEditorTimeZoneChip(identifier: $timeZoneIdentifier)
#endif
                Spacer(minLength: 0)
            }
        }
#if os(macOS)
        .background(
            isScheduleHovered ? Color.primary.opacity(0.025) : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : LifeOSMotion.ease) { isScheduleHovered = hovering }
        }
#endif
    }

    /// Series-level recurrence editing. Every occurrence of a repeating item
    /// shares this schedule; there are deliberately no per-instance overrides
    /// yet, so the caption states that honestly.
    private var editorRecurrenceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "repeat")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                Text("Repeat")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Menu {
                    Button("None") { repeatFrequency = nil }
                    ForEach(CalendarRecurrenceFrequency.allCases, id: \.self) { candidate in
                        Button(candidate.label) {
                            repeatFrequency = candidate
                            if repeatInterval < 1 { repeatInterval = 1 }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(repeatFrequency?.label ?? "None")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repeats, \(repeatFrequency?.label ?? "none")")
                .accessibilityIdentifier("calendar-item-recurrence-picker")
            }

            if repeatFrequency != nil {
                Stepper(value: $repeatInterval, in: 1...30) {
                    Text(repeatSummary)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityIdentifier("calendar-item-recurrence-interval")
                }
                .accessibilityLabel("Repeat interval")

                Toggle(isOn: $repeatUntilEnabled) {
                    Text("Until")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityIdentifier("calendar-item-recurrence-until-toggle")

                if repeatUntilEnabled {
                    DatePicker(
                        "Last occurrence",
                        selection: $repeatUntil,
                        displayedComponents: [.date]
                    )
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("calendar-item-recurrence-until-date")
                }

                if existing != nil {
                    Text("Changes apply to every occurrence.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-event-recurrence")
    }

    private var repeatSummary: String {
        guard let frequency = repeatFrequency,
              let rule = try? CalendarRecurrenceRule(frequency: frequency, interval: max(1, repeatInterval)) else {
            return ""
        }
        return rule.summary
    }

    private var editorStatusRow: some View {
        HStack(spacing: 10) {
            LifeOSIcon(status.iconName)
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
            Text("Status")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            if kind == .todo {
                Button {
                    status = status == .done ? .planned : .done
                } label: {
                    Label(status == .done ? "Done" : "Mark done", systemImage: status == .done ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(status == .done ? "To-do done" : "Mark to-do done")
                .accessibilityValue(status.label)
                .accessibilityIdentifier("calendar-todo-done-toggle")
            } else {
                CalendarEditorStatusPicker(progress: $status)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-event-status")
#if os(macOS)
        .background(
            isStatusHovered ? Color.primary.opacity(0.025) : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : LifeOSMotion.ease) { isStatusHovered = hovering }
        }
#endif
    }

    private var durationLabel: String {
        let seconds = max(0, end.timeIntervalSince(start))
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remaining = minutes % 60
            return remaining == 0 ? "\(hours) hr" : "\(hours) hr \(remaining) min"
        }
        return "\(minutes) min"
    }

    private func setAllDayBounds(for date: Date) {
        start = calendar.startOfDay(for: date)
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }

    private func commit() {
        do {
            let rule: CalendarRecurrenceRule?
            if let frequency = repeatFrequency {
                rule = try CalendarRecurrenceRule(
                    frequency: frequency,
                    interval: max(1, repeatInterval),
                    until: repeatUntilEnabled ? repeatUntil : nil
                )
            } else {
                rule = nil
            }
            let item = try CalendarItem(
                id: existing?.id ?? UUID(),
                title: title,
                kind: kind,
                icon: icon,
                iconAsset: iconAsset,
                systemIconName: systemIconName,
                status: status,
                start: start,
                end: end,
                createdAt: existing?.createdAt ?? .now,
                updatedAt: .now,
                deletedAt: existing?.deletedAt,
                timeZoneIdentifier: timeZoneIdentifier,
                recurrence: rule
            )
            onSave(item, handleMutationResult)
        } catch {
            retryAvailable = false
            validationMessage = "Please provide a title and an end time after the start time."
        }
    }

    private func requestDelete(_ item: CalendarItem) {
        onDelete(item, handleMutationResult)
    }

    private func retryLastMutation() {
        onRetry(handleMutationResult)
    }

    private func handleMutationResult(_ result: CalendarLocalSaveResult) {
        let resolution = CalendarEditorMutationResolution(result: result)
        retryAvailable = resolution.retryAvailable
        validationMessage = resolution.message
        if resolution.shouldDismiss {
            dismiss()
        }
    }

    private func platformImage(from data: Data) -> Image? {
#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
#else
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
#endif
    }
}

#if os(macOS)
private struct CalendarEditorTimePill<PopoverContent: View>: View {
    let label: String
    let date: Date
    let calendar: Calendar
    let accessibilityIdentifier: String
    let popoverContent: () -> PopoverContent
    @State private var isPresented = false

    init(
        label: String,
        date: Date,
        calendar: Calendar,
        accessibilityIdentifier: String,
        @ViewBuilder popoverContent: @escaping () -> PopoverContent
    ) {
        self.label = label
        self.date = date
        self.calendar = calendar
        self.accessibilityIdentifier = accessibilityIdentifier
        self.popoverContent = popoverContent
    }

    var body: some View {
        Button { isPresented = true } label: {
            Text(timeLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .overlay { Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.7) }
        }
        .buttonStyle(.plain)
        .help("Choose \(label.lowercased()) time")
        .accessibilityLabel(label)
        .accessibilityValue(timeLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent()
                .padding(12)
                .background(LifeOSTokens.surface)
        }
    }

    private var timeLabel: String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}

private struct CalendarEditorInlineToggle: View {
    let title: String
    @Binding var isOn: Bool
    let identifier: String

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? LifeOSTokens.Hue.green.base : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isOn ? Color.primary.opacity(0.09) : Color.primary.opacity(0.035), in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(isOn ? 0.12 : 0.06), lineWidth: 0.6) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier(identifier)
    }
}

private struct CalendarEditorDatePill: View {
    @Binding private var date: Date
    let calendar: Calendar
    @State private var isPresented = false

    init(date: Binding<Date>, calendar: Calendar) {
        _date = date
        self.calendar = calendar
    }

    var body: some View {
        Button { isPresented = true } label: {
            Text(dateLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .overlay { Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.7) }
        }
        .buttonStyle(.plain)
        .help("Choose event date")
        .accessibilityLabel("Date")
        .accessibilityValue(dateLabel)
        .accessibilityIdentifier("calendar-event-date")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Color.lifeOSCalendarRed)
                .padding(8)
                .frame(width: 286)
                .background(LifeOSTokens.surface)
        }
    }

    private var dateLabel: String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct CalendarEditorTimePopover: View {
    let title: String
    @Binding var date: Date
    let calendar: Calendar
    let minimumDate: Date?
    let quickDurations: [Int]
    let quickDurationBase: Date?
    @State private var typedValue: String

    init(
        title: String,
        date: Binding<Date>,
        calendar: Calendar,
        minimumDate: Date?,
        quickDurations: [Int] = [],
        quickDurationBase: Date? = nil
    ) {
        self.title = title
        _date = date
        self.calendar = calendar
        self.minimumDate = minimumDate
        self.quickDurations = quickDurations
        self.quickDurationBase = quickDurationBase
        _typedValue = State(initialValue: Self.label(for: date.wrappedValue, calendar: calendar))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                TextField("HH:mm", text: $typedValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .onSubmit(commitTypedValue)
                    .accessibilityIdentifier("calendar-event-time-input")
            }

            if !quickDurations.isEmpty, let quickDurationBase {
                HStack(spacing: 6) {
                    ForEach(quickDurations, id: \.self) { minutes in
                        Button(durationLabel(minutes)) {
                            if let target = calendar.date(byAdding: .minute, value: minutes, to: quickDurationBase) {
                                date = target
                                typedValue = Self.label(for: target, calendar: calendar)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("calendar-event-duration-\(minutes)")
                    }
                }
            }

            Divider()

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(0..<96, id: \.self) { minute in
                            let candidate = candidate(for: minute)
                            if isAllowed(candidate) {
                                Button {
                                    date = candidate
                                    typedValue = Self.label(for: candidate, calendar: calendar)
                                } label: {
                                    HStack {
                                        Text(Self.label(for: candidate, calendar: calendar))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        Spacer(minLength: 0)
                                        if calendar.dateComponents([.hour, .minute], from: candidate) == calendar.dateComponents([.hour, .minute], from: date) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8)
                                    .frame(height: 27)
                                    .background(isSameMinute(candidate, date) ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .id(minute)
                            }
                        }
                    }
                }
                .frame(width: 194, height: 224)
                .onAppear {
                    scrollProxy.scrollTo(calendar.component(.hour, from: date) * 4 + calendar.component(.minute, from: date) / 15, anchor: .center)
                }
            }
        }
        .frame(width: 220)
        .onChange(of: date) { _, newValue in
            typedValue = Self.label(for: newValue, calendar: calendar)
        }
    }

    private func candidate(for minute: Int) -> Date {
        let sameDay = calendar.date(bySettingHour: minute / 4, minute: (minute % 4) * 15, second: 0, of: date) ?? date
        guard let minimumDate, sameDay <= minimumDate else { return sameDay }
        return calendar.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay
    }

    private func isAllowed(_ candidate: Date) -> Bool {
        guard let minimumDate else { return true }
        return candidate > minimumDate
    }

    private func isSameMinute(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: lhs) ==
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: rhs)
    }

    private func commitTypedValue() {
        let values = typedValue.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2, (0..<24).contains(values[0]), (0..<60).contains(values[1]) else {
            typedValue = Self.label(for: date, calendar: calendar)
            return
        }
        var candidate = calendar.date(bySettingHour: values[0], minute: values[1], second: 0, of: date)
        if let minimumDate, let sameDay = candidate, sameDay <= minimumDate {
            candidate = calendar.date(byAdding: .day, value: 1, to: sameDay)
        }
        guard let candidate, isAllowed(candidate) else {
            typedValue = Self.label(for: date, calendar: calendar)
            return
        }
        date = candidate
    }

    private func durationLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    private static func label(for date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}
#endif

private struct CalendarEditorIcon: View {
    let icon: String?
    let systemIconName: String?
    let asset: CalendarIconAsset?

    var body: some View {
        Group {
            if let asset, let image = platformImage(from: asset.bytes) {
                image.resizable().scaledToFit()
            } else if let systemIconName, CalendarSystemIconSupport.isAvailable(systemIconName) {
                Image(systemName: systemIconName)
                    .font(.system(size: 21, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            } else if let icon {
                Text(icon).font(.title2)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add icon")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            hasIcon ? LifeOSTokens.Hue.green.base.opacity(0.12) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if !hasIcon {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var hasIcon: Bool {
        icon != nil || systemIconName != nil || asset != nil
    }

    private func platformImage(from data: Data) -> Image? {
#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
#else
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
#endif
    }
}

enum CalendarIconPickerTab: Hashable { case emojis }

struct CalendarEmojiEntry: Identifiable, Hashable {
    let emoji: String
    let keywords: String
    var id: String { emoji }
}

/// The system emoji keyboard is not exposed as a public, searchable catalog on
/// either Apple platform. Keep a broad, local catalog here instead of shipping
/// a dependency or scraping a remote source. It follows Apple's eight primary
/// families and stores search words alongside every glyph.
enum CalendarEmojiCatalog {
    static let groups: [(String, [CalendarEmojiEntry])] = [
        ("People", entries("""
        😀|smile happy face people
        😃|smile happy face people
        😄|smile happy face people
        😁|grin happy face people
        😆|laugh funny face people
        😅|sweat nervous laugh people
        😂|joy laugh tears people
        🙂|smile calm face people
        🙃|upside down silly face people
        😉|wink face people
        😊|blush smile face people
        😇|angel halo good people
        🥰|love hearts face people
        😍|love heart eyes people
        🤩|star struck excited people
        😘|kiss love people
        😋|yummy food face people
        😛|tongue silly people
        😜|wink tongue silly people
        🤪|crazy silly people
        🤨|skeptic doubt people
        🧐|inspect review people
        🤓|nerd study people
        😎|cool sunglasses people
        🥳|party celebration people
        😏|smirk people
        😒|unimpressed people
        😞|disappointed sad people
        😔|sad thoughtful people
        😟|worried people
        😕|confused people
        🙁|sad people
        ☹️|sad people
        😣|struggle people
        😫|tired people
        🥺|pleading people
        😢|cry sad people
        😭|cry tears people
        😤|angry steam people
        😠|angry people
        😡|rage angry people
        🤬|swear angry people
        🤯|mind blown surprise people
        😳|embarrassed people
        🥵|hot people
        🥶|cold people
        😱|scream fear people
        😨|fear people
        😰|anxious sweat people
        🤗|hug people
        🤔|think people
        🫡|salute respect people
        🤭|giggle people
        🤫|quiet secret people
        🤥|lie people
        😶|quiet speechless people
        🫠|melting people
        🫨|shaking face shock surprise startled dizzy zittern schütteln erschrocken people
        😐|neutral people
        😑|expressionless people
        😬|grimace people
        🙄|eye roll people
        😯|surprise people
        😮|open mouth surprise people
        😲|astonished people
        🥱|yawn tired people
        😴|sleep people
        🤤|drool people
        😪|sleepy people
        😵|dizzy people
        🤐|zipper quiet people
        🥴|woozy people
        🤢|sick people
        🤮|vomit sick people
        🤧|sneeze sick people
        😷|mask sick people
        🤒|ill fever people
        🤕|injured people
        🤑|money rich people
        🤠|cowboy people
        😈|devil mischievous people
        👿|angry devil people
        🤡|clown people
        💩|poop funny people
        👻|ghost spooky people
        💀|dead skull people
        ☠️|danger skull people
        👽|alien people
        👾|game monster people
        🤖|robot technology people
        🎃|halloween pumpkin people
        👋|wave hello people
        🤝|handshake meeting people
        👏|clap applause people
        🙌|celebrate hands people
        🫶|heart hands love people
        👌|okay hand people
        🤏|small hand people
        ✌️|peace victory people
        🤞|luck fingers people
        🤟|love you hand people
        🤘|rock hand music people
        🤙|call hand people
        👍|like approve people
        👎|dislike reject people
        ✊|fist strength people
        👊|punch fist people
        🤲|palms prayer people
        🙏|pray thanks people
        💪|strong muscle health people
        👀|eyes look review people
        👁️|eye look people
        🧠|brain mind study people
        🫀|heart organ health people
        🫁|lungs health people
        🦷|tooth health people
        🦴|bone health people
        👶|baby child people
        🧒|child kid people
        👦|boy child people
        👧|girl child people
        🧑|person people
        👨|man people
        👩|woman people
        🧓|older person people
        👴|grandfather people
        👵|grandmother people
        🧔|beard person people
        👮|police job people
        👷|construction worker job people
        💂|guard job people
        🕵️|detective job people
        👩‍⚕️|doctor health job people
        👨‍🏫|teacher school job people
        👩‍💻|developer coding work job people
        👨‍🍳|chef food job people
        🧘|meditation yoga wellness people
        🏃|run running people
        🚶|walk walking people
        💃|dance dancing people
        🕺|dance party people
        🧗|climb sport people
        🏋️|lift workout fitness people
        🚴|bike cycling sport people
        🏊|swim sport people
        🧑‍🤝‍🧑|friends team people
        🧑‍🍼|caregiver baby people
        """)),
        ("Animals & nature", entries("""
        🐶|dog pet animal
        🐱|cat pet animal
        🐭|mouse animal
        🐹|hamster pet animal
        🐰|rabbit animal
        🦊|fox animal
        🐻|bear animal
        🐼|panda animal
        🐨|koala animal
        🐯|tiger animal
        🦁|lion animal
        🐮|cow animal
        🐷|pig animal
        🐸|frog animal
        🐵|monkey animal
        🙈|see no evil monkey animal
        🙉|hear no evil monkey animal
        🙊|speak no evil monkey animal
        🐔|chicken bird animal
        🐧|penguin bird animal
        🐦|bird animal
        🐤|chick bird animal
        🦆|duck bird animal
        🦅|eagle bird animal
        🦉|owl bird animal
        🦇|bat animal
        🐺|wolf animal
        🐗|boar animal
        🐴|horse animal
        🦄|unicorn fantasy animal
        🐝|bee insect animal
        🪲|beetle insect animal
        🐛|bug insect animal
        🦋|butterfly insect animal
        🐌|snail animal
        🐞|ladybug insect animal
        🐜|ant insect animal
        🕷️|spider insect animal
        🦂|scorpion insect animal
        🐢|turtle animal
        🐍|snake animal
        🦎|lizard animal
        🦖|dinosaur animal
        🐙|octopus sea animal
        🦑|squid sea animal
        🦀|crab sea animal
        🦞|lobster sea food animal
        🐠|fish sea animal
        🐟|fish sea animal
        🐡|blowfish sea animal
        🐬|dolphin sea animal
        🐳|whale sea animal
        🦈|shark sea animal
        🦭|seal sea animal
        🐊|crocodile animal
        🐅|tiger animal
        🐆|leopard animal
        🦓|zebra animal
        🦒|giraffe animal
        🐘|elephant animal
        🦏|rhino animal
        🦛|hippo animal
        🐪|camel travel animal
        🐫|camel animal
        🦘|kangaroo animal
        🦬|bison animal
        🐄|cow animal
        🐕|dog pet animal
        🐈|cat pet animal
        🐓|rooster bird animal
        🦜|parrot bird animal
        🦢|swan bird animal
        🦩|flamingo bird animal
        🕊️|dove peace bird animal
        🐇|rabbit animal
        🌸|flower spring nature
        🌹|rose flower love nature
        🌻|sunflower flower nature
        🌼|blossom flower nature
        🌷|tulip flower nature
        🌱|seedling plant nature growth
        🌲|evergreen tree nature
        🌳|tree forest nature
        🌴|palm tree nature travel
        🌵|cactus plant nature
        🎋|bamboo plant nature
        🍀|luck clover nature
        ☘️|shamrock luck nature
        🍁|maple leaf autumn nature
        🍂|fallen leaf autumn nature
        🍃|leaf wind nature
        🌿|herb plant nature
        🌾|grain harvest nature
        🌍|earth world nature
        🌎|earth world nature
        🌙|moon night nature
        ☀️|sun weather nature
        🌤️|sun cloud weather nature
        ☁️|cloud weather nature
        🌧️|rain weather nature
        ⛈️|storm thunder weather
        ❄️|snow winter weather
        ☃️|snowman winter weather
        🌈|rainbow weather nature
        💧|water drop nature hydration
        🔥|fire flame nature urgent
        💨|wind air weather
        🪿|goose bird animal
        """)),
        ("Food & drink", entries("""
        🍏|apple fruit food
        🍎|apple fruit food
        🍐|pear fruit food
        🍊|orange citrus fruit food
        🍋|lemon citrus fruit food
        🍌|banana fruit food
        🍉|watermelon fruit food
        🍇|grapes fruit food
        🍓|strawberry fruit food
        🫐|blueberry fruit food
        🍈|melon fruit food
        🍒|cherry fruit food
        🍑|peach fruit food
        🥭|mango fruit food
        🍍|pineapple fruit food
        🥥|coconut fruit food
        🥝|kiwi fruit food
        🍅|tomato vegetable food
        🥑|avocado healthy food
        🍆|eggplant vegetable food
        🥔|potato vegetable food
        🥕|carrot vegetable food
        🌽|corn vegetable food
        🌶️|pepper spicy food
        🫑|pepper vegetable food
        🥒|cucumber vegetable food
        🥬|leafy greens salad food
        🥦|broccoli vegetable healthy food
        🧄|garlic food cooking
        🧅|onion food cooking
        🍄|mushroom food nature
        🥜|peanut nuts food
        🌰|chestnut nuts food
        🍞|bread bakery food
        🥐|croissant bakery food
        🥖|baguette bread food
        🥨|pretzel snack food
        🧀|cheese food
        🥚|egg breakfast food
        🍳|cooking egg breakfast food
        🧈|butter food cooking
        🥞|pancake breakfast food
        🧇|waffle breakfast food
        🥓|bacon breakfast food
        🥩|steak meat food
        🍗|chicken meat food
        🍔|burger fast food
        🍟|fries fast food
        🍕|pizza lunch dinner food
        🌭|hotdog fast food
        🥪|sandwich lunch food
        🌮|taco mexican food
        🌯|burrito mexican food
        🥗|salad healthy food
        🍝|pasta italian food
        🍜|noodles ramen food
        🍲|stew soup food
        🍣|sushi japanese food
        🍤|shrimp seafood food
        🍚|rice food
        🍙|rice ball food
        🍘|rice cracker food
        🍧|shaved ice dessert
        🍨|ice cream dessert
        🍦|ice cream dessert
        🧁|cupcake dessert
        🍰|cake birthday dessert
        🎂|birthday cake dessert
        🍪|cookie dessert snack
        🍩|donut dessert
        🍫|chocolate sweet food
        🍬|candy sweet food
        🍭|lollipop sweet food
        🍯|honey sweet food
        🍼|baby milk drink
        🥛|milk drink
        ☕|coffee cafe drink break
        🫖|tea drink cafe
        🍵|tea drink cafe
        🧃|juice drink
        🥤|soda drink
        🧋|bubble tea drink
        🍺|beer drink
        🍻|cheers beer drink
        🍷|wine drink
        🥂|champagne celebrate drink
        🥃|whiskey drink
        🍸|cocktail drink
        🍹|tropical cocktail drink
        🧊|ice drink cool
        🥢|chopsticks food
        🍴|fork knife food
        🥄|spoon food
        🍽️|plate dinner food
        🫚|ginger food cooking
        """)),
        ("Activity", entries("""
        ⚽|football soccer sport activity
        🏀|basketball sport activity
        🏈|american football sport activity
        ⚾|baseball sport activity
        🥎|softball sport activity
        🎾|tennis sport activity
        🏐|volleyball sport activity
        🏉|rugby sport activity
        🥏|frisbee sport activity
        🪃|boomerang activity
        🥊|boxing sport activity
        🥋|martial arts sport activity
        🏹|archery sport activity
        🎣|fishing activity
        🤿|diving sport activity
        🏄|surfing sport activity
        🏂|snowboard winter sport
        ⛷️|ski winter sport
        🏋️|weight lifting gym fitness
        🤼|wrestling sport activity
        🤸|gymnastics sport activity
        ⛹️|basketball sport activity
        🤺|fencing sport activity
        🏇|horse racing sport
        🚴|cycling bike sport
        🏊|swimming sport
        🧘|yoga meditation wellness
        🧗|climbing sport activity
        🏃|running sport fitness
        🚶|walking activity
        💃|dance activity
        🕺|dance party activity
        🎽|running shirt sport
        🏆|trophy win award activity
        🥇|gold medal winner activity
        🥈|silver medal activity
        🥉|bronze medal activity
        🎖️|medal honor activity
        🏅|medal award activity
        🎗️|ribbon cause activity
        🎪|circus activity
        🎭|theater drama activity
        🎨|art paint creative activity
        🎬|film movie activity
        🎤|microphone singing music activity
        🎧|headphones music activity
        🎼|music score activity
        🎹|piano music activity
        🥁|drums music activity
        🎸|guitar music activity
        🎮|video game activity
        🕹️|arcade game activity
        🎲|dice game activity
        ♟️|chess game activity
        🧩|puzzle game activity
        🎯|target goal focus activity
        🎳|bowling sport activity
        🎱|billiards game activity
        🪁|kite activity
        🧸|toy play activity
        🛝|playground activity
        🪇|maracas music activity
        """)),
        ("Travel & places", entries("""
        🚗|car drive travel transport
        🚕|taxi travel transport
        🚌|bus commute travel transport
        🚎|trolley bus travel transport
        🏎️|race car travel transport
        🚓|police car travel
        🚑|ambulance emergency travel
        🚒|fire truck emergency travel
        🚚|truck delivery travel
        🚲|bicycle bike commute travel
        🛴|scooter travel transport
        🛵|motor scooter travel
        🏍️|motorcycle travel
        🚆|train commute travel
        🚇|metro subway commute travel
        🚊|tram transport travel
        🚉|station travel
        ✈️|airplane flight travel trip
        🛫|departure flight travel
        🛬|arrival flight travel
        🛩️|small plane travel
        🚀|rocket space launch travel
        🛸|ufo space travel
        🚁|helicopter travel
        🚢|ship travel sea
        ⛵|sailboat travel sea
        🚤|speedboat travel sea
        ⚓|anchor sea travel
        🗺️|map travel places
        🧭|compass direction travel
        🗿|moai landmark travel
        🗽|statue landmark travel
        🗼|tower landmark travel
        🏰|castle landmark travel
        🏯|japanese castle travel
        🏟️|stadium sport place
        🏛️|museum classical building place
        🏗️|construction building place
        🏠|house home place
        🏡|garden house home place
        🏢|office work building place
        🏥|hospital health place
        🏦|bank finance place
        🏨|hotel travel place
        🏫|school education place
        🏪|shop store place
        🏬|department store shopping place
        🏭|factory work place
        🏙️|city skyline place
        🌆|city evening place
        🌃|city night place
        🏞️|national park nature travel
        🏖️|beach holiday travel
        🏝️|island vacation travel
        🏜️|desert travel nature
        ⛰️|mountain hiking travel
        🏕️|camping outdoor travel
        🏗️|building construction work place
        ⛺|tent camping travel
        🛎️|hotel bell travel
        🧳|luggage travel
        🎟️|ticket event travel
        🛻|pickup truck travel transport
        """)),
        ("Objects", entries("""
        📅|calendar date schedule object
        🗓️|calendar date schedule object
        ⏰|clock time alarm object
        ⌛|hourglass time object
        ⏱️|timer stopwatch time object
        ⏳|waiting time object
        🔔|bell reminder notification object
        📌|pin project object
        📍|location pin map object
        🏷️|tag label object
        ✏️|pencil write object
        📝|note write object
        📚|books study object
        📖|book read object
        📓|notebook notes object
        📒|ledger notes object
        📕|book read object
        📎|paperclip attach object
        🔗|link connect object
        📁|folder files object
        📂|folder files object
        🗂️|files archive object
        🗃️|archive files object
        🗄️|cabinet files object
        🗑️|trash delete object
        💡|idea light object
        🔦|flashlight light object
        🕯️|candle light object
        🔑|key access object
        🔒|lock security object
        🔓|unlock security object
        🛡️|shield security object
        🧰|tools work object
        🔨|hammer build object
        ⚙️|gear settings object
        🪛|screwdriver tools object
        💻|laptop computer coding work object
        🖥️|desktop computer work object
        ⌨️|keyboard computer object
        🖱️|mouse computer object
        📱|phone mobile object
        ☎️|telephone call object
        📞|phone call object
        📷|camera photo object
        📸|camera photo object
        🎥|video film object
        📺|television media object
        📻|radio media object
        🎧|headphones audio object
        🎵|music note audio object
        🎶|music notes audio object
        🖨️|printer office object
        💾|save disk object
        💿|disc media object
        🧮|calculator math object
        💳|credit card finance object
        💰|money finance object
        💵|cash money finance object
        🧾|receipt finance object
        🛒|shopping cart object
        🎁|gift present object
        🎈|balloon party object
        🎉|party celebration object
        🎊|confetti celebration object
        🧨|firecracker celebration object
        🪩|disco party object
        🎂|birthday cake object
        🧴|bottle care object
        🧼|soap clean object
        🧹|broom clean object
        🧺|basket laundry object
        🛏️|bed sleep home object
        🛋️|sofa home object
        🚿|shower home object
        🛁|bath home object
        🧯|fire extinguisher safety object
        💊|pill medicine health object
        🩹|bandage health object
        🩺|stethoscope doctor health object
        🌡️|thermometer health object
        🧪|test tube science object
        🔬|microscope science object
        🔭|telescope science object
        🪪|identity card document object
        """)),
        ("Symbols", entries("""
        ❤️|heart love favorite symbol
        🧡|orange heart love symbol
        💛|yellow heart love symbol
        💚|green heart love symbol
        💙|blue heart love symbol
        💜|purple heart love symbol
        🖤|black heart love symbol
        🤍|white heart love symbol
        🤎|brown heart love symbol
        💔|broken heart love symbol
        ❣️|heart exclamation love symbol
        💕|two hearts love symbol
        💖|sparkle heart love symbol
        💗|growing heart love symbol
        💓|beating heart love symbol
        💘|heart arrow love symbol
        💝|heart ribbon love symbol
        💟|heart decoration love symbol
        ⭐|star favorite rating symbol
        🌟|glowing star favorite symbol
        ✨|sparkles magic highlight symbol
        💫|dizzy star magic symbol
        🔥|fire hot urgent symbol
        ⚡|bolt energy urgent symbol
        💥|boom impact symbol
        ❄️|snow cold weather symbol
        ☀️|sun weather symbol
        🌙|moon night symbol
        ☑️|checked box done task symbol
        ✅|check done success symbol
        ❌|cross delete no symbol
        ❗|exclamation alert urgent symbol
        ❕|exclamation alert symbol
        ❓|question help symbol
        ❔|question help symbol
        ⁉️|question exclamation alert symbol
        ⚠️|warning danger alert symbol
        🚫|prohibited no symbol
        ⛔|stop danger symbol
        🔴|red circle status symbol
        🟠|orange circle status symbol
        🟡|yellow circle status symbol
        🟢|green circle status symbol
        🔵|blue circle status symbol
        🟣|purple circle status symbol
        ⚫|black circle symbol
        ⚪|white circle symbol
        🟤|brown circle symbol
        🔺|triangle up symbol
        🔻|triangle down symbol
        ➡️|arrow right next symbol
        ⬅️|arrow left back symbol
        ⬆️|arrow up symbol
        ⬇️|arrow down symbol
        ↗️|arrow trend symbol
        ♻️|recycle sustainability symbol
        ⚕️|medical health symbol
        ☮️|peace symbol
        ☯️|balance symbol
        ☢️|radioactive danger symbol
        ☣️|biohazard danger symbol
        🔱|trident symbol
        ⚜️|fleur de lis symbol
        ©️|copyright legal symbol
        ®️|registered legal symbol
        ™️|trademark legal symbol
        🩷|pink heart love symbol
        """)),
        ("Flags", entries("""
        🏁|checkered race flag
        🚩|red flag warning flag
        🎌|crossed flags japan flag
        🏳️|white flag peace flag
        🏳️‍🌈|rainbow pride flag
        🏴|black flag flag
        🏴‍☠️|pirate flag danger flag
        🇦🇹|Austria Österreich flag
        🇧🇪|Belgium Belgien flag
        🇨🇭|Switzerland Schweiz flag
        🇨🇿|Czechia Tschechien flag
        🇩🇪|Germany Deutschland flag
        🇩🇰|Denmark Dänemark flag
        🇪🇸|Spain Spanien flag
        🇫🇮|Finland Finnland flag
        🇫🇷|France Frankreich flag
        🇬🇧|United Kingdom Britain flag
        🇬🇷|Greece Griechenland flag
        🇭🇺|Hungary Ungarn flag
        🇮🇪|Ireland Irland flag
        🇮🇹|Italy Italien flag
        🇱🇺|Luxembourg flag
        🇳🇱|Netherlands Holland Niederlande flag
        🇳🇴|Norway Norwegen flag
        🇵🇱|Poland Polen flag
        🇵🇹|Portugal flag
        🇷🇴|Romania Rumänien flag
        🇷🇺|Russia Russland flag
        🇸🇪|Sweden Schweden flag
        🇸🇮|Slovenia Slowenien flag
        🇸🇰|Slovakia Slowakei flag
        🇺🇦|Ukraine flag
        🇺🇸|United States America USA flag
        🇨🇦|Canada flag
        🇲🇽|Mexico flag
        🇧🇷|Brazil Brasilien flag
        🇦🇷|Argentina flag
        🇨🇱|Chile flag
        🇨🇴|Colombia flag
        🇦🇺|Australia flag
        🇳🇿|New Zealand flag
        🇯🇵|Japan flag
        🇨🇳|China flag
        🇰🇷|South Korea Korea flag
        🇮🇳|India Indien flag
        🇸🇬|Singapore flag
        🇿🇦|South Africa flag
        🇪🇬|Egypt Ägypten flag
        🇮🇱|Israel flag
        🇹🇷|Turkey Türkei flag
        🇦🇪|United Arab Emirates UAE flag
        🇸🇦|Saudi Arabia flag
        """))
    ]

    private static func entries(_ source: String) -> [CalendarEmojiEntry] {
        source.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let emoji = parts.first, !emoji.isEmpty else { return nil }
            let keywords = parts.count > 1 ? String(parts[1]) : String(emoji)
            return CalendarEmojiEntry(emoji: String(emoji), keywords: keywords)
        }
    }

    static var all: [CalendarEmojiEntry] { groups.flatMap(\.1) }
    static var curatedCount: Int { all.count }
}

private struct CalendarSystemIconChoice: Identifiable, Hashable {
    let label: String
    let systemName: String
    let keywords: String
    let category: String
    var id: String { systemName + "-" + label }

    init(_ label: String, _ systemName: String, _ category: String, _ keywords: String = "") {
        self.label = label
        self.systemName = systemName
        self.category = category
        self.keywords = keywords.isEmpty ? "\(label) \(systemName) \(category)" : "\(label) \(systemName) \(category) \(keywords)"
    }

    var isAvailable: Bool {
        CalendarSystemIconSupport.isAvailable(systemName)
    }

    /// This is intentionally a local, searchable SF Symbols catalog. SF
    /// Symbols does not expose its complete name list to an app at runtime;
    /// the list below covers the common calendar, work, health, travel,
    /// finance, communication, media, nature, and status families.
    static let all: [CalendarSystemIconChoice] = [
        // Time & calendar
        .init("Clock", "clock", "Time calendar", "time schedule"),
        .init("Alarm", "alarm", "Time calendar", "reminder wake"),
        .init("Timer", "timer", "Time calendar", "duration countdown"),
        .init("Stopwatch", "stopwatch", "Time calendar", "time measure"),
        .init("Hourglass", "hourglass", "Time calendar", "waiting time"),
        .init("Calendar", "calendar", "Time calendar", "date schedule"),
        .init("Calendar plus", "calendar.badge.plus", "Time calendar", "new add date"),
        .init("Calendar today", "calendar.circle", "Time calendar", "date day"),
        .init("Calendar check", "calendar.badge.checkmark", "Time calendar", "done appointment"),
        .init("Bell", "bell", "Time calendar", "notification reminder"),
        .init("Bell badge", "bell.badge", "Time calendar", "notification unread"),
        .init("Clock badge", "clock.badge.checkmark", "Time calendar", "done time"),
        // Work & productivity
        .init("Tasks", "checklist", "Work productivity", "todo list tasks"),
        .init("List", "list.bullet", "Work productivity", "items tasks"),
        .init("List square", "list.bullet.rectangle", "Work productivity", "items tasks"),
        .init("Check circle", "checkmark.circle", "Work productivity", "done complete success"),
        .init("Check square", "checkmark.square", "Work productivity", "done complete task"),
        .init("Plus circle", "plus.circle", "Work productivity", "add new"),
        .init("Minus circle", "minus.circle", "Work productivity", "remove"),
        .init("Pencil", "pencil", "Work productivity", "write edit"),
        .init("Pencil circle", "pencil.circle", "Work productivity", "edit write"),
        .init("Note", "note.text", "Work productivity", "notes document"),
        .init("Note with image", "note.text.image", "Work productivity", "notes photo"),
        .init("Document", "doc.text", "Work productivity", "file document"),
        .init("Folder", "folder", "Work productivity", "files project"),
        .init("Folder badge", "folder.badge.plus", "Work productivity", "new files"),
        .init("Paperclip", "paperclip", "Work productivity", "attachment file"),
        .init("Link", "link", "Work productivity", "connect url"),
        .init("Bookmark", "bookmark", "Work productivity", "save favorite"),
        .init("Flag", "flag", "Work productivity", "important project"),
        .init("Target", "scope", "Work productivity", "focus goal"),
        .init("Lightbulb", "lightbulb", "Work productivity", "idea brainstorm"),
        .init("Briefcase", "briefcase", "Work productivity", "work business"),
        .init("Chart", "chart.bar", "Work productivity", "analytics report"),
        .init("Chart line", "chart.xyaxis.line", "Work productivity", "analytics trend report"),
        // People & communication
        .init("Person", "person", "People communication", "self user"),
        .init("Person badge", "person.badge.plus", "People communication", "new user"),
        .init("Two people", "person.2", "People communication", "team friends"),
        .init("Three people", "person.3", "People communication", "team group"),
        .init("Person circle", "person.crop.circle", "People communication", "profile user"),
        .init("People circle", "person.2.circle", "People communication", "team group"),
        .init("Chat", "bubble.left", "People communication", "message chat"),
        .init("Chat bubbles", "bubble.left.and.bubble.right", "People communication", "conversation chat"),
        .init("Quote", "quote.opening", "People communication", "quote text"),
        .init("Envelope", "envelope", "People communication", "email mail"),
        .init("Phone", "phone", "People communication", "call contact"),
        .init("Video call", "video", "People communication", "meeting camera"),
        .init("Megaphone", "megaphone", "People communication", "announcement"),
        .init("At sign", "at", "People communication", "email mention"),
        .init("Share", "square.and.arrow.up", "People communication", "send export"),
        // Health & fitness
        .init("Heart", "heart", "Health fitness", "love health"),
        .init("Heart filled", "heart.fill", "Health fitness", "love favorite health"),
        .init("Heart pulse", "heart.text.square", "Health fitness", "health medical"),
        .init("ECG", "waveform.path.ecg", "Health fitness", "health heart rate"),
        .init("Figure run", "figure.run", "Health fitness", "running sport"),
        .init("Figure walk", "figure.walk", "Health fitness", "walking activity"),
        .init("Figure bike", "figure.outdoor.cycle", "Health fitness", "cycling sport"),
        .init("Figure yoga", "figure.yoga", "Health fitness", "yoga meditation"),
        .init("Figure strength", "figure.strengthtraining.traditional", "Health fitness", "gym workout"),
        .init("Figure swim", "figure.pool.swim", "Health fitness", "swimming sport"),
        .init("Medical cross", "cross.case", "Health fitness", "doctor hospital"),
        .init("Pill", "pills", "Health fitness", "medicine medication"),
        .init("Bandage", "bandage", "Health fitness", "medical injury"),
        .init("Drop", "drop", "Health fitness", "water hydration"),
        .init("Flame", "flame", "Health fitness", "energy streak"),
        .init("Moon", "moon", "Health fitness", "sleep night"),
        .init("Bed", "bed.double", "Health fitness", "sleep rest"),
        .init("Gauge", "gauge.with.dots.needle.bottom.50percent", "Health fitness", "score measure"),
        // Finance & commerce
        .init("Wallet", "wallet.pass", "Finance commerce", "money budget finance"),
        .init("Banknote", "banknote", "Finance commerce", "money cash finance"),
        .init("Credit card", "creditcard", "Finance commerce", "payment money finance"),
        .init("Coins", "bitcoinsign.circle", "Finance commerce", "money crypto"),
        .init("Cart", "cart", "Finance commerce", "shopping grocery"),
        .init("Bag", "bag", "Finance commerce", "shopping store"),
        .init("Tag", "tag", "Finance commerce", "price label shopping"),
        .init("Receipt", "receipt", "Finance commerce", "invoice expense"),
        .init("Percent", "percent", "Finance commerce", "discount tax"),
        .init("Euro", "eurosign.circle", "Finance commerce", "money EUR"),
        .init("Dollar", "dollarsign.circle", "Finance commerce", "money USD"),
        .init("Chart up", "chart.line.uptrend.xyaxis", "Finance commerce", "investment growth"),
        .init("Chart down", "chart.line.downtrend.xyaxis", "Finance commerce", "loss trend"),
        // Home & travel
        .init("House", "house", "Home travel", "home living"),
        .init("House filled", "house.fill", "Home travel", "home living"),
        .init("Building", "building.2", "Home travel", "office work"),
        .init("Airplane", "airplane", "Home travel", "flight travel trip"),
        .init("Car", "car", "Home travel", "drive travel"),
        .init("Bus", "bus", "Home travel", "commute transport"),
        .init("Train", "train.side.front.car", "Home travel", "commute transport"),
        .init("Bicycle", "bicycle", "Home travel", "bike cycling"),
        .init("Map", "map", "Home travel", "location places"),
        .init("Compass", "safari", "Home travel", "direction explore"),
        .init("Location", "location", "Home travel", "map place"),
        .init("Pin", "mappin", "Home travel", "location place"),
        .init("Globe", "globe.europe.africa", "Home travel", "world earth"),
        .init("Mountain", "mountain.2", "Home travel", "hiking nature"),
        .init("Tent", "tent", "Home travel", "camping outdoors"),
        .init("Beach", "beach.umbrella", "Home travel", "vacation holiday"),
        .init("Fork and knife", "fork.knife", "Home travel", "restaurant food"),
        .init("Cup", "cup.and.saucer", "Home travel", "coffee cafe"),
        // Media & technology
        .init("Laptop", "laptopcomputer", "Media technology", "computer coding work"),
        .init("Desktop", "desktopcomputer", "Media technology", "computer work"),
        .init("Phone", "iphone", "Media technology", "mobile contact"),
        .init("Tablet", "ipad", "Media technology", "mobile computer"),
        .init("Keyboard", "keyboard", "Media technology", "typing computer"),
        .init("Camera", "camera", "Media technology", "photo picture"),
        .init("Photo", "photo", "Media technology", "image picture"),
        .init("Video", "video", "Media technology", "film movie"),
        .init("Music note", "music.note", "Media technology", "song audio"),
        .init("Music notes", "music.note.list", "Media technology", "playlist audio"),
        .init("Headphones", "headphones", "Media technology", "music audio"),
        .init("Mic", "mic", "Media technology", "recording audio"),
        .init("TV", "tv", "Media technology", "television media"),
        .init("Game controller", "gamecontroller", "Media technology", "game play"),
        .init("Printer", "printer", "Media technology", "office document"),
        .init("Wifi", "wifi", "Media technology", "internet network"),
        .init("Server", "server.rack", "Media technology", "computer infrastructure"),
        .init("Terminal", "terminal", "Media technology", "code developer"),
        // Nature & weather
        .init("Sun", "sun.max", "Nature weather", "sunny weather"),
        .init("Cloud", "cloud", "Nature weather", "weather"),
        .init("Rain", "cloud.rain", "Nature weather", "weather"),
        .init("Snow", "snowflake", "Nature weather", "winter cold"),
        .init("Wind", "wind", "Nature weather", "air weather"),
        .init("Leaf", "leaf", "Nature weather", "plant green"),
        .init("Tree", "tree", "Nature weather", "forest plant"),
        .init("Flower", "camera.macro", "Nature weather", "flower plant"),
        .init("Sparkle", "sparkles", "Nature weather", "magic highlight"),
        .init("Umbrella", "umbrella", "Nature weather", "rain weather"),
        // Status & symbols
        .init("Star", "star", "Status symbols", "favorite rating"),
        .init("Star filled", "star.fill", "Status symbols", "favorite rating"),
        .init("Sparkles", "sparkles", "Status symbols", "magic highlight"),
        .init("Bolt", "bolt", "Status symbols", "energy urgent"),
        .init("Checkmark", "checkmark", "Status symbols", "done success"),
        .init("X mark", "xmark", "Status symbols", "close delete"),
        .init("Exclamation", "exclamationmark", "Status symbols", "alert warning"),
        .init("Question", "questionmark", "Status symbols", "help"),
        .init("Info", "info.circle", "Status symbols", "information help"),
        .init("Lock", "lock", "Status symbols", "security privacy"),
        .init("Shield", "shield", "Status symbols", "security protect"),
        .init("Eye", "eye", "Status symbols", "view look"),
        .init("Bell", "bell", "Status symbols", "reminder alert"),
        .init("Circle", "circle", "Status symbols", "status"),
        .init("Square", "square", "Status symbols", "shape"),
        .init("Diamond", "diamond", "Status symbols", "shape"),
        .init("Arrow right", "arrow.right", "Status symbols", "next forward"),
        .init("Arrow up", "arrow.up", "Status symbols", "up trend"),
        .init("Arrow down", "arrow.down", "Status symbols", "down trend"),
        .init("Refresh", "arrow.clockwise", "Status symbols", "reload sync"),
        .init("Filter", "line.3.horizontal.decrease", "Status symbols", "filter sort"),
        .init("Settings", "gear", "Status symbols", "settings preferences")
    ]
}

private enum CalendarIconRecentKind: String, Codable { case emoji, symbol, custom }

private struct CalendarIconRecent: Codable, Identifiable {
    let kind: CalendarIconRecentKind
    let value: String
    let label: String
    let asset: CalendarIconAsset?
    var id: String { kind.rawValue + ":" + value }
}

private enum CalendarIconRecents {
    static let maximumCount = 16
    private static let defaultsKey = "LifeOS.Calendar.IconRecents.v1"

    static func load(defaults: UserDefaults = .standard) -> [CalendarIconRecent] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([CalendarIconRecent].self, from: data) else { return [] }
        return Array(values.prefix(maximumCount))
    }

    @discardableResult
    static func record(_ recent: CalendarIconRecent, defaults: UserDefaults = .standard) -> [CalendarIconRecent] {
        var values = load(defaults: defaults).filter { $0.id != recent.id }
        values.insert(recent, at: 0)
        values = Array(values.prefix(maximumCount))
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: defaultsKey) }
        return values
    }
}

struct CalendarIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var icon: String?
    @Binding private var systemIconName: String?
    @Binding private var iconAsset: CalendarIconAsset?
    @State private var tab: CalendarIconPickerTab = .emojis
    @State private var query = ""
    @State private var customIcons: [CalendarReusableIcon]
    @State private var recentIcons: [CalendarIconRecent]
    @State private var showingCustomIconSheet = false

    init(
        icon: Binding<String?>,
        systemIconName: Binding<String?>,
        iconAsset: Binding<CalendarIconAsset?>,
        initialTab: String? = nil,
        customIcons: [CalendarReusableIcon]? = nil
    ) {
        _icon = icon
        _systemIconName = systemIconName
        _iconAsset = iconAsset
        let storedIcons = CalendarIconLibrary.load()
        let fixtureIcons = ProcessInfo.processInfo.arguments.contains("-LifeOSCalendarIconLibraryFixture")
            ? [CalendarVisualFixtures.reusableIcon].compactMap { $0 }
            : []
        // The picker intentionally has one surface: Apple's broad emoji
        // catalog plus reusable custom emoji/icon artwork. Keep the old
        // initialTab parameter source-compatible for callers that persisted
        // an earlier tab choice, but never expose the removed system-icons
        // tab again.
        _tab = State(initialValue: .emojis)
        _customIcons = State(initialValue: customIcons ?? (storedIcons.isEmpty ? fixtureIcons : storedIcons))
        _recentIcons = State(initialValue: CalendarIconRecents.load())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 0) {
                        pickerTab(.emojis, title: "Emojis", identifier: "calendar-icon-picker-emojis")
                        Spacer()
                        Button { resetIcon() } label: {
                            Image(systemName: "circle.slash")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.07), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove the event icon")
                        .accessibilityLabel("Remove icon")
                        .accessibilityIdentifier("calendar-icon-clear")
                    }
                    .padding(.horizontal, 2)

                    if tab == .emojis {
                        emojiContent
                    }
                }
                .padding(18)
            }
            .accessibilityIdentifier("calendar-icon-picker")
            .background(LifeOSTokens.surface)
#if os(iOS)
            .navigationTitle("Change icon")
#else
            .navigationTitle("")
#endif
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .sheet(isPresented: $showingCustomIconSheet) {
                CalendarCustomIconSheet { reusableIcon in
                    customIcons = CalendarIconLibrary.upsert(reusableIcon)
                    selectCustom(reusableIcon)
                }
#if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
#endif
            }
        }
#if os(macOS)
        .frame(width: 680, height: 700)
#endif
    }

    private func pickerTab(_ value: CalendarIconPickerTab, title: String, identifier: String) -> some View {
        Button {
            tab = value
        } label: {
            Text(title)
                .font(.system(size: 17, weight: tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? .primary : .secondary)
                .frame(minWidth: 82, minHeight: 38)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(tab == value ? Color.primary : .clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private var emojiContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField(placeholder: "Search emojis")
            recentContent
            customIconRow(identifier: "calendar-emoji-custom-icon-row")

            HStack(spacing: 8) {
                Button { shuffleEmoji() } label: {
                    Label("Random", systemImage: "shuffle")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Choose a random emoji")
                .accessibilityIdentifier("calendar-icon-shuffle")

                Button { resetIcon() } label: {
                    Label("No icon", systemImage: "circle.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Remove icon")
                .accessibilityIdentifier("calendar-icon-no-icon")
            }

            ForEach(filteredEmojiGroups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.0)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("calendar-emoji-category-\(group.0)")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 5)], spacing: 5) {
                        ForEach(group.1) { entry in
                            Button { selectEmoji(entry.emoji) } label: {
                                Text(entry.emoji)
                                    .font(.system(size: 28))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.plain)
                            .help(entry.keywords)
                            .accessibilityLabel("Use \(entry.emoji) emoji")
                            .accessibilityHint("Press Return to select")
                            .accessibilityIdentifier("calendar-emoji-\(entry.id)")
                        }
                    }
                }
            }

            if filteredEmojiGroups.isEmpty {
                emptySearchState("No emojis match \"\(query)\".")
            }
        }
    }

    private var iconContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField(placeholder: "Search icons")
            recentContent
            customIconRow(identifier: "calendar-icon-custom-row")

            Text("Apple system icons")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(filteredSystemIconGroups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.0)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(group.1) { choice in
                            Button { selectSystemIcon(choice) } label: {
                                Image(systemName: choice.systemName)
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .foregroundStyle(.primary)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(choice.keywords)
                            .accessibilityLabel("Use \(choice.label) icon")
                            .accessibilityHint("Press Return to select")
                            .accessibilityIdentifier("calendar-system-icon-\(choice.label)")
                        }
                    }
                }
            }
            if filteredSystemIconGroups.isEmpty { emptySearchState("No icons match \"\(query)\".") }
        }
    }

    /// Custom emoji/icon artwork lives in the same tile grid as the native
    /// emoji catalog. There is no separate system-symbol tab: custom art and
    /// the Add New tile keep the same footprint as ordinary emoji choices.
    private func customIconRow(identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom icons")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 5)], spacing: 5) {
                Button { showingCustomIconSheet = true } label: {
                    LifeOSIcon(.add)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add custom icon")
                .accessibilityIdentifier("calendar-icon-custom-add")

                ForEach(filteredCustomIcons) { reusableIcon in
                    Button { selectCustom(reusableIcon) } label: {
                        CalendarReusableIconImage(asset: reusableIcon.asset)
                            .padding(5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use custom icon \(reusableIcon.name)")
                    .accessibilityIdentifier("calendar-icon-custom-\(reusableIcon.id)")
                }
            }
        }
    }

    private func searchField(placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("calendar-icon-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear icon search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var recentContent: some View {
        let visibleRecents = recentIcons.filter { $0.kind != .symbol }
        if !visibleRecents.isEmpty && query.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleRecents) { recent in
                            Button { selectRecent(recent) } label: {
                                recentIconView(recent)
                                    .frame(width: 44, height: 44)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Use \(recent.label)")
                            .accessibilityLabel("Use recent icon \(recent.label)")
                            .accessibilityIdentifier("calendar-icon-recent-\(recent.id)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentIconView(_ recent: CalendarIconRecent) -> some View {
        if let asset = recent.asset {
            CalendarReusableIconImage(asset: asset)
                .padding(4)
        } else if recent.kind == .symbol,
                  CalendarSystemIconSupport.isAvailable(recent.value) {
            Image(systemName: recent.value)
                .font(.system(size: 19, weight: .medium))
        } else if recent.kind == .symbol {
            Image(systemName: "circle.slash")
                .font(.system(size: 19))
        } else {
            Text(recent.value)
                .font(.system(size: 25))
        }
    }

    private func emptySearchState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private var filteredEmojiGroups: [(String, [CalendarEmojiEntry])] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return CalendarEmojiCatalog.groups }
        return CalendarEmojiCatalog.groups.compactMap { title, entries in
            let matches = entries.filter { $0.keywords.localizedLowercase.contains(normalized) || $0.emoji.contains(normalized) }
            return matches.isEmpty ? nil : (title, matches)
        }
    }

    private var filteredSystemIconGroups: [(String, [CalendarSystemIconChoice])] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let matches = CalendarSystemIconChoice.all.filter {
            $0.isAvailable && (normalized.isEmpty || $0.keywords.localizedLowercase.contains(normalized))
        }
        return Dictionary(grouping: matches, by: \.category)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private var filteredCustomIcons: [CalendarReusableIcon] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return customIcons }
        return customIcons.filter { $0.name.localizedLowercase.contains(normalized) }
    }

    private func shuffleEmoji() {
        guard let entry = CalendarEmojiCatalog.groups.flatMap(\.1).randomElement() else { return }
        selectEmoji(entry.emoji)
    }

    private func selectEmoji(_ value: String) {
        guard let value = CalendarEmojiValidation.validated(value) else { return }
        icon = value
        systemIconName = nil
        iconAsset = nil
        recentIcons = CalendarIconRecents.record(CalendarIconRecent(kind: .emoji, value: value, label: value, asset: nil))
        dismiss()
    }

    private func selectCustom(_ reusableIcon: CalendarReusableIcon, record: Bool = true) {
        icon = nil
        systemIconName = nil
        iconAsset = reusableIcon.asset
        if record {
            recentIcons = CalendarIconRecents.record(CalendarIconRecent(kind: .custom, value: reusableIcon.id, label: reusableIcon.name, asset: reusableIcon.asset))
        }
        dismiss()
    }

    private func selectSystemIcon(_ choice: CalendarSystemIconChoice, record: Bool = true) {
        guard choice.isAvailable else { return }
        icon = nil
        systemIconName = choice.systemName
        iconAsset = nil
        if record {
            recentIcons = CalendarIconRecents.record(CalendarIconRecent(kind: .symbol, value: choice.systemName, label: choice.label, asset: nil))
        }
        dismiss()
    }

    private func selectRecent(_ recent: CalendarIconRecent) {
        switch recent.kind {
        case .emoji:
            selectEmoji(recent.value)
        case .symbol:
            guard let choice = CalendarSystemIconChoice.all.first(where: { $0.systemName == recent.value }) else { return }
            selectSystemIcon(choice, record: false)
        case .custom:
            guard let asset = recent.asset else { return }
            icon = nil
            systemIconName = nil
            iconAsset = asset
            dismiss()
        }
    }

    private func resetIcon() {
        icon = nil
        systemIconName = nil
        iconAsset = nil
        dismiss()
    }
}

/// A compact, quiet status control for the editor. The shared calendar picker
/// is intentionally kept for other surfaces; this label avoids the oversized
/// native spinner treatment that makes the dense editor row feel noisy.
private struct CalendarEditorStatusPicker: View {
    @Binding var progress: CalendarProgress

    var body: some View {
        Menu {
            ForEach(CalendarProgress.allCases, id: \.self) { status in
                Button {
                    progress = status
                } label: {
                    Label {
                        Text(status.label)
                    } icon: {
                        LifeOSIcon(status.iconName)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(progress.color)
                    .frame(width: 7, height: 7)
                Text(progress.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status, \(progress.label)")
        .accessibilityHint("Choose event status")
        .accessibilityIdentifier("calendar-event-status-picker")
    }
}

private struct CalendarReusableIconImage: View {
    let asset: CalendarIconAsset

    var body: some View {
        Group {
#if os(iOS)
            if let image = UIImage(data: asset.bytes) {
                Image(uiImage: image).resizable().scaledToFit()
            }
#else
            if let image = NSImage(data: asset.bytes) {
                Image(nsImage: image).resizable().scaledToFit()
            }
#endif
        }
        .padding(6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct CalendarCustomIconSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var asset: CalendarIconAsset?
    @State private var showingImporter = false
    @State private var errorMessage: String?
    let onSave: (CalendarReusableIcon) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Custom icons can be reused across your local calendar.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Button { showingImporter = true } label: {
                    VStack(spacing: 8) {
                        if let asset {
                            CalendarReusableIconImage(asset: asset)
                                .frame(width: 54, height: 54)
                        } else {
                            LifeOSIcon(.image)
                                .frame(width: 25, height: 25)
                                .foregroundStyle(.secondary)
                        }
                        Text(asset == nil ? "Upload an image" : "Replace image")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("calendar-icon-upload")

                VStack(alignment: .leading, spacing: 7) {
                    Text("Icon name")
                        .font(.subheadline.weight(.semibold))
                    TextField("have-fun-with-it", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("calendar-icon-custom-name")
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Add custom icon")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("calendar-icon-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(asset == nil || cleanedName.isEmpty)
                        .accessibilityIdentifier("calendar-icon-save")
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false, onCompletion: importIcon)
            .alert("Unable to use image", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Choose a supported image.")
            }
        }
        .background(LifeOSTokens.canvas.ignoresSafeArea())
    }

    private var cleanedName: String {
        name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importIcon(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            asset = try CalendarIconAssetSanitizer.sanitize(data)
        } catch {
            errorMessage = "Choose a valid PNG or JPEG smaller than 256 KB after sanitization."
        }
    }

    private func save() {
        guard let asset else { return }
        do {
            onSave(try CalendarReusableIcon(name: cleanedName, asset: asset))
            dismiss()
        } catch {
            errorMessage = "Enter a short icon name and choose a valid image."
        }
    }
}

/// Live title search over every non-deleted calendar item. Upcoming matches
/// lead chronologically; past matches follow, most recent first. Selecting a
/// result jumps to its day and opens the editor.
struct CalendarSearchView: View {
    let items: [CalendarItem]
    let calendar: Calendar
    let onSelect: (CalendarItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var results: [CalendarItem] {
        trimmedQuery.isEmpty
            ? CalendarSearch.recentItems(in: items)
            : CalendarSearch.results(matching: query, in: items, calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No events yet",
                        systemImage: "calendar",
                        description: Text("Create your first event to see it here.")
                    )
                } else if !trimmedQuery.isEmpty && results.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "questionmark.text.page",
                        description: Text("Nothing in the calendar matches \"\(trimmedQuery)\".")
                    )
                } else {
                    List(results) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            searchResultRow(item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("calendar-search-result-\(item.id.uuidString)")
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .top, spacing: 0) { listHeader }
                }
            }
            .navigationTitle("Search")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(LifeOSTokens.canvas)
            }
            .onAppear { fieldFocused = true }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: trimmedQuery.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(trimmedQuery.isEmpty ? "Recent" : "Matches")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(LifeOSTokens.canvas)
        .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LifeOSTokens.tertiaryText)
            TextField("Event or to-do title", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .accessibilityIdentifier("calendar-search-field")
            if !trimmedQuery.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func searchResultRow(_ item: CalendarItem) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.status == .done ? LifeOSTokens.Hue.green.base : Color.lifeOSCalendarRed)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(resultSubtitle(item))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.hasIcon {
                CalendarIconView(item: item, size: 17)
            }
            if item.kind == .todo {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.status == .done ? LifeOSTokens.Hue.green.base : Color.secondary)
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Date and time rendered in the item's own time zone so a result row
    /// never silently relabels a cross-zone event into the device zone.
    private func resultSubtitle(_ item: CalendarItem) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        style.timeZone = item.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
        return item.start.formatted(style)
    }
}
