import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - View model

@MainActor
final class TasksViewModel: ObservableObject {
    @Published var items: [TaskItem] = []
    @Published var errorMessage: String?

    private let store: TaskStore?
    private let now: () -> Date
    private let calendar: Calendar

    /// `store == nil` selects the visual-fixtures path: fixed demo content,
    /// never persisted, never the default. Every other init loads (or starts
    /// honestly empty from) the real local store.
    init(store: TaskStore?, initialItems: [TaskItem] = [], now: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
        self.items = initialItems
    }

    func load() async {
        guard let store else { return }
        do { items = try await store.load() }
        catch { errorMessage = "Unable to load tasks: \(error.localizedDescription)" }
    }

    func quickAdd(title: String, category: TaskCategory) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = TaskItem(title: trimmed, category: category)
        guard let store else {
            items.append(item)
            return
        }
        do { items = try await store.add(item) }
        catch { errorMessage = "Unable to save task: \(error.localizedDescription)" }
    }

    func toggleComplete(_ item: TaskItem) async {
        guard let store else {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].isCompleted.toggle()
            items[index].completedAt = items[index].isCompleted ? now() : nil
            return
        }
        do { items = try await store.toggleComplete(id: item.id, now: now()) }
        catch { errorMessage = "Unable to update task: \(error.localizedDescription)" }
    }

    func save(_ item: TaskItem) async {
        guard let store else {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index] = item
            return
        }
        do { items = try await store.update(item) }
        catch { errorMessage = "Unable to save task: \(error.localizedDescription)" }
    }

    func archive(_ item: TaskItem) async {
        guard let store else {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].isArchived = true
            return
        }
        do { items = try await store.setArchived(id: item.id, archived: true) }
        catch { errorMessage = "Unable to archive task: \(error.localizedDescription)" }
    }

    func unarchive(_ item: TaskItem) async {
        guard let store else {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].isArchived = false
            return
        }
        do { items = try await store.setArchived(id: item.id, archived: false) }
        catch { errorMessage = "Unable to restore task: \(error.localizedDescription)" }
    }

    func delete(_ item: TaskItem) async {
        guard let store else {
            items.removeAll { $0.id == item.id }
            return
        }
        do { items = try await store.delete(id: item.id) }
        catch { errorMessage = "Unable to delete task: \(error.localizedDescription)" }
    }
}

// MARK: - Section model

private enum TasksSection: String, CaseIterable, Identifiable {
    case overdue, today, upcoming, inbox, completed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .inbox: "Inbox"
        case .completed: "Completed"
        }
    }
}

private enum TasksCategoryFilter: String, CaseIterable, Identifiable, Hashable {
    case all, business, finance, personal
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .business: "Business"
        case .finance: "Finance"
        case .personal: "Personal"
        }
    }

    var category: TaskCategory? {
        switch self {
        case .all: nil
        case .business: .business
        case .finance: .finance
        case .personal: .personal
        }
    }
}

// MARK: - Screen

public struct TasksView: View {
    @StateObject private var model: TasksViewModel
    @State private var quickAddTitle = ""
    @State private var quickAddCategory: TaskCategory = .personal
    @State private var categoryFilter: TasksCategoryFilter = .all
    @State private var editingItem: TaskItem?
    @State private var showingArchive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let usesVisualFixtures: Bool

    public init(usesVisualFixtures: Bool = false) {
        self.usesVisualFixtures = usesVisualFixtures
        if usesVisualFixtures {
            _model = StateObject(wrappedValue: TasksViewModel(store: nil, initialItems: TasksVisualFixtures.items()))
        } else {
            _model = StateObject(wrappedValue: TasksViewModel(store: TaskStore(url: TaskStoreURL.localURL())))
        }
    }

