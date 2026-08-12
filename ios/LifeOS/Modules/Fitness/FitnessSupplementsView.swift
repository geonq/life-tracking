import SwiftUI

private extension SupplementOccurrenceState {
    var fitnessLabel: String {
        rawValue.capitalized
    }

    var fitnessColor: Color {
        switch self {
        case .planned: LifeOSTokens.accent
        case .taken: LifeOSTokens.success
        case .snoozed: LifeOSTokens.warning
        case .skipped, .missed: LifeOSTokens.tertiaryText
        }
    }
}

// MARK: - Supplement screen

struct FitnessSupplementsView: View {
    let selectedDate: Date
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: FitnessSupplementSession?
    @State private var sessionError: String?
    @State private var showingCalendarOverlay = false
    @State private var showingAddSheet = false
    @State private var notice: String?
    @State private var noticeIsError = false
    @StateObject private var permissionCoordinator: SupplementNotificationPermissionCoordinator

    init(
        supplements: [FitnessSupplement],
        selectedDate: Date,
        notificationAdapter: SupplementNotificationAdapter = SupplementNotificationAdapter()
    ) {
        self.selectedDate = selectedDate
        _permissionCoordinator = StateObject(
            wrappedValue: SupplementNotificationPermissionCoordinator(adapter: notificationAdapter)
        )
        do {
            _session = State(initialValue: try FitnessSupplementSession(supplements: supplements, selectedDate: selectedDate))
            _sessionError = State(initialValue: nil)
        } catch {
            _session = State(initialValue: nil)
            _sessionError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                FitnessSectionHeading(title: "Supplements", subtitle: "Your entered plan for \(selectedDate.fitnessDayLabel)")
                    .layoutPriority(1)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    HStack(spacing: 5) {
                        LifeOSIcon(.add).frame(width: 14, height: 14)
                        Text("Add")
                    }
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                }
                .buttonStyle(.borderedProminent)
                .tint(LifeOSTokens.accent)
            }

            FitnessSupplementsPrivacyCard()

            if let session {
                FitnessReminderStatusCard(
                    permissionState: permissionCoordinator.state,
                    schedulingState: permissionCoordinator.schedulingState,
                    hasActionableSchedule: session.snapshot.plans.contains { $0.reminderEnabled },
                    onRequestPermission: {
                        permissionCoordinator.requestPermission(snapshot: session.snapshot)
                    },
                    onRetry: {
                        permissionCoordinator.refresh(snapshot: session.snapshot)
                    }
                )

                if session.records.isEmpty {
                    FitnessCard {
                        FitnessEmptyRow(title: "No supplement records", detail: "Add a product, its label strength, your chosen dose, timing note, and local stock. LifeOS never fills an empty dose.", icon: .verified)
                    }
                } else {
                    ForEach(session.records) { supplement in
                        FitnessSupplementProductCard(
                            supplement: supplement,
                            stock: session.stock(for: supplement.id),
                            occurrenceState: session.state(for: supplement.id) ?? .planned,
                            onAction: { action in perform(action, for: supplement) }
                        )
                    }
                }
                FitnessSupplementAdherenceCard(supplements: session.records)
                FitnessSupplementTimelineCard(supplements: session.records, states: session.states, stock: session.stocks)

                Toggle("Show read-only Calendar overlay", isOn: $showingCalendarOverlay)
                    .font(LifeOSFont.inter(12, weight: .medium))
                if showingCalendarOverlay {
                    FitnessSupplementCalendarOverlay(supplements: session.records)
                }
            } else {
                FitnessCard {
                    FitnessEmptyRow(title: "Supplement session unavailable", detail: sessionError ?? "The entered supplement records could not be mapped into the validated session domain.", icon: .warning)
                }
            }

