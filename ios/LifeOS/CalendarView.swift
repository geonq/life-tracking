import SwiftUI
import UniformTypeIdentifiers

private enum CalendarDisplayMode: Hashable {
    case timeline
    case month
}

public struct CalendarView: View {
    @ObservedObject private var coordinator: CalendarCoordinator
    @State private var selectedDate: Date
    @State private var displayMode: CalendarDisplayMode = .timeline
    @State private var showingEditor = false
    @State private var editingItem: CalendarItem?
    @State private var hourHeight: CGFloat = 54
    @State private var gestureStartHourHeight: CGFloat?
    @Binding private var requestNewEvent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let calendar: Calendar

    public init(
        selectedDate: Date = .now,
        calendar: Calendar = .current,
        coordinator: CalendarCoordinator,
        startsInMonthMode: Bool = false,
        requestNewEvent: Binding<Bool> = .constant(false)
    ) {
        _selectedDate = State(initialValue: selectedDate)
        _displayMode = State(initialValue: startsInMonthMode ? .month : .timeline)
        _requestNewEvent = requestNewEvent
        self.calendar = calendar
        self.coordinator = coordinator
    }

    private var visibleItems: [CalendarItem] {
        coordinator.snapshot.items.filter { !$0.isDeleted }
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
        CalendarDateRange.days(containing: selectedDate, count: 3, calendar: calendar)
#endif
    }

    private var selectedDayItems: [CalendarItem] {
        visibleItems
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
    }

#if os(macOS)
    private var macLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CalendarCompactMonth(
                    selectedDate: $selectedDate,
                    calendar: calendar,
                    items: visibleItems
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
        .sheet(isPresented: $showingEditor) {
            CalendarEditor(item: editingItem, onSave: save, onDelete: delete)
                .frame(minWidth: 560, idealWidth: 620, minHeight: 620, idealHeight: 700)
        }
    }

    private func compactSidebarEvent(_ item: CalendarItem) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.status.color)
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
            CalendarIconView(item: item, size: 17)
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
            .refreshable { await coordinator.manualRefresh() }
            .background(LifeOSTokens.canvas)
            .sheet(isPresented: $showingEditor) {
                CalendarEditor(item: editingItem, onSave: save, onDelete: delete)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
    }
