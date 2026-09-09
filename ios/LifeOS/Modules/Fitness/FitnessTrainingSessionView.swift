import Foundation
import SwiftUI

private enum FitnessTrainingNumericField: Hashable {
    case targetRepetitions(exerciseID: TrainingRecordID, setID: TrainingRecordID)
    case targetLoad(exerciseID: TrainingRecordID, setID: TrainingRecordID)
    case actualRepetitions(exerciseID: TrainingRecordID, setID: TrainingRecordID)
    case actualLoad(exerciseID: TrainingRecordID, setID: TrainingRecordID)
}

public enum FitnessTrainingTerminalState: Equatable, Sendable {
    case completed(TrainingSession)
    case discarded(TrainingSession)
    case deleted

    var latestSession: TrainingSession? {
        switch self {
        case .completed(let session), .discarded(let session): session
        case .deleted: nil
        }
    }

    var message: String {
        switch self {
        case .completed:
            "This session was completed elsewhere while this editor had unsaved changes. Your draft is still preserved in this editor."
        case .discarded:
            "This session was discarded elsewhere while this editor had unsaved changes. Your draft is still preserved in this editor."
        case .deleted:
            "This session was deleted elsewhere while this editor had unsaved changes. Your draft is still preserved in this editor."
        }
    }

    var reloadLabel: String {
        switch self {
        case .completed: "Reload completed session"
        case .discarded: "Reload discarded session"
        case .deleted: "Close and drop draft"
        }
    }
}

/// Editor and controls for one local LifeOS training session.
///
/// The view keeps text input in a draft and sends one immutable session to its
/// owner when the user explicitly saves, pauses, resumes, or finishes. This
/// avoids a store mutation for every keystroke while still making every set
/// editable and keyboard-safe on both Apple platforms.
public struct FitnessTrainingSessionView: View {
    private let incomingSession: TrainingSession
    private let isProcessing: Bool
    private let onSave: (TrainingSession) async -> FitnessTrainingActionResult
    private let onPause: (TrainingSession) async -> FitnessTrainingActionResult
    private let onResume: (TrainingSession) async -> FitnessTrainingActionResult
    private let onFinish: (TrainingSession) async -> FitnessTrainingActionResult
    private let onDiscard: (TrainingSession) async -> FitnessTrainingActionResult
    private let externalTerminalState: FitnessTrainingTerminalState?
    private let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var baseSession: TrainingSession
    @State private var exerciseDrafts: [TrainingExerciseDraft]
    @State private var notesText: String
    @State private var validationMessage: String?
    @State private var isDirty = false
    @State private var localActionPending = false
    @State private var showFinishConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showDismissConfirmation = false
    @State private var conflictSession: TrainingSession?
    @State private var terminalConflict: FitnessTrainingTerminalState?
    @State private var deferredTerminalConflict: FitnessTrainingTerminalState?
    @State private var deferredIncomingSession: TrainingSession?
    @State private var draftBaselineSignature: String
    @FocusState private var focusedNumericField: FitnessTrainingNumericField?

    public init(
        session: TrainingSession,
        isProcessing: Bool = false,
        onSave: @escaping (TrainingSession) async -> FitnessTrainingActionResult,
        onPause: @escaping (TrainingSession) async -> FitnessTrainingActionResult,
        onResume: @escaping (TrainingSession) async -> FitnessTrainingActionResult,
        onFinish: @escaping (TrainingSession) async -> FitnessTrainingActionResult,
        onDiscard: @escaping (TrainingSession) async -> FitnessTrainingActionResult,
        externalTerminalState: FitnessTrainingTerminalState? = nil,
        onFinished: @escaping () -> Void = {}
    ) {
        self.incomingSession = session
        self.isProcessing = isProcessing
        self.onSave = onSave
        self.onPause = onPause
        self.onResume = onResume
        self.onFinish = onFinish
        self.onDiscard = onDiscard
        self.externalTerminalState = externalTerminalState
        self.onFinished = onFinished
        _baseSession = State(initialValue: session)
        let initialExercises = session.exercises.map(TrainingExerciseDraft.init)
        _exerciseDrafts = State(initialValue: initialExercises)
        _notesText = State(initialValue: session.notes ?? "")
        _draftBaselineSignature = State(initialValue: Self.draftSignature(exercises: initialExercises, notes: session.notes ?? ""))
    }

    public var body: some View {
        sessionContent
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .onAppear {
                receiveExternalTerminalState(externalTerminalState)
            }
            .onChange(of: externalTerminalState) { _, newState in
                receiveExternalTerminalState(newState)
            }
            .onChange(of: incomingSession) { _, newSession in
                handleIncomingSession(newSession)
            }
            .confirmationDialog(
                "Finish this session?",
                isPresented: $showFinishConfirmation,
                titleVisibility: .visible
            ) {
                Button("Finish session", role: .destructive) { finish() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(finishConfirmationMessage)
            }
            .confirmationDialog(
                "Discard this session?",
                isPresented: $showDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard session", role: .destructive) {
                    discardSession()
                }
                Button("Keep session", role: .cancel) {}
            } message: {
                Text("Discarding removes this unfinished session from the active workflow. Completed history is not affected.")
            }
            .confirmationDialog(
                "Unsaved changes",
                isPresented: $showDismissConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your set values and notes have not been saved. Keep editing or discard those changes.")
            }
            .confirmationDialog(
                "Session changed",
                isPresented: Binding(
                    get: { conflictSession != nil },
                    set: { if !$0 { conflictSession = nil } }
                ),
                presenting: conflictSession
            ) { latest in
                Button("Reload latest") {
                    adoptSession(latest)
                }
                Button("Keep draft and reapply") {
                    reapplyDraft(to: latest)
                }
                Button("Keep editing", role: .cancel) {}
            } message: { _ in
                Text("Another revision was saved. Reload it, or keep this draft and explicitly reapply it to the newer revision.")
            }
            .interactiveDismissDisabled(isDirty || localActionPending || terminalConflict != nil)
            .accessibilityIdentifier("fitness-training-session")
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch session.status {
        case .active, .paused:
            editorBody
        case .completed:
            FitnessTrainingCompletionView(session: session) {
                dismiss()
            }
        case .discarded:
            discardedSessionBody
        }
    }