            if let notice {
                Text(notice)
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(noticeIsError ? LifeOSTokens.warning : LifeOSTokens.success)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FitnessCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Safety boundary")
                        .font(LifeOSFont.header(14))
                    Text("LifeOS records what you chose to take. It does not recommend a dose, validate interactions, or tell you what to do medically. Missed doses remain missed; there is never doubling advice or automatic dose changes.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            FitnessAddSupplementSheet { supplement in
                guard var current = session else {
                    noticeIsError = true
                    notice = sessionError ?? "Supplement session is unavailable."
                    return
                }
                do {
                    let now = Date.now
                    try current.add(supplement, now: now)
                    session = current
                    sessionError = nil
                    noticeIsError = false
                    notice = "\(supplement.name) added for this session only. It is not saved to persistent storage."
                    permissionCoordinator.reconcile(snapshot: current.snapshot, now: now)
                } catch {
                    noticeIsError = true
                    notice = error.localizedDescription
                }
            }
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            reconcileCurrentSession()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            reconcileCurrentSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSSystemTimeZoneDidChange)) { _ in
            reconcileCurrentSession()
        }
    }

    private func reconcileCurrentSession() {
        if let session {
            permissionCoordinator.refresh(snapshot: session.snapshot)
        } else {
            permissionCoordinator.refresh()
        }
    }

    private func perform(_ action: SupplementAction, for supplement: FitnessSupplement) {
        guard var current = session else {
            noticeIsError = true
            notice = sessionError ?? "Supplement session is unavailable."
            return
        }
        let now = Date.now
        do {
            let response = try current.apply(action, to: supplement.id, now: now)
            session = current
            permissionCoordinator.reconcile(snapshot: current.snapshot, now: now)
            noticeIsError = false
            switch action {
            case .taken:
                let changed = abs(response.inventoryDelta)
                if changed == 0 {
                    notice = "Taken recorded at \(now.fitnessTimeLabel). Stock was already zero; no inventory units were available."
                } else {
                    let suffix = changed == 1 ? "" : "s"
                    notice = "Taken recorded at \(now.fitnessTimeLabel). Stock changed by \(changed) configured inventory unit\(suffix)."
                }
            case .snooze:
                notice = "Snoozed locally. No dose was recorded and stock did not change."
            case .skip:
                notice = "Skip recorded locally. Stock did not change; a missed dose is never rescheduled as an extra dose."
            }
        } catch {
            noticeIsError = true
            notice = "Could not record \(action.rawValue): \(error.localizedDescription)"
        }
    }
}

private struct FitnessSupplementsPrivacyCard: View {
    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    LifeOSIcon(.security).foregroundStyle(LifeOSTokens.accent).frame(width: 17, height: 17)
                    Text("Private reminder copy")
                        .font(LifeOSFont.header(14))
                }
                Text("Lock-screen reminder copy is always redacted. Product name, dose, and timing remain in-app.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
    }
}

