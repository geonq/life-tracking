import SwiftUI
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if os(macOS)
import AppKit
#endif

@MainActor
final class TaxDocumentsViewModel: ObservableObject {
    @Published var documents: [TaxDocument]
    @Published var reviewDocument: TaxDocument?
    @Published var isImporterPresented = false
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isWriteBlocked = false

    private let loadDocuments: () throws -> [TaxDocument]
    private let saveDocuments: ([TaxDocument]) throws -> Void
    private var importTask: Task<Void, Never>?
    private var activeImportID: UUID?

    private enum ImportOutcome {
        case success(TaxDocument)
        case failure
        case cancelled
    }

    private static let loadFailureMessage =
        "Tax documents could not be loaded. Saving and deleting are disabled until the store can be read."
    private static let saveFailureMessage = "Tax documents could not be saved. Your current documents were kept."
    private static let importFailureMessage = "The PDF could not be imported safely on this device."
    private static let busyMessage = "A PDF import is already in progress."

    init(store: TaxDocumentStore = TaxDocumentStore()) {
        self.loadDocuments = { try store.load() }
        self.saveDocuments = { documents in try store.save(documents) }
        self.documents = []
        loadInitialDocuments()
    }

    init(
        load: @escaping () throws -> [TaxDocument],
        save: @escaping ([TaxDocument]) throws -> Void
    ) {
        self.loadDocuments = load
        self.saveDocuments = save
        self.documents = []
        loadInitialDocuments()
    }

    deinit {
        importTask?.cancel()
    }

    private func loadInitialDocuments() {
        do {
            documents = try loadDocuments()
        } catch {
            isWriteBlocked = true
            errorMessage = Self.loadFailureMessage
        }
    }

    func importPDF(url: URL) {
        guard importTask == nil else {
            errorMessage = Self.busyMessage
            return
        }
        let secured = url.startAccessingSecurityScopedResource()
        let importID = UUID()
        activeImportID = importID
        isImporting = true
        if !isWriteBlocked { errorMessage = nil }
        let task = Task { [weak self] in
            // Let the task be retained before any worker can finish and call
            // completeImport(_:outcome:).
            await Task.yield()
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }

            let outcome = await Self.performImport(url: url)
            self?.completeImport(importID, outcome: outcome)
        }
        importTask = task
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private static func performImport(url: URL) async -> ImportOutcome {
        let extraction = await TaxPDFExtractor.extract(url: url)
        guard !Task.isCancelled else { return .cancelled }
        guard case .success(let pages) = extraction else {
            if case .failure(.cancelled) = extraction { return .cancelled }
            return .failure
        }

        do {
            let document = try await parseDocument(pages: pages, documentName: url.lastPathComponent)
            return .success(document)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure
        }
    }

    private static func parseDocument(pages: [String], documentName: String) async throws -> TaxDocument {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return TaxDocumentParser.parse(
                pages: pages,
                documentName: documentName,
                cancellationCheck: { Task.isCancelled }
            )
        }
        let parsed = try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
        try Task.checkCancellation()
        return parsed
    }

    private func completeImport(_ importID: UUID, outcome: ImportOutcome) {
        guard activeImportID == importID else { return }
        activeImportID = nil
        importTask = nil
        isImporting = false
        switch outcome {
        case .success(let document):
            if !isWriteBlocked { errorMessage = nil }
            reviewDocument = document
        case .failure:
            errorMessage = Self.importFailureMessage
        case .cancelled:
            if errorMessage == Self.busyMessage { errorMessage = nil }
            break
        }
    }

    func saveReview(_ document: TaxDocument) {
        guard ensureWritable() else { return }
        var candidate = documents
        if let index = candidate.firstIndex(where: { $0.id == document.id }) {
            candidate[index] = document
        } else {
            candidate.append(document)
        }
        commit(candidate, clearReviewOnSuccess: true)
    }

    func delete(at offsets: IndexSet) {
        guard ensureWritable() else { return }
        var candidate = documents
        candidate.remove(atOffsets: offsets)
        commit(candidate, clearReviewOnSuccess: false)
    }

    private func ensureWritable() -> Bool {
        guard !isWriteBlocked else {
            errorMessage = Self.loadFailureMessage
            return false
        }
        return true
    }

    private func commit(_ candidate: [TaxDocument], clearReviewOnSuccess: Bool) {
        do {
            try saveDocuments(candidate)
            documents = candidate
            if !isWriteBlocked { errorMessage = nil }
            if clearReviewOnSuccess { reviewDocument = nil }
        } catch {
            errorMessage = Self.saveFailureMessage
        }
    }

    func csv() -> String { TaxCSVExporter.export(documents) }
}

