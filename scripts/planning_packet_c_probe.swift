import Foundation

#if canImport(Darwin)
import Darwin
#endif

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case failed(String)
    case deadline
    case oversizedOutput

    var description: String {
        switch self {
        case .usage: return "usage"
        case .failed(let value): return value
        case .deadline: return "deadline"
        case .oversizedOutput: return "oversizedOutput"
        }
    }
}

private enum CrashBarrier: String, CaseIterable {
    case p1, p2, p3, p4, p5, p6, p7

    var exitCode: Int32 {
        switch self {
        case .p1: return 71
        case .p2: return 72
        case .p3: return 73
        case .p4: return 74
        case .p5: return 75
        case .p6: return 76
        case .p7: return 77
        }
    }
}

private enum PublicationScenario: String, CaseIterable {
    case create
    case replace
    case delete
}

private struct Fixture {
    let root: URL
    let support: URL
}

private let probeDeviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let probePayload = Data("---\ntitle: Packet C probe\n---\nprobe\n".utf8)
private let probeReplacementPayload = Data("---\ntitle: Packet C probe\n---\nreplacement\n".utf8)
private let probePath = try! PlanningStoredPath("Notes/probe.md")
private let probeOwnerPrefix = Data("lifeos-packet-c-probe-owner-v2:".utf8)