private struct FitnessReminderStatusCard: View {
    let permissionState: SupplementNotificationPermissionState
    let schedulingState: SupplementNotificationSchedulingState
    let hasActionableSchedule: Bool
    let onRequestPermission: () -> Void
    let onRetry: () -> Void

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Local reminders")
                        .font(LifeOSFont.header(15))
                    Spacer()
                    Text(statusLabel)
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(statusColor)
                    Text(schedulingLabel)
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(schedulingColor)
                }
                Text("Only explicit user-entered clock times are actionable schedules. Free-form timing notes stay visible as facts; Taken, Snooze, and Skip remain session occurrence actions.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                permissionAction
            }
        }
    }

    private var statusLabel: String {
        switch permissionState {
        case .checking: "Checking"
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        case .unknown: "Unknown"
        case .error: "Error"
        }
    }

    private var statusColor: Color {
        switch permissionState {
        case .checking, .notDetermined, .denied, .unknown, .error: LifeOSTokens.warning
        case .authorized, .provisional, .ephemeral: LifeOSTokens.success
        }
    }

    @ViewBuilder
    private var permissionAction: some View {
        if !hasActionableSchedule {
            VStack(alignment: .leading, spacing: 7) {
                Text("No clock schedule. Enter a timing value in HH:mm format first; free-form timing notes remain informational and do not use notifications.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                switch permissionState {
                case .denied:
                    Text("Notifications are denied. Enable LifeOS notifications in Settings before local reminders can be used.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                case .authorized, .provisional, .ephemeral:
                    Text("Alerts and sound are allowed. No explicit clock schedule is present, so no reminder is scheduled.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                case .checking, .notDetermined, .unknown, .error:
                    EmptyView()
                }
            }
        } else {
            switch permissionState {
            case .checking:
                Text("Checking current notification permission. No reminder is being scheduled.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            case .notDetermined:
                VStack(alignment: .leading, spacing: 7) {
                    Text("Notifications are not enabled yet. Allow alert and sound access for local reminders; this does not schedule a plan.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if SupplementNotificationPermissionStateMapper.canRequestPermission(
                        for: permissionState,
                        hasActionableSchedule: hasActionableSchedule
                    ) {
                        Button("Allow alert and sound", action: onRequestPermission)
                            .font(LifeOSFont.inter(12, weight: .semiBold))
                            .foregroundStyle(LifeOSTokens.accent)
                            .buttonStyle(.plain)
                    }
                }
            case .denied:
                Text("Notifications are denied. Enable LifeOS notifications in Settings before local reminders can be used.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            case .authorized:
                schedulingSummary
            case .provisional:
                schedulingSummary
            case .ephemeral:
                schedulingSummary
            case .unknown:
                VStack(alignment: .leading, spacing: 7) {
                    Text("Notification permission returned an unrecognized state. No reminder status can be confirmed.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Check again", action: onRetry)
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.accent)
                        .buttonStyle(.plain)
                }
            case .error:
                VStack(alignment: .leading, spacing: 7) {
                    Text("Could not read notification permission. Try again; no reminder status is confirmed.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Check again", action: onRetry)
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.accent)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var schedulingLabel: String {
        switch schedulingState {
        case .checking: "Checking"
        case .notScheduled: "Not scheduled"
        case .unchanged: "Unchanged"
        case .reconciled: "Reconciled"
        case .partial: "Partial"
        case .error: "Error"
        }
    }

    private var schedulingColor: Color {
        switch schedulingState {
        case .checking, .notScheduled, .partial, .error: LifeOSTokens.warning
        case .unchanged, .reconciled: LifeOSTokens.success
        }
    }

    @ViewBuilder
    private var schedulingSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch schedulingState {
            case .checking:
                Text("Checking local pending requests. No delivery is confirmed.")
            case .notScheduled:
                Text("No reminder is scheduled yet. Pending-request state is not delivery confirmation.")
            case .unchanged(let pendingCount):
                Text("Pending requests unchanged: \(pendingCount). Pending is not delivery confirmation.")
            case .reconciled(let addedCount, let removedCount, let pendingCount):
                Text("Pending requests reconciled: \(addedCount) added, \(removedCount) removed, \(pendingCount) pending. Delivery is not confirmed.")
            case .partial(let addedCount, let failedCount, let pendingCount):
                Text("Some pending requests were reconciled: \(addedCount) added, \(failedCount) could not be added, \(pendingCount) pending. Delivery is not confirmed.")
                Button("Check again", action: onRetry)
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.accent)
                    .buttonStyle(.plain)
            case .error:
                Text("Could not reconcile local reminders. Try again; no delivery is confirmed.")
                Button("Check again", action: onRetry)
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.accent)
                    .buttonStyle(.plain)
            }
        }
        .font(LifeOSFont.caption(10))
        .foregroundStyle(LifeOSTokens.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FitnessSupplementProductCard: View {
    let supplement: FitnessSupplement
    let stock: Int
    let occurrenceState: SupplementOccurrenceState
    let onAction: (SupplementAction) -> Void

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LifeOSTokens.accent.opacity(0.13))
                        .frame(width: 40, height: 40)
                        .overlay(LifeOSIcon(.verified).foregroundStyle(LifeOSTokens.accent).frame(width: 19, height: 19))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(supplement.name)
                            .font(LifeOSFont.header(15))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(supplement.brand) · \(supplement.form.rawValue) · \(supplement.strength)")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(doseLabel)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(supplement.userDose == nil ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 5)
                    FitnessOccurrencePill(state: occurrenceState)
                }
                HStack(spacing: 8) {
                    LifeOSIcon(.calendar).frame(width: 14, height: 14).foregroundStyle(LifeOSTokens.accent)
                    Text("\(supplement.timing) · \(supplement.timeZoneIdentifier)")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FitnessInventoryRow(supplement: supplement, stock: stock)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 7)], spacing: 7) {
                    Button("Taken") { onAction(.taken) }
                        .buttonStyle(.borderedProminent)
                        .tint(LifeOSTokens.success)
                        .disabled(occurrenceState == .taken || occurrenceState == .skipped)
                    Button("Snooze") { onAction(.snooze) }
                        .buttonStyle(.bordered)
                        .disabled(occurrenceState == .taken || occurrenceState == .skipped)
                    Button("Skip") { onAction(.skip) }
                        .buttonStyle(.bordered)
                        .disabled(occurrenceState == .taken)
                }
                Text("Only a confirmed Taken action decrements stock by the configured inventory dose (\(supplement.inventoryUnitsPerDose) \(supplement.servingUnit)). Snooze and Skip never change inventory.")
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("supplement-\(supplement.id)")
    }

    private var doseLabel: String {
        let dose = supplement.userDose?.isEmpty == false ? supplement.userDose! : "Not entered"
        return "Your dose: \(dose) · \(supplement.servingUnit)"
    }
}