#endif

    private var calendarContent: some View {
        VStack(spacing: 0) {
            calendarHeader
            Group {
                switch displayMode {
                case .timeline:
                    CalendarTimelineView(
                        days: timelineDays,
                        items: visibleItems,
                        holidays: visibleHolidays,
                        hourHeight: hourHeight,
                        calendar: calendar,
                        onSelect: edit
                    )
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
                case .month:
                    ScrollView {
                        CalendarMonthGrid(
                            month: selectedDate,
                            selectedDate: selectedDate,
                            items: visibleItems,
                            holidays: visibleHolidays,
                            calendar: calendar,
                            onSelectDate: { date in
                                selectedDate = date
#if os(iOS)
                                withAnimation(reduceMotion ? nil : LifeOSMotion.easeNavigate) { displayMode = .timeline }
#endif
                            },
                            onSelectItem: edit
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
        .animation(reduceMotion ? nil : LifeOSMotion.ease, value: selectedDate)
    }

    private var calendarHeader: some View {
        Group {
#if os(iOS)
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(selectedDate, format: .dateTime.month(.wide).year())
                        .font(LifeOSFont.headerLarge(20))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Today") { selectedDate = .now }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(LifeOSTokens.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                    Button { create() } label: {
                        LifeOSIcon(.add).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(LifeOSTokens.accent, in: Circle())
                    .accessibilityIdentifier("calendar-add")
                    .accessibilityLabel("New event")
                    .accessibilityHint("Create a calendar event")
                }

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        calendarModeButton(.timeline, label: timelinePickerLabel)
                        calendarModeButton(.month, label: "Month")
                    }
                    .accessibilityIdentifier("calendar-view-picker")
                    .padding(2)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: 164)
                    Spacer(minLength: 8)
                    navigationButton(direction: -1, icon: .chevronLeft)
                    navigationButton(direction: 1, icon: .chevronRight)
                }
            }
#else
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedDate, format: .dateTime.month(.wide).year())
                            .font(LifeOSFont.headerLarge(22))
                        Text(displayMode == .month ? "Month" : timelineSubtitle)
                            .font(LifeOSFont.caption())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Today") { selectedDate = .now }
                        .buttonStyle(.bordered)
                    Button { move(by: -1) } label: {
                        LifeOSIcon(.chevronLeft).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Previous \(displayMode == .month ? "month" : timelinePeriodName)")
                    Button { move(by: 1) } label: {
                        LifeOSIcon(.chevronRight).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Next \(displayMode == .month ? "month" : timelinePeriodName)")
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
        "three days"
#endif
    }

    private var timelineSubtitle: String {
#if os(macOS)
        "Week view"
#else
        "Three-day view"
#endif
    }

    private func move(by direction: Int) {
        let component: Calendar.Component = displayMode == .month ? .month : .day
#if os(macOS)
        let amount = displayMode == .month ? direction : direction * 7
#else
        let amount = displayMode == .month ? direction : direction * 3
#endif
        selectedDate = calendar.date(byAdding: component, value: amount, to: selectedDate) ?? selectedDate
    }

    private func create() {
        editingItem = nil
        showingEditor = true
    }

    private func edit(_ item: CalendarItem) {
        editingItem = item
        showingEditor = true
    }

    private func save(_ item: CalendarItem) {
        Task { await coordinator.save(item) }
        showingEditor = false
    }

    private func delete(_ item: CalendarItem) {
        Task { await coordinator.delete(item) }
        showingEditor = false
    }
}

private struct CalendarEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var icon: String
    @State private var status: CalendarProgress
    @State private var start: Date
    @State private var end: Date
    @State private var validationMessage: String?
    @State private var showingIconImporter = false
    @State private var iconAsset: CalendarIconAsset?
    let existing: CalendarItem?
    let onSave: (CalendarItem) -> Void
    let onDelete: (CalendarItem) -> Void

    init(item: CalendarItem?, onSave: @escaping (CalendarItem) -> Void, onDelete: @escaping (CalendarItem) -> Void) {
        existing = item
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: item?.title ?? "")
        _icon = State(initialValue: item?.icon ?? "📅")
        _iconAsset = State(initialValue: item?.iconAsset)
        _status = State(initialValue: item?.status ?? .planned)
        let roundedStart = item?.start ?? Date.now.addingTimeInterval(300 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 300))
        _start = State(initialValue: roundedStart)
        _end = State(initialValue: item?.end ?? roundedStart.addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    HStack(spacing: 12) {
                        Group {
                            if let iconAsset, let image = platformImage(from: iconAsset.bytes) {
                                image.resizable().scaledToFit()
                            } else {
                                Text(icon).font(.title2)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .background(LifeOSTokens.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        TextField("Event title", text: $title)
                            .font(.headline)
                            .accessibilityLabel("Calendar event title")
                    }
                    CalendarProgressPicker(progress: $status)
                }

                Section("Icon") {
#if os(macOS)
                    HStack(alignment: .top, spacing: 18) {
                        CalendarEmojiPicker(selection: $icon)
                        customIconControls.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
#else
                    CalendarEmojiPicker(selection: $icon)
                    customIconControls
#endif
                }

                Section("When") {
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end, in: start...)
                }

                if let existing {
                    Section {
                        Button("Delete event", role: .destructive) { onDelete(existing) }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New event" : "Edit event")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .fileImporter(isPresented: $showingIconImporter, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false,
                          onCompletion: importIcon)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
                }
            }
            .alert("Unable to save", isPresented: Binding(get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })) {
                Button("OK") { validationMessage = nil }
            } message: {
                Text(validationMessage ?? "Please check the event details.")
            }
        }
    }

    private var customIconControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom").font(.subheadline.weight(.semibold))
            Text("PNG or JPEG, up to 256 KB. The original is synchronized with the event data.")
                .font(.caption).foregroundStyle(.secondary)
            Button { showingIconImporter = true } label: {
                HStack(spacing: 7) {
                    LifeOSIcon(.image).frame(width: 16, height: 16)
                    Text(iconAsset == nil ? "Upload icon" : "Replace icon")
                }
            }
            .buttonStyle(.bordered)
            if let iconAsset {
                Text("\(iconAsset.format.rawValue.uppercased()) selected")
                    .font(.caption).foregroundStyle(LifeOSTokens.accent)
                Button("Remove custom icon", role: .destructive) { self.iconAsset = nil }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func importIcon(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let format: CalendarIconAsset.Format = url.pathExtension.lowercased() == "png" ? .png : .jpeg
            iconAsset = try CalendarIconAsset(format: format, bytes: data)
        } catch {
            validationMessage = "Choose a valid PNG or JPEG smaller than 256 KB."
        }
    }

    private func commit() {
        do {
            let item = try CalendarItem(
                id: existing?.id ?? UUID(),
                title: title,
                icon: icon,
                iconAsset: iconAsset,
                status: status,
                start: start,
                end: end,
                createdAt: existing?.createdAt ?? .now,
                updatedAt: .now,
                deletedAt: existing?.deletedAt
            )
            onSave(item)
        } catch {
            validationMessage = "Please provide a title and an end time after the start time."
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