    private var editorBody: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: LifeOSTokens.Space.lg, bottomPadding: 96) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxl) {
                    header
                    progressCard

                    if let terminalConflict {
                        terminalConflictCard(terminalConflict)
                        terminalDraftPreview
                    } else {
                        if baseSession.status == .paused {
                            restNotice
                        }

                        if exerciseDrafts.isEmpty {
                            emptyExerciseState
                                .disabled(isBusy)
                        } else {
                            exerciseEditor
                                .disabled(isBusy)
                        }

                        notesEditor
                            .disabled(isBusy)
                        actionBar
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    moveFocus(previous: true)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous numeric field")
                .disabled(previousNumericField == nil)

                Button {
                    moveFocus(previous: false)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next numeric field")
                .disabled(nextNumericField == nil)

                Spacer()

                Button("Done") {
                    focusedNumericField = nil
                }
            }
        }
        #endif
        .onDisappear {
            focusedNumericField = nil
        }
    }

    private var numericFieldOrder: [FitnessTrainingNumericField] {
        exerciseDrafts.flatMap { exercise in
            exercise.sets.flatMap { set in
                [
                    .targetRepetitions(exerciseID: exercise.id, setID: set.id),
                    .targetLoad(exerciseID: exercise.id, setID: set.id),
                    .actualRepetitions(exerciseID: exercise.id, setID: set.id),
                    .actualLoad(exerciseID: exercise.id, setID: set.id)
                ]
            }
        }
    }

    private var previousNumericField: FitnessTrainingNumericField? {
        guard let focusedNumericField,
              let index = numericFieldOrder.firstIndex(of: focusedNumericField),
              index > 0 else { return nil }
        return numericFieldOrder[index - 1]
    }

    private var nextNumericField: FitnessTrainingNumericField? {
        guard let focusedNumericField,
              let index = numericFieldOrder.firstIndex(of: focusedNumericField),
              index + 1 < numericFieldOrder.count else { return nil }
        return numericFieldOrder[index + 1]
    }

    private func moveFocus(previous: Bool) {
        focusedNumericField = previous ? previousNumericField : nextNumericField
    }

    private func focus(after field: FitnessTrainingNumericField) {
        guard let index = numericFieldOrder.firstIndex(of: field) else {
            focusedNumericField = nil
            return
        }
        let nextIndex = index + 1
        focusedNumericField = nextIndex < numericFieldOrder.count ? numericFieldOrder[nextIndex] : nil
    }

    private var discardedSessionBody: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            Image(systemName: "trash.circle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(LifeOSTokens.warning)
            Text("Session discarded")
                .lifeOSTypography(.pageTitle)
                .foregroundStyle(LifeOSTokens.primaryText)
            Text("The durable session is no longer part of the active workflow.")
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.secondaryText)
            Button("Close") { dismiss() }
                .buttonStyle(LifeOSButtonStyle(.secondary))
        }
        .padding(LifeOSTokens.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var session: TrainingSession { baseSession }

    private var isBusy: Bool { isProcessing || localActionPending }

    private var terminalDraftPreview: some View {
        LifeOSCard(level: .surface, padding: LifeOSTokens.Space.lg) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                Label("Draft preview · read-only", systemImage: "doc.on.doc")
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text("Your local values remain available to inspect and copy. Resolve the external change before leaving this editor.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(terminalDraftText)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LifeOSTokens.Space.md)
                    .background(LifeOSTokens.canvas, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
            }
        }
        .accessibilityIdentifier("fitness-training-terminal-draft-preview")
    }

    private var terminalDraftText: String {
        var lines = [session.title, "Status: draft kept locally"]
        for (exerciseIndex, exercise) in exerciseDrafts.enumerated() {
            let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(exerciseIndex + 1). \(name.isEmpty ? "Unnamed exercise" : name)")
            for (setIndex, set) in exercise.sets.enumerated() {
                let target = [set.targetRepetitions, set.targetLoad].filter { !$0.isEmpty }.joined(separator: " · ")
                let actual = [set.actualRepetitions, set.actualLoad].filter { !$0.isEmpty }.joined(separator: " · ")
                let targetText = target.isEmpty ? "—" : target
                let actualText = actual.isEmpty ? "—" : actual
                lines.append("  Set \(setIndex + 1) · target \(targetText) · actual \(actualText) · \(set.isCompleted ? "complete" : "open")")
            }
            if let note = exercise.notes.trimmedOrNil {
                lines.append("  Note: \(note)")
            }
        }
        if let notes = notesText.trimmedOrNil {
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            HStack(alignment: .top, spacing: LifeOSTokens.Space.md) {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    Text(session.title)
                        .lifeOSTypography(.pageTitle)
                        .foregroundStyle(LifeOSTokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(session.activityKind.displayName)
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }
                Spacer(minLength: LifeOSTokens.Space.sm)
                LifeOSStatusPill(
                    label: session.status.displayName,
                    tone: session.status == .paused ? .warning : .success,
                    systemImage: session.status == .paused ? "pause.fill" : "figure.strengthtraining.traditional"
                )
                Button("Close") {
                    requestDismiss()
                }
                .buttonStyle(LifeOSButtonStyle(.secondary))
                .disabled(isBusy)
            }

            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.md) {
                Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                Spacer(minLength: 0)
                Text("Revision \(session.revision)")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .monospacedDigit()
            }
        }
    }

    private var progressCard: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { context in
            progressCard(at: context.date)
        }
    }

    private func progressCard(at now: Date) -> some View {
        let completedSets = exerciseDrafts.reduce(0) { partialResult, exercise in
            partialResult + exercise.sets.filter(\.isCompleted).count
        }
        let totalSets = exerciseDrafts.reduce(0) { partialResult, exercise in
            partialResult + exercise.sets.count
        }

        return LifeOSCard(level: .raised, cornerRadius: LifeOSTokens.Radius.hero, padding: LifeOSTokens.Space.xl) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: LifeOSTokens.Space.xxl) {
                    progressMetric(value: "\(completedSets)/\(totalSets)", label: "Sets complete")
                    progressMetric(value: durationText(at: now), label: "Active time")
                    progressMetric(value: "\(exerciseDrafts.count)", label: "Exercises")
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                    HStack(spacing: LifeOSTokens.Space.xl) {
                        progressMetric(value: "\(completedSets)/\(totalSets)", label: "Sets complete")
                        progressMetric(value: durationText(at: now), label: "Active time")
                    }
                    progressMetric(value: "\(exerciseDrafts.count)", label: "Exercises")
                }
            }
        }
    }

    private func progressMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(value)
                .lifeOSTypography(.metricCompact)
                .foregroundStyle(LifeOSTokens.primaryText)
                .monospacedDigit()
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func durationText(at now: Date) -> String {
        let end = session.endedAt ?? now
        var seconds = max(0, end.timeIntervalSince(session.startedAt))
        for pause in session.pauses {
            let pauseEnd = pause.endedAt ?? (session.status == .paused ? now : pause.startedAt)
            seconds -= max(0, pauseEnd.timeIntervalSince(pause.startedAt))
        }
        return formatClock(seconds)
    }

    private var restNotice: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { context in
            restNotice(at: context.date)
        }
    }

    private func restNotice(at now: Date) -> some View {
        let restSeconds = session.pauses.last(where: { $0.endedAt == nil }).map {
            max(0, now.timeIntervalSince($0.startedAt))
        } ?? 0
        return LifeOSCard(level: .surface, padding: LifeOSTokens.Space.md) {
            HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(LifeOSTokens.warning)
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                    Text("Rest is active")
                        .lifeOSTypography(.cardTitle)
                        .foregroundStyle(LifeOSTokens.primaryText)
                    Text("Rest duration \(formatClock(restSeconds)). Your draft stays local while the session is paused; no sets or load are invented.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyExerciseState: some View {
        LifeOSCard(level: .surface) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LifeOSTokens.Module.fitness)
                Text("Add an exercise to this session")
                    .lifeOSTypography(.sectionTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(completionGuidance)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add custom exercise") { addExercise() }
                    .buttonStyle(LifeOSButtonStyle(.secondary))
            }
        }
    }

    private var completionGuidance: String {
        if session.activityKind == .strength {
            return "A finished strength session needs at least one completed set. Add an exercise below, then enter its actual repetitions and load."
        }
        return "Timed \(session.activityKind.displayName.lowercased()) sessions can finish without sets. Add an exercise only when you want to record repetitions or load; LifeOS never invents either value."
    }

    private var finishConfirmationMessage: String {
        if session.activityKind == .strength {
            return "LifeOS will close the session and keep its local sets, repetitions, and load in history."
        }
        return "LifeOS will close this timed \(session.activityKind.displayName.lowercased()) session. Any sets you entered are kept, and missing repetitions or load remain missing."
    }

    private var exerciseEditor: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
            LifeOSSectionHeader(
                title: "Exercises",
                subtitle: "Targets are your plan. Actual values are the local record."
            )

            ForEach(exerciseDrafts.indices, id: \.self) { index in
                let exerciseID = exerciseDrafts[index].id
                FitnessTrainingExerciseEditorCard(
                    exercise: $exerciseDrafts[index],
                    focusedField: $focusedNumericField,
                    repetitionLabel: session.activityKind == .cardio ? "Intervals" : "Repetitions",
                    onAddSet: { addSet(to: exerciseID) },
                    onDelete: { deleteExercise(id: exerciseID) },
                    onChange: markDirty,
                    onSubmit: focus(after:)
                )
            }

            Button {
                addExercise()
            } label: {
                Label("Add custom exercise", systemImage: "plus")
            }
            .buttonStyle(LifeOSButtonStyle(.secondary))
        }
    }

    private var notesEditor: some View {
        LifeOSCard(level: .surface) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                Text("Session note")
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.primaryText)
                TextField("Optional note", text: $notesText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: notesText) { _, _ in markDirty() }
                Text("Stored with this local session only. Wearable evidence remains read-only.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LifeOSTokens.Space.sm) {
                saveButton
                stateButton
                finishButton
                discardButton
            }
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                saveButton
                HStack(spacing: LifeOSTokens.Space.sm) {
                    stateButton
                    finishButton
                    discardButton
                }
            }
        }
        .disabled(isBusy)
    }

    private var saveButton: some View {
        Button {
            saveDraft()
        } label: {
            Label("Save changes", systemImage: "checkmark")
        }
        .buttonStyle(LifeOSButtonStyle(.secondary))
        .disabled(!isDirty)
        .accessibilityIdentifier("fitness-training-save")
    }

    private var stateButton: some View {
        Button {
            baseSession.status == .paused ? resume() : pause()
        } label: {
            Label(
                baseSession.status == .paused ? "Resume" : "Pause",
                systemImage: baseSession.status == .paused ? "play.fill" : "pause.fill"
            )
        }
        .buttonStyle(LifeOSButtonStyle(.secondary))
        .accessibilityIdentifier(baseSession.status == .paused ? "fitness-training-resume" : "fitness-training-pause")
    }

    private var finishButton: some View {
        Button {
            showFinishConfirmation = true
        } label: {
            Label("Finish", systemImage: "flag.checkered")
        }
        .buttonStyle(LifeOSButtonStyle(.primary))
        .accessibilityIdentifier("fitness-training-finish")
    }

    private var discardButton: some View {
        Button("Discard", role: .destructive) {
            showDiscardConfirmation = true
        }
        .buttonStyle(LifeOSButtonStyle(.destructive))
        .accessibilityIdentifier("fitness-training-discard")
    }

    private func saveDraft() {
        guard let draft = makeDraft() else { return }
        runAction(with: draft, action: onSave)
    }

    private func pause() {
        guard let draft = makeDraft() else { return }
        runAction(with: draft, action: onPause)
    }

    private func resume() {
        guard let draft = makeDraft() else { return }
        runAction(with: draft, action: onResume)
    }

    private func finish() {
        guard let draft = makeDraft() else { return }
        runAction(with: draft, action: onFinish, onPersisted: onFinished)
    }

    private func discardSession() {
        guard !isBusy else { return }
        localActionPending = true
        Task { @MainActor in
            let result = await onDiscard(baseSession)
            localActionPending = false
            if result.didPersist {
                dismiss()
            } else {
                validationMessage = result.message ?? "LifeOS could not discard this session. The editor is still open; try again."
            }
        }
    }

    private func runAction(
        with draft: TrainingSession,
        action: @escaping (TrainingSession) async -> FitnessTrainingActionResult,
        onPersisted: (() -> Void)? = nil
    ) {
        guard !isBusy else { return }
        let submittedSignature = currentDraftSignature
        localActionPending = true
        validationMessage = nil
        Task { @MainActor in
            let result = await action(draft)
            let draftStillMatchesSubmission = currentDraftSignature == submittedSignature
            if result.didPersist {
                if draftStillMatchesSubmission {
                    isDirty = false
                    validationMessage = result.message
                } else {
                    // Controls are disabled while an action is in flight,
                    // but this guard also protects programmatic changes and
                    // future controls from losing a newer local draft.
                    isDirty = true
                    validationMessage = "Saved the submitted revision. Your newer draft is still here; save it again when ready."
                }
                if let latest = newestIncomingSession() {
                    if draftStillMatchesSubmission {
                        adoptSession(latest)
                    } else {
                        advanceBaseKeepingDraft(to: latest)
                    }
                }
                onPersisted?()
            } else {
                validationMessage = result.message ?? "LifeOS could not save this local training change. Your draft is still here; try again."
                if let latest = newestIncomingSession() {
                    conflictSession = latest
                }
            }
            localActionPending = false
            if let deferredTerminalConflict {
                self.deferredTerminalConflict = nil
                receiveExternalTerminalState(deferredTerminalConflict)
            }
        }
    }

    private func requestDismiss() {
        guard !isBusy else { return }
        if terminalConflict != nil {
            validationMessage = "Resolve the terminal session change before closing this editor. Your draft is still preserved."
            return
        }
        if isDirty {
            showDismissConfirmation = true
        } else {
            dismiss()
        }
    }

    private func markDirty() {
        isDirty = currentDraftSignature != draftBaselineSignature
        validationMessage = nil
    }

    private func newestIncomingSession() -> TrainingSession? {
        [deferredIncomingSession, incomingSession]
            .compactMap { $0 }
            .filter {
                $0.id == baseSession.id &&
                ($0.status == .active || $0.status == .paused) &&
                ($0.revision > baseSession.revision || $0.status != baseSession.status)
            }
            .max {
                if $0.revision != $1.revision { return $0.revision < $1.revision }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.rawValue < $1.id.rawValue
            }
    }

    private func adoptSession(_ newSession: TrainingSession) {
        guard newSession.id == baseSession.id else { return }
        baseSession = newSession
        exerciseDrafts = newSession.exercises.map(TrainingExerciseDraft.init)
        notesText = newSession.notes ?? ""
        draftBaselineSignature = Self.draftSignature(exercises: exerciseDrafts, notes: notesText)
        isDirty = false
        conflictSession = nil
        deferredIncomingSession = nil
        validationMessage = nil
    }

    private func handleIncomingSession(_ newSession: TrainingSession) {
        guard newSession.id == baseSession.id,
              newSession.revision > baseSession.revision || newSession.status != baseSession.status else {
            return
        }
        if newSession.status == .completed || newSession.status == .discarded {
            receiveExternalTerminalState(
                newSession.status == .completed ? .completed(newSession) : .discarded(newSession)
            )
            return
        }
        if localActionPending {
            deferredIncomingSession = newSession
        } else if isDirty {
            conflictSession = newSession
            validationMessage = "Another active revision arrived. Reload it, or keep this draft and explicitly reapply it."
        } else {
            adoptSession(newSession)
        }
    }

    private func receiveExternalTerminalState(_ state: FitnessTrainingTerminalState?) {
        guard let state else { return }
        if localActionPending {
            deferredTerminalConflict = state
            return
        }
        terminalConflict = state
        validationMessage = state.message
    }

    @ViewBuilder
    private func terminalConflictCard(_ state: FitnessTrainingTerminalState) -> some View {
        LifeOSCard(level: .surface, padding: LifeOSTokens.Space.lg) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                Label("Session changed outside this editor", systemImage: "exclamationmark.triangle")
                    .lifeOSTypography(.cardTitle)
                    .foregroundStyle(LifeOSTokens.warningText)
                Text(state.message)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Reloading or discarding the draft replaces the editor. Keeping it leaves a read-only, selectable copy below; a terminal session cannot accept another revision or be re-applied in place.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LifeOSTokens.Space.sm) {
                        Button(state.reloadLabel) { resolveTerminalConflict(.reload) }
                            .buttonStyle(LifeOSButtonStyle(.primary))
                        Button("Keep draft") { keepTerminalDraft() }
                            .buttonStyle(LifeOSButtonStyle(.secondary))
                        Button("Discard draft", role: .destructive) { resolveTerminalConflict(.discardDraft) }
                            .buttonStyle(LifeOSButtonStyle(.destructive))
                    }
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        Button(state.reloadLabel) { resolveTerminalConflict(.reload) }
                            .buttonStyle(LifeOSButtonStyle(.primary))
                        HStack(spacing: LifeOSTokens.Space.sm) {
                            Button("Keep draft") { keepTerminalDraft() }
                                .buttonStyle(LifeOSButtonStyle(.secondary))
                            Button("Discard draft", role: .destructive) { resolveTerminalConflict(.discardDraft) }
                                .buttonStyle(LifeOSButtonStyle(.destructive))
                        }
                    }
                }
            }
        }
    }

    private enum TerminalConflictResolution {
        case reload
        case discardDraft
    }

    private func keepTerminalDraft() {
        isDirty = true
        validationMessage = "Draft kept in this editor. It cannot be saved to the terminal session; reload or discard it when you are ready."
    }

    private func resolveTerminalConflict(_ resolution: TerminalConflictResolution) {
        guard let state = terminalConflict else { return }
        switch resolution {
        case .reload, .discardDraft:
            terminalConflict = nil
            if let latest = state.latestSession {
                adoptSession(latest)
            } else {
                isDirty = false
                dismiss()
            }
        }
    }

    private func reapplyDraft(to latest: TrainingSession) {
        guard latest.id == baseSession.id else { return }
        baseSession = latest
        deferredIncomingSession = nil
        conflictSession = nil
        isDirty = true
        validationMessage = "Your draft is kept on revision \(latest.revision). Save to reapply it."
    }

    private func advanceBaseKeepingDraft(to latest: TrainingSession) {
        guard latest.id == baseSession.id else { return }
        baseSession = latest
        deferredIncomingSession = nil
        conflictSession = nil
    }

    private func makeDraft() -> TrainingSession? {
        do {
            let now = Date.now
            let exercises = try exerciseDrafts.map { exercise in
                let sets = try exercise.sets.map { set in
                    try TrainingSetLog(
                        id: set.id,
                        kind: set.kind,
                        targetRepetitions: try parseInteger(set.targetRepetitions),
                        targetLoadKilograms: try parseLoad(
                            set.targetLoad,
                            originalToken: set.originalTargetLoadToken,
                            originalValue: set.originalTargetLoadValue
                        ),
                        actualRepetitions: try parseInteger(set.actualRepetitions),
                        actualLoadKilograms: try parseLoad(
                            set.actualLoad,
                            originalToken: set.originalActualLoadToken,
                            originalValue: set.originalActualLoadValue
                        ),
                        isCompleted: set.isCompleted,
                        completedAt: set.isCompleted ? (set.completedAt ?? now) : nil,
                        now: now
                    )
                }
                return try TrainingExerciseLog(
                    id: exercise.id,
                    templateExerciseID: exercise.templateExerciseID,
                    name: exercise.name,
                    muscleGroup: exercise.muscleGroup,
                    loadConvention: exercise.loadConvention,
                    sets: sets,
                    notes: exercise.notes.trimmedOrNil
                )
            }

            return try TrainingSession(
                id: baseSession.id,
                revision: baseSession.revision,
                activityKind: baseSession.activityKind,
                title: baseSession.title,
                createdAt: baseSession.createdAt,
                updatedAt: baseSession.updatedAt,
                startedAt: baseSession.startedAt,
                endedAt: baseSession.endedAt,
                timeZoneIdentifier: baseSession.timeZoneIdentifier,
                templateID: baseSession.templateID,
                templateSnapshot: baseSession.templateSnapshot,
                pauses: baseSession.pauses,
                status: baseSession.status,
                exercises: exercises,
                notes: notesText.trimmedOrNil,
                importedRecordKey: baseSession.importedRecordKey,
                now: now
            )
        } catch {
            validationMessage = "Review the set values before saving. Completed sets need actual repetitions; numbers must be finite and within the allowed range."
            return nil
        }
    }

    private func parseInteger(_ value: String) throws -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard let parsed = Int(normalized) else { throw TrainingDraftInputError.invalidInteger }
        return parsed
    }

    private func parseLoad(_ value: String, originalToken: String?, originalValue: Double?) throws -> Double? {
        if let originalToken,
           let originalValue,
           value == originalToken {
            return originalValue
        }
        return try FitnessTrainingLoadText.parse(value)
    }

    private func addExercise() {
        exerciseDrafts.append(TrainingExerciseDraft())
        markDirty()
    }

    private func deleteExercise(id: TrainingRecordID) {
        guard exerciseDrafts.count > 1 else {
            validationMessage = "Keep one exercise in the session, or discard it instead."
            return
        }
        exerciseDrafts.removeAll { $0.id == id }
        markDirty()
    }

    private func addSet(to exerciseID: TrainingRecordID) {
        guard let index = exerciseDrafts.firstIndex(where: { $0.id == exerciseID }) else { return }
        let previous = exerciseDrafts[index].sets.last
        exerciseDrafts[index].sets.append(
            TrainingSetDraft(
                kind: previous?.kind ?? .working,
                targetRepetitions: previous?.targetRepetitions ?? "",
                targetLoad: previous?.targetLoad ?? ""
            )
        )
        markDirty()
    }

    private var currentDraftSignature: String {
        Self.draftSignature(exercises: exerciseDrafts, notes: notesText)
    }

    private static func draftSignature(exercises: [TrainingExerciseDraft], notes: String) -> String {
        var values = [notes]
        for exercise in exercises {
            values.append(exercise.id.rawValue)
            values.append(exercise.name)
            values.append(exercise.notes)
            for set in exercise.sets {
                values.append(set.id.rawValue)
                values.append(set.kind.rawValue)
                values.append(set.targetRepetitions)
                values.append(set.targetLoad)
                values.append(set.actualRepetitions)
                values.append(set.actualLoad)
                values.append(String(set.isCompleted))
            }
        }
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

private struct FitnessTrainingExerciseEditorCard: View {
    @Binding var exercise: TrainingExerciseDraft
    let focusedField: FocusState<FitnessTrainingNumericField?>.Binding
    let repetitionLabel: String
    let onAddSet: () -> Void
    let onDelete: () -> Void
    let onChange: () -> Void
    let onSubmit: (FitnessTrainingNumericField) -> Void
    @State private var isExpanded = true

    var body: some View {
        LifeOSCard(level: .surface) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.sm) {
                    Image(systemName: exercise.activityIcon)
                        .foregroundStyle(LifeOSTokens.Module.fitness)
                    TextField("Exercise name", text: $exercise.name)
                        .textFieldStyle(.roundedBorder)
                        .lifeOSTypography(.cardTitle)
                        .onChange(of: exercise.name) { _, _ in onChange() }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(LifeOSMotion.decorative(LifeOSMotion.snappy)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Collapse \(exercise.name)" : "Expand \(exercise.name)")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(exercise.name.isEmpty ? "exercise" : exercise.name)")
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                        Text("Target and actual \(repetitionLabel.lowercased()) / load")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)

                        ForEach(exercise.sets.indices, id: \.self) { index in
                            FitnessTrainingSetEditorRow(
                                index: index,
                                exerciseID: exercise.id,
                                set: $exercise.sets[index],
                                repetitionLabel: repetitionLabel,
                                focusedField: focusedField,
                                onChange: onChange,
                                onSubmit: onSubmit
                            )
                        }

                        TextField("Exercise note (optional)", text: $exercise.notes, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: exercise.notes) { _, _ in onChange() }

                        Button(action: onAddSet) {
                            Label("Add set", systemImage: "plus")
                        }
                        .buttonStyle(LifeOSButtonStyle(.secondary))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(LifeOSMotion.decorative(LifeOSMotion.snappy), value: isExpanded)
    }
}