private struct FitnessOccurrencePill: View {
    let state: SupplementOccurrenceState

    var body: some View {
        Text(state.fitnessLabel)
            .font(LifeOSFont.inter(10, weight: .semiBold))
            .foregroundStyle(state.fitnessColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(state.fitnessColor.opacity(0.12), in: Capsule())
    }
}

private struct FitnessInventoryRow: View {
    let supplement: FitnessSupplement
    let stock: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stock").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                    Text("\(stock) \(unitLabel)").font(LifeOSFont.inter(14, weight: .semiBold)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(stock <= supplement.reorderThreshold ? "Low stock" : "Estimated remaining")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(stock <= supplement.reorderThreshold ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                    Text(remainingLabel)
                        .font(LifeOSFont.inter(11, weight: .semiBold))
                        .foregroundStyle(stock <= supplement.reorderThreshold ? LifeOSTokens.warning : .primary)
                        .multilineTextAlignment(.trailing)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(expiryLabel)
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(isExpired ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                Text(refillLabel)
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(stock <= supplement.reorderThreshold ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
            }
        }
        .padding(10)
        .background(LifeOSTokens.screenCanvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(stock <= supplement.reorderThreshold ? LifeOSTokens.warning.opacity(0.42) : LifeOSTokens.quietBorder, lineWidth: 0.75))
    }

    private var remainingLabel: String {
        let dosesPerWeek = max(1, supplement.scheduledDays.count) * supplement.inventoryUnitsPerDose
        guard stock > 0 else { return "Run-out now" }
        let days = Int(Double(stock) / Double(dosesPerWeek) * 7.0)
        if days <= 0 { return "Run-out soon" }
        return "~\(days) days · threshold \(supplement.reorderThreshold)"
    }

    private var unitLabel: String {
        let unit = supplement.servingUnit
        guard stock != 1 else { return unit }
        if unit.lowercased() == "softgel" { return "softgels" }
        return unit.hasSuffix("s") ? unit : "\(unit)s"
    }

    private var isExpired: Bool {
        guard let expiryDate = supplement.expiryDate else { return false }
        return expiryDate < .now
    }

