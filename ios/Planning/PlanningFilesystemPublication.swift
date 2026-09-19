import Foundation

#if canImport(Darwin)
import Darwin
#endif

internal enum PlanningFilesystemBarrier: String, Sendable, CaseIterable {
    case p1
    case p2
    case p3
    case p4
    case p5
    case p6
    case p7
    case beforeParentCreation
    case cleanupAfterWitness
    case cleanupAfterBackup
}

public final class PlanningFilesystemPublication: @unchecked Sendable {
    private let journal: PlanningMutationJournal
    private let access: PlanningVaultAccess
    private let coordination: PlanningCoordinatedAccess
    private let manifests: PlanningFilesystemAttemptStore
    private let testBarrier: ((PlanningFilesystemBarrier) throws -> Void)?
    private let clock: () -> Date
    private var cleanupAfterAttemptID: UUID?

    public convenience init(
        journal: PlanningMutationJournal,
        access: PlanningVaultAccess,
        applicationSupportDirectory: URL,
        coordination: PlanningCoordinatedAccess = PlanningCoordinatedAccess()
    ) {
        self.init(
            journal: journal,
            access: access,
            applicationSupportDirectory: applicationSupportDirectory,
            coordination: coordination,
            testBarrier: nil,
            clock: { Date() },
            marker: ()
        )
    }

    internal convenience init(
        journal: PlanningMutationJournal,
        access: PlanningVaultAccess,
        applicationSupportDirectory: URL,
        coordination: PlanningCoordinatedAccess = PlanningCoordinatedAccess(),
        testBarrier: ((PlanningFilesystemBarrier) throws -> Void)?,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.init(
            journal: journal,
            access: access,
            applicationSupportDirectory: applicationSupportDirectory,
            coordination: coordination,
            testBarrier: testBarrier,
            clock: clock,
            marker: ()
        )
    }