private struct FitnessTrainingSetEditorRow: View {
    let index: Int
    let exerciseID: TrainingRecordID
    @Binding var set: TrainingSetDraft
    let repetitionLabel: String
    let focusedField: FocusState<FitnessTrainingNumericField?>.Binding
    let onChange: () -> Void
    let onSubmit: (FitnessTrainingNumericField) -> Void

    private enum NumericKind {
        case integer
        case decimal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Set \(index + 1)")
                    .lifeOSTypography(.label)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Spacer()
                Toggle("Completed", isOn: $set.isCompleted)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Set \(index + 1) completed")
                    .onChange(of: set.isCompleted) { _, _ in onChange() }
            }

            ViewThatFits(in: .horizontal) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 132), alignment: .leading),
                        GridItem(.flexible(minimum: 132), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: LifeOSTokens.Space.sm
                ) {
                    inputFields
                }
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                    inputFields
                }
            }
        }
        .padding(LifeOSTokens.Space.sm)
        .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                .stroke(set.isCompleted ? LifeOSTokens.success.opacity(0.55) : LifeOSTokens.subtleBorder, lineWidth: set.isCompleted ? 1 : 0.5)
        }
    }

    private var repetitionUnit: String {
        repetitionLabel == "Intervals" ? "intervals" : "reps"
    }

    @ViewBuilder
    private var inputFields: some View {
        inputField(
            title: "Target \(repetitionLabel.lowercased())",
            unit: repetitionUnit,
            text: $set.targetRepetitions,
            field: .targetRepetitions(exerciseID: exerciseID, setID: set.id),
            numericKind: .integer
        )
        inputField(
            title: "Target load",
            unit: "kg",
            text: $set.targetLoad,
            field: .targetLoad(exerciseID: exerciseID, setID: set.id),
            numericKind: .decimal
        )
        inputField(
            title: "Actual \(repetitionLabel.lowercased())",
            unit: repetitionUnit,
            text: $set.actualRepetitions,
            field: .actualRepetitions(exerciseID: exerciseID, setID: set.id),
            numericKind: .integer
        )
        inputField(
            title: "Actual load",
            unit: "kg",
            text: $set.actualLoad,
            field: .actualLoad(exerciseID: exerciseID, setID: set.id),
            numericKind: .decimal
        )
    }

    private func inputField(
        title: String,
        unit: String,
        text: Binding<String>,
        field: FitnessTrainingNumericField,
        numericKind: NumericKind
    ) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(title)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                TextField("—", text: text)
                    .textFieldStyle(.plain)
                    .lifeOSTypography(.body)
                    .focused(focusedField, equals: field)
                    .submitLabel(.next)
                    #if os(iOS)
                    .keyboardType(numericKind == .integer ? .numberPad : .decimalPad)
                    #endif
                    .autocorrectionDisabled(true)
                    .accessibilityLabel(title)
                    .accessibilityValue(text.wrappedValue.isEmpty ? "Empty" : text.wrappedValue)
                    .onSubmit { onSubmit(field) }
                    .onChange(of: text.wrappedValue) { _, _ in onChange() }
                Text(unit)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LifeOSTokens.Space.sm)
            .padding(.vertical, LifeOSTokens.Space.xs)
            .background(LifeOSTokens.canvas, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                    .stroke(focusedField.wrappedValue == field ? LifeOSTokens.accent : LifeOSTokens.subtleBorder, lineWidth: focusedField.wrappedValue == field ? 1.5 : 0.5)
            }
        }
        .frame(minWidth: 132, maxWidth: .infinity, alignment: .leading)
    }

}