    private var expiryLabel: String {
        guard let expiryDate = supplement.expiryDate else { return "Expiry not entered" }
        if expiryDate < .now { return "Expired \(expiryDate.formatted(.dateTime.month(.abbreviated).day().year()))" }
        return "Expires \(expiryDate.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private var refillLabel: String {
        if stock <= supplement.reorderThreshold {
            guard let leadTime = supplement.expectedLeadTimeDays else { return "Refill needed" }
            return "Refill · \(leadTime)-day lead"
        }
        guard let leadTime = supplement.expectedLeadTimeDays else { return "Refill threshold \(supplement.reorderThreshold)" }
        return "Lead time \(leadTime) days"
    }
}

private struct FitnessSupplementAdherenceCard: View {
    let supplements: [FitnessSupplement]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Adherence")
                        .font(LifeOSFont.header(15))
                    Spacer()
                    Text("Confirmed occurrences")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                    AdherenceColumn(label: "7 days", value: average(\.adherence7))
                    AdherenceColumn(label: "30 days", value: average(\.adherence30))
                    AdherenceColumn(label: "90 days", value: average(\.adherence90))
                }
                Text("Descriptive percentages only. They do not represent a health outcome and do not imply that adherence caused a change in sleep, HRV, stress, or any other metric.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func average(_ keyPath: KeyPath<FitnessSupplement, Double?>) -> String {
        let values = supplements.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return "Not available" }
        return "\(Int((values.reduce(0, +) / Double(values.count) * 100).rounded()))%"
    }
}

