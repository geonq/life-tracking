import Foundation
import XCTest
@testable import LifeOSMac

#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit

@MainActor
private final class PlanningCanvasHost {
    private let hostingView: NSHostingView<AnyView>
    private(set) var window: NSWindow
    private var didClose = false

    init<Content: View>(rootView: Content) {
        let hostingView = NSHostingView(rootView: AnyView(rootView))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.hostingView = hostingView
        self.window = window
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}
#elseif os(iOS)
import UIKit

@MainActor
private final class PlanningCanvasHost {
    private let hostingController: UIHostingController<AnyView>
    private(set) var window: UIWindow
    private var didClose = false

    init<Content: View>(rootView: Content) {
        let hostingController = UIHostingController(rootView: AnyView(rootView))
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.hostingController = hostingController
        self.window = window
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        hostingController.view.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }
}
#endif
#endif

private final class PlanningWorkspaceTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

private final class PlanningWorkspaceTaskBox: @unchecked Sendable {
    var openTask: Task<Void, Never>?
    var unmountTask: Task<Void, Never>?
}

private actor PlanningWorkspaceTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if entered {
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
            }
        }
    }

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        pendingReleaseWaiters.forEach { $0.resume() }
    }
}

private final class PlanningWorkspaceScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = 0
    private var maximumActive = 0

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        starts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
        active -= 1
    }

    var counts: (starts: Int, stops: Int, active: Int, maximumActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, stops, active, maximumActive)
    }
}

private final class PlanningWorkspaceRemovalBarrierFault: @unchecked Sendable {
    private let lock = NSLock()
    private var prefix: String?
    private var count = 0

    func arm(prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        self.prefix = prefix
        count = 0
    }

    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        prefix = nil
    }

    var hits: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func check(_ name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let prefix, name.hasPrefix(prefix) else { return }
        count += 1
        throw PlanningFilesystemError.diskFull
    }
}

private final class PlanningWorkspaceSelectionCommitFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailBeforeReplacement = false
    private var shouldFailAfterReplacement = false

    func failNextCommit() {
        lock.lock()
        shouldFailBeforeReplacement = true
        lock.unlock()
    }

    func beforeReplacement() throws {
        lock.lock()
        let shouldFail = shouldFailBeforeReplacement
        shouldFailBeforeReplacement = false
        lock.unlock()
        if shouldFail {
            throw PlanningFilesystemError.diskFull
        }
    }

    func failNextAfterReplacement() {
        lock.lock()
        shouldFailAfterReplacement = true
        lock.unlock()
    }

    func afterReplacement() throws {
        lock.lock()
        let shouldFail = shouldFailAfterReplacement
        shouldFailAfterReplacement = false
        lock.unlock()
        if shouldFail {
            throw PlanningFilesystemError.diskFull
        }
    }
}

@MainActor
final class PlanningWorkspaceTests: XCTestCase {
    private func chooserWorkspace(_ fixture: Fixture, canvas: Bool = true) async -> PlanningWorkspaceCoordinator {
        let workspace = PlanningWorkspaceCoordinator(store: fixture.store, localGrantOwnerID: fixture.ownerID)
        await workspace.attach(fixture.selection)
        if canvas { await workspace.openCanvas(relativePath: "Projects/Personal.canvas") }
        return workspace
    }

    private func choose(_ path: String, fixture: Fixture, workspace: PlanningWorkspaceCoordinator) async throws {
        let ticket = try XCTUnwrap(workspace.beginDocumentSelection())
        let selection = try PlanningUserSelectedDocument(pickerURL: noteURL(fixture, path: path))
        await workspace.openSelectedDocument(selection, ticket: ticket)
    }

    private func assertSelectionRejected(_ url: URL, store: PlanningVaultStore,
                                         context: PlanningCanvasAccessContext,
                                         expected: PlanningFilesystemError? = nil,
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let selection = try PlanningUserSelectedDocument(pickerURL: url)
        do {
            _ = try await store.resolveSelectedDocument(selection, expectedContext: context)
            XCTFail("Unexpectedly accepted \(url)", file: file, line: line)
        } catch let error as PlanningFilesystemError {
            if let expected {
                XCTAssertEqual(error, expected, file: file, line: line)
                XCTAssertEqual(error.stableCode, expected.stableCode, file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected rejection error type: \(error)", file: file, line: line)
        }
    }

    func testDocumentSelectionRoutesExistingCanvasAndMarkdown() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/A.md", source: "# A")
        let w = await chooserWorkspace(f, canvas: false)
        let context = try await f.store.currentCanvasAccessContext()
        for (path, expected) in [
            ("Projects/Personal.canvas", PlanningDocumentDestination.canvas(try PlanningStoredPath("Projects/Personal.canvas"))),
            ("Projects/A.md", PlanningDocumentDestination.markdown(try PlanningStoredPath("Projects/A.md")))
        ] {
            let result = try await f.store.resolveSelectedDocument(
                PlanningUserSelectedDocument(pickerURL: noteURL(f, path: path)), expectedContext: context)
            XCTAssertEqual(result, expected)
        }
        try await choose("Projects/Personal.canvas", fixture: f, workspace: w)
        XCTAssertEqual(w.phase, .showingCanvas)
        try await choose("Projects/A.md", fixture: f, workspace: w)
        XCTAssertEqual(w.inspectorNoteSource, "# A")
    }

    func testDocumentSelectionRejectsOutsideSiblingAndTraversalPaths() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let workspace = await chooserWorkspace(f)
        defer { withExtendedLifetime(workspace) {} }
        let context = try await f.store.currentCanvasAccessContext()
        let urls = [f.root.appendingPathComponent("Outside.md"),
                    f.root.appendingPathComponent("LifeOS-other/A.md"),
                    URL(string: f.root.absoluteString + "LifeOS/Projects/../A.md")!,
                    URL(string: noteURL(f, path: "Projects/Personal.canvas").absoluteString + "?x=1")!,
                    URL(string: noteURL(f, path: "Projects/Personal.canvas").absoluteString + "#node")!]
        for url in urls { try await assertSelectionRejected(url, store: f.store, context: context) }
    }