@main
private struct PlanningPacketCProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw ProbeError.usage }
            switch command {
            case "--child":
                guard arguments.count == 5,
                      let scenario = PublicationScenario(rawValue: arguments[1]),
                      let barrier = CrashBarrier(rawValue: arguments[2]) else {
                    throw ProbeError.usage
                }
                try await runChild(
                    scenario: scenario,
                    barrier: barrier,
                    root: URL(fileURLWithPath: arguments[3], isDirectory: true),
                    support: URL(fileURLWithPath: arguments[4], isDirectory: true)
                )
            case "--parent":
                guard arguments.count == 2 else { throw ProbeError.usage }
                try await runParent(
                    runDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true)
                )
            default:
                throw ProbeError.usage
            }
        } catch {
            print("PROBE_FAIL code=\(safeCode(error))")
            exit(1)
        }
    }

    private static func runChild(
        scenario: PublicationScenario,
        barrier: CrashBarrier,
        root: URL,
        support: URL
    ) async throws {
        var armed = false
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: probeDeviceID,
            testBarrier: { point in
                guard armed else { return }
                guard point.rawValue == barrier.rawValue else { return }
                terminateAt(barrier)
            }
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await store.select(selection: selection, intent: .initialize)
        guard let vaultID = selected.vaultID else { throw ProbeError.failed("child.selection") }
        if scenario != .create {
            let baseline = try PlanningMutationRequest(
                vaultID: vaultID,
                path: probePath,
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: probePayload
            )
            _ = try await store.stage(baseline)
            let baselineResult = try await store.publish(baseline)
            guard baselineResult.status == .published else {
                throw ProbeError.failed("child.baseline.\(scenario.rawValue)")
            }
        }
        let request: PlanningMutationRequest
        switch scenario {
        case .create:
            request = try PlanningMutationRequest(
                vaultID: vaultID,
                path: probePath,
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: probePayload
            )
        case .replace:
            request = try PlanningMutationRequest(
                vaultID: vaultID,
                path: probePath,
                operation: .replace,
                expectedVersion: PlanningContentVersion(data: probePayload),
                proposedBytes: probeReplacementPayload
            )
        case .delete:
            request = try PlanningMutationRequest(
                vaultID: vaultID,
                path: probePath,
                operation: .delete,
                expectedVersion: PlanningContentVersion(data: probePayload),
                proposedBytes: nil
            )
        }
        _ = try await store.stage(request)
        armed = true
        _ = try await store.publish(request)
        throw ProbeError.failed("child.didNotReachBarrier.\(scenario.rawValue).\(barrier.rawValue)")
    }

    private static func runParent(runDirectory: URL) async throws {
        try makeDirectory(runDirectory)
        var completed: [String] = []
        for scenario in PublicationScenario.allCases {
            for barrier in CrashBarrier.allCases {
                let fixture = try makeFixture(
                    parent: runDirectory,
                    label: "\(scenario.rawValue)-\(barrier.rawValue)-\(UUID().uuidString.lowercased())"
                )
                defer {
                    try? removeOwned(fixture.root)
                    try? removeOwned(fixture.support)
                }
                let child = try launchChild(
                    scenario: scenario,
                    barrier: barrier,
                    fixture: fixture
                )
                guard child.terminationStatus == barrier.exitCode else {
                    throw ProbeError.failed("child.\(scenario.rawValue).\(barrier.rawValue).exit\(child.terminationStatus)")
                }
                try await recover(fixture: fixture, scenario: scenario, barrier: barrier)
                completed.append("\(scenario.rawValue)-\(barrier.rawValue)")
            }
        }
        try await runSameInodeRecoveryAdversary(parent: runDirectory)
        try runAdversaries(parent: runDirectory)
        print("PROBE_PASS recovery=\(completed.joined(separator: ",")) adversary=parent-substitution,same-inode,symlink,hardlink,fifo")
    }

    private static func recover(
        fixture: Fixture,
        scenario: PublicationScenario,
        barrier: CrashBarrier
    ) async throws {
        let identity = try readMarker(root: fixture.root)
        let store = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: probeDeviceID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: fixture.root)
        _ = try await store.select(
            selection: selection,
            intent: .attach(expectedVaultID: identity.vaultID)
        )
        let first = try await store.publishPendingPage()
        let status = try await store.status()
        if barrier == .p7 {
            guard first.examined == 0,
                  first.reconciled == 0,
                  first.blocked == 0,
                  first.errorCodes.isEmpty,
                  status.pendingMutationCount == 0 else {
                throw ProbeError.failed("recovery.p7.examined=\(first.examined).reconciled=\(first.reconciled).blocked=\(first.blocked).pending=\(status.pendingMutationCount)")
            }
        } else {
            guard first.examined == 1,
                  first.reconciled == 1,
                  first.blocked == 0,
                  first.errorCodes.isEmpty,
                  status.pendingMutationCount == 0 else {
                throw ProbeError.failed("recovery.\(barrier.rawValue).examined=\(first.examined).reconciled=\(first.reconciled).blocked=\(first.blocked).errors=\(first.errorCodes.joined(separator: ",")).pending=\(status.pendingMutationCount)")
            }
        }
        let read = try await store.read(probePath)
        switch scenario {
        case .create:
            guard read.snapshot?.bytes == probePayload else {
                throw ProbeError.failed("recovery.\(scenario.rawValue).\(barrier.rawValue).bytes")
            }
        case .replace:
            guard read.snapshot?.bytes == probeReplacementPayload else {
                throw ProbeError.failed("recovery.\(scenario.rawValue).\(barrier.rawValue).bytes")
            }
        case .delete:
            guard read.version == .absent else {
                throw ProbeError.failed("recovery.\(scenario.rawValue).\(barrier.rawValue).notDeleted")
            }
        }
        let second = try await store.publishPendingPage(after: first.nextCursor)
        guard second.examined == 0,
              second.reconciled == 0,
              second.blocked == 0,
              second.errorCodes.isEmpty,
              second.endOfPass else {
            throw ProbeError.failed("recovery.\(barrier.rawValue).replay")
        }
        await store.close()
    }

    private static func runSameInodeRecoveryAdversary(parent: URL) async throws {
        let fixture = try makeFixture(parent: parent, label: "same-inode-\(UUID().uuidString.lowercased())")
        defer {
            try? removeOwned(fixture.root)
            try? removeOwned(fixture.support)
        }
        let child = try launchChild(scenario: .create, barrier: .p3, fixture: fixture)
        guard child.terminationStatus == CrashBarrier.p3.exitCode else {
            throw ProbeError.failed("sameInode.child.exit\(child.terminationStatus)")
        }
        let manifest = try loadOnlyManifest(support: fixture.support)
        let witnessURL = fixture.root
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent(manifest.witnessName, isDirectory: false)
        let changed = Data(repeating: 0x58, count: probePayload.count)
        try overwriteInPlace(witnessURL, data: changed)
        let identity = try readMarker(root: fixture.root)
        let store = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: probeDeviceID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: fixture.root)
        _ = try await store.select(selection: selection, intent: .attach(expectedVaultID: identity.vaultID)
        )
        let result = try await store.publishPendingPage()
        guard result.examined == 1,
              result.reconciled == 0,
              result.blocked == 1,
              result.errorCodes.contains("conflict") else {
            throw ProbeError.failed("sameInode.recovery.examined=\(result.examined).reconciled=\(result.reconciled).blocked=\(result.blocked).errors=\(result.errorCodes.joined(separator: ","))")
        }
        let targetURL = fixture.root
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("probe.md", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: targetURL.path),
              try Data(contentsOf: witnessURL) == changed else {
            throw ProbeError.failed("sameInode.evidenceLost")
        }
        print("PROBE_SAME_INODE_PASS conflict=preserved")
    }

    private static func runAdversaries(parent: URL) throws {
        let fixture = try makeFixture(parent: parent, label: "adversary-\(UUID().uuidString.lowercased())")
        defer {
            try? removeOwned(fixture.root)
            try? removeOwned(fixture.support)
        }
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: probeDeviceID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: fixture.root)
        _ = try access.select(selection: selection, intent: .initialize)
        let outside = fixture.root.appendingPathComponent("outside-sentinel.md")
        let sentinel = Data("outside-sentinel\n".utf8)
        try sentinel.write(to: outside, options: [.atomic])

        try access.withLease { lease in
            let parentHandle = try PlanningSafeFileIO.openParent(
                lease,
                path: probePath,
                createMissing: true
            )
            defer { parentHandle.close() }
            _ = try PlanningSafeFileIO.createExclusive(
                parentHandle,
                name: parentHandle.leafName,
                data: probePayload
            )

            let notesURL = fixture.root
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
            let symlinkURL = notesURL.appendingPathComponent("Symlink.md")
            try FileManager.default.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: outside.path
            )
            try expectFailure("symlink") {
                _ = try PlanningSafeFileIO.readBounded(
                    lease,
                    path: try PlanningStoredPath("Notes/Symlink.md")
                )
            }