    private init(
        journal: PlanningMutationJournal,
        access: PlanningVaultAccess,
        applicationSupportDirectory: URL,
        coordination: PlanningCoordinatedAccess,
        testBarrier: ((PlanningFilesystemBarrier) throws -> Void)?,
        clock: @escaping () -> Date,
        marker: Void
    ) {
        self.journal = journal
        self.access = access
        self.coordination = coordination
        self.testBarrier = testBarrier
        self.clock = clock
        self.manifests = PlanningFilesystemAttemptStore(
            directory: applicationSupportDirectory
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Planning", isDirectory: true)
                .appendingPathComponent(journal.vault.vaultID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("filesystem", isDirectory: true)
        )
    }

    @discardableResult
    public func publish(
        _ request: PlanningMutationRequest,
        attemptID: UUID? = nil
    ) throws -> PlanningFilesystemPublishResult {
        try access.requirePublishCapability()
        guard request.vaultID == journal.vault.vaultID else {
            throw PlanningFilesystemError.invalid("request.vault")
        }
        let currentReceipt = try validateImmutableRequest(
            request,
            requestedAttemptID: attemptID
        )
        if let deferred = try retryDeferredResult(
            for: request,
            receipt: currentReceipt
        ) {
            return deferred
        }
        switch currentReceipt.state {
        case .published:
            return PlanningFilesystemPublishResult(
                status: .published,
                receipt: currentReceipt,
                version: currentReceipt.resultVersion
            )
        case .conflicted, .resolved:
            return PlanningFilesystemPublishResult(
                status: .conflicted,
                receipt: currentReceipt,
                errorCode: "conflict"
            )
        case .cancelled, .failed:
            break
        case .staged, .prepared, .stageReady, .publishing:
            break
        }
        let result: PlanningFilesystemPublishResult
        if let existingAttempt = try journal.publicationAttempt(for: request.mutationID),
           existingAttempt.phase == .publishing {
            let recoveryEntry = PlanningPublicationRecoveryEntry(
                recovery: PlanningRecoveryEntry(
                    mutationID: request.mutationID,
                    state: .publishing,
                    request: request,
                    attemptID: existingAttempt.attemptID
                ),
                attempt: existingAttempt,
                sequence: 0
            )
            result = try reconcile(recoveryEntry)
        } else {
            result = try coordinatedWrite(path: request.path, deleting: request.operation == .delete) { lease, checkCancellation in
                try self.publishOnLease(
                    request,
                    lease: lease,
                    attemptID: attemptID,
                    checkCancellation: checkCancellation
                )
            }
        }
        guard result.status == .published || result.status == .reconciled else {
            return result
        }
        do {
            try cleanupPublishedEvidence(for: request.mutationID)
            return result
        } catch {
            return PlanningFilesystemPublishResult(
                status: result.status,
                receipt: result.receipt,
                version: result.version,
                errorCode: "cleanupPending"
            )
        }
    }

    public func reconcile(
        _ entry: PlanningPublicationRecoveryEntry
    ) throws -> PlanningFilesystemPublishResult {
        try access.requirePublishCapability()
        guard entry.recovery.request.vaultID == journal.vault.vaultID else {
            throw PlanningFilesystemError.invalid("recovery.vault")
        }
        let request = entry.recovery.request
        _ = try validateImmutableRequest(
            request,
            requestedAttemptID: entry.attempt?.attemptID
        )
        if entry.recovery.state == .staged {
            guard entry.attempt == nil else {
                return PlanningFilesystemPublishResult(status: .blocked, errorCode: "corruptEvidence")
            }
            return try publish(request)
        }
        guard let attempt = entry.attempt, !attempt.legacyUnverified else {
            return PlanningFilesystemPublishResult(status: .blocked, errorCode: "corruptEvidence")
        }
        guard let context = attempt.context else {
            return PlanningFilesystemPublishResult(status: .blocked, errorCode: "corruptEvidence")
        }
        switch attempt.phase {
        case .prepared, .stageReady:
            return try publish(request, attemptID: attempt.attemptID)
        case .publishing:
            return try coordinatedWrite(path: request.path, deleting: request.operation == .delete) { lease, checkCancellation in
                try PlanningSafeFileIO.verifyChain(
                    lease,
                    expectedRoot: lease.rootIdentity,
                    expectedLifeOS: context.rootIdentity,
                    expectedVaultID: self.journal.vault.vaultID
                )
                return try self.continuePublishing(
                    request,
                    attempt: attempt,
                    lease: lease,
                    checkCancellation: checkCancellation
                )
            }
        case .conflicted:
            return PlanningFilesystemPublishResult(status: .conflicted, errorCode: "conflict")
        case .failed:
            guard case .failed(let code, let retryable)? = attempt.outcome else {
                return PlanningFilesystemPublishResult(status: .blocked, errorCode: "corruptEvidence")
            }
            guard retryable else {
                return PlanningFilesystemPublishResult(status: .reconciled)
            }
            guard let retryAfter = attempt.retryAfter else {
                return PlanningFilesystemPublishResult(status: .blocked, errorCode: "corruptEvidence")
            }
            guard clock() >= retryAfter else {
                return PlanningFilesystemPublishResult(status: .queued, errorCode: code)
            }
            return try publish(request)
        case .published:
            return PlanningFilesystemPublishResult(status: .reconciled)
        }
    }

    private func validateImmutableRequest(
        _ request: PlanningMutationRequest,
        requestedAttemptID: UUID?
    ) throws -> PlanningMutationReceipt {
        let receipt = try journal.stageMutation(request)
        guard receipt.mutationID == request.mutationID,
              receipt.fingerprint == request.fingerprint else {
            throw PlanningFilesystemError.corruptEvidence
        }

        let attempt = try journal.publicationAttempt(for: request.mutationID)
        if let requestedAttemptID {
            guard let attempt, attempt.attemptID == requestedAttemptID else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
        guard let attempt else { return receipt }
        guard attempt.mutationID == request.mutationID else {
            throw PlanningFilesystemError.corruptEvidence
        }
        if let context = attempt.context {
            guard context.observedVersion == request.expectedVersion else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }

        guard let manifest = try manifests.load(attemptID: attempt.attemptID) else {
            // A published attempt may already have had its private evidence
            // cleaned. A prepared attempt can be interrupted after the
            // journal row is durable but before parent creation and manifest
            // persistence; it is safe to reconstruct only that exact
            // pre-evidence state. Witnessed or staged attempts still require
            // their manifest and lineage evidence.
            guard attempt.phase == .published
                || (attempt.phase == .prepared
                    && !attempt.legacyUnverified
                    && attempt.witnessName == nil
                    && attempt.stagedIdentity == nil) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            return receipt
        }
        try validateManifestLineage(
            manifest,
            request: request,
            attempt: attempt
        )
        return receipt
    }

    private func retryDeferredResult(
        for request: PlanningMutationRequest,
        receipt: PlanningMutationReceipt
    ) throws -> PlanningFilesystemPublishResult? {
        guard let attempt = try journal.publicationAttempt(for: request.mutationID),
              attempt.phase == .failed,
              case .failed(let code, let retryable)? = attempt.outcome,
              retryable else {
            return nil
        }
        guard let retryAfter = attempt.retryAfter else {
            throw PlanningFilesystemError.corruptEvidence
        }
        guard clock() < retryAfter else { return nil }
        return PlanningFilesystemPublishResult(
            status: .queued,
            receipt: receipt,
            errorCode: code
        )
    }

    private func validateManifestLineage(
        _ manifest: PlanningFilesystemAttemptRecord,
        request: PlanningMutationRequest,
        attempt: PlanningPublicationAttemptSnapshot
    ) throws {
        let proposedVersion = request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
        let expectedWitness = ".lifeos-stage-\(attempt.attemptID.uuidString.lowercased())"
        guard manifest.vaultID == request.vaultID,
              manifest.deviceID == journal.deviceID,
              manifest.mutationID == request.mutationID,
              manifest.mutationFingerprint == request.fingerprint,
              manifest.attemptID == attempt.attemptID,
              manifest.operation == request.operation,
              manifest.path == request.path,
              manifest.expectedVersion == request.expectedVersion,
              manifest.proposedVersion == proposedVersion,
              manifest.witnessName == (attempt.witnessName ?? expectedWitness),
              manifest.stageIdentity == attempt.stagedIdentity else {
            throw PlanningFilesystemError.corruptEvidence
        }
        if let context = attempt.context {
            guard manifest.selectionGeneration == context.selectionGeneration,
                  manifest.rootIdentity == context.rootIdentity else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
        switch request.operation {
        case .create:
            guard manifest.backupIdentity == nil,
                  manifest.backupVersion == nil,
                  manifest.backupDigest == nil else {
                throw PlanningFilesystemError.corruptEvidence
            }
        case .replace, .delete:
            guard manifest.backupIdentity != nil,
                  manifest.backupVersion == request.expectedVersion,
                  manifest.backupDigest != nil else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
        if case .published(let version)? = manifest.verifiedOutcome {
            guard version == proposedVersion else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
    }

    @discardableResult
    public func preserveConflict(_ conflict: PlanningConflict) throws -> PlanningMutationReceipt {
        try journal.recordConflict(conflict)
    }

    internal func cleanupPublishedEvidence(for mutationID: UUID) throws {
        try access.requirePublishCapability()
        guard let attempt = try journal.publicationAttempt(for: mutationID),
              attempt.phase == .published,
              let record = try manifests.load(attemptID: attempt.attemptID) else {
            return
        }
        switch record.phase {
        case .verified:
            try cleanupVerified(record)
        case .cleanupPending where record.errorCode == "cleanupStarted":
            try cleanupRecord(record, resumed: true)
        default:
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    internal func cleanupPublishedArtifacts(
        maximumRecords: Int = PlanningFilesystemLimits.maximumRecoveryEntries,
        deadlineNanoseconds: UInt64? = nil
    ) throws -> [String] {
        try access.requirePublishCapability()
        guard maximumRecords > 0 else { return [] }
        let records = try manifests.records(
            limit: maximumRecords,
            after: cleanupAfterAttemptID
        )
        guard !records.isEmpty else {
            cleanupAfterAttemptID = nil
            return []
        }
        var errorCodes: [String] = []
        var processed = 0
        for record in records {
            if let deadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
                break
            }
            do {
                try cleanupPublishedEvidence(for: record.mutationID)
            } catch {
                errorCodes.append(planningFilesystemSafeErrorCode(error))
            }
            cleanupAfterAttemptID = record.attemptID
            processed += 1
        }
        if processed == records.count && records.count < maximumRecords {
            cleanupAfterAttemptID = nil
        }
        return errorCodes
    }

    public func cleanupVerified(_ record: PlanningFilesystemAttemptRecord) throws {
        try access.requirePublishCapability()
        try validatePublishedRecord(record, allowCleanupMarker: false)
        try cleanupRecord(record, resumed: false)
    }

    private func validatePublishedRecord(
        _ record: PlanningFilesystemAttemptRecord,
        allowCleanupMarker: Bool
    ) throws {
        let receipt = try journal.receipt(for: record.mutationID)
        guard let receipt, receipt.state == .published,
              receipt.resultVersion == record.verifiedOutcome.flatMap({
                  if case .published(let version) = $0 { return version }
                  return nil
              }),
              record.verifiedOutcome != nil else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let phaseIsValid = record.phase == .verified
            || (allowCleanupMarker
                && record.phase == .cleanupPending
                && record.errorCode == "cleanupStarted")
        guard phaseIsValid else { throw PlanningFilesystemError.corruptEvidence }
        guard let attempt = try journal.publicationAttempt(for: record.mutationID),
              attempt.attemptID == record.attemptID,
              attempt.phase == .published,
              case .published? = attempt.outcome else {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    private func cleanupRecord(
        _ record: PlanningFilesystemAttemptRecord,
        resumed: Bool
    ) throws {
        try validatePublishedRecord(record, allowCleanupMarker: resumed)
        try coordinatedWrite(path: record.path, deleting: false) { lease, checkCancellation in
            guard lease.generation == record.selectionGeneration,
                  lease.lifeOSIdentity == record.rootIdentity,
                  lease.vaultID == record.vaultID else {
                throw PlanningFilesystemError.identityChanged
            }
            try PlanningSafeFileIO.verifyChain(
                lease,
                expectedRoot: lease.rootIdentity,
                expectedLifeOS: record.rootIdentity,
                expectedParentChain: record.parentChain,
                path: record.path,
                expectedVaultID: record.vaultID
            )
            let parent = try PlanningSafeFileIO.openParent(lease, path: record.path)
            defer { parent.close() }
            let target = try PlanningSafeFileIO.readNamedBoundedFromParent(
                parent,
                name: parent.leafName
            )
            let witness = try PlanningSafeFileIO.readNamedBoundedFromParent(
                parent,
                name: record.witnessName
            )
            let backup = resumed
                ? try self.manifests.loadBackupIfPresent(for: record)
                : try self.manifests.loadBackup(for: record)
            if let backup {
                guard record.backupDigest == PlanningContentVersion(data: backup).digest,
                      record.backupVersion == Optional(PlanningContentVersion(data: backup)) else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            } else if !resumed, record.backupDigest != nil {
                throw PlanningFilesystemError.corruptEvidence
            }
            let backupMatches: (PlanningRawFileRead?) -> Bool = { raw in
                guard let raw, let backup else { return false }
                return raw.identity == record.backupIdentity
                    && raw.data == backup
                    && PlanningContentVersion(data: raw.data) == record.backupVersion
            }
            let recordedBackupMatches: (PlanningRawFileRead?) -> Bool = { raw in
                guard let raw else { return false }
                return raw.identity == record.backupIdentity
                    && PlanningContentVersion(data: raw.data) == record.backupVersion
            }
            switch record.operation {
            case .create:
                guard witness == nil, backup == nil,
                      target.map({ $0.identity.fileType == 1 }) ?? true else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            case .replace, .delete:
                guard record.backupDigest != nil else {
                    throw PlanningFilesystemError.corruptEvidence
                }
                let witnessMatchesBackup: Bool
                if backup != nil {
                    witnessMatchesBackup = backupMatches(witness)
                        || (resumed && witness == nil)
                } else {
                    witnessMatchesBackup = witness == nil
                        || (resumed && recordedBackupMatches(witness))
                }
                let targetCanBePreserved = target.map {
                    $0.identity.fileType == 1 && $0.identity != record.backupIdentity
                } ?? true
                let valid = targetCanBePreserved && witnessMatchesBackup
                guard valid,
                      (backup != nil || resumed) else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            }
            try checkCancellation()
            var cleanupRecord = record
            if !resumed {
                cleanupRecord = try self.markCleanupStarted(record)
                try self.saveManifest(cleanupRecord, backup: backup, lease: lease)
            }
            if let witness {
                try self.access.validateLease(lease)
                try checkCancellation()
                try PlanningSafeFileIO.removeVerified(
                    parent,
                    name: record.witnessName,
                    expected: witness.identity
                )
                try PlanningSafeFileIO.flush(parent.fileDescriptor, directory: true)
                try PlanningSafeFileIO.verifyParentChain(
                    lease,
                    path: record.path,
                    expected: record.parentChain
                )
            }
            try self.testBarrier?(.cleanupAfterWitness)
            try checkCancellation()
            try self.manifests.removeVerified(
                cleanupRecord,
                checkCancellation: checkCancellation,
                afterBackup: { try self.testBarrier?(.cleanupAfterBackup) }
            )
        }
    }

    private func coordinatedWrite<T>(
        path: PlanningStoredPath,
        deleting: Bool,
        _ body: @escaping (PlanningDirectoryLease, @escaping () throws -> Void) throws -> T
    ) throws -> T {
        try access.requirePublishCapability()
        guard let rootURL = access.selectedRootURL,
              let generation = access.snapshot.selectionGeneration else {
            throw PlanningFilesystemError.unselected
        }
        let token = PlanningCoordinationToken(generation: generation)
        let targetURL = rootURL
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(path.value, isDirectory: false)
        // The coordinator owns the namespace wait; descriptor I/O is opened
        // only inside its returned parent URL accessor.
        return try coordination.writeWithCancellationCheck(
            parentURL: rootURL,
            targetURL: targetURL,
            deleting: deleting,
            token: token
        ) { coordinatedRoot, coordinatedTarget, checkCancellation in
            try checkCancellation()
            guard coordinatedRoot.standardizedFileURL == rootURL.standardizedFileURL,
                  coordinatedRoot.pathComponents == rootURL.standardizedFileURL.pathComponents,
                  coordinatedTarget.standardizedFileURL == targetURL.standardizedFileURL,
                  coordinatedTarget.pathComponents == targetURL.standardizedFileURL.pathComponents else {
                throw PlanningFilesystemError.identityChanged
            }
            return try self.access.withLease(
                coordinatedRootURL: coordinatedRoot,
                expectedGeneration: generation,
                { lease in
                    try checkCancellation()
                    let result = try body(lease, checkCancellation)
                    try checkCancellation()
                    return result
                }
            )
        }
    }

    private func publishOnLease(
        _ request: PlanningMutationRequest,
        lease: PlanningDirectoryLease,
        attemptID requestedAttemptID: UUID?,
        checkCancellation: @escaping () throws -> Void
    ) throws -> PlanningFilesystemPublishResult {
        let observation: PlanningRawFileRead?
        do {
            observation = try PlanningSafeFileIO.readBounded(lease, path: request.path)
        } catch {
            return try failBeforePublishing(request, error: error, attemptID: requestedAttemptID)
        }
        let observedVersion = observation.map { PlanningContentVersion(data: $0.data) } ?? .absent
        if observedVersion != request.expectedVersion {
            try checkCancellation()
            return try recordVersionConflict(
                request,
                observedVersion: observedVersion,
                observedBytes: observation?.data
            )
        }

        let context = try PlanningPublicationContext(
            selectionGeneration: lease.generation,
            rootIdentity: lease.lifeOSIdentity,
            observedVersion: observedVersion,
            observedIdentity: observation?.identity
        )
        let attemptID = try journal.beginPublication(
            for: request.mutationID,
            attemptID: requestedAttemptID ?? UUID(),
            context: context
        )
        guard let initialAttempt = try journal.publicationAttempt(for: request.mutationID),
              initialAttempt.attemptID == attemptID else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let parentCheck: () throws -> Void = {
            try checkCancellation()
            try self.testBarrier?(.beforeParentCreation)
            try checkCancellation()
        }
        let parent = try PlanningSafeFileIO.openParent(
            lease,
            path: request.path,
            createMissing: request.operation == .create,
            checkCancellation: parentCheck
        )
        defer { parent.close() }
        let witness = initialAttempt.witnessName ?? ".lifeos-stage-\(attemptID.uuidString.lowercased())"
        let proposedVersion = request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
        let observedBackupVersion = observation.map { PlanningContentVersion(data: $0.data) }
        let observedBackupDigest: String? = observation.flatMap { PlanningContentVersion(data: $0.data).digest }
        let persistedManifest = try manifests.load(attemptID: attemptID)
        let isResuming = persistedManifest != nil
            || initialAttempt.witnessName != nil
            || initialAttempt.stagedIdentity != nil
        var manifest: PlanningFilesystemAttemptRecord
        if isResuming {
            guard let persistedManifest,
                  persistedManifest.vaultID == journal.vault.vaultID,
                  persistedManifest.deviceID == journal.deviceID,
                  persistedManifest.selectionGeneration == lease.generation,
                  persistedManifest.mutationID == request.mutationID,
                  persistedManifest.mutationFingerprint == request.fingerprint,
                  persistedManifest.attemptID == attemptID,
                  persistedManifest.operation == request.operation,
                  persistedManifest.path == request.path,
                  persistedManifest.expectedVersion == request.expectedVersion,
                  persistedManifest.proposedVersion == proposedVersion,
                  persistedManifest.rootIdentity == lease.lifeOSIdentity,
                  persistedManifest.parentChain == parent.parentChain,
                  persistedManifest.stageIdentity == initialAttempt.stagedIdentity,
                  persistedManifest.backupIdentity == observation?.identity,
                  persistedManifest.backupVersion == observedBackupVersion,
                  persistedManifest.backupDigest == observedBackupDigest,
                  persistedManifest.witnessName == witness else {
                throw PlanningFilesystemError.corruptEvidence
            }
            manifest = persistedManifest
        } else {
            guard persistedManifest == nil else {
                throw PlanningFilesystemError.corruptEvidence
            }
            manifest = try makeManifest(
                request: request,
                attemptID: attemptID,
                lease: lease,
                parent: parent,
                witnessName: witness,
                proposedVersion: proposedVersion,
                backupVersion: observedBackupVersion,
                backupIdentity: observation?.identity,
                backup: observation?.data,
                phase: .intent
            )
            try saveManifest(manifest, backup: observation?.data, lease: lease)
        }
        do {
            try testBarrier?(.p1)
            try checkCancellation()
        } catch {
            let code = planningFilesystemSafeErrorCode(error)
            guard code == PlanningFilesystemError.providerOffline.stableCode
                || code == PlanningFilesystemError.notDownloaded.stableCode
                || code == PlanningFilesystemError.diskFull.stableCode else {
                throw error
            }
            return try failBeforePublishing(request, error: error, attemptID: attemptID)
        }

        var markedPublishing = false
        do {
            switch request.operation {
            case .create, .replace:
                if let existing = try PlanningSafeFileIO.identity(parent, name: witness) {
                    guard initialAttempt.stagedIdentity == existing else {
                        throw PlanningFilesystemError.ambiguousPublication
                    }
                } else {
                    guard let bytes = request.proposedBytes else {
                        throw PlanningFilesystemError.invalid("request.proposedBytes")
                    }
                    try reservePreservationCapacity(
                        lease,
                        additionalBytes: bytes.count,
                        additionalArtifacts: 1
                    )
                    try checkCancellation()
                    let staged = try PlanningSafeFileIO.createExclusive(parent, name: witness, data: bytes)
                    try reservePreservationCapacity(
                        lease,
                        additionalBytes: 0,
                        additionalArtifacts: 0
                    )
                    try journal.recordStagedIdentity(
                        mutationID: request.mutationID,
                        attemptID: attemptID,
                        identity: staged,
                        witnessName: witness
                    )
                    manifest = try replace(manifest, stageIdentity: staged, phase: .verified)
                    try saveManifest(manifest, backup: observation?.data, lease: lease)
                    try checkCancellation()
                }
            case .delete:
                break
            }

            try testBarrier?(.p2)
            try checkCancellation()

            try PlanningSafeFileIO.verifyChain(
                lease,
                expectedRoot: lease.rootIdentity,
                expectedLifeOS: lease.lifeOSIdentity,
                expectedParentChain: parent.parentChain,
                path: request.path,
                expectedVaultID: journal.vault.vaultID
            )
            let beforePublishing = try PlanningSafeFileIO.readBounded(lease, path: request.path)
            guard beforePublishing?.identity == observation?.identity,
                  (beforePublishing.map { PlanningContentVersion(data: $0.data) } ?? .absent) == observedVersion else {
                try checkCancellation()
                return try recordVersionConflict(
                    request,
                    observedVersion: beforePublishing.map { PlanningContentVersion(data: $0.data) } ?? .absent,
                    observedBytes: beforePublishing?.data
                )
            }
            try journal.markPublishing(
                mutationID: request.mutationID,
                attemptID: attemptID,
                context: context
            )
            markedPublishing = true
            manifest = try replace(manifest, phase: .cleanupPending)
            try saveManifest(manifest, backup: observation?.data, lease: lease)
            try testBarrier?(.p3)
            try checkCancellation()

            try access.validateLease(lease)
            try PlanningSafeFileIO.verifyChain(
                lease,
                expectedRoot: lease.rootIdentity,
                expectedLifeOS: lease.lifeOSIdentity,
                expectedParentChain: manifest.parentChain,
                path: manifest.path,
                expectedVaultID: manifest.vaultID
            )

            let namespaceAdditionalBytes: Int
            let namespaceAdditionalArtifacts: Int
            switch request.operation {
            case .create:
                namespaceAdditionalBytes = 0
                namespaceAdditionalArtifacts = 0
            case .replace:
                namespaceAdditionalBytes = max(
                    0,
                    (observation?.data.count ?? 0) - (request.proposedBytes?.count ?? 0)
                )
                namespaceAdditionalArtifacts = 0
            case .delete:
                namespaceAdditionalBytes = observation?.data.count ?? 0
                namespaceAdditionalArtifacts = 1
            }
            try reserveRecoveryCompletionCapacity(
                request: request,
                manifest: manifest,
                backup: observation?.data,
                namespaceAdditionalBytes: namespaceAdditionalBytes,
                namespaceAdditionalArtifacts: namespaceAdditionalArtifacts,
                lease: lease
            )
            try checkCancellation()
            try applyNamespaceOperation(
                request: request,
                parent: parent,
                witness: witness,
                stagedIdentity: manifest.stageIdentity,
                observedIdentity: observation?.identity
            )
            try reservePreservationCapacity(
                lease,
                additionalBytes: 0,
                additionalArtifacts: 0
            )
            try testBarrier?(.p4)
            try PlanningSafeFileIO.flush(parent.fileDescriptor, directory: true)
            try access.validateLease(lease)
            try PlanningSafeFileIO.verifyChain(
                lease,
                expectedRoot: lease.rootIdentity,
                expectedLifeOS: lease.lifeOSIdentity,
                expectedParentChain: manifest.parentChain,
                path: manifest.path,
                expectedVaultID: manifest.vaultID
            )
            try checkCancellation()
            let result = try verifyPublished(
                request: request,
                parent: parent,
                witness: witness,
                stagedIdentity: manifest.stageIdentity,
                observedIdentity: observation?.identity,
                observedBytes: observation?.data
            )
            try testBarrier?(.p5)
            try checkCancellation()
            if result.interference {
                let conflict = try makeConflict(
                    request: request,
                    reason: "postSwapInterference",
                    observed: result.observation
                )
                _ = try journal.recordConflict(conflict)
                try saveManifest(
                    replace(manifest, verifiedOutcome: .conflicted, errorCode: "conflict"),
                    backup: observation?.data,
                    lease: lease
                )
                return PlanningFilesystemPublishResult(status: .conflicted, errorCode: "conflict")
            }
            let version = request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
            let verifiedManifest = try replace(
                manifest,
                phase: .verified,
                verifiedOutcome: .published(version),
                errorCode: nil
            )
            try checkCancellation()
            try saveManifest(verifiedManifest, backup: observation?.data, lease: lease)
            try testBarrier?(.p6)
            try checkCancellation()
            let receipt = try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attemptID,
                outcome: .published(version)
            )
            try testBarrier?(.p7)
            try checkCancellation()
            manifest = verifiedManifest
            return PlanningFilesystemPublishResult(
                status: .published,
                receipt: receipt,
                version: version
            )
        } catch {
            let safe = planningFilesystemSafeErrorCode(error)
            if markedPublishing {
                let persistedVerified: PlanningFilesystemAttemptRecord?
                do {
                    persistedVerified = try manifests.load(attemptID: attemptID)
                } catch {
                    persistedVerified = nil
                }
                if let persistedVerified,
                   persistedVerified.phase == .verified,
                   case .published? = persistedVerified.verifiedOutcome {
                    manifest = persistedVerified
                } else if let updated = try? replace(manifest, phase: .cleanupPending, errorCode: safe) {
                    try checkCancellation()
                    manifest = updated
                    try? saveManifest(manifest, backup: observation?.data, lease: lease)
                }
                return PlanningFilesystemPublishResult(status: .blocked, errorCode: "ambiguousPublication")
            }
            if safe == PlanningFilesystemError.cancelled.stableCode
                || safe == PlanningFilesystemError.unavailable("coordinationTimeout").stableCode {
                throw error
            }
            return try failBeforePublishing(request, error: error, attemptID: attemptID)
        }
    }

    private func continuePublishing(
        _ request: PlanningMutationRequest,
        attempt: PlanningPublicationAttemptSnapshot,
        lease: PlanningDirectoryLease,
        checkCancellation: () throws -> Void
    ) throws -> PlanningFilesystemPublishResult {
        guard let context = attempt.context,
              context.selectionGeneration == lease.generation,
              context.rootIdentity == lease.lifeOSIdentity,
              let witness = attempt.witnessName else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let manifest = try manifests.load(attemptID: attempt.attemptID)
        guard let manifest,
              manifest.mutationID == request.mutationID,
              manifest.attemptID == attempt.attemptID,
              manifest.witnessName == witness else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let parent = try PlanningSafeFileIO.openParent(lease, path: request.path)
        defer { parent.close() }
        try access.validateLease(lease)
        try PlanningSafeFileIO.verifyChain(
            lease,
            expectedRoot: lease.rootIdentity,
            expectedLifeOS: manifest.rootIdentity,
            expectedParentChain: manifest.parentChain,
            path: manifest.path,
            expectedVaultID: manifest.vaultID
        )
        let backup = try manifests.loadBackup(for: manifest)
        if let backupDigest = manifest.backupDigest {
            guard let backup,
                  PlanningContentVersion(data: backup).digest == backupDigest,
                  manifest.backupVersion == Optional(PlanningContentVersion(data: backup)) else {
                throw PlanningFilesystemError.corruptEvidence
            }
        } else {
            guard backup == nil, request.operation == .create else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
        if manifest.phase == .verified,
           case .published(let version)? = manifest.verifiedOutcome {
            guard version == (request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            try checkCancellation()
            return try finalizePublished(
                request,
                attempt: attempt,
                manifest: manifest,
                lease: lease,
                checkCancellation: checkCancellation
            )
        }
        let target = try PlanningSafeFileIO.identity(parent, name: parent.leafName)
        let witnessIdentity = try PlanningSafeFileIO.identity(parent, name: witness)
        let targetRead = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: parent.leafName)
        let witnessRead = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: witness)
        let proposedMatches: (PlanningRawFileRead?) -> Bool = { raw in
            guard let raw else { return false }
            return raw.identity.fileType == 1
                && PlanningContentVersion(data: raw.data) == manifest.proposedVersion
        }
        let backupMatches: (PlanningRawFileRead?) -> Bool = { raw in
            guard let raw, let backup else { return false }
            return raw.identity.fileType == 1
                && PlanningContentVersion(data: raw.data) == manifest.backupVersion
                && raw.data == backup
        }
        switch request.operation {
        case .create:
            if target == manifest.stageIdentity,
               witnessIdentity == nil,
               proposedMatches(targetRead) {
                try checkCancellation()
                return try finalizePublished(
                    request,
                    attempt: attempt,
                    manifest: manifest,
                    lease: lease,
                    checkCancellation: checkCancellation
                )
            }
            guard target == nil,
                  witnessIdentity == manifest.stageIdentity,
                  proposedMatches(witnessRead) else {
                return try ambiguousOrConflict(
                    request,
                    parent: parent,
                    lease: lease,
                    manifest: manifest,
                    checkCancellation: checkCancellation,
                    reason: "createArrangement"
                )
            }
            try reserveRecoveryCompletionCapacity(
                request: request,
                manifest: manifest,
                backup: backup,
                namespaceAdditionalBytes: 0,
                namespaceAdditionalArtifacts: 0,
                lease: lease
            )
            try access.validateLease(lease)
            try checkCancellation()
            try PlanningSafeFileIO.renameExclusive(parent, source: witness, destination: parent.leafName)
            try PlanningSafeFileIO.flush(parent.fileDescriptor, directory: true)
            try access.validateLease(lease)
            try PlanningSafeFileIO.verifyParentChain(lease, path: manifest.path, expected: manifest.parentChain)
            guard let published = try PlanningSafeFileIO.readNamedBoundedFromParent(
                parent,
                name: parent.leafName
            ), proposedMatches(published),
                  try PlanningSafeFileIO.identity(parent, name: witness) == nil else {
                return try ambiguousOrConflict(
                    request,
                    parent: parent,
                    lease: lease,
                    manifest: manifest,
                    checkCancellation: checkCancellation,
                    reason: "createPostSwap"
                )
            }
            try checkCancellation()
            return try finalizePublished(
                request,
                attempt: attempt,
                manifest: manifest,
                lease: lease,
                checkCancellation: checkCancellation
            )
        case .replace:
            if target == manifest.stageIdentity,
               witnessIdentity == manifest.backupIdentity,
               proposedMatches(targetRead),
               backupMatches(witnessRead) {
                try checkCancellation()
                return try finalizePublished(
                    request,
                    attempt: attempt,
                    manifest: manifest,
                    lease: lease,
                    checkCancellation: checkCancellation
                )
            }
            guard target == manifest.backupIdentity,
                  witnessIdentity == manifest.stageIdentity,
                  backupMatches(targetRead),
                  proposedMatches(witnessRead) else {
                return try ambiguousOrConflict(
                    request,
                    parent: parent,
                    lease: lease,
                    manifest: manifest,
                    checkCancellation: checkCancellation,
                    reason: "replaceArrangement"
                )
            }
            try reserveRecoveryCompletionCapacity(
                request: request,
                manifest: manifest,
                backup: backup,
                namespaceAdditionalBytes: max(0, (backup?.count ?? 0) - (request.proposedBytes?.count ?? 0)),
                namespaceAdditionalArtifacts: 0,
                lease: lease
            )
            try access.validateLease(lease)
            try checkCancellation()
            try PlanningSafeFileIO.swap(parent, source: witness, destination: parent.leafName)
            try PlanningSafeFileIO.flush(parent.fileDescriptor, directory: true)
            try access.validateLease(lease)
            try PlanningSafeFileIO.verifyParentChain(lease, path: manifest.path, expected: manifest.parentChain)
            let postTarget = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: parent.leafName)
            let postWitness = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: witness)
            guard postTarget?.identity == manifest.stageIdentity,
                  proposedMatches(postTarget),
                  postWitness?.identity == manifest.backupIdentity,
                  backupMatches(postWitness) else {
                return try ambiguousOrConflict(
                    request,
                    parent: parent,
                    lease: lease,
                    manifest: manifest,
                    checkCancellation: checkCancellation,
                    reason: "replacePostSwap"
                )
            }
            try checkCancellation()
            return try finalizePublished(
                request,
                attempt: attempt,
                manifest: manifest,
                lease: lease,
                checkCancellation: checkCancellation
            )
        case .delete:
            if target == nil,
               witnessIdentity == manifest.backupIdentity,
               backupMatches(witnessRead) {
                try checkCancellation()
                return try finalizePublished(
                    request,
                    attempt: attempt,
                    manifest: manifest,
                    lease: lease,
                    checkCancellation: checkCancellation
                )
            }
            guard target == manifest.backupIdentity,
                  witnessIdentity == nil,
                  backupMatches(targetRead) else {
                return try ambiguousOrConflict(
                    request,
                    parent: parent,
                    lease: lease,
                    manifest: manifest,
                    checkCancellation: checkCancellation,
                    reason: "deleteArrangement"
                )
            }
            try reserveRecoveryCompletionCapacity(
                request: request,
                manifest: manifest,
                backup: backup,
                namespaceAdditionalBytes: backup?.count ?? 0,
                namespaceAdditionalArtifacts: 1,
                lease: lease
            )
            try access.validateLease(lease)
            try checkCancellation()
            try PlanningSafeFileIO.renameExclusive(parent, source: parent.leafName, destination: witness)
            try PlanningSafeFileIO.flush(parent.fileDescriptor, directory: true)
            try access.validateLease(lease)
            try PlanningSafeFileIO.verifyParentChain(lease, path: manifest.path, expected: manifest.parentChain)
            guard try PlanningSafeFileIO.identity(parent, name: parent.leafName) == nil,
                  let postWitness = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: witness),
                  postWitness.identity == manifest.backupIdentity,
                  backupMatches(postWitness) else {
                return try ambiguousOrConflict(
                    request,
                    parent: parent,
                    lease: lease,
                    manifest: manifest,
                    checkCancellation: checkCancellation,
                    reason: "deletePostSwap"
                )
            }
            try checkCancellation()
            return try finalizePublished(
                request,
                attempt: attempt,
                manifest: manifest,
                lease: lease,
                checkCancellation: checkCancellation
            )
        }
    }

    private func finalizePublished(
        _ request: PlanningMutationRequest,
        attempt: PlanningPublicationAttemptSnapshot,
        manifest: PlanningFilesystemAttemptRecord,
        lease: PlanningDirectoryLease,
        checkCancellation: () throws -> Void
    ) throws -> PlanningFilesystemPublishResult {
        let version = request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
        let updated = try replace(manifest, phase: .verified, verifiedOutcome: .published(version), errorCode: nil)
        let backup = try manifests.loadBackup(for: manifest)
        try checkCancellation()
        try saveManifest(updated, backup: backup, lease: lease)
        try checkCancellation()
        let receipt = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attempt.attemptID,
            outcome: .published(version)
        )
        return PlanningFilesystemPublishResult(status: .reconciled, receipt: receipt, version: version)
    }

    private func applyNamespaceOperation(
        request: PlanningMutationRequest,
        parent: PlanningParentHandle,
        witness: String,
        stagedIdentity: PlanningFileIdentity?,
        observedIdentity: PlanningFileIdentity?
    ) throws {
        switch request.operation {
        case .create:
            guard stagedIdentity != nil else { throw PlanningFilesystemError.corruptEvidence }
            try PlanningSafeFileIO.renameExclusive(parent, source: witness, destination: parent.leafName)
        case .replace:
            guard stagedIdentity != nil, observedIdentity != nil else { throw PlanningFilesystemError.corruptEvidence }
            try PlanningSafeFileIO.swap(parent, source: witness, destination: parent.leafName)
        case .delete:
            guard observedIdentity != nil else { throw PlanningFilesystemError.corruptEvidence }
            try PlanningSafeFileIO.renameExclusive(parent, source: parent.leafName, destination: witness)
        }
    }

    private func verifyPublished(
        request: PlanningMutationRequest,
        parent: PlanningParentHandle,
        witness: String,
        stagedIdentity: PlanningFileIdentity?,
        observedIdentity: PlanningFileIdentity?,
        observedBytes: Data?
    ) throws -> (interference: Bool, observation: PlanningRawFileRead?) {
        let target = try PlanningSafeFileIO.readBoundedFromParent(parent)
        switch request.operation {
        case .create:
            guard let proposed = request.proposedBytes,
                  let target,
                  target.data == proposed,
                  target.identity == stagedIdentity,
                  try PlanningSafeFileIO.identity(parent, name: witness) == nil else {
                return (true, target)
            }
            return (false, target)
        case .replace:
            let displaced = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: witness)
            guard let proposed = request.proposedBytes,
                  let target,
                  target.data == proposed,
                  target.identity == stagedIdentity,
                  let displaced,
                  displaced.identity == observedIdentity,
                  displaced.data == observedBytes,
                  PlanningContentVersion(data: displaced.data) == request.expectedVersion else {
                return (true, target)
            }
            return (false, target)
        case .delete:
            guard target == nil,
                  let witnessIdentity = try PlanningSafeFileIO.identity(parent, name: witness),
                  witnessIdentity == observedIdentity,
                  let displaced = try PlanningSafeFileIO.readNamedBoundedFromParent(parent, name: witness),
                  displaced.identity == observedIdentity,
                  displaced.data == observedBytes,
                  PlanningContentVersion(data: displaced.data) == request.expectedVersion else {
                return (true, target)
            }
            return (false, nil)
        }
    }

    private func recordVersionConflict(
        _ request: PlanningMutationRequest,
        observedVersion: PlanningContentVersion,
        observedBytes: Data?
    ) throws -> PlanningFilesystemPublishResult {
        let conflict = try makeConflict(
            request: request,
            reason: "versionChanged",
            observedVersion: observedVersion,
            observedBytes: observedBytes
        )
        let receipt = try journal.recordConflict(conflict)
        return PlanningFilesystemPublishResult(status: .conflicted, receipt: receipt, errorCode: "conflict")
    }

    private func ambiguousOrConflict(
        _ request: PlanningMutationRequest,
        parent: PlanningParentHandle,
        lease: PlanningDirectoryLease,
        manifest: PlanningFilesystemAttemptRecord? = nil,
        checkCancellation: () throws -> Void,
        reason: String
    ) throws -> PlanningFilesystemPublishResult {
        let observation = try PlanningSafeFileIO.readBoundedFromParent(parent)
        let conflict = try makeConflict(request: request, reason: reason, observed: observation)
        try checkCancellation()
        let receipt = try journal.recordConflict(conflict)
        if let manifest {
            let updated = try replace(
                manifest,
                phase: .cleanupPending,
                verifiedOutcome: .conflicted,
                errorCode: "conflict"
            )
            try checkCancellation()
            try saveManifest(
                updated,
                backup: try manifests.loadBackup(for: manifest),
                lease: lease
            )
        }
        return PlanningFilesystemPublishResult(status: .conflicted, receipt: receipt, errorCode: "conflict")
    }

    private func failBeforePublishing(
        _ request: PlanningMutationRequest,
        error: Error,
        attemptID: UUID?
    ) throws -> PlanningFilesystemPublishResult {
        let code = planningFilesystemSafeErrorCode(error)
        guard let attemptID,
              let attempt = try journal.publicationAttempt(for: request.mutationID),
              attempt.attemptID == attemptID,
              attempt.phase == .prepared || attempt.phase == .stageReady else {
            throw error
        }
        let retryable = code == PlanningFilesystemError.providerOffline.stableCode
            || code == PlanningFilesystemError.notDownloaded.stableCode
            || code == PlanningFilesystemError.diskFull.stableCode
        let receipt = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .failed(code: code, retryable: retryable)
        )
        return PlanningFilesystemPublishResult(status: .queued, receipt: receipt, errorCode: code)
    }

    private func makeConflict(
        request: PlanningMutationRequest,
        reason: String,
        observed: PlanningRawFileRead?
    ) throws -> PlanningConflict {
        try makeConflict(
            request: request,
            reason: reason,
            observedVersion: observed.map { PlanningContentVersion(data: $0.data) } ?? .absent,
            observedBytes: observed?.data
        )
    }

    private func makeConflict(
        request: PlanningMutationRequest,
        reason: String,
        observedVersion: PlanningContentVersion,
        observedBytes: Data?
    ) throws -> PlanningConflict {
        try PlanningConflict(
            mutationID: request.mutationID,
            vaultID: request.vaultID,
            path: request.path,
            operation: request.operation,
            reason: reason,
            baseVersion: request.expectedVersion,
            localBytes: request.proposedBytes,
            observedVersion: observedVersion,
            observedBytes: observedBytes
        )
    }

    private func makeManifest(
        request: PlanningMutationRequest,
        attemptID: UUID,
        lease: PlanningDirectoryLease,
        parent: PlanningParentHandle,
        witnessName: String,
        proposedVersion: PlanningContentVersion,
        backupVersion: PlanningContentVersion?,
        backupIdentity: PlanningFileIdentity?,
        backup: Data?,
        phase: PlanningFilesystemAttemptPhase
    ) throws -> PlanningFilesystemAttemptRecord {
        let backupDigest = backup.flatMap { PlanningContentVersion(data: $0).digest }
        return try PlanningFilesystemAttemptRecord(
            vaultID: journal.vault.vaultID,
            deviceID: journal.deviceID,
            selectionGeneration: lease.generation,
            mutationID: request.mutationID,
            mutationFingerprint: request.fingerprint,
            attemptID: attemptID,
            operation: request.operation,
            path: request.path,
            expectedVersion: request.expectedVersion,
            proposedVersion: proposedVersion,
            rootIdentity: lease.lifeOSIdentity,
            parentChain: parent.parentChain,
            backupIdentity: backupIdentity,
            witnessName: witnessName,
            backupVersion: backupVersion,
            backupDigest: backupDigest,
            phase: phase
        )
    }

    private func reservePreservationCapacity(
        _ lease: PlanningDirectoryLease,
        additionalBytes: Int,
        additionalArtifacts: Int
    ) throws {
        let vault = try PlanningSafeFileIO.preservationInventory(lease)
        let local = try manifests.preservationInventory()
        let (localBytes, byteOverflow) = local.bytes.addingReportingOverflow(additionalBytes)
        let (localArtifacts, artifactOverflow) = local.artifacts.addingReportingOverflow(additionalArtifacts)
        guard !byteOverflow, !artifactOverflow else {
            throw PlanningFilesystemError.backpressure("preservation")
        }
        try PlanningPreservationInventory(
            bytes: vault.bytes,
            artifacts: vault.artifacts
        ).reserving(bytes: localBytes, artifacts: localArtifacts)
    }

    private func reserveRecoveryCompletionCapacity(
        request: PlanningMutationRequest,
        manifest: PlanningFilesystemAttemptRecord,
        backup: Data?,
        namespaceAdditionalBytes: Int,
        namespaceAdditionalArtifacts: Int,
        lease: PlanningDirectoryLease
    ) throws {
        let resultVersion = request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
        let finalManifest = try replace(
            manifest,
            phase: .verified,
            verifiedOutcome: .published(resultVersion),
            errorCode: nil
        )
        let additional = try manifests.additionalPreservationCapacity(
            for: finalManifest,
            backup: backup
        )
        try reservePreservationCapacity(
            lease,
            additionalBytes: try addingPreservationCapacity(
                additional.bytes,
                namespaceAdditionalBytes
            ),
            additionalArtifacts: try addingPreservationCapacity(
                additional.artifacts,
                namespaceAdditionalArtifacts
            )
        )
    }

    private func addingPreservationCapacity(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard rhs >= 0 else {
            throw PlanningFilesystemError.invalid("preservationReservation")
        }
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw PlanningFilesystemError.backpressure("preservation")
        }
        return value
    }