    public var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: 16, bottomPadding: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    quickAddField
                    categoryFilterControl
                    if visibleItems.isEmpty {
                        emptyState
                    } else {
                        ForEach(TasksSection.allCases) { section in
                            let sectionItems = items(in: section)
                            if !sectionItems.isEmpty {
                                sectionView(section, items: sectionItems)
                            }
                        }
                    }
                    archiveLink
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .task {
            if !usesVisualFixtures { await model.load() }
        }
        .sheet(item: $editingItem) { item in
            TaskEditSheet(
                item: item,
                onSave: { updated in
                    Task { await model.save(updated) }
                    editingItem = nil
                },
                onArchive: { archived in
                    Task { await model.archive(archived) }
                    editingItem = nil
                },
                onDelete: { deleted in
                    Task { await model.delete(deleted) }
                    editingItem = nil
                }
            )
        }
        .sheet(isPresented: $showingArchive) {
            TaskArchiveView(
                items: model.items.filter(\.isArchived),
                onUnarchive: { item in Task { await model.unarchive(item) } }
            )
        }
        .alert("Tasks", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { }
        } message: { Text(model.errorMessage ?? "") }
        .accessibilityIdentifier("tasks-screen")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Tasks")
                .font(LifeOSFont.spaceGrotesk(28, weight: .bold))
            Text("The next actions that need your attention")
                .font(LifeOSFont.inter(14))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }

    // MARK: Quick add

    private var quickAddField: some View {
        HStack(spacing: 10) {
            LifeOSIcon(.add)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 16, height: 16)
            TextField("Add a task…", text: $quickAddTitle)
                .textFieldStyle(.plain)
                .font(LifeOSFont.inter(15))
                .submitLabel(.done)
                .onSubmit(submitQuickAdd)
                .accessibilityIdentifier("tasks-quick-add-field")
            if !quickAddTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add", action: submitQuickAdd)
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.accent)
                    .accessibilityIdentifier("tasks-quick-add-submit")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }

    private func submitQuickAdd() {
        let title = quickAddTitle
        quickAddTitle = ""
        Task { await model.quickAdd(title: title, category: quickAddCategory) }
    }

    // MARK: Category filter

    private var categoryFilterControl: some View {
        SpringPillSelector(options: TasksCategoryFilter.allCases, selection: $categoryFilter) { option, isSelected in
            Text(option.label)
                .font(LifeOSFont.inter(13, weight: isSelected ? .semiBold : .medium))
                .foregroundStyle(isSelected ? Color.primary : LifeOSTokens.tertiaryText)
        }
        .accessibilityIdentifier("tasks-category-filter")
    }

    // MARK: Filtering / sectioning

    private var visibleItems: [TaskItem] {
        model.items.filter { item in
            !item.isArchived && (categoryFilter.category == nil || item.category == categoryFilter.category)
        }
    }

    private func items(in section: TasksSection) -> [TaskItem] {
        let source = visibleItems
        switch section {
        case .overdue:
            return source.filter { $0.isOverdue() }.sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
        case .today:
            return source.filter { $0.isToday() }.sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
        case .upcoming:
            return source.filter { $0.isUpcoming() }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        case .inbox:
            return source.filter { $0.isInbox() }.sorted { $0.createdAt > $1.createdAt }
        case .completed:
            return source.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
    }

    private func sectionView(_ section: TasksSection, items: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title.uppercased())
                .font(LifeOSFont.inter(11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(section == .overdue ? LifeOSTokens.danger : LifeOSTokens.tertiaryText)

            if section == .upcoming {
                upcomingGrouped(items: items)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        TaskRow(item: item, onToggle: { toggle(item) }, onOpen: { editingItem = item })
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
                .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            }
        }
        .accessibilityIdentifier("tasks-section-\(section.rawValue)")
    }

    /// Upcoming groups by calendar day, per spec ("grouped by date").
    private func upcomingGrouped(items: [TaskItem]) -> some View {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.dueDate ?? .distantFuture)
        }
        let orderedDays = groups.keys.sorted()

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(orderedDays, id: \.self) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    let dayItems = groups[day] ?? []
                    VStack(spacing: 0) {
                        ForEach(dayItems) { item in
                            TaskRow(item: item, onToggle: { toggle(item) }, onOpen: { editingItem = item })
                            if item.id != dayItems.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
                    .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                }
            }
        }
    }

    private func toggle(_ item: TaskItem) {
        if reduceMotion {
            Task { await model.toggleComplete(item) }
        } else {
            withAnimation(LifeOSMotion.snappy) {
                Task { await model.toggleComplete(item) }
            }
        }
#if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No tasks yet — add one above")
                .font(LifeOSFont.inter(14, weight: .medium))
                .foregroundStyle(.primary)
            Text("Anything you capture here stays local to this device.")
                .font(LifeOSFont.inter(12))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityIdentifier("tasks-empty-state")
    }

    private var archiveLink: some View {
        Button {
            showingArchive = true
        } label: {
            HStack(spacing: 6) {
                Text("Archived")
                    .font(LifeOSFont.inter(13, weight: .medium))
                Spacer()
                Text("\(model.items.filter(\.isArchived).count)")
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                LifeOSIcon(.chevronRight)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
            .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tasks-archive-link")
    }
}

// MARK: - Row

private struct TaskRow: View {
    let item: TaskItem
    let onToggle: () -> Void
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                LifeOSIcon(item.isCompleted ? .done : .planned)
                    .foregroundStyle(item.isCompleted ? LifeOSTokens.success : LifeOSTokens.tertiaryText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark incomplete" : "Mark complete")
            .accessibilityIdentifier("task-toggle-\(item.id.uuidString)")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(LifeOSFont.inter(14, weight: .medium))
                        .foregroundStyle(item.isCompleted ? LifeOSTokens.tertiaryText : .primary)
                        .strikethrough(item.isCompleted)
                        .lineLimit(2)
                    if item.dueDate != nil || !item.tags.isEmpty || !item.subtasks.isEmpty {
                        HStack(spacing: 8) {
                            if let dueDate = item.dueDate {
                                Text(dueLabel(dueDate))
                                    .font(LifeOSFont.inter(11))
                                    .foregroundStyle(item.isOverdue() ? LifeOSTokens.danger : LifeOSTokens.tertiaryText)
                            }
                            if !item.subtasks.isEmpty {
                                Text("\(item.subtasks.filter(\.done).count)/\(item.subtasks.count)")
                                    .font(LifeOSFont.inter(11))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                            categoryBadge
                        }
                    } else {
                        categoryBadge
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            LifeOSIcon(.chevronRight)
                .frame(width: 12, height: 12)
                .foregroundStyle(LifeOSTokens.tertiaryText.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityIdentifier("task-row-\(item.id.uuidString)")
    }

    private var categoryBadge: some View {
        Text(item.category.label)
            .font(LifeOSFont.inter(10, weight: .semiBold))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LifeOSTokens.quietBorder, in: Capsule())
    }

    private func dueLabel(_ date: Date) -> String {
        if item.hasDueTime {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Edit sheet

private struct TaskEditSheet: View {
    @State var item: TaskItem
    let onSave: (TaskItem) -> Void
    let onArchive: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newSubtaskTitle = ""
    @State private var hasDueDate: Bool

    init(item: TaskItem, onSave: @escaping (TaskItem) -> Void, onArchive: @escaping (TaskItem) -> Void, onDelete: @escaping (TaskItem) -> Void) {
        _item = State(initialValue: item)
        self.onSave = onSave
        self.onArchive = onArchive
        self.onDelete = onDelete
        _hasDueDate = State(initialValue: item.dueDate != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $item.title)
                    Picker("Category", selection: $item.category) {
                        ForEach(TaskCategory.allCases) { category in
                            Text(category.label).tag(category)
                        }
                    }
                }

                Section("Due date") {
                    Toggle("Has due date", isOn: $hasDueDate)
                        .onChange(of: hasDueDate) { _, newValue in
                            if newValue {
                                item.dueDate = item.dueDate ?? .now
                            } else {
                                item.dueDate = nil
                                item.hasDueTime = false
                            }
                        }
                    if hasDueDate {
                        DatePicker(
                            "Date",
                            selection: Binding(get: { item.dueDate ?? .now }, set: { item.dueDate = $0 }),
                            displayedComponents: item.hasDueTime ? [.date, .hourAndMinute] : [.date]
                        )
                        Toggle("Include time", isOn: $item.hasDueTime)
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: Binding(get: { item.notes ?? "" }, set: { item.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Subtasks") {
                    ForEach($item.subtasks) { $subtask in
                        HStack {
                            Button {
                                subtask.done.toggle()
                            } label: {
                                LifeOSIcon(subtask.done ? .done : .planned)
                                    .foregroundStyle(subtask.done ? LifeOSTokens.success : LifeOSTokens.tertiaryText)
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            Text(subtask.title)
                                .strikethrough(subtask.done)
                        }
                    }
                    .onDelete { offsets in item.subtasks.remove(atOffsets: offsets) }

                    HStack {
                        TextField("Add subtask…", text: $newSubtaskTitle)
                        Button("Add") {
                            let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            item.subtasks.append(TaskSubitem(title: trimmed))
                            newSubtaskTitle = ""
                        }
                        .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section {
                    Button("Archive task") { onArchive(item) }
                        .foregroundStyle(LifeOSTokens.warning)
                    Button("Delete task", role: .destructive) { onDelete(item) }
                }
            }
            .navigationTitle("Edit Task")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(item) }
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Archive

private struct TaskArchiveView: View {
    let items: [TaskItem]
    let onUnarchive: (TaskItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Text("No archived tasks")
                            .font(LifeOSFont.inter(14, weight: .medium))
                        Text("Tasks you archive show up here.")
                            .font(LifeOSFont.inter(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Button("Restore") { onUnarchive(item) }
                                    .font(LifeOSFont.inter(12, weight: .semiBold))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Archived")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Visual fixtures

/// Deterministic, clearly-labelled demo content for `-LifeOSVisualFixtures`
/// launches only. Never reachable from the default/live path — `TasksView`
/// only constructs this when `usesVisualFixtures` is explicitly true.
enum TasksVisualFixtures {
    static func items(anchor: Date = .now, calendar: Calendar = .current) -> [TaskItem] {
        let day = calendar.startOfDay(for: anchor)
        func date(dayOffset: Int, hour: Int = 9) -> Date {
            let shifted = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted) ?? shifted
        }
        return [
            TaskItem(title: "DEMO — Follow up on invoice #204", dueDate: date(dayOffset: -2), hasDueTime: false, category: .finance),
            TaskItem(title: "DEMO — Review Q3 numbers", dueDate: date(dayOffset: 0, hour: 15), hasDueTime: true, category: .business),
            TaskItem(title: "DEMO — Call bank about card limit", dueDate: date(dayOffset: 3), category: .finance),
            TaskItem(title: "DEMO — Plan client onboarding", dueDate: date(dayOffset: 3), category: .business,
                     subtasks: [TaskSubitem(title: "Draft agenda", done: true), TaskSubitem(title: "Send calendar invite")]),
            TaskItem(title: "DEMO — Book dentist appointment", category: .personal),
            TaskItem(title: "DEMO — Renew passport", dueDate: date(dayOffset: -10), category: .personal, isCompleted: true, completedAt: date(dayOffset: -9))
        ]
    }
}
