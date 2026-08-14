import Foundation

/// The three category lenses over the single underlying task list, per
/// `modules/tasks-and-lists/overview.md`. A task belongs to exactly one
/// category; Business/Finance/Personal are filtered views, not separate
/// storage buckets.
public enum TaskCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case business
    case finance
    case personal

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .business: "Business"
        case .finance: "Finance"
        case .personal: "Personal"
        }
    }
}

/// One-level subtask checklist item, for breaking a task down into a few
/// concrete steps without introducing a second level of nesting.
public struct TaskSubitem: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var done: Bool

    public init(id: UUID = UUID(), title: String, done: Bool = false) {
        self.id = id
        self.title = title
        self.done = done
    }
}

/// A single durable task. Section membership (Inbox/Today/Upcoming/Overdue)
/// is derived from `dueDate` and completion state rather than stored, so
/// there is exactly one source of truth for where a task currently belongs.
public struct TaskItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var dueDate: Date?
    /// Whether `dueDate` carries a meaningful time-of-day, vs. being a
    /// date-only commitment. Irrelevant when `dueDate` is nil.
    public var hasDueTime: Bool
    public var category: TaskCategory
    public var tags: [String]
    public var notes: String?
    public var subtasks: [TaskSubitem]
    public var isCompleted: Bool
    public var completedAt: Date?
    public var isArchived: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        category: TaskCategory = .personal,
        tags: [String] = [],
        notes: String? = nil,
        subtasks: [TaskSubitem] = [],
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.category = category
        self.tags = tags
        self.notes = notes
        self.subtasks = subtasks
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    /// Newly captured tasks with no due date and no triage decision yet —
    /// the "I need to remember this" bucket.
    public func isInbox(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, !isArchived, dueDate == nil else { return false }
        return true
    }

    public func isToday(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, !isArchived, let dueDate else { return false }
        return calendar.isDate(dueDate, inSameDayAs: now)
    }

    public func isUpcoming(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, !isArchived, let dueDate else { return false }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfDueDay = calendar.dateInterval(of: .day, for: dueDate)?.start else { return false }
        return startOfDueDay > startOfToday
    }

    /// Past due and not completed — surfaced distinctly so nothing slips
    /// silently, per the spec. Archived-but-overdue tasks are excluded since
    /// archiving is an explicit "no longer relevant" decision.
    public func isOverdue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, !isArchived, let dueDate else { return false }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfDueDay = calendar.dateInterval(of: .day, for: dueDate)?.start else { return false }
        return startOfDueDay < startOfToday
    }
}

/// The durable on-disk shape. A thin wrapper (rather than a bare array)
/// keeps the store format extensible without a breaking migration, matching
/// `CalendarSnapshot`'s pattern.
public struct TaskSnapshot: Codable, Equatable, Sendable {
    public var items: [TaskItem]

    public init(items: [TaskItem] = []) {
        self.items = items
    }
}