    func testDocumentSelectionRejectsDirectoryUnsupportedMissingAndSymlink() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let context = try await f.store.currentCanvasAccessContext()
        try writeNote(f, path: "Projects/file.txt", source: "unsupported")
        try FileManager.default.createSymbolicLink(at: noteURL(f, path: "Projects/link.md"),
                                                  withDestinationURL: noteURL(f, path: "Projects/Personal.canvas"))
        for path in ["Projects", "Projects/file.txt", "Projects/Missing.md", "Projects/link.md"] {
            try await assertSelectionRejected(noteURL(f, path: path), store: f.store, context: context)
        }
        XCTAssertNotNil(w.project)
    }

    func testDocumentSelectionBalancesTemporaryScopeOnSuccessAndFailure() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let counter = PlanningWorkspaceScopeCounter()
        let store = try PlanningVaultStore.makeTesting(rootURL: f.root,
            applicationSupportDirectory: f.support, deviceID: f.ownerID,
            documentSelectionScope: PlanningSecurityScopeStrategy(start: { _ in counter.start() }, stop: { _ in counter.stop() }))
        _ = try await store.attachExisting(selection: f.selection)
        let context = try await store.currentCanvasAccessContext()
        _ = try await store.resolveSelectedDocument(PlanningUserSelectedDocument(
            pickerURL: noteURL(f, path: "Projects/Personal.canvas")), expectedContext: context)
        try await assertSelectionRejected(noteURL(f, path: "Missing.md"), store: store, context: context)
        XCTAssertEqual(counter.counts.starts, 2)
        XCTAssertEqual(counter.counts.stops, 2)
        XCTAssertEqual(counter.counts.active, 0)
        await store.close()
    }

    func testDocumentSelectionScopeFalseStillRequiresAttachedVaultAuthority() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let store = try PlanningVaultStore.makeTesting(rootURL: f.root,
            applicationSupportDirectory: f.support, deviceID: f.ownerID,
            documentSelectionScope: PlanningSecurityScopeStrategy(start: { _ in false }, stop: { _ in XCTFail("No scope to stop") }))
        _ = try await store.attachExisting(selection: f.selection)
        let context = try await store.currentCanvasAccessContext()
        let url = noteURL(f, path: "Projects/Personal.canvas")
        let result = try await store.resolveSelectedDocument(PlanningUserSelectedDocument(pickerURL: url), expectedContext: context)
        XCTAssertEqual(result, .canvas(try PlanningStoredPath("Projects/Personal.canvas")))
        await store.close()
        try await assertSelectionRejected(url, store: store, context: context)
    }

    func testDocumentSelectionRejectsDifferentVaultGeneration() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let context = try await f.store.currentCanvasAccessContext()
        let replacement = try fixture(); registerTeardown(for: replacement)
        await w.attach(replacement.selection)
        try await assertSelectionRejected(noteURL(f, path: "Projects/Personal.canvas"), store: f.store, context: context)
    }

    func testDocumentPickerCancellationPreservesCanvasAndInspector() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        w.inspectNode(id: "root")
        let project = try XCTUnwrap(w.project)
        let ticket = try XCTUnwrap(w.beginDocumentSelection())
        w.cancelDocumentSelection(ticket)
        XCTAssertTrue(w.project === project)
        XCTAssertEqual(project.selectedNodeID, "root")
        XCTAssertTrue(w.isInspectorPresented)
    }

    func testPickedCanvasFailurePreservesExistingProjectAndSelection() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        w.inspectNode(id: "root")
        let project = try XCTUnwrap(w.project)
        try writeNote(f, path: "Projects/Broken.canvas", source: "not canvas")
        try await choose("Projects/Broken.canvas", fixture: f, workspace: w)
        XCTAssertTrue(w.project === project)
        XCTAssertEqual(project.selectedNodeID, "root")
        XCTAssertEqual(w.openedPath?.value, "Projects/Personal.canvas")
        XCTAssertNotNil(w.lastError)
        await w.retry()
        XCTAssertTrue(w.project === project)
        XCTAssertTrue(w.isInspectorPresented)
    }

    func testPickedCanvasRetrySuccessClearsFailureState() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let previousProject = try XCTUnwrap(w.project)
        let repairedSource = try String(contentsOf: noteURL(f, path: "Projects/Personal.canvas"), encoding: .utf8)
        try writeNote(f, path: "Projects/Broken.canvas", source: "not canvas")
        try await choose("Projects/Broken.canvas", fixture: f, workspace: w)
        XCTAssertTrue(w.project === previousProject)
        XCTAssertNotNil(w.lastError)
        XCTAssertNotNil(w.lastFailure)
        XCTAssertNotNil(w.lastDiagnostic)
        XCTAssertTrue(w.canRetryDocumentSelection)

        try writeNote(f, path: "Projects/Broken.canvas", source: repairedSource)
        await w.retry()

        let repairedProject = try XCTUnwrap(w.project)
        XCTAssertFalse(repairedProject === previousProject)
        XCTAssertEqual(w.phase, .showingCanvas)
        XCTAssertEqual(w.openedPath?.value, "Projects/Broken.canvas")
        XCTAssertNotNil(repairedProject.nodesByID["root"])
        XCTAssertNil(w.lastError)
        XCTAssertNil(w.lastFailure)
        XCTAssertNil(w.lastDiagnostic)
        XCTAssertFalse(w.canRetryDocumentSelection)
    }

    func testPickedMarkdownWithoutCanvasUsesReadOnlyPreview() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/A.md", source: "# Picked")
        let w = await chooserWorkspace(f, canvas: false)
        try await choose("Projects/A.md", fixture: f, workspace: w)
        XCTAssertNil(w.project)
        XCTAssertNil(w.openedPath)
        XCTAssertNil(w.inspectorNode)
        XCTAssertEqual(w.phase, .ready)
        XCTAssertEqual(w.inspectorNoteSource, "# Picked")
        w.closeInspectorNote()
        XCTAssertFalse(w.isInspectorPresented)
    }

    func testPickedMarkdownBackPreservesCanvasIdentityAndViewport() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/A.md", source: "# A")
        let w = await chooserWorkspace(f)
        let project = try XCTUnwrap(w.project)
        project.selectNode("root")
        try await choose("Projects/A.md", fixture: f, workspace: w)
        w.closeInspectorNote()
        XCTAssertTrue(w.project === project)
        XCTAssertEqual(project.selectedNodeID, "root")
        XCTAssertEqual(w.phase, .showingCanvas)
        // Viewport belongs to the mounted Canvas view; identity preservation is
        // the logic guarantee. Mounted UI viewport verification is separate.
    }

    func testPickedMarkdownRefreshRetainsOnlySameRouteStaleSource() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/A.md", source: "# Original")
        let w = await chooserWorkspace(f)
        try await choose("Projects/A.md", fixture: f, workspace: w)
        try Data([0xff, 0xfe, 0xff]).write(to: noteURL(f, path: "Projects/A.md"))
        await w.refreshInspectorNote()
        XCTAssertEqual(w.inspectorNoteSource, "# Original")
        XCTAssertEqual(w.inspectorNoteStatus, .stale)
        try writeNote(f, path: "Projects/B.md", source: "# Other")
        try await choose("Projects/B.md", fixture: f, workspace: w)
        XCTAssertEqual(w.inspectorNoteSource, "# Other")
    }

    func testDocumentSelectionLateResultCannotPublishAfterLifecycleChange() async throws {
        for action in ["close", "unmount", "picker", "vault", "cancel"] {
            let f = try fixture(); registerTeardown(for: f)
            try writeNote(f, path: "Projects/A.md", source: "# Late")
            let w = await chooserWorkspace(f)
            let ticket = try XCTUnwrap(w.beginDocumentSelection())
            let gate = PlanningWorkspaceTestGate()
            w.afterDocumentSelectionResolution = { await gate.wait() }
            let selection = try PlanningUserSelectedDocument(pickerURL: noteURL(f, path: "Projects/A.md"))
            let task = Task { await w.openSelectedDocument(selection, ticket: ticket) }
            await gate.waitForEntry()
            var lifecycle: Task<Void, Never>?
            switch action {
            case "close": w.closeDocument()
            case "unmount":
                w.requestUnmount()
                lifecycle = Task { await w.unmount() }
            case "picker": _ = w.beginDocumentSelection()
            case "vault":
                let replacement = try fixture(); registerTeardown(for: replacement)
                _ = try await f.store.attachExisting(selection: replacement.selection)
            default: w.cancelDocumentSelection(ticket)
            }
            await gate.release()
            await task.value
            await lifecycle?.value
            XCTAssertNil(w.inspectorNoteSource, action)
        }
    }

    func testPickedMarkdownLateReadCannotReplaceNewSelection() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/A.md", source: "# Late")
        let w = await chooserWorkspace(f)
        let gate = PlanningWorkspaceTestGate()
        w.afterInspectorRead = { await gate.wait() }
        let task = Task { try await choose("Projects/A.md", fixture: f, workspace: w) }
        await gate.waitForEntry()
        w.inspectNode(id: "root")
        await gate.release()
        try await task.value
        XCTAssertNil(w.inspectorNoteSource)
        XCTAssertEqual(w.inspectorNode?.id, "root")
    }

    func testDocumentRetryCannotCrossVaultGeneration() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        try writeNote(f, path: "Projects/Broken.canvas", source: "broken")
        try await choose("Projects/Broken.canvas", fixture: f, workspace: w)
        let replacement = try fixture(); registerTeardown(for: replacement)
        _ = try await f.store.attachExisting(selection: replacement.selection)
        await w.retry()
        XCTAssertEqual(w.lastFailure, .needsReselection)
        XCTAssertNotEqual(w.openedPath?.value, "Projects/Broken.canvas")
    }

    func testDocumentChooserDoesNotMutateVaultContents() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/A.md", source: "# Untouched")
        let w = await chooserWorkspace(f)
        func contents() throws -> [String: Data] {
            let base = f.root.appendingPathComponent("LifeOS")
            var result: [String: Data] = [:]
            for path in try FileManager.default.subpathsOfDirectory(atPath: base.path) {
                let url = base.appendingPathComponent(path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                result[path] = values.isRegularFile == true ? try Data(contentsOf: url) : Data()
            }
            return result
        }
        let before = try contents()
        try await choose("Projects/A.md", fixture: f, workspace: w)
        await w.refreshInspectorNote()
        w.closeInspectorNote()
        try await choose("Projects/Personal.canvas", fixture: f, workspace: w)
        XCTAssertEqual(try contents(), before)
        let status = try await f.store.status()
        XCTAssertEqual(status.pendingMutationCount, 0)
    }