private struct AdherenceColumn: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .font(LifeOSFont.spaceGrotesk(21, weight: .bold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FitnessSupplementTimelineCard: View {
    let supplements: [FitnessSupplement]
    let states: [String: SupplementOccurrenceState]
    let stock: [String: Int]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Daily timeline")
                        .font(LifeOSFont.header(15))
                    Spacer()
                    Text("Local status")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if supplements.isEmpty {
                    FitnessEmptyRow(title: "No scheduled doses", detail: "Add a user-entered schedule to see its local timeline.", icon: .calendar)
                } else {
                    ForEach(supplements) { supplement in
                        HStack(spacing: 9) {
                            Rectangle()
                                .fill((states[supplement.id]?.fitnessColor ?? LifeOSTokens.accent).opacity(0.8))
                                .frame(width: 2, height: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(supplement.timing)
                                    .font(LifeOSFont.caption(10))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(supplement.name)
                                    .font(LifeOSFont.inter(12, weight: .semiBold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(timelineLabel(for: supplement))
                                    .font(LifeOSFont.caption(10))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .layoutPriority(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func timelineLabel(for supplement: FitnessSupplement) -> String {
        let state = states[supplement.id]?.fitnessLabel ?? "Planned"
        let units = stock[supplement.id] ?? supplement.stockUnits
        return "\(state) · stock \(units)"
    }
}

private struct FitnessSupplementCalendarOverlay: View {
    let supplements: [FitnessSupplement]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    HStack(spacing: 7) {
                        LifeOSIcon(.calendar).foregroundStyle(LifeOSTokens.accent).frame(width: 16, height: 16)
                        Text("Calendar overlay")
                            .font(LifeOSFont.header(14))
                    }
                    Spacer()
                    Text("Read-only")
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.warning)
                }
                Text("This is a projection of the supplement schedule. Supplements remain the source of truth; editing an event should return to this screen.")
                    .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                ForEach(supplements) { supplement in
                    HStack {
                        Text(supplement.timing).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                        Text(supplement.name).font(LifeOSFont.inter(12, weight: .medium))
                        Spacer()
                        Text("Planned").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.accent)
                    }
                }
            }
        }
    }
}

private struct FitnessAddSupplementSheet: View {
    let onAdd: (FitnessSupplement) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var form = FitnessSupplement.Form.capsule
    @State private var strength = ""
    @State private var userDose = ""
    @State private var timing = "Before lunch"
    @State private var stock = ""
    @State private var reorderThreshold = ""
    @State private var expectedLeadTimeDays = ""
    @State private var tracksExpiry = false
    @State private var expiryDate = Date.now
    @State private var inventoryUnitsPerDose = "1"
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text("User-entered product")
                        .font(LifeOSFont.headerLarge(22))
                    Text("LifeOS stores the product label and your chosen dose as facts. Leave the dose blank rather than accepting a generic recommendation.")
                        .font(LifeOSFont.body(12)).foregroundStyle(LifeOSTokens.tertiaryText)
                    FitnessCard {
                        VStack(spacing: 11) {
                            FitnessSupplementField(title: "Product name", text: $name)
                            Picker("Form", selection: $form) {
                                ForEach(FitnessSupplement.Form.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .font(LifeOSFont.inter(13, weight: .medium))
                            FitnessSupplementField(title: "Label strength", text: $strength)
                            FitnessSupplementField(title: "Your dose", text: $userDose)
                            FitnessSupplementField(title: "Inventory units / dose", text: $inventoryUnitsPerDose, numeric: true)
                            FitnessSupplementField(title: "Timing (HH:mm or note)", text: $timing)
                            Text("Use HH:mm (for example 08:30) to make a clock schedule actionable. Any other text stays a free-form note and will not request notifications.")
                                .font(LifeOSFont.caption(9))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            FitnessSupplementField(title: "Stock units", text: $stock)
                            FitnessSupplementField(title: "Refill threshold", text: $reorderThreshold, numeric: true)
                            FitnessSupplementField(title: "Supplier lead time (days)", text: $expectedLeadTimeDays, numeric: true)
                            Toggle("Track expiry date", isOn: $tracksExpiry)
                            if tracksExpiry {
                                DatePicker("Expiry date", selection: $expiryDate, displayedComponents: .date)
                            }
                        }
                    }
                    Text("Reminders use the local timezone, and Taken/Snooze/Skip are separate from this product record.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                    Text("Add is local to this open session. Nothing entered here is written to persistent storage.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if let validationMessage {
                        Text(validationMessage)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.warning)
                    }
                    HStack {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Add locally") { addLocally() }
                            .buttonStyle(.borderedProminent)
                            .tint(LifeOSTokens.accent)
                    }
                }
                .padding(16)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("Add supplement")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }

    private func addLocally() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a product name to add a local record."
            return
        }
        let parsedStock = max(0, Int(stock.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let parsedThreshold = max(0, Int(reorderThreshold.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let parsedLeadTime = Int(expectedLeadTimeDays.trimmingCharacters(in: .whitespacesAndNewlines)).map { max(0, $0) }
        let parsedUnits = max(1, Int(inventoryUnitsPerDose.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1)
        let supplement = FitnessSupplement(
            id: "local-\(UUID().uuidString)",
            name: trimmedName,
            brand: "User-entered product",
            form: form,
            strength: strength.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not entered" : strength,
            servingUnit: form.inventoryUnit,
            userDose: userDose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userDose,
            inventoryUnitsPerDose: parsedUnits,
            timing: timing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Timing not entered" : timing,
            reminderStatus: .localOnly,
            stockUnits: parsedStock,
            reorderThreshold: parsedThreshold,
            expectedLeadTimeDays: parsedLeadTime,
            expiryDate: tracksExpiry ? expiryDate : nil
        )
        onAdd(supplement)
        dismiss()
    }
}

private struct FitnessSupplementField: View {
    let title: String
    @Binding var text: String
    var numeric = false

    var body: some View {
        HStack {
            Text(title).font(LifeOSFont.caption(11)).foregroundStyle(LifeOSTokens.tertiaryText)
            Spacer()
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .font(LifeOSFont.inter(13, weight: .medium))
#if os(iOS)
                .keyboardType(numeric ? .numbersAndPunctuation : .default)
#endif
        }
    }
}
