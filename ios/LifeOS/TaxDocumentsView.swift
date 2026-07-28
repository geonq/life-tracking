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

    private let store: TaxDocumentStore

    init(store: TaxDocumentStore = TaxDocumentStore()) {
        self.store = store
        self.documents = (try? store.load()) ?? []
    }

    func importPDF(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        Task {
            let result = await TaxPDFExtractor.extract(url: url)
            if secured { url.stopAccessingSecurityScopedResource() }
            switch result {
            case .success(let pages):
                reviewDocument = TaxDocumentParser.parse(pages: pages, documentName: url.lastPathComponent)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveReview(_ document: TaxDocument) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        } else {
            documents.append(document)
        }
        reviewDocument = nil
        persist()
    }

    func delete(at offsets: IndexSet) {
        documents.remove(atOffsets: offsets)
        persist()
    }

    func persist() {
        do { try store.save(documents) }
        catch { errorMessage = "Could not save locally: \(error.localizedDescription)" }
    }

    func csv() -> String { TaxCSVExporter.export(documents) }
}

enum TaxPDFExtractor {
    enum ExtractError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The PDF could not be read locally." }
    }

    static func extract(url: URL) async -> Result<[String], Error> {
        await Task.detached(priority: .userInitiated) { extractSync(url: url) }.value
    }

    private static func extractSync(url: URL) -> Result<[String], Error> {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { return .failure(ExtractError.unreadable) }
        var pages: [String] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { pages.append(""); continue }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !embedded.isEmpty { pages.append(embedded); continue }
            #if canImport(Vision)
            guard let image = cgImage(for: page) else { pages.append(""); continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                pages.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            } catch { pages.append("") }
            #else
            pages.append("")
            #endif
        }
        return .success(pages)
        #else
        return .failure(ExtractError.unreadable)
        #endif
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
            List {
                Section {
                    Text("Stored only on this device. Candidates are rule-based, not tax advice, and nothing is filed automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.documents) { document in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.title).font(.headline)
                        Text("\(document.documentType) · \(document.taxYear.map(String.init) ?? \"Year not found\") · \(document.confidence.rawValue) confidence")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: model.delete)
            }
            .navigationTitle("Tax Documents")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Import PDF") { model.isImporterPresented = true } } }
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
    @Environment(\.dismiss) private var dismiss
    @State var document: TaxDocument
    let onSave: (TaxDocument) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Review before saving") {
                    TextField("Document name", text: $document.title)
                    TextField("Document type", text: $document.documentType)
                    Text("Rule-based confidence: \(document.confidence.rawValue). Review all candidates and evidence.").font(.footnote)
                    Text("No tax advice is provided and no filing occurs automatically.").font(.footnote).foregroundStyle(.secondary)
                }
                if !document.warnings.isEmpty {
                    Section("Warnings") { ForEach(document.warnings, id: \.self) { Text($0).foregroundStyle(.orange) } }
                }
                Section("Detected amounts") {
                    ForEach(Array(document.amounts.enumerated()), id: \.offset) { _, amount in
                        Text("Page \(amount.evidence.page): \(amount.label) = \(amount.value)\n\(amount.evidence.snippet)").font(.footnote)
                    }
                }
            }
            .navigationTitle("Review import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(document) } }
            }
        }
    }
}
