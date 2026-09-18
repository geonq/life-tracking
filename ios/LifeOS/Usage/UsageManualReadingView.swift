import SwiftUI
import Combine

/// Native entry surface for the reviewed manual Google AI Pro usage boundary.
/// It accepts only the two known windows and stores a canonical used percent;
/// no credentials or provider supplied URLs enter the app.
struct UsageManualReadingView: View {
    private struct Draft: Identifiable {
        let window: UsageManualReadingWindow
        var valueKind: UsageManualReadingValueKind
        var valueText: String
        var observedAt: Date
        var hasResetAt: Bool
        var resetAt: Date

        var id: String { window.rawValue }

        init(window: UsageManualReadingWindow, now: Date) {
            self.window = window
            self.valueKind = .used
            self.valueText = ""
            self.observedAt = now
            self.hasResetAt = false
            self.resetAt = now.addingTimeInterval(Double(window.durationMinutes) * 60)
        }

        init(reading: UsageManualReading, now: Date) {
            self.window = reading.window
            self.valueKind = .used
            self.valueText = String(format: "%.2f", reading.usedPercent)
            self.observedAt = reading.observedAt
            self.hasResetAt = reading.resetAt != nil
            self.resetAt = reading.resetAt ?? now.addingTimeInterval(Double(reading.window.durationMinutes) * 60)
        }
    }

    let currentReadings: [UsageManualReading]
    let now: Date
    let initialErrorMessage: String?
    let onSave: ([UsageManualReading]) -> Bool
    let onDelete: () -> Bool
    let clock: () -> Date

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [Draft]
    @State private var errorMessage: String?
    @State private var freshnessNow: Date

    init(
        currentReadings: [UsageManualReading] = [],
        now: Date = .now,
        initialErrorMessage: String? = nil,
        onSave: @escaping ([UsageManualReading]) -> Bool,
        onDelete: @escaping () -> Bool,
        clock: @escaping () -> Date = { Date.now }
    ) {
        self.currentReadings = currentReadings
        self.now = now
        self.initialErrorMessage = initialErrorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.clock = clock
        let readingsByWindow = currentReadings.reduce(
            into: [UsageManualReadingWindow: UsageManualReading]()
        ) { result, reading in
            guard result[reading.window].map({ $0.observedAt < reading.observedAt }) ?? true else {
                return
            }
            result[reading.window] = reading
        }
        _drafts = State(initialValue: UsageManualReadingWindow.allCases.map { window in
            if let reading = readingsByWindow[window] {
                return Draft(reading: reading, now: now)
            }
            return Draft(window: window, now: now)
        })
        _errorMessage = State(initialValue: initialErrorMessage)
        _freshnessNow = State(initialValue: now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                    introduction
                    ForEach($drafts) { $draft in
                        readingCard($draft)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .lifeOSTypography(.metadata, weight: .medium)
                            .foregroundStyle(LifeOSTokens.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("usage-manual-reading-error")
                    }
                    if !currentReadings.isEmpty || initialErrorMessage != nil {
                        Button(
                            currentReadings.isEmpty ? "Clear unavailable saved reading" : "Delete saved readings",
                            role: .destructive,
                            action: delete
                        )
                            .lifeOSTypography(.button, weight: .medium)
                            .accessibilityIdentifier("usage-manual-reading-delete")
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, LifeOSTokens.pageGutter)
                .padding(.vertical, LifeOSTokens.Space.lg)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("Google AI Pro usage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(drafts.allSatisfy { $0.valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            freshnessNow = date
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
            Text(currentReadings.isEmpty ? "Automatic usage isn’t available" : "Manually recorded")
                .lifeOSTypography(.sectionTitle, weight: .semibold)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text("Read the values from the official Gemini page and enter either percentage used or percentage remaining. Gemini API project usage is separate from Google AI Pro.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readingCard(_ draft: Binding<Draft>) -> some View {
        LifeOSCard(
            level: .surface,
            cornerRadius: LifeOSTokens.Radius.card,
            padding: LifeOSTokens.cardPadding
        ) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                        Text(draft.wrappedValue.window.label)
                            .lifeOSTypography(.cardTitle, weight: .semibold)
                            .foregroundStyle(LifeOSTokens.primaryText)
                        Text(statusText(for: draft.wrappedValue))
                            .lifeOSTypography(.metadata, weight: .medium)
                            .foregroundStyle(statusColor(for: draft.wrappedValue))
                    }
                    Spacer(minLength: LifeOSTokens.Space.sm)
                    Text("0–100")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }

                Picker("Value type", selection: draft.valueKind) {
                    ForEach(UsageManualReadingValueKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("usage-manual-reading-kind-\(draft.wrappedValue.window.rawValue)")

                HStack(spacing: LifeOSTokens.Space.xs) {
                    TextField("Percentage", text: draft.valueText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                    Text("%")
                        .lifeOSTypography(.label, weight: .medium)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }

                DatePicker(
                    "Observed",
                    selection: draft.observedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .lifeOSTypography(.label)

                Toggle("Record reset time", isOn: draft.hasResetAt)
                    .lifeOSTypography(.label)
                if draft.wrappedValue.hasResetAt {
                    DatePicker(
                        "Resets",
                        selection: draft.resetAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .lifeOSTypography(.label)
                }
            }
        }
        .accessibilityIdentifier("usage-manual-reading-\(draft.wrappedValue.window.rawValue)")
    }

    private func statusText(for draft: Draft) -> String {
        guard let reading = currentReadings.first(where: { $0.window == draft.window }) else {
            return "Not recorded"
        }
        switch reading.status(at: freshnessNow) {
        case .recorded:
            return "Manually recorded · \(reading.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        case .needsUpdating:
            return "Needs updating"
        }
    }

    private func statusColor(for draft: Draft) -> Color {
        guard let reading = currentReadings.first(where: { $0.window == draft.window }) else {
            return LifeOSTokens.tertiaryText
        }
        return reading.status(at: freshnessNow) == .needsUpdating
            ? LifeOSTokens.warningText
            : LifeOSTokens.successText
    }

    private func save() {
        guard let providerID = try? UsageProviderID(UsageManualReading.supportedProviderID) else {
            errorMessage = "The reviewed Gemini provider identifier is unavailable."
            return
        }

        do {
            let draftsWithValues = drafts.filter {
                !$0.valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !draftsWithValues.isEmpty else {
                errorMessage = "Enter a value for at least one usage window."
                return
            }
            let saveTime = clock()
            let readings = try draftsWithValues.map { draft in
                guard let value = parsePercent(draft.valueText) else {
                    throw UsageManualReadingStoreError.invalidValue
                }
                return try UsageManualReading(
                    providerID: providerID,
                    adapterID: UsageManualReading.supportedAdapterID,
                    window: draft.window,
                    value: value,
                    valueKind: draft.valueKind,
                    observedAt: draft.observedAt,
                    resetAt: draft.hasResetAt ? draft.resetAt : nil,
                    now: saveTime
                )
            }
            guard onSave(readings) else {
                errorMessage = "The manual reading could not be saved."
                return
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard onDelete() else {
            errorMessage = "The saved readings could not be deleted."
            return
        }
        dismiss()
    }

    private func parsePercent(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        return formatter.number(from: trimmed)?.doubleValue
    }
}