#if DEBUG
    private enum FixtureEntryKind: Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    private struct FixtureEntrySnapshot: Equatable {
        let kind: FixtureEntryKind
        let bytes: Data?
        let modificationDate: Date?
        let symlinkDestination: String?
    }

    private enum FixtureSnapshotError: Error {
        case missingType(URL)
    }

    private func fixtureSnapshot(at root: URL) throws -> [String: FixtureEntrySnapshot] {
        let fileManager = FileManager.default
        var snapshots: [String: FixtureEntrySnapshot] = [:]

        func visit(_ url: URL, relativePath: String) throws {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                throw FixtureSnapshotError.missingType(url)
            }
            let modificationDate = attributes[.modificationDate] as? Date

            if type == .typeDirectory {
                snapshots[relativePath] = FixtureEntrySnapshot(
                    kind: .directory,
                    bytes: nil,
                    modificationDate: modificationDate,
                    symlinkDestination: nil
                )
                let children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: []
                ).sorted { $0.path < $1.path }
                for child in children {
                    let childPath = relativePath == "."
                        ? child.lastPathComponent
                        : relativePath + "/" + child.lastPathComponent
                    try visit(child, relativePath: childPath)
                }
            } else if type == .typeRegular {
                snapshots[relativePath] = FixtureEntrySnapshot(
                    kind: .regularFile,
                    bytes: try Data(contentsOf: url),
                    modificationDate: modificationDate,
                    symlinkDestination: nil
                )
            } else if type == .typeSymbolicLink {
                snapshots[relativePath] = FixtureEntrySnapshot(
                    kind: .symbolicLink,
                    bytes: nil,
                    modificationDate: modificationDate,
                    symlinkDestination: try fileManager.destinationOfSymbolicLink(atPath: url.path)
                )
            } else {
                snapshots[relativePath] = FixtureEntrySnapshot(
                    kind: .other,
                    bytes: nil,
                    modificationDate: modificationDate,
                    symlinkDestination: nil
                )
            }
        }

        try visit(root, relativePath: ".")
        return snapshots
    }

    private func canvasHost(
        for workspace: PlanningWorkspaceCoordinator,
        probe: PlanningCanvasViewportProbe
    ) throws -> PlanningCanvasHost {
        let project = try XCTUnwrap(workspace.project)
        return PlanningCanvasHost(
            rootView: PlanningCanvasView(
                coordinator: project,
                viewportProbe: probe
            )
        )
    }

    private func canvasViewport(
        _ probe: PlanningCanvasViewportProbe
    ) async throws -> PlanningCanvasViewport {
        if let viewport = probe.currentViewport {
            return viewport
        }
        let mounted = expectation(description: "Canvas viewport mounted")
        probe.onMount = { mounted.fulfill() }
        if probe.currentViewport != nil {
            mounted.fulfill()
        }
        await fulfillment(of: [mounted], timeout: 2)
        probe.onMount = nil
        return try XCTUnwrap(probe.currentViewport)
    }

    private func setCanvasViewport(
        _ viewport: PlanningCanvasViewport,
        on probe: PlanningCanvasViewportProbe
    ) async {
        guard probe.currentViewport != viewport else { return }
        let changed = expectation(description: "Canvas viewport changed")
        probe.onViewportChange = { next in
            if next == viewport { changed.fulfill() }
        }
        defer { probe.onViewportChange = nil }
        probe.setViewport(viewport)
        if probe.currentViewport != viewport {
            await fulfillment(of: [changed], timeout: 2)
        }
    }

    private func drainTask(
        _ task: Task<Void, Never>?,
        state: PlanningWorkspaceTaskState,
        finished: XCTestExpectation,
        label: String
    ) async {
        guard let task else { return }
        task.cancel()
        if !state.isCompleted {
            await fulfillment(of: [finished], timeout: 2)
        }
        if state.isCompleted {
            await task.value
        } else {
            XCTFail("Timed out draining \(label) task")
        }
    }

    func testDocumentSelectionSupersedesStaleTicket() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let probe = PlanningCanvasViewportProbe()
        let host = try canvasHost(for: w, probe: probe)
        defer { host.close() }
        _ = try await canvasViewport(probe)

        let first = try XCTUnwrap(w.beginDocumentSelection())
        let second = try XCTUnwrap(w.beginDocumentSelection())
        XCTAssertNotEqual(first, second)
        w.cancelDocumentSelection(first)
        w.cancelDocumentSelection(second)
    }

    func testCanvasViewportSurvivesDocumentCancellation() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let probe = PlanningCanvasViewportProbe()
        let host = try canvasHost(for: w, probe: probe)
        defer { host.close() }
        _ = try await canvasViewport(probe)

        let expected = PlanningCanvasViewport(
            translation: CGSize(width: 137, height: -83),
            scale: 1.35
        )
        await setCanvasViewport(expected, on: probe)
        let viewportAfterInput = try XCTUnwrap(probe.currentViewport)
        XCTAssertEqual(viewportAfterInput, expected)

        let ticket = try XCTUnwrap(w.beginDocumentSelection())
        w.cancelDocumentSelection(ticket)
        XCTAssertEqual(probe.currentViewport, expected)
        XCTAssertNotNil(w.project)
    }

    func testCanvasViewportSurvivesDocumentFailure() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let project = try XCTUnwrap(w.project)
        let probe = PlanningCanvasViewportProbe()
        let host = try canvasHost(for: w, probe: probe)
        defer { host.close() }
        _ = try await canvasViewport(probe)

        let expected = PlanningCanvasViewport(
            translation: CGSize(width: 137, height: -83),
            scale: 1.35
        )
        await setCanvasViewport(expected, on: probe)
        try writeNote(f, path: "Projects/Broken.canvas", source: "not canvas")
        try await choose("Projects/Broken.canvas", fixture: f, workspace: w)

        XCTAssertTrue(w.project === project)
        XCTAssertEqual(probe.currentViewport, expected)
        XCTAssertNotNil(w.lastError)
        XCTAssertTrue(w.canRetryDocumentSelection)
    }

    func testDocumentSelectionUnmountIgnoresLateResult() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/Late.md", source: "# Late")
        let w = await chooserWorkspace(f)
        let probe = PlanningCanvasViewportProbe()
        let host = try canvasHost(for: w, probe: probe)
        let gate = PlanningWorkspaceTestGate()
        let tasks = PlanningWorkspaceTaskBox()
        let openState = PlanningWorkspaceTaskState()
        let unmountState = PlanningWorkspaceTaskState()
        let openFinished = expectation(description: "Late document selection task finished")
        let unmountFinished = expectation(description: "Workspace unmount task finished")
        let cleanupOpenFinished = expectation(description: "Cleanup: late document selection task finished")
        let cleanupUnmountFinished = expectation(description: "Cleanup: workspace unmount task finished")
        let gateEntered = expectation(description: "Document selection reached the lifecycle gate")
        let probeDisappeared = expectation(description: "Canvas probe disappeared")
        probe.onDisappear = { probeDisappeared.fulfill() }
        w.afterDocumentSelectionResolution = {
            gateEntered.fulfill()
            await gate.wait()
        }
        addTeardownBlock { @MainActor in
            defer {
                w.afterDocumentSelectionResolution = nil
                host.close()
                probe.onMount = nil
                probe.onDisappear = nil
                probe.onViewportChange = nil
            }
            w.afterDocumentSelectionResolution = nil
            host.close()
            await gate.release()
            await self.drainTask(
                tasks.openTask,
                state: openState,
                finished: cleanupOpenFinished,
                label: "document selection"
            )
            await self.drainTask(
                tasks.unmountTask,
                state: unmountState,
                finished: cleanupUnmountFinished,
                label: "workspace unmount"
            )
        }

        _ = try await canvasViewport(probe)
        let ticket = try XCTUnwrap(w.beginDocumentSelection())
        let selection = try PlanningUserSelectedDocument(
            pickerURL: noteURL(f, path: "Projects/Late.md")
        )
        tasks.openTask = Task {
            defer {
                openState.markCompleted()
                openFinished.fulfill()
                cleanupOpenFinished.fulfill()
            }
            await w.openSelectedDocument(selection, ticket: ticket)
        }
        await fulfillment(of: [gateEntered], timeout: 2)

        w.requestUnmount()
        tasks.unmountTask = Task {
            defer {
                unmountState.markCompleted()
                unmountFinished.fulfill()
                cleanupUnmountFinished.fulfill()
            }
            await w.unmount()
        }
        await gate.release()
        await fulfillment(of: [openFinished, unmountFinished], timeout: 2)
        if openState.isCompleted { await tasks.openTask?.value }
        if unmountState.isCompleted { await tasks.unmountTask?.value }

        host.close()
        await fulfillment(of: [probeDisappeared], timeout: 2)

        XCTAssertNil(w.inspectorNoteSource)
        XCTAssertNil(w.project)
        XCTAssertEqual(w.phase, .idle)
        XCTAssertFalse(probe.isActive)
        XCTAssertNil(probe.onViewportChange)
    }

    func testDocumentSelectionCanReopenAfterCancellation() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let w = await chooserWorkspace(f)
        let probe = PlanningCanvasViewportProbe()
        let host = try canvasHost(for: w, probe: probe)
        defer { host.close() }
        let initial = try await canvasViewport(probe)

        let first = try XCTUnwrap(w.beginDocumentSelection())
        w.cancelDocumentSelection(first)
        let second = try XCTUnwrap(w.beginDocumentSelection())
        w.cancelDocumentSelection(second)

        XCTAssertEqual(probe.currentViewport, initial)
        XCTAssertTrue(w.phase == .showingCanvas)
    }

    func testPickedMarkdownBackPreservesCanvasViewport() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/Note.md", source: "# Note")
        let w = await chooserWorkspace(f)
        let project = try XCTUnwrap(w.project)
        let probe = PlanningCanvasViewportProbe()
        let host = try canvasHost(for: w, probe: probe)
        defer { host.close() }
        _ = try await canvasViewport(probe)

        let expected = PlanningCanvasViewport(
            translation: CGSize(width: 137, height: -83),
            scale: 1.35
        )
        await setCanvasViewport(expected, on: probe)
        try await choose("Projects/Note.md", fixture: f, workspace: w)
        w.closeInspectorNote()

        XCTAssertTrue(w.project === project)
        XCTAssertEqual(w.phase, .showingCanvas)
        XCTAssertEqual(probe.currentViewport, expected)
    }

    func testStandaloneMarkdownPreviewBackReturnsToReady() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/Note.md", source: "# Note")
        let w = await chooserWorkspace(f, canvas: false)
        try await choose("Projects/Note.md", fixture: f, workspace: w)
        XCTAssertEqual(w.phase, .ready)
        XCTAssertEqual(w.inspectorNoteSource, "# Note")
        w.closeInspectorNote()

        XCTAssertEqual(w.phase, .ready)
        XCTAssertFalse(w.isInspectorPresented)
        XCTAssertNil(w.project)
        w.requestUnmount()
        await w.unmount()
    }

    func testVaultChooserRoundTripDoesNotMutateVault() async throws {
        let f = try fixture(); registerTeardown(for: f)
        try writeNote(f, path: "Projects/Note.md", source: "# Untouched")
        let w = await chooserWorkspace(f)
        let before = try fixtureSnapshot(at: f.root)
        try await choose("Projects/Note.md", fixture: f, workspace: w)
        XCTAssertEqual(w.inspectorNoteSource, "# Untouched")
        w.closeInspectorNote()
        try await choose("Projects/Personal.canvas", fixture: f, workspace: w)
        XCTAssertEqual(w.openedPath?.value, "Projects/Personal.canvas")
        XCTAssertEqual(w.phase, .showingCanvas)
        let after = try fixtureSnapshot(at: f.root)
        XCTAssertEqual(after, before)
        let status = try await f.store.status()
        XCTAssertEqual(status.pendingMutationCount, 0)
        w.requestUnmount()
        await w.unmount()
    }

    func testVaultChooserRejectsSiblingAndSymlink() async throws {
        let f = try fixture(); registerTeardown(for: f)
        let siblingURL = f.root.appendingPathComponent("LifeOS-other/Sibling.md")
        try FileManager.default.createDirectory(
            at: siblingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# Sibling".utf8).write(to: siblingURL, options: .atomic)
        let outsideURL = f.root.appendingPathComponent("Outside.md")
        try Data("# Outside".utf8).write(to: outsideURL, options: .atomic)
        let symlinkURL = noteURL(f, path: "Projects/Escape.md")
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideURL
        )
        let w = await chooserWorkspace(f)
        let context = try await f.store.currentCanvasAccessContext()

        try await assertSelectionRejected(
            siblingURL,
            store: f.store,
            context: context,
            expected: .invalid("document.containment")
        )
        try await assertSelectionRejected(
            symlinkURL,
            store: f.store,
            context: context,
            expected: .needsReselection
        )

        w.requestUnmount()
        await w.unmount()
    }