private enum TrainingDraftInputError: Error {
    case invalidInteger
    case invalidLoad
}

private struct TrainingExerciseDraft: Identifiable {
    let id: TrainingRecordID
    let templateExerciseID: String?
    var name: String
    let muscleGroup: TrainingMuscleGroup
    let loadConvention: TrainingLoadConvention
    var sets: [TrainingSetDraft]
    var notes: String

    init(_ exercise: TrainingExerciseLog) {
        id = exercise.id
        templateExerciseID = exercise.templateExerciseID
        name = exercise.name
        muscleGroup = exercise.muscleGroup
        loadConvention = exercise.loadConvention
        sets = exercise.sets.map(TrainingSetDraft.init)
        notes = exercise.notes ?? ""
    }

    init() {
        id = TrainingRecordID()
        templateExerciseID = nil
        name = ""
        muscleGroup = .other
        loadConvention = .externalTotal
        sets = [TrainingSetDraft()]
        notes = ""
    }

    var activityIcon: String {
        switch muscleGroup {
        case .arms: "figure.arms.open"
        case .chest: "figure.strengthtraining.traditional"
        case .back: "figure.rower"
        case .legs: "figure.run"
        case .shoulders: "figure.cooldown"
        case .core: "figure.core.training"
        case .other: "circle.dashed"
        }
    }
}