#if canImport(Darwin)
            let hardURL = notesURL.appendingPathComponent("Hard.md")
            guard Darwin.link(outside.path, hardURL.path) == 0 else {
                throw ProbeError.failed("adversary.hardlink.create")
            }
            try expectFailure("hardlink") {
                _ = try PlanningSafeFileIO.readBounded(
                    lease,
                    path: try PlanningStoredPath("Notes/Hard.md")
                )
            }

            let fifoURL = notesURL.appendingPathComponent("Fifo.md")
            guard mkfifo(fifoURL.path, mode_t(0o600)) == 0 else {
                throw ProbeError.failed("adversary.fifo.create")
            }
            try expectFailure("fifo") {
                _ = try PlanningSafeFileIO.readBounded(
                    lease,
                    path: try PlanningStoredPath("Notes/Fifo.md")
                )
            }
#else
            throw ProbeError.failed("adversary.darwinUnsupported")
#endif
        }
        guard try Data(contentsOf: outside) == sentinel else {
            throw ProbeError.failed("adversary.sentinelChanged")
        }

        let substitutionRoot = fixture.root.appendingPathComponent("Substitution", isDirectory: true)
        try makeDirectory(substitutionRoot)
        let substitutionSupport = fixture.support.appendingPathComponent("substitution", isDirectory: true)
        try makeDirectory(substitutionSupport)
        let substitutionAccess = try PlanningVaultAccess.makeTesting(
            rootURL: substitutionRoot,
            applicationSupportDirectory: substitutionSupport,
            deviceID: probeDeviceID
        )
        let substitutionSelection = try PlanningUserSelectedDirectory.testFactory(url: substitutionRoot)
        _ = try substitutionAccess.select(selection: substitutionSelection, intent: .initialize)
        try substitutionAccess.withLease { lease in
            let parent = try PlanningSafeFileIO.openParent(lease, path: probePath, createMissing: true)
            defer { parent.close() }
            let notes = substitutionRoot.appendingPathComponent("LifeOS/Notes", isDirectory: true)
            let moved = substitutionRoot.appendingPathComponent("LifeOS/Notes-moved", isDirectory: true)
            try FileManager.default.moveItem(at: notes, to: moved)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            try expectFailure("parentSubstitution") {
                try PlanningSafeFileIO.verifyParentChain(
                    lease,
                    path: probePath,
                    expected: parent.parentChain
                )
            }
        }
        print("PROBE_ADVERSARY_PASS symlink=blocked hardlink=blocked fifo=blocked parentSubstitution=blocked sentinel=preserved")
    }

    private static func launchChild(
        scenario: PublicationScenario,
        barrier: CrashBarrier,
        fixture: Fixture
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "--child",
            scenario.rawValue,
            barrier.rawValue,
            fixture.root.path,
            fixture.support.path
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw ProbeError.deadline
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard stdout.count <= 64 * 1024, stderr.count <= 64 * 1024 else {
            throw ProbeError.oversizedOutput
        }
        if let text = String(data: stdout, encoding: .utf8), !text.isEmpty {
            print("PROBE_CHILD_OUTPUT barrier=\(barrier.rawValue) \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let text = String(data: stderr, encoding: .utf8), !text.isEmpty {
            print("PROBE_CHILD_ERROR barrier=\(barrier.rawValue) \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return process
    }

    private static func loadOnlyManifest(support: URL) throws -> PlanningFilesystemAttemptRecord {
        let directory = support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Planning", isDirectory: true)
        let vaultDirectories = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let filesystemDirectories = vaultDirectories.flatMap { vaultDirectory in
            let filesystem = vaultDirectory.appendingPathComponent("filesystem", isDirectory: true)
            return (try? FileManager.default.contentsOfDirectory(at: filesystem, includingPropertiesForKeys: nil)) ?? []
        }
        let manifests = filesystemDirectories.filter { $0.pathExtension == "json" }
        guard manifests.count == 1 else { throw ProbeError.failed("manifest.count=\(manifests.count)") }
        let data = try Data(contentsOf: manifests[0])
        guard data.count <= PlanningFilesystemLimits.maximumManifestBytes else {
            throw ProbeError.failed("manifest.oversized")
        }
        return try JSONDecoder().decode(PlanningFilesystemAttemptRecord.self, from: data)
    }

    private static func overwriteInPlace(_ url: URL, data: Data) throws {
#if canImport(Darwin)
        let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw ProbeError.failed("sameInode.open") }
        defer { _ = Darwin.close(fd) }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.pwrite(
                    fd,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset,
                    off_t(offset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProbeError.failed("sameInode.write")
                }
                guard count > 0 else { throw ProbeError.failed("sameInode.shortWrite") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ProbeError.failed("sameInode.flush") }
#else
        throw ProbeError.failed("sameInode.unsupported")
#endif
    }

    private static func makeFixture(parent: URL, label: String) throws -> Fixture {
        let root = parent.appendingPathComponent("root-\(label)", isDirectory: true)
        let support = parent.appendingPathComponent("support-\(label)", isDirectory: true)
        try makeDirectory(root)
        try makeDirectory(support)
        let owner = probeOwnerPrefix + Data("\(UUID().uuidString.lowercased())\n".utf8)
        try owner.write(to: root.appendingPathComponent(".packet-c-owner"), options: [.atomic])
        try owner.write(to: support.appendingPathComponent(".packet-c-owner"), options: [.atomic])
        return Fixture(root: root, support: support)
    }

    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    private static func removeOwned(_ url: URL) throws {
        let marker = url.appendingPathComponent(".packet-c-owner")
        let owner = try Data(contentsOf: marker)
        guard owner.starts(with: probeOwnerPrefix) else {
            throw ProbeError.failed("cleanup.ownerInvalid")
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func readMarker(root: URL) throws -> PlanningVaultIdentity {
        let url = root.appendingPathComponent("LifeOS/.lifeos-vault.json")
        let data = try Data(contentsOf: url)
        guard data.count <= PlanningFilesystemLimits.maximumMarkerBytes else {
            throw ProbeError.failed("marker.oversized")
        }
        return try JSONDecoder().decode(PlanningVaultIdentity.self, from: data)
    }

    private static func expectFailure(_ label: String, operation: () throws -> Void) throws {
        do {
            try operation()
            throw ProbeError.failed("adversary.\(label).accepted")
        } catch let error as ProbeError {
            throw error
        } catch {
            print("PROBE_ADVERSARY_CASE name=\(label) code=\(safeCode(error))")
        }
    }

    private static func terminateAt(_ barrier: CrashBarrier) -> Never {
        print("PROBE_CHILD_BARRIER name=\(barrier.rawValue)")
        fflush(stdout)
#if canImport(Darwin)
        Darwin._exit(barrier.exitCode)
#else
        exit(barrier.exitCode)
#endif
    }

    private static func safeCode(_ error: Error) -> String {
        if let error = error as? PlanningFilesystemError { return error.stableCode }
        if let error = error as? PlanningStorageError {
            switch error {
            case .databaseFull: return "diskFull"
            case .writerBusy: return "writerBusy"
            case .closed: return "closed"
            case .staleAccess: return "needsReselection"
            default: return "storageError"
            }
        }
        if let error = error as? ProbeError { return error.description }
        return "probeError"
    }
}