#endif

    private struct Fixture {
        let root: URL
        let support: URL
        let selection: PlanningUserSelectedDirectory
        let store: PlanningVaultStore
        let ownerID: UUID
    }

    private func fixture(withCanvas: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-vault-\(UUID().uuidString)", isDirectory: true)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let vaultID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: root, vaultID: vaultID)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("LifeOS/Projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        if withCanvas {
            let canvas = #"{"nodes":[{"id":"root","type":"text","x":0,"y":0,"width":200,"height":100,"text":"Plan"}],"edges":[],"custom":"keep"}"#
            try Data(canvas.utf8).write(
                to: root.appendingPathComponent("LifeOS/Projects/Personal.canvas"),
                options: .atomic
            )
        }

        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: vaultID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        return Fixture(root: root, support: support, selection: selection, store: store, ownerID: vaultID)
    }

    private func registerTeardown(for fixture: Fixture) {
        addTeardownBlock {
            await fixture.store.close()
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.support)
        }
    }

    private func writeCanvas(_ fixture: Fixture, nodes: [PlanningCanvasNode]) throws {
        let document = try PlanningCanvasDocument(nodes: nodes, edges: [])
        let bytes = try PlanningCanvasCodec.encode(document)
        try bytes.write(
            to: fixture.root.appendingPathComponent("LifeOS/Projects/Personal.canvas"),
            options: .atomic
        )
    }

    private func noteURL(_ fixture: Fixture, path: String) -> URL {
        fixture.root
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
    }

    private func writeNote(_ fixture: Fixture, path: String, source: String) throws {
        let url = noteURL(fixture, path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: url, options: .atomic)
    }

    private func makeFileNode(id: String, reference: String) throws -> PlanningCanvasNode {
        try PlanningCanvasNode(
            id: id,
            type: .file,
            x: 0,
            y: 0,
            width: 200,
            height: 100,
            file: reference
        )
    }

    func testAtomicSelectionCommitFailureRestoresPreviousSelectionAfterReopen() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-selection-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        let commitFailure = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionCommitHook: { try commitFailure.beforeReplacement() }
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }

        let original = try await store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        commitFailure.failNextCommit()
        do {
            _ = try await store.select(
                selection: candidateSelection,
                intent: .attach(expectedVaultID: candidateID)
            )
            XCTFail("The injected composite commit failure must reject the candidate.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .diskFull)
        }

        XCTAssertEqual(access.snapshot, original)
        await store.close()

        let reopenedAccess = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        let reopenedStore = PlanningVaultStore(
            access: reopenedAccess,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await reopenedStore.close() }

        let restored = try await reopenedStore.restore()
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
        XCTAssertEqual(restored.state, .ready)
        let document = try await reopenedStore.read(
            try PlanningStoredPath("Projects/Personal.canvas")
        )
        XCTAssertEqual(
            document.snapshot?.bytes,
            Data(#"{"nodes":[{"id":"root","type":"text","x":0,"y":0,"width":200,"height":100,"text":"Plan"}],"edges":[],"custom":"keep"}"#.utf8)
        )
    }

    func testAfterReplacementSelectionFailureRestoresPreviousSelectionAfterReopen() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-selection-after-replacement-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        let commitFailure = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionAfterReplacementHook: { try commitFailure.afterReplacement() }
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }

        let original = try await store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        commitFailure.failNextAfterReplacement()
        do {
            _ = try await store.select(
                selection: candidateSelection,
                intent: .attach(expectedVaultID: candidateID)
            )
            XCTFail("The injected after-replacement failure must reject the candidate.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .diskFull)
        }

        XCTAssertEqual(access.snapshot, original)
        let pendingSelectionURL = fixture.support
            .appendingPathComponent(
                "LifeOS/Planning/vault-selection-pending-\(fixture.ownerID.uuidString.lowercased()).json"
            )
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingSelectionURL.path))
        await store.close()

        let reopenedAccess = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        let reopenedStore = PlanningVaultStore(
            access: reopenedAccess,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await reopenedStore.close() }

        let restored = try await reopenedStore.restore()
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
        XCTAssertNotEqual(restored.vaultID, candidateID)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingSelectionURL.path))
    }

    func testCommittedCandidateSurvivesUnlinkBeforeFlushFailure() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let fault = PlanningWorkspaceRemovalBarrierFault()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionRemovalBarrierHook: { try fault.check($0) })
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let candidate = fixture.support.appendingPathComponent("BarrierCandidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidate, vaultID: candidateID)
        fault.arm(prefix: "vault-selection-pending-")
        let committed = try access.select(selection: .testFactory(url: candidate),
            intent: .attach(expectedVaultID: candidateID))
        XCTAssertEqual(committed.vaultID, candidateID)
        XCTAssertEqual(fault.hits, 1)
        let pending = fixture.support.appendingPathComponent(
            "LifeOS/Planning/vault-selection-pending-\(fixture.ownerID.uuidString.lowercased()).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), "Hook must run after unlink")
        let reopened = try PlanningVaultAccess.makeTesting(rootURL: candidate,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.vaultID, committed.vaultID)
        XCTAssertEqual(restored.selectionGeneration, committed.selectionGeneration)
        XCTAssertEqual(restored.state, .ready)
    }

    func testRollbackUnlinkBeforeFlushFailureNeverAcceptsCandidate() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let fault = PlanningWorkspaceRemovalBarrierFault()
        let replacement = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID,
            selectionAfterReplacementHook: { try replacement.afterReplacement() },
            selectionRemovalBarrierHook: { try fault.check($0) })
        defer { access.close() }
        let original = try access.select(selection: fixture.selection, intent: .initialize)
        let candidate = fixture.support.appendingPathComponent("RollbackCandidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidate, vaultID: candidateID)
        replacement.failNextAfterReplacement()
        XCTAssertThrowsError(try access.select(selection: .testFactory(url: candidate),
            intent: .attach(expectedVaultID: candidateID)))
        fault.arm(prefix: "vault-selection-pending-")
        XCTAssertThrowsError(try access.restore())
        XCTAssertEqual(fault.hits, 1)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        let reopened = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
        XCTAssertNotEqual(restored.vaultID, candidateID)
    }

    func testRevokeRetryRequiresRemovalDirectoryBarrier() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let fault = PlanningWorkspaceRemovalBarrierFault()
        let access = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID,
            selectionRemovalBarrierHook: { try fault.check($0) })
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let name = "vault-selection-\(fixture.ownerID.uuidString.lowercased()).json"
        fault.arm(prefix: name)
        XCTAssertFalse(access.revoke())
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.support.appendingPathComponent("LifeOS/Planning/" + name).path))
        XCTAssertFalse(access.revoke(), "ENOENT must still reach the failing directory barrier")
        XCTAssertEqual(fault.hits, 2)
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        fault.disarm()
        XCTAssertTrue(access.revoke())
        XCTAssertEqual(access.snapshot.state, .unselected)
        let reopened = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.restore().state, .unselected)
    }

    func testSelectionTransactionEvidenceValidation() throws {
        for scenario in ["transaction", "device", "orphan"] {
            let fixture = try fixture()
            registerTeardown(for: fixture)
            let access = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
                applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
            defer { access.close() }
            _ = try access.select(selection: fixture.selection, intent: .initialize)
            let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
            let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
            let composite = try Data(contentsOf: directory.appendingPathComponent("vault-selection-" + suffix))
            var candidate = composite
            if scenario == "device" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: composite) as? [String: Any])
                var grant = try XCTUnwrap(object["grant"] as? [String: Any])
                grant["deviceID"] = UUID().uuidString
                object["grant"] = grant
                candidate = try JSONSerialization.data(withJSONObject: object)
            }
            let transactionID = UUID().uuidString
            if scenario != "orphan" {
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 2, "transactionID": transactionID,
                    "previousComposite": composite.base64EncodedString(),
                    "candidateComposite": candidate.base64EncodedString()
                ]).write(to: directory.appendingPathComponent("vault-selection-pending-" + suffix))
            } else {
                // A valid but byte-distinct composite cannot be authorized by an orphan decision.
                let object = try JSONSerialization.jsonObject(with: composite)
                candidate = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                XCTAssertNotEqual(candidate, composite)
            }
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "transactionID": scenario == "transaction" ? UUID().uuidString : transactionID,
                "candidateComposite": candidate.base64EncodedString()
            ]).write(to: directory.appendingPathComponent("vault-selection-decision-" + suffix))
            XCTAssertThrowsError(try access.restore(), scenario) {
                XCTAssertEqual($0 as? PlanningFilesystemError, .corruptEvidence, scenario)
            }
            XCTAssertEqual(access.snapshot.state, .needsReselection, scenario)
            XCTAssertFalse(access.snapshot.capabilities.canRead, scenario)
            XCTAssertFalse(access.snapshot.capabilities.canPublish, scenario)
            XCTAssertThrowsError(try access.withLease { _ in XCTFail("Invalid evidence granted a lease") })
        }
    }

    func testCommittedSelectionSurvivesPostRemovalCleanupFailure() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionPendingCleanupHook: { throw PlanningFilesystemError.diskFull }
        )
        defer { access.close() }
        let committed = try access.select(selection: fixture.selection, intent: .initialize)
        XCTAssertEqual(committed.state, .ready)
        let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
        let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("vault-selection-pending-" + suffix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("vault-selection-decision-" + suffix).path))
        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.vaultID, committed.vaultID)
        XCTAssertEqual(restored.selectionGeneration, committed.selectionGeneration)
        XCTAssertEqual(restored.state, .ready)
    }

    func testRevocationRemovalFailureRequiresReselectionAndCanRestoreGrant() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionPendingCleanupHook: { throw PlanningFilesystemError.diskFull })
        defer { access.close() }
        let original = try access.select(selection: fixture.selection, intent: .initialize)
        let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
        let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
        let composite = try Data(contentsOf: directory.appendingPathComponent("vault-selection-" + suffix))
        // A rollback-only transaction forces remove() through recovery cleanup.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("vault-selection-decision-" + suffix))
        let pending = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "previousComposite": composite.base64EncodedString()
        ])
        try pending.write(to: directory.appendingPathComponent("vault-selection-pending-" + suffix))

        XCTAssertFalse(access.revoke())
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        XCTAssertFalse(access.snapshot.capabilities.canPublish)
        XCTAssertNil(access.selectedRootURL)
        XCTAssertThrowsError(try access.withLease { _ in XCTFail("Revoked access granted a lease") })

        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
    }

    func testSuccessfulRevocationRemovesSelectionAndTransactionMetadata() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
        let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
        let composite = try Data(contentsOf: directory.appendingPathComponent("vault-selection-" + suffix))
        let transactionID = UUID().uuidString
        let pending = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "transactionID": transactionID,
            "previousComposite": composite.base64EncodedString(),
            "candidateComposite": composite.base64EncodedString()
        ])
        let decision = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "transactionID": transactionID,
            "candidateComposite": composite.base64EncodedString()
        ])
        try pending.write(to: directory.appendingPathComponent("vault-selection-pending-" + suffix))
        try decision.write(to: directory.appendingPathComponent("vault-selection-decision-" + suffix))

        XCTAssertTrue(access.revoke())
        XCTAssertEqual(access.snapshot.state, .unselected)
        for prefix in ["vault-selection-", "vault-selection-pending-", "vault-selection-decision-",
                       "vault-grant-", "authority-", "test-grant-"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(prefix + suffix).path))
        }
        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.restore().state, .unselected)
    }

    func testMalformedSelectionTransactionInvalidatesReadyAccess() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let pendingURL = fixture.support.appendingPathComponent(
            "LifeOS/Planning/vault-selection-pending-\(fixture.ownerID.uuidString.lowercased()).json")
        try Data(#"{"schemaVersion":2,"transactionID":"invalid","candidateComposite":"AA=="}"#.utf8)
            .write(to: pendingURL, options: .atomic)
        XCTAssertThrowsError(try access.restore()) { error in
            XCTAssertEqual(error as? PlanningFilesystemError, .corruptEvidence)
        }
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        XCTAssertFalse(access.snapshot.capabilities.canPublish)
        XCTAssertNil(access.selectedVault)
        var leaseWasGranted = false
        XCTAssertThrowsError(try access.withLease { _ in leaseWasGranted = true })
        XCTAssertFalse(leaseWasGranted)
    }

    func testUncertainDecisionAcknowledgmentRequiresRecovery() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionDecisionCommitHook: { throw PlanningFilesystemError.diskFull })
        defer { access.close() }
        XCTAssertThrowsError(try access.select(selection: fixture.selection, intent: .initialize))
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, fixture.ownerID)
    }

    func testUncertainAttachCommitReleasesInstalledWriterLock() async throws {
        try await assertUncertainSelectionReleasesInstalledWriterLock(initializing: false)
    }

    func testUncertainInitializeCommitReleasesInstalledWriterLock() async throws {
        try await assertUncertainSelectionReleasesInstalledWriterLock(initializing: true)
    }

    private func assertUncertainSelectionReleasesInstalledWriterLock(initializing: Bool) async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let commitFailure = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionDecisionCommitHook: { try commitFailure.beforeReplacement() }
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }
        let original = try await store.attachExisting(selection: fixture.selection)
        let originalStatus = try await store.status()
        XCTAssertGreaterThan(originalStatus.databaseBytes, 0)
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let originalDocument = try await store.read(path)

        commitFailure.failNextCommit()
        let intent: PlanningVaultSelectionIntent = initializing
            ? .initialize : .attach(expectedVaultID: fixture.ownerID)
        do {
            _ = try await store.select(selection: fixture.selection, intent: intent)
            XCTFail("An uncertain decision acknowledgment must invalidate access.")
        } catch {
            XCTAssertEqual(error as? PlanningFilesystemError, .unavailable("selectionCommitUncertain"))
        }
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        let failedStatus = try await store.status()
        XCTAssertEqual(failedStatus.databaseBytes, 0)

        // Keep the failed store alive and unclosed: recovery must not depend
        // on coordinator teardown to release its installed journal writer lock.
        let reopened = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await reopened.close() }
        let restored = try await reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, original.vaultID)
        let context = try await reopened.currentCanvasAccessContext()
        XCTAssertEqual(context.vaultID, restored.vaultID)
        XCTAssertEqual(context.selectionGeneration, restored.selectionGeneration)
        let status = try await reopened.status()
        XCTAssertGreaterThan(status.databaseBytes, 0)
        XCTAssertEqual(status.pendingMutationCount, originalStatus.pendingMutationCount)
        XCTAssertEqual(status.openConflictCount, originalStatus.openConflictCount)
        let document = try await reopened.read(path)
        XCTAssertEqual(document.snapshot?.bytes, originalDocument.snapshot?.bytes)
        XCTAssertEqual(document.selectionGeneration, restored.selectionGeneration)
    }

    func testAttachInvalidCandidateLeavesOldWorkspaceReadable() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        let original = workspace.accessSnapshot
        XCTAssertEqual(original.state, .ready)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-invalid-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        await workspace.attach(candidateSelection)

        XCTAssertEqual(workspace.accessSnapshot, original)
        XCTAssertEqual(workspace.accessSnapshot.state, .ready)
        let document = try await fixture.store.read(
            try PlanningStoredPath("Projects/Personal.canvas")
        )
        XCTAssertEqual(
            document.snapshot?.bytes,
            Data(#"{"nodes":[{"id":"root","type":"text","x":0,"y":0,"width":200,"height":100,"text":"Plan"}],"edges":[],"custom":"keep"}"#.utf8)
        )
    }

    func testAttachCorruptCandidateLeavesOldWorkspaceReadyAndReadable() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        let original = workspace.accessSnapshot
        XCTAssertEqual(workspace.phase, .ready)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-corrupt-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateJournalDirectory = fixture.support
            .appendingPathComponent("LifeOS/Planning/\(candidateID.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateJournalDirectory, withIntermediateDirectories: true)
        try Data("corrupt journal".utf8).write(
            to: candidateJournalDirectory.appendingPathComponent("journal.sqlite"),
            options: .atomic
        )
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        await workspace.attach(candidateSelection)

        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.accessSnapshot, original)
        XCTAssertEqual(workspace.accessSnapshot.state, .ready)
        let document = try await fixture.store.read(
            try PlanningStoredPath("Projects/Personal.canvas")
        )
        XCTAssertEqual(document.vaultID, original.vaultID)
        XCTAssertEqual(document.selectionGeneration, original.selectionGeneration)
        XCTAssertEqual(document.accessState, .ready)
    }

    func testRestoreJournalFailureDoesNotPublishReadyAccess() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }
        let original = try await store.attachExisting(selection: fixture.selection)
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        _ = try await store.read(path)
        _ = try await store.currentCanvasAccessContext()
        let originalStatus = try await store.status()
        XCTAssertEqual(original.state, .ready)
        XCTAssertGreaterThan(originalStatus.databaseBytes, 0)

        // Retain the resource fields and persisted selection, but force restore
        // to reopen and validate the journal instead of reusing a live handle.
        await store.closeInstalledJournalForTesting()
        let journalURL = fixture.support.appendingPathComponent(
            "LifeOS/Planning/\(fixture.ownerID.uuidString.lowercased())/journal.sqlite"
        )
        try Data("corrupt journal".utf8).write(to: journalURL, options: .atomic)

        do {
            _ = try await store.restore()
            XCTFail("Restore must reject the corrupt journal before publishing readiness.")
        } catch {
            // Resource errors use the access layer's existing error mapping.
            XCTAssertEqual(error as? PlanningFilesystemError, .unavailable("grant"))
        }
        let snapshot = access.snapshot
        XCTAssertEqual(snapshot.state, .needsReselection)
        XCTAssertFalse(snapshot.capabilities.canRead)
        XCTAssertFalse(snapshot.capabilities.canPublish)
        XCTAssertNil(snapshot.vaultID)
        XCTAssertNotEqual(snapshot.selectionGeneration, original.selectionGeneration)
        XCTAssertNil(access.selectedRootURL)
        let storeSnapshot = await store.accessSnapshot()
        XCTAssertEqual(storeSnapshot, snapshot)
        var leaseWasGranted = false
        XCTAssertThrowsError(try access.withLease { _ in leaseWasGranted = true })
        XCTAssertFalse(leaseWasGranted)
        do {
            _ = try await store.currentCanvasAccessContext()
            XCTFail("Failed restore must not expose a canvas context.")
        } catch {
            XCTAssertEqual(error as? PlanningFilesystemError, .needsReselection)
        }
        do {
            _ = try await store.read(path)
            XCTFail("Failed restore must not return a retained cached document.")
        } catch {
            XCTAssertEqual(error as? PlanningFilesystemError, .unselected)
        }
        let status = try await store.status()
        XCTAssertEqual(status.accessState, .needsReselection)
        XCTAssertEqual(status.pendingMutationCount, 0)
        XCTAssertEqual(status.openConflictCount, 0)
        XCTAssertEqual(status.retainedPayloadBytes, 0)
        XCTAssertEqual(status.databaseBytes, 0)
    }

    func testSelectAttachCorruptJournalImmediatelyPreservesOriginalWorkspace() async throws {
        try await assertCorruptCandidatePreservesWorkspace(useAttachExisting: false)
    }

    func testAttachExistingCorruptJournalImmediatelyPreservesOriginalWorkspace() async throws {
        try await assertCorruptCandidatePreservesWorkspace(useAttachExisting: true)
    }

    func testInitializeCorruptJournalImmediatelyPreservesOriginalWorkspace() async throws {
        try await assertCorruptCandidatePreservesWorkspace(useAttachExisting: false, initialize: true)
    }

    func testInitializeInstallsCandidateResourcesAfterCommit() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let original = try await fixture.store.attachExisting(selection: fixture.selection)
        let candidate = try self.fixture()
        registerTeardown(for: candidate)

        let selected = try await fixture.store.select(selection: candidate.selection, intent: .initialize)

        XCTAssertEqual(selected.state, .ready)
        XCTAssertEqual(selected.vaultID, candidate.ownerID)
        XCTAssertNotEqual(selected.selectionGeneration, original.selectionGeneration)
        let snapshot = await fixture.store.accessSnapshot()
        XCTAssertEqual(snapshot, selected)
        let context = try await fixture.store.currentCanvasAccessContext()
        let document = try await fixture.store.read(try PlanningStoredPath("Projects/Personal.canvas"))
        XCTAssertEqual(document.vaultID, candidate.ownerID)
        XCTAssertEqual(document.selectionGeneration, selected.selectionGeneration)
        XCTAssertEqual(document.snapshot?.bytes, try Data(contentsOf:
            candidate.root.appendingPathComponent("LifeOS/Projects/Personal.canvas")))
        XCTAssertFalse(document.stale)
        XCTAssertFalse(document.fromCache)
        let status = try await fixture.store.status()
        XCTAssertEqual(status.accessState, .ready)
        XCTAssertGreaterThan(status.databaseBytes, 0)

        let repeated = try await fixture.store.select(selection: candidate.selection, intent: .initialize)
        XCTAssertEqual(repeated, selected)
        let repeatedContext = try await fixture.store.currentCanvasAccessContext()
        XCTAssertEqual(repeatedContext, context)
    }

    private func assertCorruptCandidatePreservesWorkspace(
        useAttachExisting: Bool,
        initialize: Bool = false
    ) async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let original = try await fixture.store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let originalContext = try await fixture.store.currentCanvasAccessContext()
        let originalDocument = try await fixture.store.read(path)
        let originalStatus = try await fixture.store.status()
        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-corrupt-configuration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateJournalDirectory = fixture.support
            .appendingPathComponent("LifeOS/Planning/\(candidateID.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateJournalDirectory, withIntermediateDirectories: true)
        try Data("corrupt journal".utf8).write(
            to: candidateJournalDirectory.appendingPathComponent("journal.sqlite"),
            options: .atomic
        )
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        do {
            if initialize {
                _ = try await fixture.store.select(selection: candidateSelection, intent: .initialize)
            } else if useAttachExisting {
                _ = try await fixture.store.attachExisting(selection: candidateSelection)
            } else {
                _ = try await fixture.store.select(
                    selection: candidateSelection,
                    intent: .attach(expectedVaultID: candidateID)
                )
            }
            XCTFail("A corrupt candidate journal must reject configuration.")
        } catch let error as PlanningStorageError {
            XCTAssertEqual(error, .corruptDatabase)
        } catch {
            XCTFail("Unexpected configuration error: \(error)")
        }

        let preserved = await fixture.store.accessSnapshot()
        let context = try await fixture.store.currentCanvasAccessContext()
        XCTAssertEqual(preserved, original)
        XCTAssertEqual(context, originalContext)
        let status = try await fixture.store.status()
        XCTAssertEqual(status.accessState, .ready)
        XCTAssertEqual(status.pendingMutationCount, originalStatus.pendingMutationCount)
        XCTAssertEqual(status.openConflictCount, originalStatus.openConflictCount)
        XCTAssertEqual(status.retainedPayloadBytes, originalStatus.retainedPayloadBytes)
        XCTAssertEqual(status.databaseBytes, originalStatus.databaseBytes)
        // Failed initialization must leave the candidate's existing marker intact.
        let markerLease = try PlanningSafeFileIO.openRoot(candidateRoot, expectedVaultID: candidateID)
        markerLease.close()
        let document = try await fixture.store.read(path)
        XCTAssertEqual(document.snapshot?.bytes, originalDocument.snapshot?.bytes)
        XCTAssertEqual(document.version, originalDocument.version)
        XCTAssertEqual(document.vaultID, original.vaultID)
        XCTAssertEqual(document.selectionGeneration, original.selectionGeneration)
        XCTAssertEqual(document.accessState, .ready)
        XCTAssertFalse(document.stale)
        XCTAssertFalse(document.fromCache)
    }

    func testAttachReplacesClosedMatchingJournalWithoutChangingGeneration() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let original = try await fixture.store.attachExisting(selection: fixture.selection)
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let originalContext = try await fixture.store.currentCanvasAccessContext()
        let originalDocument = try await fixture.store.read(path)
        let originalStatus = try await fixture.store.status()

        // Retain the installed resources and access; close only the journal.
        await fixture.store.closeInstalledJournalForTesting()
        let reattached = try await fixture.store.attachExisting(selection: fixture.selection)

        XCTAssertEqual(reattached, original)
        let context = try await fixture.store.currentCanvasAccessContext()
        XCTAssertEqual(context, originalContext)
        let status = try await fixture.store.status()
        XCTAssertEqual(status.accessState, .ready)
        XCTAssertEqual(status.pendingMutationCount, originalStatus.pendingMutationCount)
        XCTAssertEqual(status.openConflictCount, originalStatus.openConflictCount)
        let document = try await fixture.store.read(path)
        XCTAssertEqual(document.snapshot?.bytes, originalDocument.snapshot?.bytes)
        XCTAssertEqual(document.vaultID, original.vaultID)
        XCTAssertEqual(document.selectionGeneration, original.selectionGeneration)
        XCTAssertFalse(document.stale)
        XCTAssertFalse(document.fromCache)
    }

    func testRejectedReplacementPreservesCommittedAccessAndBalancesCandidateScope() async throws {
        let fixture = try fixture()
        let counter = PlanningWorkspaceScopeCounter()
        let strategy = PlanningSecurityScopeStrategy(
            start: { _ in counter.start() },
            stop: { _ in counter.stop() }
        )
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            scopeStrategy: strategy
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.support)
        }

        let selected = try await store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        let selectedContext = try await store.currentCanvasAccessContext()
        XCTAssertEqual(counter.counts.starts, 1)
        XCTAssertEqual(counter.counts.stops, 0)
        XCTAssertEqual(counter.counts.active, 1)

        let rejectedSelection = try PlanningUserSelectedDirectory.testFactory(url: fixture.root)
        do {
            _ = try await store.select(
                selection: rejectedSelection,
                intent: .attach(expectedVaultID: UUID())
            )
            XCTFail("A replacement with the wrong vault identity must fail.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .identityChanged)
        } catch {
            XCTFail("Unexpected replacement error: \(error)")
        }

        let afterFailure = access.snapshot
        XCTAssertEqual(afterFailure, selected)
        XCTAssertEqual(afterFailure.state, .ready)
        XCTAssertEqual(afterFailure.capabilities, selected.capabilities)
        let contextAfterFailure = try await store.currentCanvasAccessContext()
        XCTAssertEqual(contextAfterFailure, selectedContext)
        let leasedVaultID = try access.withLease { $0.vaultID }
        XCTAssertEqual(leasedVaultID, fixture.ownerID)
        XCTAssertEqual(counter.counts.starts, 2)
        XCTAssertEqual(counter.counts.stops, 1)
        XCTAssertEqual(counter.counts.active, 1)
        XCTAssertEqual(counter.counts.maximumActive, 2)

        await store.close()
        XCTAssertEqual(counter.counts.starts, 2)
        XCTAssertEqual(counter.counts.stops, 2)
        XCTAssertEqual(counter.counts.active, 0)
    }

    func testExistingInspectionDoesNotSelectOrInitialize() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let access = PlanningVaultAccess(
            applicationSupportDirectory: fixture.support,
            deviceID: UUID()
        )
        let identity = try access.inspectExistingSelection(fixture.selection)

        XCTAssertNotNil(identity.vaultID)
        XCTAssertEqual(access.snapshot.state, .unselected)
        XCTAssertNil(access.snapshot.vaultID)
    }

    func testAttachOpenPreservesCanvasUnknownFieldsAndKeepsProductionReadOnly() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        XCTAssertEqual(workspace.phase, .ready)
        XCTAssertEqual(workspace.accessSnapshot.state, .ready)

        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")
        XCTAssertEqual(workspace.openedPath?.value, "Projects/Personal.canvas")
        XCTAssertEqual(workspace.project?.document?.unknownFields["custom"], .string("keep"))
        XCTAssertFalse(workspace.project?.allowsEditing ?? true)
        XCTAssertFalse(workspace.project?.canEdit ?? true)
        XCTAssertFalse(workspace.project?.beginNodeDrag(id: "root") ?? true)

        let status = try await fixture.store.status()
        XCTAssertEqual(status.pendingMutationCount, 0)
        XCTAssertEqual(status.openConflictCount, 0)
    }

    func testReadOnlyAdapterRejectsStageAndPublish() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        let context = try await fixture.store.currentCanvasAccessContext()
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let bytes = Data(#"{"nodes":[],"edges":[]}"#.utf8)
        let request = try PlanningMutationRequest(
            vaultID: fixture.ownerID,
            path: path,
            operation: .replace,
            expectedVersion: PlanningContentVersion(data: Data("existing".utf8)),
            proposedBytes: bytes
        )
        let adapter = PlanningReadOnlyCanvasPersistence(store: fixture.store)

        do {
            _ = try await adapter.stage(request, expectedContext: context)
            XCTFail("A read-only workspace must reject staging.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .readOnly)
        }

        do {
            _ = try await adapter.publish(request, expectedContext: context)
            XCTFail("A read-only workspace must reject publication.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .readOnly)
        }
    }

    func testMissingCanvasFailsWithoutFabricatingEmptyDocumentAndPreservesPath() async throws {
        let fixture = try fixture(withCanvas: false)
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Missing.canvas")

        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.pathInput, "Projects/Missing.canvas")
        XCTAssertNil(workspace.project)
        XCTAssertEqual(workspace.lastFailure, .notFound)
        XCTAssertEqual(workspace.lastDiagnostic?.stage, .sessionRead)
        XCTAssertEqual(workspace.lastDiagnostic?.code, PlanningFilesystemError.notFound.stableCode)
    }

    func testMalformedCanvasReportsDecodeFailure() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        try Data("not a canvas".utf8).write(
            to: fixture.root.appendingPathComponent("LifeOS/Projects/Personal.canvas"),
            options: .atomic
        )

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")

        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.lastFailure, .decodeFailed)
        XCTAssertEqual(workspace.lastDiagnostic?.stage, .sessionRead)
        XCTAssertEqual(workspace.lastDiagnostic?.code, PlanningFilesystemError.malformedDocument.stableCode)
    }

    func testMarkdownAndTraversalInputsFailBeforeOpening() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)

        await workspace.openCanvas(relativePath: "Projects/Plan.md")
        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.lastFailure, .invalidPath)
        XCTAssertNil(workspace.project)

        await workspace.openCanvas(relativePath: "../Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.lastFailure, .invalidPath)
        XCTAssertNil(workspace.project)
    }

    func testInspectorOpensLifeOSMarkdownReferenceReadOnly() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let source = "# Inspector note\n\nRead-only body"
        let node = try makeFileNode(
            id: "note",
            reference: "LifeOS/Projects/Inspector.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(fixture, path: "Projects/Inspector.md", source: source)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        let project = try XCTUnwrap(workspace.project)

        project.selectNode("note")
        workspace.inspectNode(id: "note")
        XCTAssertTrue(workspace.isInspectorPresented)
        XCTAssertEqual(workspace.inspectorReference, "LifeOS/Projects/Inspector.md")
        XCTAssertEqual(workspace.inspectorNotePath?.value, "Projects/Inspector.md")
        XCTAssertFalse(project.canEdit)

        await workspace.openSelectedNodeNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .ready)
        XCTAssertEqual(workspace.inspectorNoteSource, source)
        XCTAssertEqual(workspace.inspectorReferenceFragment, nil)
        XCTAssertFalse(project.beginNodeDrag(id: "note"))
        let status = try await fixture.store.status()
        XCTAssertEqual(status.pendingMutationCount, 0)
    }

    func testInspectorStripsFragmentWithoutChangingStoredPath() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "fragment",
            reference: "LifeOS/Projects/Fragment.md#Section%20One#Second"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(
            fixture,
            path: "Projects/Fragment.md",
            source: "# Fragment\n\nSource remains selectable."
        )

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "fragment")

        XCTAssertEqual(workspace.inspectorReferencePath?.value, "Projects/Fragment.md")
        XCTAssertEqual(workspace.inspectorNotePath?.value, "Projects/Fragment.md")
        XCTAssertEqual(workspace.inspectorReferenceFragment, "Section%20One#Second")

        await workspace.openSelectedNodeNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .ready)
        XCTAssertEqual(workspace.inspectorNotePath?.value, "Projects/Fragment.md")
    }

    func testInspectorRejectsOutsideTraversalAndUnsupportedReferences() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let outside = try makeFileNode(id: "outside", reference: "Projects/Outside.md")
        let unsupported = try makeFileNode(
            id: "unsupported",
            reference: "LifeOS/Projects/Board.canvas"
        )
        let image = try makeFileNode(id: "image", reference: "LifeOS/Projects/Image.png")
        let wrongCase = try makeFileNode(id: "case", reference: "lifeos/Projects/Note.md")
        XCTAssertThrowsError(try makeFileNode(id: "traversal", reference: "LifeOS/../Outside.md"))
        XCTAssertThrowsError(try makeFileNode(id: "absolute", reference: "/LifeOS/Outside.md"))
        try writeCanvas(fixture, nodes: [outside, unsupported, image, wrongCase])

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")

        workspace.inspectNode(id: "outside")
        XCTAssertEqual(workspace.inspectorNoteStatus, .unsupported)
        XCTAssertEqual(workspace.inspectorFailure, .unsupportedReference)
        XCTAssertNil(workspace.inspectorReferencePath)
        XCTAssertNil(workspace.inspectorNotePath)

        workspace.inspectNode(id: "unsupported")
        XCTAssertEqual(workspace.inspectorNoteStatus, .unsupported)
        XCTAssertEqual(workspace.inspectorFailure, .unsupportedReference)
        XCTAssertEqual(workspace.inspectorReferencePath?.value, "Projects/Board.canvas")
        XCTAssertNil(workspace.inspectorNotePath)

        for id in ["image", "case"] {
            workspace.inspectNode(id: id)
            XCTAssertNil(workspace.inspectorNotePath)
            await workspace.openSelectedNodeNote()
            XCTAssertFalse(workspace.isInspectorNotePresented)
        }
        XCTAssertEqual(workspace.phase, .showingCanvas)
    }

    func testMissingInspectorNoteDoesNotCreateDocumentOrCloseCanvas() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "missing",
            reference: "LifeOS/Projects/Missing.md"
        )
        try writeCanvas(fixture, nodes: [node])

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        let project = try XCTUnwrap(workspace.project)
        workspace.inspectNode(id: "missing")

        await workspace.openSelectedNodeNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .failed)
        XCTAssertEqual(workspace.inspectorFailure, .notFound)
        XCTAssertNil(workspace.inspectorNoteSource)
        XCTAssertTrue(workspace.isInspectorPresented)
        XCTAssertTrue(workspace.isInspectorNotePresented)
        XCTAssertEqual(workspace.phase, .showingCanvas)
        XCTAssertTrue(workspace.project === project)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: noteURL(fixture, path: "Projects/Missing.md").path
        ))
    }

    func testMalformedInspectorNoteKeepsParentCanvas() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "malformed",
            reference: "LifeOS/Projects/Malformed.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(
            fixture,
            path: "Projects/Malformed.md",
            source: "---\ntitle: missing closing delimiter\n"
        )

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        let project = try XCTUnwrap(workspace.project)
        workspace.inspectNode(id: "malformed")

        await workspace.openSelectedNodeNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .failed)
        XCTAssertEqual(workspace.inspectorFailure, .decodeFailed)
        XCTAssertNil(workspace.inspectorNoteSource)
        XCTAssertEqual(workspace.phase, .showingCanvas)
        XCTAssertTrue(workspace.project === project)
        XCTAssertNil(workspace.lastFailure)
        XCTAssertNil(workspace.lastError)
    }

    func testInspectorRefreshReadsExternalReplacement() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "refresh",
            reference: "LifeOS/Projects/Refresh.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(fixture, path: "Projects/Refresh.md", source: "Initial source")

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "refresh")
        await workspace.openSelectedNodeNote()
        XCTAssertEqual(workspace.inspectorNoteStatus, .ready)

        try writeNote(fixture, path: "Projects/Refresh.md", source: "External replacement")
        await workspace.refreshInspectorNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .ready)
        XCTAssertEqual(workspace.inspectorNoteSource, "External replacement")
        XCTAssertNil(workspace.inspectorFailure)
        XCTAssertEqual(workspace.phase, .showingCanvas)
    }

    func testInspectorRefreshFailureRetainsOnlySameRoutePreviewAsStale() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "stale",
            reference: "LifeOS/Projects/Stale.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(fixture, path: "Projects/Stale.md", source: "Cached before failure")

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "stale")
        await workspace.openSelectedNodeNote()
        try FileManager.default.removeItem(at: noteURL(fixture, path: "Projects/Stale.md"))

        await workspace.refreshInspectorNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .stale)
        XCTAssertEqual(workspace.inspectorNoteSource, "Cached before failure")
        XCTAssertEqual(workspace.inspectorFailure, .notFound)
        XCTAssertNotEqual(workspace.inspectorNoteStatus, .ready)
        XCTAssertEqual(workspace.phase, .showingCanvas)
    }

    func testInspectorCachedReadIsNeverPresentedAsCurrent() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "cached",
            reference: "LifeOS/Projects/Cached.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(fixture, path: "Projects/Cached.md", source: "Last current source")

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "cached")
        await workspace.openSelectedNodeNote()
        XCTAssertEqual(workspace.inspectorNoteStatus, .ready)

        let url = noteURL(fixture, path: "Projects/Cached.md")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: url.path
            )
        }

        await workspace.refreshInspectorNote()

        XCTAssertEqual(workspace.inspectorNoteStatus, .stale)
        XCTAssertEqual(workspace.inspectorNoteSource, "Last current source")
        XCTAssertNotEqual(workspace.inspectorNoteStatus, .ready)
        XCTAssertEqual(workspace.inspectorFailure, .unavailable)
    }

    func testInspectorLateReadCannotReplaceNewSelection() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let first = try makeFileNode(id: "first", reference: "LifeOS/Projects/First.md")
        let second = try makeFileNode(id: "second", reference: "LifeOS/Projects/Second.md")
        try writeCanvas(fixture, nodes: [first, second])
        try writeNote(fixture, path: "Projects/First.md", source: "First")
        try writeNote(fixture, path: "Projects/Second.md", source: "Second")

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "first")
        let gate = PlanningWorkspaceTestGate()
        workspace.beforeInspectorRead = { await gate.wait() }
        let readTask = Task { await workspace.openSelectedNodeNote() }
        await gate.waitForEntry()

        workspace.inspectNode(id: "second")
        await gate.release()
        await readTask.value
        workspace.beforeInspectorRead = nil

        XCTAssertEqual(workspace.inspectorNode?.id, "second")
        XCTAssertEqual(workspace.project?.selectedNodeID, "second")
        XCTAssertNil(workspace.inspectorNoteSource)
        XCTAssertEqual(workspace.inspectorNoteStatus, .idle)
    }

    func testInspectorLateReadCannotPublishAfterCloseOrUnmount() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let node = try makeFileNode(
            id: "unmounted",
            reference: "LifeOS/Projects/Unmounted.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(fixture, path: "Projects/Unmounted.md", source: "Should not publish")

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "unmounted")
        let gate = PlanningWorkspaceTestGate()
        workspace.beforeInspectorRead = { await gate.wait() }
        let readTask = Task { await workspace.openSelectedNodeNote() }
        await gate.waitForEntry()

        workspace.requestUnmount()
        await gate.release()
        await readTask.value
        await workspace.unmount()
        workspace.beforeInspectorRead = nil

        XCTAssertFalse(workspace.isInspectorPresented)
        XCTAssertNil(workspace.inspectorNode)
        XCTAssertNil(workspace.inspectorNoteSource)
        XCTAssertNil(workspace.project)
        XCTAssertEqual(workspace.phase, .idle)
    }

    func testInspectorLateReadCannotPublishAfterVaultReplacement() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let replacement = try self.fixture()
        registerTeardown(for: replacement)
        let node = try makeFileNode(
            id: "old",
            reference: "LifeOS/Projects/Old.md"
        )
        try writeCanvas(fixture, nodes: [node])
        try writeNote(fixture, path: "Projects/Old.md", source: "Old vault")

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        workspace.inspectNode(id: "old")
        let gate = PlanningWorkspaceTestGate()
        workspace.beforeInspectorRead = { await gate.wait() }
        let readTask = Task { await workspace.openSelectedNodeNote() }
        await gate.waitForEntry()

        await workspace.attach(replacement.selection)
        await gate.release()
        await readTask.value
        workspace.beforeInspectorRead = nil

        XCTAssertEqual(workspace.phase, .ready)
        XCTAssertEqual(workspace.accessSnapshot.vaultID, replacement.ownerID)
        XCTAssertFalse(workspace.isInspectorPresented)
        XCTAssertNil(workspace.inspectorNoteSource)
        XCTAssertNil(workspace.project)
    }

    func testInspectorLateLoadedReadIsDiscardedAcrossLifecycleChanges() async throws {
        for action in ["selection", "dismiss", "back", "canvas", "close", "context"] {
            let fixture = try fixture()
            registerTeardown(for: fixture)
            let first = try makeFileNode(id: "first", reference: "LifeOS/Projects/First.md")
            let second = try makeFileNode(id: "second", reference: "LifeOS/Projects/Second.md")
            try writeCanvas(fixture, nodes: [first, second])
            try writeNote(fixture, path: "Projects/First.md", source: "Must not publish")
            let workspace = PlanningWorkspaceCoordinator(
                store: fixture.store, localGrantOwnerID: fixture.ownerID
            )
            await workspace.attach(fixture.selection)
            await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
            let project = try XCTUnwrap(workspace.project)
            workspace.inspectNode(id: "first")
            let gate = PlanningWorkspaceTestGate()
            workspace.afterInspectorRead = { await gate.wait() }
            let readTask = Task { await workspace.openSelectedNodeNote() }
            await gate.waitForEntry()

            switch action {
            case "selection":
                project.selectNode("second")
                project.selectNode("first")
                XCTAssertFalse(workspace.isInspectorPresented)
            case "dismiss": workspace.closeInspector()
            case "back": workspace.closeInspectorNote()
            case "canvas": await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
            case "close": workspace.closeDocument()
            case "context":
                // Replace the store's generation without updating the workspace
                // snapshot, exercising the live persistence authority check.
                let replacement = try self.fixture()
                registerTeardown(for: replacement)
                _ = try await fixture.store.attachExisting(selection: replacement.selection)
            default: XCTFail("Unknown test action")
            }
            await gate.release()
            await readTask.value
            workspace.afterInspectorRead = nil
            XCTAssertNil(workspace.inspectorNoteSource, action)
            XCTAssertNotEqual(workspace.inspectorNoteStatus, .ready, action)
            if action == "context" {
                XCTAssertEqual(workspace.inspectorNoteStatus, .unavailable)
                XCTAssertEqual(workspace.inspectorFailure, .contextMismatch)
            }
            if action == "back" || action == "dismiss" || action == "selection" {
                XCTAssertTrue(workspace.project === project)
                XCTAssertEqual(workspace.phase, .showingCanvas)
            }
            await workspace.unmount()
        }
    }

    func testInspectorTextGroupAndLinkAreMetadataOnly() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let nodes = [
            try PlanningCanvasNode(id: "text", type: .text, x: 0, y: 0,
                                   width: 200, height: 100, text: "Plain **source**"),
            try PlanningCanvasNode(id: "group", type: .group, x: 0, y: 0,
                                   width: 200, height: 100, label: "Group label"),
            try PlanningCanvasNode(id: "link", type: .link, x: 0, y: 0,
                                   width: 200, height: 100, url: "https://example.com")
        ]
        try writeCanvas(fixture, nodes: nodes)
        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store, localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        for node in nodes {
            workspace.inspectNode(id: node.id)
            XCTAssertEqual(workspace.inspectorNode, node)
            XCTAssertNil(workspace.inspectorNotePath)
            await workspace.openSelectedNodeNote()
            XCTAssertFalse(workspace.isInspectorNotePresented)
            XCTAssertNil(workspace.inspectorNoteSource)
        }
        let status = try await fixture.store.status()
        XCTAssertEqual(status.pendingMutationCount, 0)
    }

    func testStableGrantOwnerIdentifierSurvivesCoordinatorRecreation() {
        let suite = "LifeOS.P06B.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-owner-\(UUID().uuidString)", isDirectory: true)
        let first = PlanningWorkspaceCoordinator(
            applicationSupportDirectory: support,
            defaults: defaults
        )
        let second = PlanningWorkspaceCoordinator(
            applicationSupportDirectory: support,
            defaults: defaults
        )

        XCTAssertEqual(first.localGrantOwnerID, second.localGrantOwnerID)
    }

    func testCloseAndSuspendReleasePresentationWithoutChangingCalendarOwnedState() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")

        workspace.closeDocument()
        XCTAssertEqual(workspace.phase, .ready)
        XCTAssertNil(workspace.project)
        XCTAssertNil(workspace.openedPath)

        await workspace.suspend()
        XCTAssertEqual(workspace.phase, .idle)
        XCTAssertEqual(workspace.accessSnapshot.state, .needsReselection)
    }

    func testCancelledOpenCannotPublishAfterSuspendAndCanReattach() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        workspace.beforePresentationOpen = {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        let openTask = Task { await workspace.openCanvas(relativePath: "Projects/Personal.canvas") }
        for _ in 0..<100 where workspace.phase != .opening {
            await Task.yield()
        }
        XCTAssertEqual(workspace.phase, .opening)

        await workspace.suspend()
        await openTask.value
        XCTAssertEqual(workspace.phase, .idle)
        XCTAssertNil(workspace.project)
        XCTAssertNil(workspace.openedPath)

        workspace.beforePresentationOpen = nil
        await workspace.attach(fixture.selection)
        XCTAssertEqual(workspace.phase, .ready)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")
    }

    func testRetryReopensEditedPathAndKeepsTypedFailure() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Missing.canvas")
        XCTAssertEqual(workspace.lastFailure, .notFound)
        XCTAssertEqual(workspace.pathInput, "Projects/Missing.canvas")

        workspace.pathInput = "Projects/Personal.canvas"
        await workspace.retry()
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")
        XCTAssertEqual(workspace.openedPath?.value, "Projects/Personal.canvas")
    }

    func testContextFailureIsTypedAndReleasesWorkspaceLease() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await fixture.store.close()
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")

        XCTAssertEqual(workspace.phase, .needsReselection)
        XCTAssertEqual(workspace.lastFailure, .needsReselection)
        XCTAssertEqual(workspace.lastDiagnostic?.stage, .storeContext)
        XCTAssertEqual(workspace.lastDiagnostic?.code, PlanningFilesystemError.needsReselection.stableCode)

        await workspace.attach(fixture.selection)
        XCTAssertEqual(workspace.phase, .ready)
    }

    func testLeaseContentionReleasesAfterSuspension() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let secondStore = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await secondStore.close() }

        let first = PlanningWorkspaceCoordinator(store: fixture.store, localGrantOwnerID: fixture.ownerID)
        let second = PlanningWorkspaceCoordinator(store: secondStore, localGrantOwnerID: fixture.ownerID)
        await first.attach(fixture.selection)
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .unavailable)
        XCTAssertEqual(second.lastFailure, .unavailable)

        await first.suspend()
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .ready)
        await second.suspend()
    }

    func testRetryCannotReopenAfterDismissal() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Missing.canvas")
        XCTAssertEqual(workspace.lastFailure, .notFound)

        let gate = PlanningWorkspaceTestGate()
        workspace.pathInput = "Projects/Personal.canvas"
        workspace.beforeRetryOpen = { await gate.wait() }
        let retryTask = Task { await workspace.retry() }
        for _ in 0..<200 {
            if await gate.hasEntered { break }
            await Task.yield()
        }
        let retryGateEntered = await gate.hasEntered
        XCTAssertTrue(retryGateEntered)

        workspace.requestUnmount()
        await gate.release()
        await retryTask.value
        await workspace.unmount()

        XCTAssertEqual(workspace.phase, .idle)
        XCTAssertNil(workspace.project)
        XCTAssertNil(workspace.openedPath)
    }

    func testRemountWaitsForPendingCleanupBeforeReacquiringLease() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let secondStore = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await secondStore.close() }

        let first = PlanningWorkspaceCoordinator(store: fixture.store, localGrantOwnerID: fixture.ownerID)
        let second = PlanningWorkspaceCoordinator(store: secondStore, localGrantOwnerID: fixture.ownerID)
        await first.attach(fixture.selection)
        let original = first.accessSnapshot

        let gate = PlanningWorkspaceTestGate()
        first.beforeCleanupClose = { await gate.wait() }
        first.requestUnmount()
        for _ in 0..<200 {
            if await gate.hasEntered { break }
            await Task.yield()
        }
        let cleanupGateEntered = await gate.hasEntered
        XCTAssertTrue(cleanupGateEntered)

        let remountTask = Task { await first.mount() }
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .unavailable)

        await gate.release()
        await remountTask.value
        first.beforeCleanupClose = nil
        XCTAssertEqual(first.phase, .ready)
        XCTAssertEqual(first.accessSnapshot.vaultID, original.vaultID)
        XCTAssertEqual(first.accessSnapshot.selectionGeneration, original.selectionGeneration)

        await first.suspend()
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .ready)
        await second.suspend()
    }

    func testDestroyedCoordinatorRetainsLeaseUntilStoreClose() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let secondStore = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await secondStore.close() }

        let gate = PlanningWorkspaceTestGate()
        PlanningWorkspaceCoordinator.beforeDeinitStoreClose = { await gate.wait() }
        defer { PlanningWorkspaceCoordinator.beforeDeinitStoreClose = nil }

        var first: PlanningWorkspaceCoordinator? = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await first?.attach(fixture.selection)
        first = nil

        for _ in 0..<200 {
            if await gate.hasEntered { break }
            await Task.yield()
        }
        let deinitGateEntered = await gate.hasEntered
        XCTAssertTrue(deinitGateEntered)

        let second = PlanningWorkspaceCoordinator(store: secondStore, localGrantOwnerID: fixture.ownerID)
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .unavailable)

        await gate.release()
        for _ in 0..<200 {
            await second.attach(fixture.selection)
            if second.phase == .ready { break }
            await Task.yield()
        }
        XCTAssertEqual(second.phase, .ready)
        await second.suspend()
    }

    func testDiagnosticCodesDoNotEchoAssociatedInput() {
        XCTAssertEqual(
            PlanningFilesystemError.invalid("/private/user/secret.canvas").stableCode,
            "invalid.request"
        )
        XCTAssertEqual(
            PlanningCanvasSessionError.persistence("/private/user/secret").stableCode,
            "persistence.operation"
        )
    }
}