enum TaxPDFExtractor {
    enum ExtractError: LocalizedError, Equatable, Sendable {
        case unreadable
        case fileTooLarge
        case tooManyPages
        case textTooLarge
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The PDF could not be read locally."
            case .fileTooLarge: return "The PDF exceeds the safe import size limit."
            case .tooManyPages: return "The PDF has too many pages to import safely."
            case .textTooLarge: return "The PDF contains more text than can be imported safely."
            case .cancelled: return "The PDF import was cancelled."
            }
        }
    }

    static func extract(url: URL) async -> Result<[String], ExtractError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let worker = Task.detached(priority: .userInitiated) { extractSync(url: url) }
        return await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private static func extractSync(url: URL) -> Result<[String], ExtractError> {
        #if canImport(PDFKit)
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= TaxDocumentLimits.maximumPDFBytes else {
            return .failure(ExtractError.fileTooLarge)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { return .failure(ExtractError.unreadable) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard pdf.pageCount <= TaxDocumentLimits.maximumPages else { return .failure(ExtractError.tooManyPages) }
        var pages: [String] = []
        var totalBytes = 0
        for index in 0..<pdf.pageCount {
            guard !Task.isCancelled else { return .failure(.cancelled) }
            guard let page = pdf.page(at: index) else { pages.append(""); continue }
            guard !Task.isCancelled else { return .failure(.cancelled) }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !Task.isCancelled else { return .failure(.cancelled) }
            if !embedded.isEmpty {
                guard appendBounded(embedded, to: &pages, totalBytes: &totalBytes) else {
                    return .failure(ExtractError.textTooLarge)
                }
                continue
            }
            #if canImport(Vision)
            guard !Task.isCancelled else { return .failure(.cancelled) }
            guard let image = cgImage(for: page) else { pages.append(""); continue }
            guard !Task.isCancelled else { return .failure(.cancelled) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                guard !Task.isCancelled else { return .failure(.cancelled) }
                var recognizedLines: [String] = []
                var recognizedCharacters = 0
                var recognizedBytes = 0
                for observation in request.results ?? [] {
                    guard !Task.isCancelled else { return .failure(.cancelled) }
                    if let line = observation.topCandidates(1).first?.string {
                        let separatorCharacters = recognizedLines.isEmpty ? 0 : 1
                        let separatorBytes = recognizedLines.isEmpty ? 0 : 1
                        let lineBytes = line.utf8.count
                        let remainingDocumentBytes = TaxDocumentLimits.maximumTotalPageBytes - totalBytes
                        guard recognizedLines.count < TaxDocumentLimits.maximumPageCharacters,
                              recognizedCharacters <= TaxDocumentLimits.maximumPageCharacters - separatorCharacters,
                              line.count <= TaxDocumentLimits.maximumPageCharacters - recognizedCharacters - separatorCharacters,
                              separatorBytes <= remainingDocumentBytes,
                              recognizedBytes <= remainingDocumentBytes - separatorBytes,
                              lineBytes <= remainingDocumentBytes - separatorBytes - recognizedBytes else {
                            return .failure(.textTooLarge)
                        }
                        recognizedLines.append(line)
                        recognizedCharacters += separatorCharacters + line.count
                        recognizedBytes += separatorBytes + lineBytes
                    }
                }
                let recognized = recognizedLines.joined(separator: "\n")
                guard appendBounded(recognized, to: &pages, totalBytes: &totalBytes) else {
                    return .failure(ExtractError.textTooLarge)
                }
            } catch {
                if Task.isCancelled { return .failure(.cancelled) }
                pages.append("")
            }
            #else
            guard !Task.isCancelled else { return .failure(.cancelled) }
            pages.append("")
            #endif
        }
        return .success(pages)
        #else
        return .failure(ExtractError.unreadable)
        #endif
    }

    static func appendBounded(_ text: String, to pages: inout [String], totalBytes: inout Int) -> Bool {
        guard pages.count < TaxDocumentLimits.maximumPages,
              text.count <= TaxDocumentLimits.maximumPageCharacters,
              totalBytes <= TaxDocumentLimits.maximumTotalPageBytes else { return false }
        let byteCount = text.utf8.count
        guard byteCount <= TaxDocumentLimits.maximumTotalPageBytes - totalBytes else { return false }
        pages.append(text)
        totalBytes += byteCount
        return true
    }

    #if canImport(PDFKit) && canImport(Vision)
    private static func cgImage(for page: PDFPage) -> CGImage? {
        let thumbnail = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
        #if os(macOS)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return thumbnail.cgImage
        #endif
    }
    #endif
}

struct TaxDocumentsView: View {
    @StateObject private var model = TaxDocumentsViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: LifeOSTokens.spacing) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tax Documents")
                            .lifeOSTypography(.pageTitle)
                            .tracking(-0.5)
                        Text("Private, on-device review")
                            .lifeOSTypography(.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.isImporterPresented = true } label: {
                        HStack(spacing: 6) {
                            LifeOSIcon(.importDocument).frame(width: 16, height: 16)
                            Text("Import PDF")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isImporting)
                    .accessibilityIdentifier("import-tax-pdf")
                }
                .padding(LifeOSTokens.pagePadding)

                if model.isImporting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Importing PDF…")
                        Spacer()
                        Button("Cancel") { model.cancelImport() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, LifeOSTokens.pagePadding)
                    .padding(.bottom, 8)
                }

                if model.isWriteBlocked {
                    Label("Stored documents are read-only until they can be loaded safely.", systemImage: "lock")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LifeOSTokens.pagePadding)
                        .padding(.bottom, 8)
                }

                List {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            LifeOSIcon(.security)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(width: 17, height: 17)
                            Text("Stored only on this device. Candidates are rule-based, not tax advice, and nothing is filed automatically.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(model.documents) { document in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title).lifeOSTypography(.cardTitle)
                            Text("\(document.documentType) · \(document.taxYear.map(String.init) ?? "Year not found") · \(document.confidence.rawValue) confidence")
                                .lifeOSTypography(.label).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: model.delete)
                }
                .scrollContentBackground(.hidden)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .tint(LifeOSTokens.accent)
            .onDisappear { model.cancelImport() }
        }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importPDF(url: url) }
        }
        .sheet(item: $model.reviewDocument) { document in
            TaxDocumentReviewView(document: document) { model.saveReview($0) }
        }
        .alert("Tax document", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct TaxDocumentReviewView: View {
    private enum FocusedField: Hashable {
        case title
        case documentType
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FocusedField?
    @State var document: TaxDocument
    let onSave: (TaxDocument) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                reviewHeader
                documentDetails
                detectedIdentity
                detectedDates
                detectedAmounts
                if !document.warnings.isEmpty {
                    warnings
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, LifeOSTokens.pagePadding)
            .padding(.top, LifeOSTokens.Space.lg)
            .padding(.bottom, LifeOSTokens.Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            reviewActions
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private var reviewHeader: some View {
        HStack(alignment: .top, spacing: LifeOSTokens.Space.sm) {
            LifeOSIcon(.documents)
                .frame(width: 24, height: 24)
                .foregroundStyle(LifeOSTokens.Module.tax)

            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text("Review import")
                    .lifeOSTypography(.sectionTitle, weight: .semibold)
                Text("Check the extracted fields before saving this document locally.")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var documentDetails: some View {
        TaxReviewGroup(title: "Document details", subtitle: "Editable local metadata") {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                reviewField(
                    label: "Document name",
                    placeholder: "Name",
                    text: $document.title,
                    focus: .title,
                    submit: .documentType
                )
                reviewField(
                    label: "Document type",
                    placeholder: "Type",
                    text: $document.documentType,
                    focus: .documentType,
                    submit: nil
                )

                HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                    Text("Extraction")
                        .lifeOSTypography(.metadata, weight: .medium)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                    Text("Rule-based · \(document.confidence.rawValue.capitalized) confidence")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(1)
                }
                Text("Review candidates and evidence before saving. Nothing is filed automatically.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detectedIdentity: some View {
        TaxReviewGroup(title: "Detected identity", subtitle: "Masked values are kept local") {
            VStack(alignment: .leading, spacing: 0) {
                candidateRow("Issuer", candidate: document.issuer)
                candidateRow("Tax identifier", candidate: document.taxpayerIdentifier)
                candidateRow("Reference", candidate: document.referenceIdentifier)
            }
        }
    }

    private var detectedDates: some View {
        TaxReviewGroup(title: "Detected dates", subtitle: document.taxYear.map { "Tax year \($0)" } ?? "No tax year detected") {
            if document.dates.isEmpty {
                emptyDetail("No dates were detected.")
            } else {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                    ForEach(Array(document.dates.prefix(8).enumerated()), id: \.offset) { _, date in
                        HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                            Text(date.value)
                                .lifeOSTypography(.body, weight: .medium)
                                .monospacedDigit()
                            Spacer(minLength: LifeOSTokens.Space.xs)
                            Text("Page \(date.evidence.page)")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    if document.dates.count > 8 {
                        moreDetail(document.dates.count - 8, noun: "dates")
                    }
                }
            }
        }
    }

    private var detectedAmounts: some View {
        TaxReviewGroup(title: "Detected amounts", subtitle: "Evidence is shown from the local extraction") {
            if document.amounts.isEmpty {
                emptyDetail("No amounts were detected.")
            } else {
                VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
                    ForEach(Array(document.amounts.prefix(24).enumerated()), id: \.offset) { index, amount in
                        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                                Text(amount.label)
                                    .lifeOSTypography(.body, weight: .medium)
                                    .lineLimit(2)
                                Spacer(minLength: LifeOSTokens.Space.xs)
                                Text(amount.value)
                                    .lifeOSTypography(.body, weight: .semibold)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            HStack(alignment: .top, spacing: LifeOSTokens.Space.xs) {
                                Text("Page \(amount.evidence.page)")
                                    .lifeOSTypography(.metadata, weight: .medium)
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                Text(amount.evidence.snippet)
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.secondaryText)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if index < min(document.amounts.count, 24) - 1 {
                            Divider().overlay(LifeOSTokens.subtleBorder)
                        }
                    }
                    if document.amounts.count > 24 {
                        moreDetail(document.amounts.count - 24, noun: "amounts")
                    }
                }
            }
        }
    }

    private var warnings: some View {
        TaxReviewGroup(title: "Review notes", subtitle: "The import needs your judgement") {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xs) {
                ForEach(Array(document.warnings.prefix(8).enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if document.warnings.count > 8 {
                    moreDetail(document.warnings.count - 8, noun: "notes")
                }
            }
        }
    }

    @ViewBuilder
    private func reviewField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        focus: FocusedField,
        submit: FocusedField?
    ) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            Text(label)
                .lifeOSTypography(.metadata, weight: .medium)
                .foregroundStyle(LifeOSTokens.secondaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, LifeOSTokens.Space.sm)
                .frame(minHeight: 40)
                .background(LifeOSTokens.raised, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.control, style: .continuous)
                        .stroke(
                            focusedField == focus ? LifeOSTokens.focusStroke : LifeOSTokens.essentialBorder,
                            lineWidth: focusedField == focus ? 2 : 1
                        )
                }
                .focused($focusedField, equals: focus)
                .onSubmit {
                    focusedField = submit
                }
        }
    }

    private func candidateRow(_ title: String, candidate: TaxCandidate?) -> some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: LifeOSTokens.Space.xs) {
                Text(title)
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                Spacer(minLength: LifeOSTokens.Space.xs)
                Text(candidate.map { "Page \($0.evidence.page)" } ?? "Not detected")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(1)
            }
            Text(candidate?.value ?? "Not detected")
                .lifeOSTypography(.body)
                .foregroundStyle(candidate == nil ? LifeOSTokens.tertiaryText : LifeOSTokens.primaryText)
                .lineLimit(2)
                .textSelection(.enabled)
            if let snippet = candidate?.evidence.snippet, !snippet.isEmpty, snippet != candidate?.value {
                Text(snippet)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, LifeOSTokens.Space.xs)
        .overlay(alignment: .bottom) {
            Divider().overlay(LifeOSTokens.subtleBorder)
        }
    }

    private func emptyDetail(_ text: String) -> some View {
        Text(text)
            .lifeOSTypography(.metadata)
            .foregroundStyle(LifeOSTokens.secondaryText)
    }

    private func moreDetail(_ count: Int, noun: String) -> some View {
        Text("+\(count) more \(noun) available in the saved document")
            .lifeOSTypography(.metadata)
            .foregroundStyle(LifeOSTokens.tertiaryText)
    }

    private var reviewActions: some View {
        HStack(spacing: LifeOSTokens.Space.sm) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
            Spacer(minLength: LifeOSTokens.Space.xs)
            Button("Save document") {
                focusedField = nil
                onSave(document)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, LifeOSTokens.pagePadding)
        .padding(.vertical, LifeOSTokens.Space.sm)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().overlay(LifeOSTokens.subtleBorder)
        }
    }
}

private struct TaxReviewGroup<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.Space.sm) {
            VStack(alignment: .leading, spacing: LifeOSTokens.Space.xxs) {
                Text(title)
                    .lifeOSTypography(.cardTitle, weight: .semibold)
                Text(subtitle)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            content
                .padding(LifeOSTokens.Space.sm)
                .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LifeOSTokens.Radius.card, style: .continuous)
                        .stroke(LifeOSTokens.subtleBorder, lineWidth: 1)
                }
        }
    }
}