private struct TrainingSetDraft: Identifiable {
    let id: TrainingRecordID
    let kind: TrainingSetKind
    var targetRepetitions: String
    var targetLoad: String
    let originalTargetLoadToken: String?
    let originalTargetLoadValue: Double?
    var actualRepetitions: String
    var actualLoad: String
    let originalActualLoadToken: String?
    let originalActualLoadValue: Double?
    var isCompleted: Bool
    var completedAt: Date?

    init(_ set: TrainingSetLog) {
        id = set.id
        kind = set.kind
        targetRepetitions = set.targetRepetitions.map(String.init) ?? ""
        originalTargetLoadValue = set.targetLoadKilograms
        originalTargetLoadToken = set.targetLoadKilograms.map { FitnessTrainingLoadText.string($0) }
        targetLoad = originalTargetLoadToken ?? ""
        actualRepetitions = set.actualRepetitions.map(String.init) ?? ""
        originalActualLoadValue = set.actualLoadKilograms
        originalActualLoadToken = set.actualLoadKilograms.map { FitnessTrainingLoadText.string($0) }
        actualLoad = originalActualLoadToken ?? ""
        isCompleted = set.isCompleted
        completedAt = set.completedAt
    }

    init(
        id: TrainingRecordID = TrainingRecordID(),
        kind: TrainingSetKind = .working,
        targetRepetitions: String = "",
        targetLoad: String = "",
        actualRepetitions: String = "",
        actualLoad: String = "",
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetRepetitions = targetRepetitions
        self.targetLoad = targetLoad
        self.originalTargetLoadToken = nil
        self.originalTargetLoadValue = nil
        self.actualRepetitions = actualRepetitions
        self.actualLoad = actualLoad
        self.originalActualLoadToken = nil
        self.originalActualLoadValue = nil
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }
}