    private func saveManifest(
        _ record: PlanningFilesystemAttemptRecord,
        backup: Data?,
        lease: PlanningDirectoryLease
    ) throws {
        let additional = try manifests.additionalPreservationCapacity(
            for: record,
            backup: backup
        )
        try reservePreservationCapacity(
            lease,
            additionalBytes: additional.bytes,
            additionalArtifacts: additional.artifacts
        )
        try manifests.save(record, backup: backup)
    }

    private func replace(
        _ record: PlanningFilesystemAttemptRecord,
        stageIdentity: PlanningFileIdentity? = nil,
        phase: PlanningFilesystemAttemptPhase? = nil,
        verifiedOutcome: PlanningPublicationOutcomeRecord? = nil,
        errorCode: String? = nil
    ) throws -> PlanningFilesystemAttemptRecord {
        try PlanningFilesystemAttemptRecord(
            vaultID: record.vaultID,
            deviceID: record.deviceID,
            selectionGeneration: record.selectionGeneration,
            mutationID: record.mutationID,
            mutationFingerprint: record.mutationFingerprint,
            attemptID: record.attemptID,
            operation: record.operation,
            path: record.path,
            expectedVersion: record.expectedVersion,
            proposedVersion: record.proposedVersion,
            rootIdentity: record.rootIdentity,
            parentChain: record.parentChain,
            stageIdentity: stageIdentity ?? record.stageIdentity,
            backupIdentity: record.backupIdentity,
            witnessName: record.witnessName,
            backupVersion: record.backupVersion,
            backupDigest: record.backupDigest,
            phase: phase ?? record.phase,
            verifiedOutcome: verifiedOutcome ?? record.verifiedOutcome,
            errorCode: errorCode,
            createdAt: record.createdAt,
            updatedAt: Date()
        )
    }

