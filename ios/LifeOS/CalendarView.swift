import SwiftUI

public struct CalendarView: View {
    @ObservedObject private var coordinator: CalendarCoordinator
    @State private var selectedDate: Date
    @State private var showingEditor = false
    @State private var editingItem: CalendarItem?
    private let calendar: Calendar

    public init(selectedDate: Date = .now, calendar: Calendar = .current, coordinator: CalendarCoordinator) {
        _selectedDate = State(initialValue: selectedDate); self.calendar = calendar; self.coordinator = coordinator
    }

    private var dayItems: [CalendarItem] {
        coordinator.snapshot.items.filter { calendar.isDate($0.start, inSameDayAs: selectedDate) && $0.deletedAt == nil }.sorted { $0.start < $1.start }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Calendar").font(.largeTitle.bold())
                        Text(selectedDate, format: .dateTime.weekday(.wide).month(.wide).day()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { editingItem = nil; showingEditor = true } label: {
                        Label("Add", systemImage: "plus")
                    }.buttonStyle(.borderedProminent).accessibilityHint("Create a calendar item")
                }
                DatePicker("Choose date", selection: $selectedDate, displayedComponents: [.date])
                    .datePickerStyle(.graphical).labelsHidden().accessibilityLabel("Choose calendar date")
                HStack { Text("Agenda").font(.title2.bold()); Spacer(); Text("\(dayItems.count) \(dayItems.count == 1 ? "item" : "items")").foregroundStyle(.secondary).font(.subheadline) }
                if dayItems.isEmpty { ContentUnavailableView("A clear day", systemImage: "sun.max", description: Text("Add a time commitment to get started.")) }
                else {
                    ForEach(dayItems) { item in
                        Button { editingItem = item; showingEditor = true } label: { CalendarItemRow(item: item) }
                            .buttonStyle(.plain).padding(.horizontal)
                            .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.corner))
                    }
                }
            }.padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.canvas)
        .sheet(isPresented: $showingEditor) { CalendarEditor(item: editingItem, onSave: save, onDelete: delete) }
    }

    private func save(_ item: CalendarItem) {
        Task { await coordinator.save(item) }
        showingEditor = false
    }
    private func delete(_ item: CalendarItem) {
        Task { await coordinator.delete(item) }; showingEditor = false
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
    let existing: CalendarItem?
    let onSave: (CalendarItem) -> Void
    let onDelete: (CalendarItem) -> Void

    init(item: CalendarItem?, onSave: @escaping (CalendarItem) -> Void, onDelete: @escaping (CalendarItem) -> Void) {
        existing = item; self.onSave = onSave; self.onDelete = onDelete
        _title = State(initialValue: item?.title ?? "")
        _icon = State(initialValue: item?.icon ?? "📅")
        _status = State(initialValue: item?.status ?? .planned)
        _start = State(initialValue: item?.start ?? .now)
        _end = State(initialValue: item?.end ?? .now.addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
#if os(iOS)
                    TextField("Icon", text: $icon)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Calendar icon")
#else
                    TextField("Icon", text: $icon)
                        .accessibilityLabel("Calendar icon")
#endif
                    TextField("Title", text: $title).accessibilityLabel("Calendar item title")
                    CalendarProgressPicker(progress: $status)
                }
                Section("When") {
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end, in: start...)
                }
                if existing != nil { Section { Button("Delete item", role: .destructive) { if let existing { onDelete(existing) } } } }
            }
            .navigationTitle(existing == nil ? "New item" : "Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
                }
            }
            .alert("Unable to save", isPresented: Binding(get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })) {
                Button("OK") { validationMessage = nil }
            } message: { Text(validationMessage ?? "Please check the item details.") }
        }
    }

    private func commit() {
        do {
            let item = try CalendarItem(id: existing?.id ?? UUID(), title: title, icon: icon, status: status,
                                        start: start, end: end, createdAt: existing?.createdAt ?? .now,
                                        updatedAt: .now, deletedAt: existing?.deletedAt)
            onSave(item)
        } catch { validationMessage = "Please provide a title and an end time after the start time." }
    }
}
