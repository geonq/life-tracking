import Foundation
import SwiftUI

public extension CalendarProgress {
    var label: String {
        switch self {
        case .planned: "Planned"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    var color: Color {
        switch self {
        case .planned: .indigo
        case .inProgress: .orange
        case .blocked: .red
        case .done: .green
        }
    }
}

public struct CalendarItemRow: View {
    public let item: CalendarItem
    private static let time: Date.FormatStyle = .dateTime.hour().minute()

    public init(item: CalendarItem) { self.item = item }

    public var body: some View {
        HStack(spacing: 12) {
            Text(item.icon).font(.title3).accessibilityLabel("Icon \(item.icon)")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text("\(item.start, format: Self.time) – \(item.end, format: Self.time)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(item.status.color).frame(width: 9, height: 9)
                .accessibilityLabel(item.status.label)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.icon) \(item.title), \(item.status.label), \(item.start, format: Self.time) to \(item.end, format: Self.time)")
    }
}

public struct CalendarProgressPicker: View {
    @Binding public var progress: CalendarProgress
    public init(progress: Binding<CalendarProgress>) { _progress = progress }
    public var body: some View {
        Picker("Status", selection: $progress) {
            ForEach(CalendarProgress.allCases, id: \.self) { Text($0.label).tag($0) }
        }.pickerStyle(.segmented)
    }
}