    private func markCleanupStarted(
        _ record: PlanningFilesystemAttemptRecord
    ) throws -> PlanningFilesystemAttemptRecord {
        try PlanningFilesystemAttemptRecord(
            vaultID: record.vaultID,
            deviceID: record.deviceID,
            selectionGeneration: record.selectionGeneration,
            mutationID: record.mutationID,
            mutationFingerprint: record.mutationFingerprint,
            attemptID: record.attemptID,
            operation: record.operation,
            path: record.path,
            expectedVersion: record.expectedVersion,
            proposedVersion: record.proposedVersion,
            rootIdentity: record.rootIdentity,
            parentChain: record.parentChain,
            stageIdentity: record.stageIdentity,
            backupIdentity: record.backupIdentity,
            witnessName: record.witnessName,
            backupVersion: record.backupVersion,
            backupDigest: record.backupDigest,
            phase: .cleanupPending,
            verifiedOutcome: record.verifiedOutcome,
            errorCode: "cleanupStarted",
            createdAt: record.createdAt,
            updatedAt: Date()
        )
    }
}

private final class PlanningFilesystemPrivateDirectories: @unchecked Sendable {
    let directoryFD: Int32
    let backupFD: Int32
    private let lock = NSLock()
    private var closed = false

    init(directoryFD: Int32, backupFD: Int32) {
        self.directoryFD = directoryFD
        self.backupFD = backupFD
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
#if canImport(Darwin)
        _ = Darwin.close(backupFD)
        _ = Darwin.close(directoryFD)
#endif
    }