private extension FitnessTrainingSessionView {
    func formatClock(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private extension TrainingActivityKind {
    var displayName: String {
        switch self {
        case .strength: "Strength"
        case .cardio: "Cardio"
        case .mobility: "Mobility"
        case .flexibility: "Flexibility"
        case .sport: "Sport"
        case .other: "Training"
        }
    }
}

private extension TrainingSessionStatus {
    var displayName: String {
        switch self {
        case .active: "In progress"
        case .paused: "Resting"
        case .completed: "Completed"
        case .discarded: "Discarded"
        }
    }
}

enum FitnessTrainingLoadText {
    static func string(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "" }
        let raw = expandedDecimal(String(value))
        let withoutZeroFraction: String
        if let separator = raw.firstIndex(of: "."),
           raw[raw.index(after: separator)...].allSatisfy({ $0 == "0" }) {
            withoutZeroFraction = String(raw[..<separator])
        } else {
            withoutZeroFraction = raw
        }
        guard let decimalSeparator = locale.decimalSeparator,
              decimalSeparator != "." else { return withoutZeroFraction }
        return withoutZeroFraction.replacingOccurrences(of: ".", with: decimalSeparator)
    }

    /// `Double.description` is the shortest round-tripping representation, but
    /// it may use an exponent. Editable locale text deliberately stays in the
    /// same grammar as `parse`, so expand that exponent without rounding.
    private static func expandedDecimal(_ raw: String) -> String {
        guard let exponentIndex = raw.firstIndex(where: { $0 == "e" || $0 == "E" }),
              let exponent = Int(raw[raw.index(after: exponentIndex)...]) else {
            return raw
        }
        let mantissa = String(raw[..<exponentIndex])
        let sign = mantissa.first == "-" ? "-" : ""
        let unsignedMantissa = sign.isEmpty ? mantissa : String(mantissa.dropFirst())
        let parts = unsignedMantissa.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = parts.first.map(String.init) ?? "0"
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        let digits = integerPart + fractionPart
        let decimalPosition = integerPart.count + exponent
        if decimalPosition <= 0 {
            return "\(sign)0.\(String(repeating: "0", count: -decimalPosition))\(digits)"
        }
        if decimalPosition >= digits.count {
            return "\(sign)\(digits)\(String(repeating: "0", count: decimalPosition - digits.count))"
        }
        let split = digits.index(digits.startIndex, offsetBy: decimalPosition)
        return "\(sign)\(digits[..<split]).\(digits[split...])"
    }

    static func parse(_ value: String, locale: Locale = .current) throws -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator ?? ","
        guard !decimalSeparator.isEmpty else {
            throw TrainingDraftInputError.invalidLoad
        }
        let sign: String
        let unsigned: String
        if normalized.first == "-" || normalized.first == "+" {
            sign = String(normalized.prefix(1))
            unsigned = String(normalized.dropFirst())
        } else {
            sign = ""
            unsigned = normalized
        }

        let decimalParts = unsigned.components(separatedBy: decimalSeparator)
        guard decimalParts.count <= 2 else { throw TrainingDraftInputError.invalidLoad }
        let integerPart = decimalParts[0]
        let fractionPart = decimalParts.count == 2 ? decimalParts[1] : ""
        guard !integerPart.isEmpty,
              decimalParts.count == 1 || !fractionPart.isEmpty,
              Self.isASCIIDigits(fractionPart, allowingEmpty: true) else {
            throw TrainingDraftInputError.invalidLoad
        }

        let integerDigits: String
        if integerPart.contains(groupingSeparator) {
            guard !groupingSeparator.isEmpty else { throw TrainingDraftInputError.invalidLoad }
            let groups = integerPart.components(separatedBy: groupingSeparator)
            guard groups.count >= 2,
                  (1...3).contains(groups[0].utf8.count),
                  Self.isASCIIDigits(groups[0]),
                  groups.dropFirst().allSatisfy({ $0.utf8.count == 3 && Self.isASCIIDigits($0) }) else {
                throw TrainingDraftInputError.invalidLoad
            }
            integerDigits = groups.joined()
        } else {
            guard Self.isASCIIDigits(integerPart) else { throw TrainingDraftInputError.invalidLoad }
            integerDigits = integerPart
        }

        let canonical = sign + integerDigits + (fractionPart.isEmpty ? "" : ".\(fractionPart)")
        guard let parsed = Double(canonical) else {
            throw TrainingDraftInputError.invalidLoad
        }
        guard parsed.isFinite else { throw TrainingDraftInputError.invalidLoad }
        return parsed
    }

    private static func isASCIIDigits(_ value: String, allowingEmpty: Bool = false) -> Bool {
        if value.isEmpty { return allowingEmpty }
        return value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