    deinit { close() }
}

private final class PlanningFilesystemAttemptStore: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func save(_ record: PlanningFilesystemAttemptRecord, backup: Data?) throws {
        let manifestData = try JSONEncoder().encode(record)
        guard manifestData.count <= PlanningFilesystemLimits.maximumManifestBytes else {
            throw PlanningFilesystemError.backpressure("manifest")
        }
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        var inventory = try inventoryLocked(directories)
        let manifestName = manifestName(record.attemptID)
        let manifestSize = try regularSize(
            parentFD: directories.directoryFD,
            name: manifestName,
            maximum: PlanningFilesystemLimits.maximumManifestBytes
        )
        if manifestSize == nil,
           inventory.manifestCount >= PlanningFilesystemLimits.maximumManifestCount {
            throw PlanningFilesystemError.backpressure("manifestCount")
        }
        if let backup, let digest = record.backupDigest {
            guard backup.count <= planningFilesystemDocumentLimit(for: record.path),
                  PlanningContentVersion(data: backup).digest == digest,
                  record.backupVersion == Optional(PlanningContentVersion(data: backup)) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            let name = backupName(record.attemptID, digest)
            if let existing = try regularSize(
                parentFD: directories.backupFD,
                name: name,
                maximum: planningFilesystemDocumentLimit(for: record.path)
            ) {
                guard existing == backup.count,
                      try readPrivate(
                          parentFD: directories.backupFD,
                          name: name,
                          maximum: existing
                      ) == backup else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            } else {
                try reserveWrite(
                    inventory: inventory,
                    dataBytes: backup.count,
                    existingBytes: nil,
                    createsDestination: true
                )
                try writePrivateAtomic(
                    backup,
                    parentFD: directories.backupFD,
                    name: name,
                    replacing: false,
                    maximum: planningFilesystemDocumentLimit(for: record.path)
                )
                inventory = try inventoryLocked(directories)
            }
        } else if record.backupDigest != nil {
            throw PlanningFilesystemError.corruptEvidence
        }
        try reserveWrite(
            inventory: inventory,
            dataBytes: manifestData.count,
            existingBytes: manifestSize,
            createsDestination: manifestSize == nil
        )
        try writePrivateAtomic(
            manifestData,
            parentFD: directories.directoryFD,
            name: manifestName,
            replacing: true,
            maximum: PlanningFilesystemLimits.maximumManifestBytes
        )
        let after = try inventoryLocked(directories)
        guard after.manifestCount <= PlanningFilesystemLimits.maximumManifestCount,
              after.artifactCount <= PlanningFilesystemLimits.maximumPreservedArtifacts,
              after.privateBytes <= PlanningFilesystemLimits.maximumPreservedBytes else {
            throw PlanningFilesystemError.backpressure("preservation")
        }
    }

    func load(attemptID: UUID) throws -> PlanningFilesystemAttemptRecord? {
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        let name = manifestName(attemptID)
        guard let size = try regularSize(
            parentFD: directories.directoryFD,
            name: name,
            maximum: PlanningFilesystemLimits.maximumManifestBytes
        ) else { return nil }
        let data = try readPrivate(
            parentFD: directories.directoryFD,
            name: name,
            maximum: size
        )
        guard data.count == size else { throw PlanningFilesystemError.corruptEvidence }
        do { return try JSONDecoder().decode(PlanningFilesystemAttemptRecord.self, from: data) }
        catch { throw PlanningFilesystemError.corruptEvidence }
    }

    func loadBackup(for record: PlanningFilesystemAttemptRecord) throws -> Data? {
        guard let data = try loadBackupIfPresent(for: record) else {
            guard record.backupDigest == nil else {
                throw PlanningFilesystemError.corruptEvidence
            }
            return nil
        }
        return data
    }

    func loadBackupIfPresent(for record: PlanningFilesystemAttemptRecord) throws -> Data? {
        guard let digest = record.backupDigest else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        let name = backupName(record.attemptID, digest)
        guard let size = try regularSize(
            parentFD: directories.backupFD,
            name: name,
            maximum: planningFilesystemDocumentLimit(for: record.path)
        ) else { return nil }
        let data = try readPrivate(
            parentFD: directories.backupFD,
            name: name,
            maximum: size
        )
        guard data.count == size,
              PlanningContentVersion(data: data).digest == digest,
              record.backupVersion == Optional(PlanningContentVersion(data: data)) else {
            throw PlanningFilesystemError.corruptEvidence
        }
        return data
    }

    func preservationInventory() throws -> PlanningPreservationInventory {
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        let inventory = try inventoryLocked(directories)
        return PlanningPreservationInventory(
            bytes: inventory.privateBytes,
            artifacts: inventory.artifactCount
        )
    }

    func additionalPreservationCapacity(
        for record: PlanningFilesystemAttemptRecord,
        backup: Data?
    ) throws -> (bytes: Int, artifacts: Int) {
        let manifestData = try JSONEncoder().encode(record)
        guard manifestData.count <= PlanningFilesystemLimits.maximumManifestBytes else {
            throw PlanningFilesystemError.backpressure("manifest")
        }
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        _ = try inventoryLocked(directories)

        var bytes = manifestData.count
        var artifacts = 1 // the manifest's atomic temporary file
        if let backup, let digest = record.backupDigest {
            guard backup.count <= planningFilesystemDocumentLimit(for: record.path),
                  PlanningContentVersion(data: backup).digest == digest,
                  record.backupVersion == Optional(PlanningContentVersion(data: backup)) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            let name = backupName(record.attemptID, digest)
            if try regularSize(
                parentFD: directories.backupFD,
                name: name,
                maximum: planningFilesystemDocumentLimit(for: record.path)
            ) == nil {
                let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(backup.count)
                let (nextArtifacts, artifactOverflow) = artifacts.addingReportingOverflow(1)
                guard !byteOverflow, !artifactOverflow else {
                    throw PlanningFilesystemError.backpressure("preservation")
                }
                bytes = nextBytes
                artifacts = nextArtifacts
            }
        } else if record.backupDigest != nil {
            throw PlanningFilesystemError.corruptEvidence
        }
        return (bytes, artifacts)
    }

    func records(
        limit: Int,
        after attemptID: UUID? = nil
    ) throws -> [PlanningFilesystemAttemptRecord] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, PlanningFilesystemLimits.maximumRecoveryEntries)
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        _ = try inventoryLocked(directories)
        var records: [PlanningFilesystemAttemptRecord] = []
        try scanNames(parentFD: directories.directoryFD, maximum: PlanningFilesystemLimits.maximumDirectoryEntries) { name in
            guard let attemptID = parseManifestName(name) else { return }
            guard let size = try regularSize(
                parentFD: directories.directoryFD,
                name: name,
                maximum: PlanningFilesystemLimits.maximumManifestBytes
            ) else { throw PlanningFilesystemError.corruptEvidence }
            let data = try readPrivate(
                parentFD: directories.directoryFD,
                name: name,
                maximum: size
            )
            guard let record = try? JSONDecoder().decode(PlanningFilesystemAttemptRecord.self, from: data),
                  record.attemptID == attemptID else {
                throw PlanningFilesystemError.corruptEvidence
            }
            records.append(record)
        }
        records.sort { $0.attemptID.uuidString < $1.attemptID.uuidString }
        if let attemptID {
            records.removeAll { $0.attemptID.uuidString <= attemptID.uuidString }
        }
        return Array(records.prefix(boundedLimit))
    }

    func removeVerified(
        _ record: PlanningFilesystemAttemptRecord,
        checkCancellation: (() throws -> Void)? = nil,
        afterBackup: (() throws -> Void)? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let directories = try openDirectoriesLocked(create: true)
        defer { directories.close() }
        let manifestName = manifestName(record.attemptID)
        guard let manifestSize = try regularSize(
            parentFD: directories.directoryFD,
            name: manifestName,
            maximum: PlanningFilesystemLimits.maximumManifestBytes
        ) else { throw PlanningFilesystemError.corruptEvidence }
        let manifestData = try readPrivate(
            parentFD: directories.directoryFD,
            name: manifestName,
            maximum: manifestSize
        )
        guard try JSONDecoder().decode(PlanningFilesystemAttemptRecord.self, from: manifestData) == record else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let cleanupWasStarted = record.phase == .cleanupPending
            && record.errorCode == "cleanupStarted"
        if let digest = record.backupDigest {
            let name = backupName(record.attemptID, digest)
            guard let size = try regularSize(
                parentFD: directories.backupFD,
                name: name,
                maximum: planningFilesystemDocumentLimit(for: record.path)
            ) else {
                guard cleanupWasStarted else { throw PlanningFilesystemError.corruptEvidence }
                return try removeManifestOnly(
                    directories: directories,
                    manifestName: manifestName,
                    checkCancellation: checkCancellation
                )
            }
            let data = try readPrivate(parentFD: directories.backupFD, name: name, maximum: size)
            guard record.backupVersion == Optional(PlanningContentVersion(data: data)),
                  PlanningContentVersion(data: data).digest == digest else {
                throw PlanningFilesystemError.corruptEvidence
            }
            try checkCancellation?()
            guard unlinkat(directories.backupFD, name, 0) == 0 else {
                throw planningFilesystemPrivateError(errno)
            }
            try flushDirectory(directories.backupFD)
            try afterBackup?()
        }
        try checkCancellation?()
        guard unlinkat(directories.directoryFD, manifestName, 0) == 0 else {
            throw planningFilesystemPrivateError(errno)
        }
        try flushDirectory(directories.directoryFD)
    }

    private func removeManifestOnly(
        directories: PlanningFilesystemPrivateDirectories,
        manifestName: String,
        checkCancellation: (() throws -> Void)?
    ) throws {
        try checkCancellation?()
        guard unlinkat(directories.directoryFD, manifestName, 0) == 0 else {
            throw planningFilesystemPrivateError(errno)
        }
        try flushDirectory(directories.directoryFD)
    }

    private struct Inventory {
        var manifestCount = 0
        var artifactCount = 0
        var privateBytes = 0
    }

    private func reserveWrite(
        inventory: Inventory,
        dataBytes: Int,
        existingBytes: Int?,
        createsDestination: Bool
    ) throws {
        let (artifactCount, artifactOverflow) = inventory.artifactCount.addingReportingOverflow(1)
        let replacedBytes = max(0, existingBytes ?? 0)
        let additionalBytes = max(0, dataBytes - replacedBytes)
        let (privateBytes, byteOverflow) = inventory.privateBytes.addingReportingOverflow(additionalBytes)
        guard !artifactOverflow, !byteOverflow,
              (!createsDestination || artifactCount <= PlanningFilesystemLimits.maximumPreservedArtifacts),
              privateBytes <= PlanningFilesystemLimits.maximumPreservedBytes else {
            throw PlanningFilesystemError.backpressure("preservation")
        }
    }

    private func inventoryLocked(_ directories: PlanningFilesystemPrivateDirectories) throws -> Inventory {
        var inventory = Inventory()
        try scanNames(parentFD: directories.directoryFD, maximum: PlanningFilesystemLimits.maximumDirectoryEntries) { name in
            if name == "backups" {
                let backupFD = try openDirectory(parentFD: directories.directoryFD, name: name, create: false)
#if canImport(Darwin)
                _ = Darwin.close(backupFD)
#endif
                return
            }
            if let _ = parseManifestName(name) {
                guard let size = try regularSize(
                    parentFD: directories.directoryFD,
                    name: name,
                    maximum: PlanningFilesystemLimits.maximumManifestBytes
                ) else { throw PlanningFilesystemError.corruptEvidence }
                inventory.manifestCount += 1
                try addArtifact(size, to: &inventory)
            } else if isTemporaryName(name) {
                guard let size = try regularSize(
                    parentFD: directories.directoryFD,
                    name: name,
                    maximum: PlanningFilesystemLimits.maximumManifestBytes
                ) else { throw PlanningFilesystemError.corruptEvidence }
                try addArtifact(size, to: &inventory)
            } else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
        try scanNames(parentFD: directories.backupFD, maximum: PlanningFilesystemLimits.maximumDirectoryEntries) { name in
            if let parsed = parseBackupName(name) {
                guard let size = try regularSize(
                    parentFD: directories.backupFD,
                    name: name,
                    maximum: PlanningFilesystemLimits.maximumPreservedBytes
                ) else { throw PlanningFilesystemError.corruptEvidence }
                let data = try readPrivate(
                    parentFD: directories.backupFD,
                    name: name,
                    maximum: size
                )
                guard PlanningContentVersion(data: data).digest == parsed.digest else {
                    throw PlanningFilesystemError.corruptEvidence
                }
                try addArtifact(size, to: &inventory)
            } else if isTemporaryName(name) {
                guard let size = try regularSize(
                    parentFD: directories.backupFD,
                    name: name,
                    maximum: PlanningFilesystemLimits.maximumPreservedBytes
                ) else { throw PlanningFilesystemError.corruptEvidence }
                try addArtifact(size, to: &inventory)
            } else {
                throw PlanningFilesystemError.corruptEvidence
            }
        }
        guard inventory.manifestCount <= PlanningFilesystemLimits.maximumManifestCount else {
            throw PlanningFilesystemError.backpressure("manifestCount")
        }
        return inventory
    }

    private func addArtifact(_ size: Int, to inventory: inout Inventory) throws {
        inventory.artifactCount += 1
        let (sum, overflow) = inventory.privateBytes.addingReportingOverflow(size)
        guard !overflow, sum <= PlanningFilesystemLimits.maximumPreservedBytes else {
            throw PlanningFilesystemError.backpressure("preservationBytes")
        }
        inventory.privateBytes = sum
        guard inventory.artifactCount <= PlanningFilesystemLimits.maximumPreservedArtifacts else {
            throw PlanningFilesystemError.backpressure("preservationArtifacts")
        }
    }

    private func openDirectoriesLocked(create: Bool) throws -> PlanningFilesystemPrivateDirectories {
#if canImport(Darwin)
        let directoryFD = try openDirectoryPath(directory, create: create)
        do {
            let backupFD = try openDirectory(
                parentFD: directoryFD,
                name: "backups",
                create: create
            )
            do {
                guard fchmod(directoryFD, mode_t(0o700)) == 0,
                      fchmod(backupFD, mode_t(0o700)) == 0 else {
                    throw planningFilesystemPrivateError(errno)
                }
                try excludeFromBackup(directoryFD)
                try excludeFromBackup(backupFD)
                return PlanningFilesystemPrivateDirectories(
                    directoryFD: directoryFD,
                    backupFD: backupFD
                )
            } catch {
                _ = Darwin.close(backupFD)
                throw error
            }
        } catch {
            _ = Darwin.close(directoryFD)
            throw error
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    private func scanNames(
        parentFD: Int32,
        maximum: Int,
        _ body: (String) throws -> Void
    ) throws {
#if canImport(Darwin)
        let directoryFD = ".".withCString {
            Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw planningFilesystemPrivateError(errno) }
        guard let directory = fdopendir(directoryFD) else {
            _ = Darwin.close(directoryFD)
            throw planningFilesystemPrivateError(errno)
        }
        defer { closedir(directory) }
        var count = 0
        var seen = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw planningFilesystemPrivateError(errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard name.utf8.count <= PlanningFilesystemLimits.maximumDirectoryNameBytes else {
                throw PlanningFilesystemError.backpressure("privateName")
            }
            count += 1
            guard count <= maximum, seen.insert(planningFilesystemCollisionKey(name)).inserted else {
                throw PlanningFilesystemError.backpressure("privateEntries")
            }
            try body(name)
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    private func parseManifestName(_ name: String) -> UUID? {
        let prefix = "manifest-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -5)
        let uuidText = String(name[start..<end])
        guard let value = UUID(uuidString: uuidText),
              value.uuidString.lowercased() == uuidText else { return nil }
        return value
    }

    private func parseBackupName(_ name: String) -> (attemptID: UUID, digest: String)? {
        let prefix = "backup-"
        guard name.hasPrefix(prefix) else { return nil }
        let body = String(name.dropFirst(prefix.count))
        guard body.count > 37 else { return nil }
        let uuidEnd = body.index(body.startIndex, offsetBy: 36)
        guard body[uuidEnd] == "-" else { return nil }
        let uuidText = String(body[..<uuidEnd])
        let digest = String(body[body.index(after: uuidEnd)...])
        guard let attemptID = UUID(uuidString: uuidText),
              attemptID.uuidString.lowercased() == uuidText,
              planningDigestIsValid(digest),
              backupName(attemptID, digest) == name else { return nil }
        return (attemptID, digest)
    }

    private func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(".lifeos-private-tmp-") || name.hasPrefix(".tmp-")
    }

    private func regularSize(parentFD: Int32, name: String, maximum: Int) throws -> Int? {
#if canImport(Darwin)
        guard let opened = try openRegular(parentFD: parentFD, name: name, maximum: maximum) else {
            return nil
        }
        defer { _ = Darwin.close(opened.fd) }
        return opened.size
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    private func readPrivate(parentFD: Int32, name: String, maximum: Int) throws -> Data {
#if canImport(Darwin)
        guard let opened = try openRegular(parentFD: parentFD, name: name, maximum: maximum) else {
            throw PlanningFilesystemError.corruptEvidence
        }
        defer { _ = Darwin.close(opened.fd) }
        return try readFD(opened.fd, expectedSize: opened.size, maximum: maximum)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    private func writePrivateAtomic(
        _ data: Data,
        parentFD: Int32,
        name: String,
        replacing: Bool,
        maximum: Int
    ) throws {
#if canImport(Darwin)
        guard data.count <= maximum else { throw PlanningFilesystemError.backpressure("privateFile") }
        let temporaryName = ".lifeos-private-tmp-\(UUID().uuidString.lowercased())"
        var descriptor: Int32 = -1
        var temporaryPresent = false
        do {
            descriptor = try createExclusive(parentFD: parentFD, name: temporaryName)
            temporaryPresent = true
            try writeAll(descriptor, data: data)
            guard fsync(descriptor) == 0 else { throw planningFilesystemPrivateError(errno) }
#if os(macOS)
            let fullSyncResult = fcntl(descriptor, F_FULLFSYNC)
            if fullSyncResult != 0 {
                let fullSyncError = errno
                guard fullSyncError == ENOTSUP || fullSyncError == EINVAL else {
                    throw planningFilesystemPrivateError(fullSyncError)
                }
            }
#endif
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw planningFilesystemPrivateError(errno)
            }
            descriptor = -1
            if replacing {
                _ = try regularSize(
                    parentFD: parentFD,
                    name: name,
                    maximum: maximum
                )
            } else if try regularSize(parentFD: parentFD, name: name, maximum: maximum) != nil {
                throw PlanningFilesystemError.alreadyExists
            }
            guard renameat(parentFD, temporaryName, parentFD, name) == 0 else {
                throw planningFilesystemPrivateError(errno)
            }
            temporaryPresent = false
            try flushDirectory(parentFD)
        } catch {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if temporaryPresent { _ = unlinkat(parentFD, temporaryName, 0) }
            throw error
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

#if canImport(Darwin)
    private struct TrustedVarAliasIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32
    }

    private struct TrustedVarAlias {
        let identity: TrustedVarAliasIdentity
        let target: String
    }

    private func openDirectoryPath(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw PlanningFilesystemError.invalid("privateDirectory")
        }
        let components = url.pathComponents
        guard components.first == "/" else {
            throw PlanningFilesystemError.invalid("privateDirectory")
        }
        for component in components.dropFirst() {
            try validatePrivateComponent(component)
        }
        let rootFD = "/".withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw planningFilesystemPrivateError(errno) }
        var current = rootFD
        do {
            try requireTrustedAnchorDirectory(rootFD)
            var componentIndex = 1
            if components.dropFirst().first == "var" {
                let aliasFD = try openTrustedVarAlias(rootFD: rootFD)
                _ = Darwin.close(current)
                current = aliasFD
                componentIndex += 1
            }
            while componentIndex < components.count {
                let component = components[componentIndex]
                try validatePrivateComponent(component)
                let child: Int32
                do {
                    child = try openDirectory(parentFD: current, name: component, create: false)
                } catch let error as PlanningFilesystemError where error == .notFound && create {
                    let created = mkdirat(current, component, mode_t(0o700))
                    guard created == 0 || errno == EEXIST else {
                        throw planningFilesystemPrivateError(errno)
                    }
                    if created == 0 { try flushDirectory(current) }
                    child = try openDirectory(parentFD: current, name: component, create: false)
                }
                _ = Darwin.close(current)
                current = child
                componentIndex += 1
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private func openTrustedVarAlias(rootFD: Int32) throws -> Int32 {
        let initial = try readTrustedVarAlias(rootFD: rootFD)
        let privateFD = try openTrustedAnchorDirectory(parentFD: rootFD, name: "private")
        do {
            let varFD = try openTrustedAnchorDirectory(parentFD: privateFD, name: "var")
            do {
                let final = try readTrustedVarAlias(rootFD: rootFD)
                guard initial.identity == final.identity,
                      initial.target == final.target else {
                    throw PlanningFilesystemError.corruptEvidence
                }
                _ = Darwin.close(privateFD)
                // The returned descriptor, rather than the alias pathname, is
                // the authority used for all caller-controlled suffixes.
                return varFD
            } catch {
                _ = Darwin.close(varFD)
                throw error
            }
        } catch {
            _ = Darwin.close(privateFD)
            throw error
        }
    }

    private func readTrustedVarAlias(rootFD: Int32) throws -> TrustedVarAlias {
        var value = stat()
        let statResult = "var".withCString {
            Darwin.fstatat(rootFD, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw planningFilesystemPrivateError(errno) }
        guard (value.st_mode & S_IFMT) == S_IFLNK,
              value.st_uid == 0 else {
            throw PlanningFilesystemError.corruptEvidence
        }

        let expectedTarget = Array("private/var".utf8)
        var targetBytes = [UInt8](repeating: 0, count: expectedTarget.count + 1)
        let targetLength = targetBytes.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return "var".withCString {
                Darwin.readlinkat(
                    rootFD,
                    $0,
                    base.assumingMemoryBound(to: CChar.self),
                    rawBuffer.count
                )
            }
        }
        guard targetLength == expectedTarget.count,
              Array(targetBytes.prefix(targetLength)) == expectedTarget,
              let target = String(bytes: targetBytes.prefix(targetLength), encoding: .utf8) else {
            throw PlanningFilesystemError.corruptEvidence
        }
        return TrustedVarAlias(
            identity: TrustedVarAliasIdentity(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino),
                mode: UInt32(value.st_mode),
                owner: UInt32(value.st_uid),
                group: UInt32(value.st_gid)
            ),
            target: target
        )
    }

    private func openTrustedAnchorDirectory(parentFD: Int32, name: String) throws -> Int32 {
        try validatePrivateComponent(name)
        let fd = name.withCString {
            Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw planningFilesystemPrivateError(errno) }
        do {
            try requireTrustedAnchorDirectory(fd)
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private func requireTrustedAnchorDirectory(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else {
            throw planningFilesystemPrivateError(errno)
        }
        guard (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == 0,
              (value.st_mode & mode_t(0o022)) == 0 else {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    private func openDirectory(parentFD: Int32, name: String, create: Bool) throws -> Int32 {
        try validatePrivateComponent(name)
        do {
            let fd = name.withCString {
                Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw planningFilesystemPrivateError(errno) }
            var value = stat()
            guard fstat(fd, &value) == 0 else {
                _ = Darwin.close(fd)
                throw planningFilesystemPrivateError(errno)
            }
            guard (value.st_mode & S_IFMT) == S_IFDIR else {
                _ = Darwin.close(fd)
                throw PlanningFilesystemError.corruptEvidence
            }
            return fd
        } catch let error as PlanningFilesystemError where error == .notFound && create {
            let created = mkdirat(parentFD, name, mode_t(0o700))
            guard created == 0 || errno == EEXIST else {
                throw planningFilesystemPrivateError(errno)
            }
            if created == 0 { try flushDirectory(parentFD) }
            return try openDirectory(parentFD: parentFD, name: name, create: false)
        }
    }

    private func openRegular(
        parentFD: Int32,
        name: String,
        maximum: Int
    ) throws -> (fd: Int32, size: Int)? {
        try validatePrivateComponent(name)
        let fd = name.withCString {
            Darwin.openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw planningFilesystemPrivateError(errno)
        }
        do {
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw planningFilesystemPrivateError(errno) }
            guard (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1 else {
                throw PlanningFilesystemError.corruptEvidence
            }
            guard value.st_size >= 0, value.st_size <= Int64(maximum), value.st_size <= Int64(Int.max) else {
                throw PlanningFilesystemError.backpressure("privateFile")
            }
            return (fd, Int(value.st_size))
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private func createExclusive(parentFD: Int32, name: String) throws -> Int32 {
        try validatePrivateComponent(name)
        let fd = name.withCString {
            Darwin.openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw planningFilesystemPrivateError(errno) }
        do {
            guard fchmod(fd, mode_t(0o600)) == 0 else {
                throw planningFilesystemPrivateError(errno)
            }
            try excludeFromBackup(fd)
            return fd
        } catch {
            _ = Darwin.close(fd)
            _ = unlinkat(parentFD, name, 0)
            throw error
        }
    }

    private func readFD(_ fd: Int32, expectedSize: Int, maximum: Int) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw planningFilesystemPrivateError(errno) }
        var data = Data()
        data.reserveCapacity(min(expectedSize, maximum))
        var buffer = [UInt8](repeating: 0, count: PlanningFilesystemLimits.ioChunkBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw planningFilesystemPrivateError(errno)
            }
            if count == 0 { break }
            guard data.count <= maximum - count else {
                throw PlanningFilesystemError.backpressure("privateFile")
            }
            data.append(buffer, count: count)
        }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw planningFilesystemPrivateError(errno) }
        guard value.st_size == Int64(data.count), expectedSize == data.count else {
            throw PlanningFilesystemError.corruptEvidence
        }
        return data
    }

    private func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw planningFilesystemPrivateError(errno)
                }
                guard count > 0 else { throw PlanningFilesystemError.unavailable("privateShortWrite") }
                offset += count
            }
        }
    }

    private func flushDirectory(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw planningFilesystemPrivateError(errno) }
    }

    private func excludeFromBackup(_ fd: Int32) throws {
        let key = "com.apple.metadata:com_apple_backup_exclude_item"
        let value = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        let result = value.withUnsafeBytes { rawBuffer -> Int32 in
            key.withCString { keyPointer in
                fsetxattr(
                    fd,
                    keyPointer,
                    rawBuffer.baseAddress,
                    value.count,
                    0,
                    0
                )
            }
        }
        if result != 0 {
            let error = errno
            guard error == ENOTSUP || error == EINVAL else {
                throw planningFilesystemPrivateError(error)
            }
        }
    }

    private func validatePrivateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.unicodeScalars.contains(where: { $0.value == 0 }),
              component.utf8.count <= PlanningFilesystemLimits.maximumDirectoryNameBytes else {
            throw PlanningFilesystemError.invalid("privateComponent")
        }
    }
#endif

    private func manifestName(_ attemptID: UUID) -> String {
        "manifest-\(attemptID.uuidString.lowercased()).json"
    }

    private func backupName(_ attemptID: UUID, _ digest: String) -> String {
        "backup-\(attemptID.uuidString.lowercased())-\(digest)"
    }
}

private func planningFilesystemPrivateError(_ value: Int32) -> PlanningFilesystemError {
    switch value {
    case ENOENT: return .notFound
    case EEXIST: return .alreadyExists
    case EACCES, EPERM: return .permissionDenied
    case ENOSPC, EDQUOT: return .diskFull
    case EROFS: return .readOnly
    case ELOOP, ENOTDIR: return .corruptEvidence
    default: return .unavailable("privateIO")
    }
}

private func planningFilesystemAttemptError(_ value: Int32) -> PlanningFilesystemError {
    switch value {
    case ENOENT: return .notFound
    case EEXIST: return .alreadyExists
    case EACCES, EPERM: return .permissionDenied
    case ENOSPC, EDQUOT: return .diskFull
    case EROFS: return .readOnly
    default: return .unavailable("privateIO")
    }
}
