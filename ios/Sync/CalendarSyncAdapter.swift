import CryptoKit
import Foundation

/// The authenticated V1 payload for one durable calendar series.
///
/// The payload deliberately carries domain `CalendarItem` values for this
/// boundary. Derived recurrence occurrences are never part of the payload;
/// `occurrenceSourceID` must remain nil on every item.
public struct CalendarSeriesPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentTag = "calendarSeries"

    public let schemaVersion: Int
    public let tag: String
    /// Lowercase, hyphenated canonical UUID text. This is the series identity,
    /// not a store ID and not a per-device identifier.
    public let seriesID: String
    public let items: [CalendarItem]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        tag: String = Self.currentTag,
        seriesID: String,
        items: [CalendarItem]
    ) throws {
        // Keep local CalendarItem values untouched while storing a normalized
        // value-semantic copy for public wire encoding.
        let normalizedItems = try items.map(CalendarSeriesWireItem.normalizedForWire)
        try self.init(
            validatingSchemaVersion: schemaVersion,
            tag: tag,
            seriesID: seriesID,
            items: Self.sortedItems(normalizedItems),
            requireSorted: true
        )
    }

    private init(
        validatingSchemaVersion schemaVersion: Int,
        tag: String,
        seriesID: String,
        items: [CalendarItem],
        requireSorted: Bool
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              tag == Self.currentTag else {
            throw SyncFailure.unsupportedSchema
        }
        guard Self.isCanonicalUUID(seriesID) else {
            throw SyncFailure.invalidInput
        }
        guard !items.isEmpty else {
            throw SyncFailure.invalidInput
        }
        guard items.count <= CalendarSnapshot.maximumItemCount else {
            throw CalendarSnapshotError.tooManyItems
        }
        if requireSorted {
            guard Self.isSortedByID(items) else {
                throw SyncFailure.invalidInput
            }
        }

        var seenIDs = Set<UUID>()
        seenIDs.reserveCapacity(items.count)
        for item in items {
            guard seenIDs.insert(item.id).inserted else {
                throw CalendarSnapshotError.duplicateItemID
            }
            try item.validatedForPersistence()
            guard item.occurrenceSourceID == nil else {
                throw CalendarValidationError.transientOccurrence
            }
        }

        self.schemaVersion = schemaVersion
        self.tag = tag
        self.seriesID = seriesID
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CalendarPayloadCodingKey.self)
        let actualKeys = Set(container.allKeys.map(\.stringValue))
        guard actualKeys == Self.requiredRootKeys else {
            throw SyncFailure.invalidInput
        }

        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let tag = try container.decode(String.self, forKey: .tag)
        let seriesID = try container.decode(String.self, forKey: .seriesID)

        var itemContainer = try container.nestedUnkeyedContainer(forKey: .items)
        var decodedItems: [CalendarItem] = []
        decodedItems.reserveCapacity(min(itemContainer.count ?? 0, CalendarSnapshot.maximumItemCount))
        while !itemContainer.isAtEnd {
            guard decodedItems.count < CalendarSnapshot.maximumItemCount else {
                throw CalendarSnapshotError.tooManyItems
            }
            decodedItems.append(try itemContainer.decode(CalendarSeriesWireItem.self).value)
        }

        // The public initializer sorts caller input for deterministic output.
        // Wire input is already required to be in canonical ID order, so a
        // peer cannot silently have its order rewritten during decoding.
        try self.init(
            validatingSchemaVersion: schemaVersion,
            tag: tag,
            seriesID: seriesID,
            items: decodedItems,
            requireSorted: true
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validateForWire()
        var container = encoder.container(keyedBy: CalendarSeriesCodingKey.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tag, forKey: .tag)
        try container.encode(seriesID, forKey: .seriesID)
        try container.encode(items, forKey: .items)
    }

    private func validateForWire() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              tag == Self.currentTag else {
            throw SyncFailure.unsupportedSchema
        }
        guard Self.isCanonicalUUID(seriesID),
              !items.isEmpty,
              items.count <= CalendarSnapshot.maximumItemCount,
              Self.isSortedByID(items) else {
            throw SyncFailure.invalidInput
        }

        var seenIDs = Set<UUID>()
        seenIDs.reserveCapacity(items.count)
        for item in items {
            guard seenIDs.insert(item.id).inserted else {
                throw CalendarSnapshotError.duplicateItemID
            }
            try item.validatedForPersistence()
            guard item.occurrenceSourceID == nil else {
                throw CalendarValidationError.transientOccurrence
            }
        }
    }

    private static let requiredRootKeys: Set<String> = [
        "schemaVersion", "tag", "seriesID", "items"
    ]

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func sortedItems(_ items: [CalendarItem]) -> [CalendarItem] {
        items.sorted { lhs, rhs in
            lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    private static func isSortedByID(_ items: [CalendarItem]) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { previous, next in
            previous.id.uuidString.lowercased() < next.id.uuidString.lowercased()
        }
    }
}

/// The codec is the only boundary that turns a calendar series into V1 wire
/// bytes. It uses the existing calendar date strategy and then the shared
/// canonical JSON writer; no second date or payload format is introduced.
public enum CalendarPayloadCodec {
    private static let maximumPayloadBytes = min(
        CalendarSnapshot.maximumEncodedBytes,
        SyncContractConstants.maxInlinePayloadBytes,
        SyncContractConstants.maxOperationBytes
    )

    public static func encode(seriesID: UUID, items: [CalendarItem]) throws -> Data {
        let payload = try CalendarSeriesPayload(
            seriesID: seriesID.uuidString.lowercased(),
            items: items
        )
        let encoded = try JSONEncoder.calendar.encode(payload)
        try validateSize(encoded)
        let canonical = try SyncWireCodec.canonicalizeJSON(
            encoded,
            maximumBytes: maximumPayloadBytes
        )
        try validateSize(canonical)
        return canonical
    }

    public static func decode(_ bytes: Data) throws -> CalendarSeriesPayload {
        try validateSize(bytes)
        let canonical: Data
        do {
            canonical = try SyncWireCodec.canonicalizeJSON(
                bytes,
                maximumBytes: maximumPayloadBytes
            )
        } catch let error as SyncFailure {
            throw error
        } catch {
            throw SyncFailure.invalidInput
        }
        try validateSize(canonical)
        guard canonical == bytes else {
            throw SyncFailure.invalidInput
        }

        do {
            return try JSONDecoder.calendar.decode(CalendarSeriesPayload.self, from: bytes)
        } catch let error as SyncFailure {
            throw error
        } catch let error as CalendarSnapshotError {
            throw error
        } catch let error as CalendarValidationError {
            throw error
        } catch {
            throw SyncFailure.invalidInput
        }
    }

    private static func validateSize(_ data: Data) throws {
        guard data.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        guard data.count <= SyncContractConstants.maxInlinePayloadBytes,
              data.count <= SyncContractConstants.maxOperationBytes else {
            throw SyncFailure.capacity
        }
    }
}

private struct CalendarSeriesWireItem: Decodable {
    let value: CalendarItem

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CalendarPayloadCodingKey.self)
        try requireWireKeys(
            container,
            required: Self.requiredKeys,
            optional: Self.optionalKeys
        )

        let rawTitle = try container.decode(String.self, forKey: .title)
        let rawIcon = try container.decodeIfPresent(String.self, forKey: .icon)
        let rawSystemIconName = try container.decodeIfPresent(String.self, forKey: .systemIconName)
        let rawTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        let title = try Self.nfc(rawTitle)
        let icon = try Self.nfcOptional(rawIcon)
        let systemIconName = try Self.nfcOptional(rawSystemIconName)
        let timeZoneIdentifier = try Self.nfcOptional(rawTimeZoneIdentifier)

        // Keep CalendarItem's existing local validation and legacy defaults,
        // while decoding nested values through strict wire wrappers below.
        guard icon.map({ CalendarEmojiValidation.validated($0) == Optional($0) }) ?? true,
              systemIconName.map({ CalendarSystemIconSupport.validatedName($0) == Optional($0) }) ?? true,
              timeZoneIdentifier.map({
                  !$0.isEmpty
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      && TimeZone(identifier: $0) != nil
              }) ?? true else {
            throw CalendarValidationError.invalidIconAsset
        }

        let recurrence = try container.decodeIfPresent(
            CalendarRecurrenceWireValue.self,
            forKey: .recurrence
        )?.value
        let iconAsset = try container.decodeIfPresent(
            CalendarIconAssetWireValue.self,
            forKey: .iconAsset
        )?.value
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decodeIfPresent(CalendarItemKind.self, forKey: .kind) ?? .event
        let status = try container.decode(CalendarProgress.self, forKey: .status)
        let start = try container.decode(Date.self, forKey: .start)
        let end = try container.decode(Date.self, forKey: .end)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        let item = try CalendarItem(
            id: id,
            title: title,
            kind: kind,
            icon: icon,
            iconAsset: iconAsset,
            systemIconName: systemIconName,
            status: status,
            start: start,
            end: end,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence
        )
        try item.validatedForPersistence()
        guard item.occurrenceSourceID == nil else {
            throw CalendarValidationError.transientOccurrence
        }
        value = item
    }

    static func normalizedForWire(_ item: CalendarItem) throws -> CalendarItem {
        try item.validatedForPersistence()
        return try CalendarItem(
            id: item.id,
            title: item.title.precomposedStringWithCanonicalMapping,
            kind: item.kind,
            icon: item.icon?.precomposedStringWithCanonicalMapping,
            iconAsset: item.iconAsset,
            systemIconName: item.systemIconName?.precomposedStringWithCanonicalMapping,
            status: item.status,
            start: item.start,
            end: item.end,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            deletedAt: item.deletedAt,
            timeZoneIdentifier: item.timeZoneIdentifier?.precomposedStringWithCanonicalMapping,
            recurrence: item.recurrence
        )
    }

    private static func nfc(_ value: String) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard Array(normalized.utf8) == Array(value.utf8) else {
            throw SyncFailure.invalidInput
        }
        return value
    }

    private static func nfcOptional(_ value: String?) throws -> String? {
        guard let value else { return nil }
        return try nfc(value)
    }

    private static let requiredKeys: Set<String> = [
        "id", "title", "status", "start", "end", "createdAt", "updatedAt"
    ]

    private static let optionalKeys: Set<String> = [
        "kind", "icon", "iconAsset", "systemIconName", "deletedAt",
        "timeZoneIdentifier", "recurrence"
    ]
}

private struct CalendarRecurrenceWireValue: Decodable {
    let value: CalendarRecurrenceRule

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CalendarPayloadCodingKey.self)
        try requireWireKeys(
            container,
            required: ["frequency"],
            optional: ["interval", "until"]
        )
        let frequency = try container.decode(CalendarRecurrenceFrequency.self, forKey: .frequency)
        let interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        let until = try container.decodeIfPresent(Date.self, forKey: .until)
        value = try CalendarRecurrenceRule(
            frequency: frequency,
            interval: interval,
            until: until
        )
    }
}

private struct CalendarIconAssetWireValue: Decodable {
    let value: CalendarIconAsset

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CalendarPayloadCodingKey.self)
        try requireWireKeys(
            container,
            required: ["format", "bytes"],
            optional: ["schemaVersion", "contentHash"]
        )

        if let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion),
           schemaVersion != CalendarIconAsset.currentSchemaVersion {
            throw CalendarValidationError.invalidIconAsset
        }
        let format = try container.decode(CalendarIconAsset.Format.self, forKey: .format)
        let bytes = try container.decode(Data.self, forKey: .bytes)
        if let encodedHash = try container.decodeIfPresent(String.self, forKey: .contentHash),
           encodedHash != SyncWireCodec.sha256(bytes) {
            throw CalendarValidationError.invalidIconAsset
        }
        let asset = try CalendarIconAsset(format: format, bytes: bytes)
        value = asset
    }
}

private func requireWireKeys(
    _ container: KeyedDecodingContainer<CalendarPayloadCodingKey>,
    required: Set<String>,
    optional: Set<String>
) throws {
    let keys = Set(container.allKeys.map(\.stringValue))
    guard required.isSubset(of: keys),
          keys.isSubset(of: required.union(optional)) else {
        throw SyncFailure.invalidInput
    }
}

private enum CalendarSeriesCodingKey: String, CodingKey {
    case schemaVersion
    case tag
    case seriesID
    case items
}

private struct CalendarPayloadCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }

    static let schemaVersion = CalendarPayloadCodingKey(stringValue: "schemaVersion")!
    static let tag = CalendarPayloadCodingKey(stringValue: "tag")!
    static let seriesID = CalendarPayloadCodingKey(stringValue: "seriesID")!
    static let items = CalendarPayloadCodingKey(stringValue: "items")!
    static let id = CalendarPayloadCodingKey(stringValue: "id")!
    static let title = CalendarPayloadCodingKey(stringValue: "title")!
    static let kind = CalendarPayloadCodingKey(stringValue: "kind")!
    static let icon = CalendarPayloadCodingKey(stringValue: "icon")!
    static let iconAsset = CalendarPayloadCodingKey(stringValue: "iconAsset")!
    static let systemIconName = CalendarPayloadCodingKey(stringValue: "systemIconName")!
    static let status = CalendarPayloadCodingKey(stringValue: "status")!
    static let start = CalendarPayloadCodingKey(stringValue: "start")!
    static let end = CalendarPayloadCodingKey(stringValue: "end")!
    static let createdAt = CalendarPayloadCodingKey(stringValue: "createdAt")!
    static let updatedAt = CalendarPayloadCodingKey(stringValue: "updatedAt")!
    static let deletedAt = CalendarPayloadCodingKey(stringValue: "deletedAt")!
    static let timeZoneIdentifier = CalendarPayloadCodingKey(stringValue: "timeZoneIdentifier")!
    static let recurrence = CalendarPayloadCodingKey(stringValue: "recurrence")!
    static let frequency = CalendarPayloadCodingKey(stringValue: "frequency")!
    static let interval = CalendarPayloadCodingKey(stringValue: "interval")!
    static let until = CalendarPayloadCodingKey(stringValue: "until")!
    static let contentHash = CalendarPayloadCodingKey(stringValue: "contentHash")!
    static let format = CalendarPayloadCodingKey(stringValue: "format")!
    static let bytes = CalendarPayloadCodingKey(stringValue: "bytes")!
}

/// Durable authenticated adapter for the calendar domain. The actor keeps
/// signing and ledger derivation outside the store's synchronous mutation
/// closure, then commits the signed operation and its entity candidate in one
/// CalendarStore transaction.
public actor CalendarSyncAdapter: SyncDomainAdapter {
    public let storeID: String
    public let domain: SyncDomain = .calendar

    /// This origin is an adapter-private cursor namespace. It is emitted only
    /// in `SyncPage.cursor`; it must never be copied into the gateway frontier
    /// sent in a `SyncExchangeRequest`.
    private static let pageCursorOriginID = "00000000-0000-4000-8000-0000000000ff"
    private static let requestOverheadBytes: Int = {
        let positions = (0..<SyncContractConstants.maxFrontierPositions).map { index in
            let suffix = String(index + 1, radix: 16)
            let paddedSuffix = String(repeating: "0", count: max(0, 12 - suffix.count)) + suffix
            return SyncPosition(
                stream: SyncStream(
                    storeID: "00000000-0000-4000-8000-000000000001",
                    originID: "00000000-0000-4000-8000-\(paddedSuffix)"
                ),
                through: String(UInt64.max)
            )
        }
        let request = SyncExchangeRequest(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: "00000000-0000-4000-8000-000000000001",
            received: SyncFrontier(positions: positions),
            upper: nil,
            operations: [],
            acknowledgements: [],
            limit: SyncContractConstants.maxPageOperations
        )
        return (try? SyncWireCodec.canonicalJSON(request, maximumBytes: SyncContractConstants.maxBodyBytes).count)
            ?? SyncContractConstants.maxBodyBytes
    }()

    private let store: CalendarStore
    private let datasetID: String
    private let epoch: String
    private let originID: String
    private let identity: SyncIdentityStore
    private let gatewayCursorID: String?
    private let authorizedApplyingReplicaIDs: Set<String>
    private var recovered = false

    public init(
        store: CalendarStore,
        datasetID: String,
        epoch: String,
        originID: String,
        storeID: String,
        identity: SyncIdentityStore,
        gatewayCursorID: String? = nil,
        authorizedApplyingReplicaIDs: Set<String> = []
    ) throws {
        try SyncContractValidation.requireUUID(datasetID)
        try SyncContractValidation.requireUnsigned(epoch, positive: true)
        try SyncContractValidation.requireUUID(originID)
        try SyncContractValidation.requireUUID(storeID)
        guard originID != Self.pageCursorOriginID else { throw SyncFailure.invalidInput }
        if let gatewayCursorID {
            try SyncContractValidation.requireUUID(gatewayCursorID)
            guard gatewayCursorID != Self.pageCursorOriginID,
                  gatewayCursorID != originID else { throw SyncFailure.invalidInput }
        }
        for replicaID in authorizedApplyingReplicaIDs {
            try SyncContractValidation.requireUUID(replicaID)
        }
        self.store = store
        self.datasetID = datasetID
        self.epoch = epoch
        self.originID = originID
        self.storeID = storeID
        self.identity = identity
        self.gatewayCursorID = gatewayCursorID
        self.authorizedApplyingReplicaIDs = authorizedApplyingReplicaIDs
    }

    public func recover() async throws {
        let device = try await identity.identity()
        guard device.role == .applying, device.deviceID == originID else {
            throw SyncFailure.identityUnavailable
        }
        let configuredStoreID = storeID
        let configuredDatasetID = datasetID
        let configuredOriginID = originID
        let configuredEpoch = epoch
        try await store.mutateEnvelope { current in
            var replication = current.replication
            if let existing = replication {
                guard existing.storeID == configuredStoreID,
                      existing.datasetID == configuredDatasetID,
                      existing.localOriginID == configuredOriginID,
                      existing.epoch == configuredEpoch else {
                    throw SyncFailure.corruptStore
                }
                try Self.validateLocalIdentity(existing, device: device)
                try Self.validateCalendarLedger(existing)
                var recoveredReplication = try Self.migratedAcknowledgements(in: existing)
                if recoveredReplication.receiptLedgerVersion == 0 {
                    recoveredReplication = try Self.migratedReceipts(in: recoveredReplication, device: device)
                }
                replication = recoveredReplication
                guard let recoveredReplication = replication else { throw SyncFailure.corruptStore }
                try Self.validateReceiptHashes(recoveredReplication)
            } else {
                replication = Self.emptyEnvelope(
                    storeID: configuredStoreID,
                    datasetID: configuredDatasetID,
                    originID: configuredOriginID,
                    epoch: configuredEpoch
                )
            }
            guard let replication else { throw SyncFailure.corruptStore }
            let updated = try CalendarStoreEnvelope(
                snapshot: current.snapshot,
                seriesMembership: current.seriesMembership,
                replication: replication
            )
            return (updated, ())
        }
        recovered = true
    }

    public func pendingPage(after frontier: SyncFrontier?, limit: Int) async throws -> SyncPage {
        guard (1...SyncContractConstants.maxPageOperations).contains(limit) else {
            throw SyncFailure.invalidInput
        }
        try await ensureRecovered()
        if let frontier { try SyncWireCodec.validate(frontier) }
        let cursor = try Self.pendingCursor(after: frontier, storeID: storeID, originID: originID)
        let device = try await identity.identity()
        guard device.role == .applying, device.deviceID == originID else {
            throw SyncFailure.identityUnavailable
        }
        let signingKey = try await identity.loadOrCreateKey()
        let signingSeed = signingKey.rawRepresentation
        let configuredStoreID = storeID
        let configuredDatasetID = datasetID
        let configuredOriginID = originID
        let configuredEpoch = epoch

        return try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            guard existing.storeID == configuredStoreID,
                  existing.datasetID == configuredDatasetID,
                  existing.localOriginID == configuredOriginID,
                  existing.epoch == configuredEpoch else { throw SyncFailure.corruptStore }

            var replication = existing
            var outbox = existing.outbox
            var entities = existing.entities
            var nextSequence = try SyncContractValidation.requireUnsigned(existing.nextSequence, positive: true)
            let groups = try Self.seriesGroups(snapshot: current.snapshot, links: current.seriesMembership)
            let sortedSeriesIDs = groups.keys.sorted()
            var dirtySeriesIDs: [String] = []
            dirtySeriesIDs.reserveCapacity(sortedSeriesIDs.count)
            for seriesIDString in sortedSeriesIDs {
                guard let seriesID = UUID(uuidString: seriesIDString) else { throw SyncFailure.corruptStore }
                let payloadBytes = try CalendarPayloadCodec.encode(
                    seriesID: seriesID,
                    items: groups[seriesIDString] ?? []
                )
                let payloadHash = SyncWireCodec.sha256(payloadBytes)
                let entityID = Self.entityID(for: seriesIDString)
                let currentEntity = entities.first { $0.entityID == entityID }
                if currentEntity?.versionHash != payloadHash {
                    dirtySeriesIDs.append(seriesIDString)
                }
            }
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingSeed)
            var generated = 0

            for seriesIDString in dirtySeriesIDs.prefix(SyncContractConstants.maxPageOperations) {
                guard let seriesID = UUID(uuidString: seriesIDString) else { throw SyncFailure.corruptStore }
                let payloadBytes = try CalendarPayloadCodec.encode(seriesID: seriesID, items: groups[seriesIDString] ?? [])
                let payloadHash = SyncWireCodec.sha256(payloadBytes)
                let entityID = Self.entityID(for: seriesIDString)
                let entityIndex = entities.firstIndex { $0.entityID == entityID }
                let currentEntity = entityIndex.flatMap { entities[$0] }

                guard nextSequence < UInt64.max else { throw SyncFailure.capacity }
                let mutationID = UUID().uuidString.lowercased()
                let payload = SyncPayload(
                    schemaVersion: SyncContractConstants.schemaVersion,
                    hash: payloadHash,
                    byteCount: payloadBytes.count,
                    inline: CalendarSyncBase64URL.encode(payloadBytes),
                    blobHash: nil
                )
                let unsigned = SyncOperation(
                    schemaVersion: SyncContractConstants.schemaVersion,
                    datasetID: configuredDatasetID,
                    epoch: configuredEpoch,
                    storeID: configuredStoreID,
                    domain: .calendar,
                    originID: configuredOriginID,
                    keyID: device.keyID,
                    sequence: String(nextSequence),
                    mutationID: mutationID,
                    entityID: entityID,
                    parents: currentEntity?.heads ?? [],
                    baseHash: currentEntity?.versionHash,
                    kind: currentEntity == nil ? .bootstrap : .put,
                    payload: payload,
                    signature: ""
                )
                let operation = try SyncWireCodec.signOperation(unsigned, using: signingKey)
                try SyncWireCodec.validate(operation)
                _ = try SyncWireCodec.canonicalJSON(
                    operation,
                    maximumBytes: SyncContractConstants.maxOperationBytes
                )
                outbox.append(SyncOutboxEntry(
                    schemaVersion: SyncContractConstants.schemaVersion,
                    operation: operation,
                    state: .ready,
                    attempts: 0,
                    lastError: nil,
                    acknowledgements: []
                ))
                let candidate = SyncEntityVersion(
                    entityID: entityID,
                    heads: [mutationID],
                    versionHash: payloadHash,
                    deleted: false
                )
                if let entityIndex { entities[entityIndex] = candidate } else { entities.append(candidate) }
                nextSequence += 1
                generated += 1
            }

            outbox.sort { lhs, rhs in
                let left = UInt64(lhs.operation.sequence) ?? 0
                let right = UInt64(rhs.operation.sequence) ?? 0
                return left == right ? lhs.operation.mutationID < rhs.operation.mutationID : left < right
            }
            guard outbox.count <= CalendarStoreEnvelope.maximumLedgerEntries,
                  entities.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
                throw SyncFailure.capacity
            }
            replication = SyncAdapterEnvelope(
                schemaVersion: existing.schemaVersion,
                storeID: existing.storeID,
                datasetID: existing.datasetID,
                localOriginID: existing.localOriginID,
                epoch: existing.epoch,
                nextSequence: String(nextSequence),
                received: existing.received,
                applied: existing.applied,
                outbox: outbox,
                inbox: existing.inbox,
                entities: entities,
                conflicts: existing.conflicts,
                acknowledgements: existing.acknowledgements,
                receivedAcknowledgements: existing.receivedAcknowledgements,
                receipts: existing.receipts,
                receiptLedgerVersion: existing.receiptLedgerVersion
            )

            let outboxByMutationID = Dictionary(
                outbox.map { ($0.operation.mutationID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let configuredGatewayID = gatewayCursorID
            var eligible: [(UInt64, SyncOperation)] = []
            var deferredOperations = false
            var blockedOrigins = Set<String>()
            for entry in outbox {
                guard let sequence = UInt64(entry.operation.sequence), sequence > cursor.operation else {
                    continue
                }
                if let configuredGatewayID {
                    guard !entry.gatewayStoredBy.contains(configuredGatewayID) else { continue }

                    // The gateway accepts each origin as a contiguous sequence.
                    // Once an unsent operation is blocked by a local causal
                    // parent, later operations from that origin must stay out of
                    // this page even when their own parents are independent.
                    // Otherwise the gateway rejects the whole exchange (including
                    // the safe prefix) and the page cursor can skip the blocked
                    // operation permanently.
                    guard !blockedOrigins.contains(entry.operation.originID) else {
                        deferredOperations = true
                        continue
                    }
                    guard entry.operation.parents.allSatisfy({ parentID in
                        guard let parent = outboxByMutationID[parentID] else { return true }
                        return parent.gatewayStoredBy.contains(configuredGatewayID)
                    }) else {
                        blockedOrigins.insert(entry.operation.originID)
                        deferredOperations = true
                        continue
                    }
                }
                eligible.append((sequence, entry.operation))
            }
            // `acknowledgements` is the local outbound queue. Filter by the
            // configured origin as a defense-in-depth guard for legacy files
            // that may still contain a foreign ACK from the pre-separation
            // format; recovery migrates those ACKs to durable evidence.
            let deduplicatedAcknowledgements = try Self.deduplicatedAcknowledgements(
                replication.acknowledgements.filter { $0.replicaID == configuredOriginID }
            )
            guard Self.requestOverheadBytes < SyncContractConstants.maxBodyBytes else {
                throw SyncFailure.capacity
            }
            let bodyBudget = SyncContractConstants.maxBodyBytes - Self.requestOverheadBytes
            var usedBytes = 0
            var acknowledgements: [SyncAck] = []
            if !eligible.isEmpty, !deduplicatedAcknowledgements.isEmpty {
                let acknowledgement = deduplicatedAcknowledgements[0]
                let encodedSize = try SyncWireCodec.canonicalJSON(
                    acknowledgement,
                    maximumBytes: SyncContractConstants.maxOperationBytes
                ).count
                guard encodedSize <= bodyBudget else { throw SyncFailure.capacity }
                acknowledgements.append(acknowledgement)
                usedBytes += encodedSize
            }
            var selected: [SyncOperation] = []
            for (_, operation) in eligible {
                guard selected.count + acknowledgements.count < limit else { break }
                let encodedSize = try SyncWireCodec.canonicalJSON(
                    operation,
                    maximumBytes: SyncContractConstants.maxOperationBytes
                ).count
                let elementSize = encodedSize + (selected.isEmpty ? 0 : 1)
                if selected.isEmpty {
                    guard elementSize <= bodyBudget else { throw SyncFailure.capacity }
                } else if usedBytes + elementSize > bodyBudget {
                    break
                }
                selected.append(operation)
                usedBytes += elementSize
            }
            let through = selected.last.flatMap { UInt64($0.sequence) } ?? cursor.operation
            for acknowledgement in deduplicatedAcknowledgements {
                if acknowledgements.contains(where: {
                    Self.acknowledgementIdentityKey($0) == Self.acknowledgementIdentityKey(acknowledgement)
                }) {
                    continue
                }
                guard selected.count + acknowledgements.count < limit else { break }
                let encodedSize = try SyncWireCodec.canonicalJSON(
                    acknowledgement,
                    maximumBytes: SyncContractConstants.maxOperationBytes
                ).count
                let elementSize = encodedSize + (acknowledgements.isEmpty ? 0 : 1)
                guard usedBytes + elementSize <= bodyBudget else { break }
                acknowledgements.append(acknowledgement)
                usedBytes += elementSize
            }
            let hasMoreOperations = selected.count < eligible.count
                || deferredOperations
                || dirtySeriesIDs.count > generated
            let hasMoreAcknowledgements = acknowledgements.count < deduplicatedAcknowledgements.count
            let pageCursor = Self.pageCursor(
                storeID: configuredStoreID,
                originID: configuredOriginID,
                operationThrough: through
            )
            let page = SyncPage(
                operations: selected,
                acknowledgements: acknowledgements,
                cursor: pageCursor,
                hasMore: hasMoreOperations || hasMoreAcknowledgements
            )
            let updated = try CalendarStoreEnvelope(
                snapshot: current.snapshot,
                seriesMembership: current.seriesMembership,
                replication: replication
            )
            return (updated, page)
        }
    }

    public func applyRemote(_ operation: SyncOperation) async throws -> SyncCommitReceipt {
        try await ensureRecovered()
        try SyncWireCodec.validate(operation)
        guard operation.datasetID == datasetID,
              operation.epoch == epoch,
              operation.storeID == storeID,
              operation.domain == .calendar else {
            throw SyncFailure.invalidInput
        }
        guard operation.kind == .put || operation.kind == .bootstrap else {
            throw SyncFailure.invalidInput
        }
        guard operation.payload.blobHash == nil,
              let inline = operation.payload.inline else {
            throw SyncFailure.unsupportedMedia
        }
        let bytes = try CalendarSyncBase64URL.decode(inline)
        guard bytes.count == operation.payload.byteCount,
              SyncWireCodec.sha256(bytes) == operation.payload.hash else {
            throw SyncFailure.hashMismatch
        }
        let payload = try CalendarPayloadCodec.decode(bytes)
        guard Self.entityID(for: payload.seriesID) == operation.entityID else {
            throw SyncFailure.invalidInput
        }
        let operationHash = try SyncWireCodec.operationHash(for: operation)
        let configuredStoreID = storeID
        let configuredDatasetID = datasetID
        let configuredOriginID = originID
        let configuredEpoch = epoch

        return try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            guard existing.storeID == configuredStoreID,
                  existing.datasetID == configuredDatasetID,
                  existing.localOriginID == configuredOriginID,
                  existing.epoch == configuredEpoch else { throw SyncFailure.corruptStore }
            if let known = Self.knownOperation(hash: operationHash, in: existing) {
                let storedReceipt = existing.receipts.first(where: {
                    $0.operationHash == operationHash && $0.mutationID == known.mutationID
                })
                if storedReceipt?.disposition == .ambiguous {
                    throw SyncFailure.receiptMigrationNeedsEvidence
                }
                let receipt = SyncCommitReceipt(
                    schemaVersion: SyncContractConstants.schemaVersion,
                    mutationID: known.mutationID,
                    operationHash: operationHash,
                    entityVersion: storedReceipt?.entityVersion ?? known.payload.hash,
                    disposition: storedReceipt?.disposition ?? .alreadyApplied
                )
                return (current, receipt)
            }
            if Self.isCoveredByFrontier(operation, frontier: existing.applied) {
                // Checkpoint compaction may remove the payload and receipt
                // after the applied frontier has durably covered this stream.
                // The frontier is the replay barrier: a covered operation is
                // acknowledged as already applied and is never executed again.
                return (current, SyncCommitReceipt(
                    schemaVersion: SyncContractConstants.schemaVersion,
                    mutationID: operation.mutationID,
                    operationHash: operationHash,
                    entityVersion: operation.payload.hash,
                    disposition: .alreadyApplied
                ))
            }
            for knownOperation in Self.ledgerOperations(in: existing) {
                if knownOperation.mutationID == operation.mutationID && knownOperation != operation {
                    throw SyncFailure.operationReuse
                }
                if knownOperation.originID == operation.originID,
                   knownOperation.sequence == operation.sequence,
                   knownOperation != operation {
                    throw SyncFailure.operationReuse
                }
            }
            let sequence = try SyncContractValidation.requireUnsigned(operation.sequence, positive: true)
            if sequence > 1 {
                let predecessor = String(sequence - 1)
                let physicalPredecessorExists = Self.ledgerOperations(in: existing).contains {
                    $0.originID == operation.originID && $0.sequence == predecessor
                }
                let frontierCoversPredecessor = Self.frontierThrough(
                    operation.originID,
                    in: existing.applied
                ) >= sequence - 1
                guard physicalPredecessorExists || frontierCoversPredecessor else {
                    throw SyncFailure.missingParent
                }
            }

            let incomingSeriesID = payload.seriesID
            let entityIndex = existing.entities.firstIndex { $0.entityID == operation.entityID }
            let entity = entityIndex.flatMap { existing.entities[$0] }
            let localItems = try Self.seriesItems(
                snapshot: current.snapshot,
                links: current.seriesMembership,
                seriesID: incomingSeriesID
            )
            let hasLocalSeries = current.seriesMembership.contains { $0.seriesID == incomingSeriesID }
            let localSeriesHash: String?
            if !hasLocalSeries {
                localSeriesHash = nil
            } else {
                guard let incomingSeriesUUID = UUID(uuidString: incomingSeriesID) else {
                    throw SyncFailure.invalidInput
                }
                localSeriesHash = SyncWireCodec.sha256(try CalendarPayloadCodec.encode(
                    seriesID: incomingSeriesUUID,
                    items: localItems
                ))
            }

            if operation.kind == .bootstrap {
                guard operation.parents.isEmpty, operation.baseHash == nil else {
                    throw SyncFailure.missingParent
                }
                if entity != nil, localSeriesHash != operation.payload.hash {
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: entity?.versionHash ?? operation.payload.hash,
                        reason: "bootstrapAlreadyActivated"
                    )
                }
                if !localItems.isEmpty, localSeriesHash != operation.payload.hash {
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: localSeriesHash ?? operation.payload.hash,
                        reason: "bootstrapCollision"
                    )
                }
            } else {
                let knownMutationIDs = Set(Self.ledgerOperations(in: existing).map(\.mutationID))
                    .union(existing.entities.flatMap(\.heads))
                if operation.parents.contains(where: { !knownMutationIDs.contains($0) }) {
                    guard entity != nil || hasLocalSeries else { throw SyncFailure.missingParent }
                    let currentBranches = entity?.heads.compactMap { head in
                        Self.ledgerOperations(in: existing).first { $0.mutationID == head }
                    } ?? []
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: entity?.versionHash ?? localSeriesHash ?? operation.payload.hash,
                        reason: "compactedParent",
                        additionalBranches: currentBranches
                    )
                }
                guard let entity else {
                    guard hasLocalSeries else { throw SyncFailure.missingParent }
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: localSeriesHash ?? operation.payload.hash,
                        reason: "legacyBootstrapCollision"
                    )
                }
                let currentBranches = entity.heads.compactMap { head in
                    Self.ledgerOperations(in: existing).first { $0.mutationID == head }
                }
                guard operation.parents == entity.heads else {
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: entity.versionHash,
                        reason: "concurrentParentHeads",
                        additionalBranches: currentBranches
                    )
                }
                guard operation.baseHash == entity.versionHash else {
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: entity.versionHash,
                        reason: "staleBase",
                        additionalBranches: currentBranches
                    )
                }
                guard localSeriesHash == entity.versionHash else {
                    return try Self.retainedConflict(
                        current: current,
                        existing: existing,
                        operation: operation,
                        operationHash: operationHash,
                        entityVersion: localSeriesHash ?? entity.versionHash,
                        reason: "localSeriesChanged",
                        additionalBranches: currentBranches
                    )
                }
            }

            let replacedItemIDs = Set(current.seriesMembership.filter { $0.seriesID == incomingSeriesID }.map(\.itemID))
            var existingItemIDs = Set<String>()
            let unrelatedItems = current.snapshot.items.filter { item in
                let itemID = item.id.uuidString.lowercased()
                guard !replacedItemIDs.contains(itemID) else { return false }
                existingItemIDs.insert(itemID)
                return true
            }
            for item in payload.items {
                let itemID = item.id.uuidString.lowercased()
                guard existingItemIDs.insert(itemID).inserted else { throw SyncFailure.idCollision }
            }
            let snapshot = CalendarSnapshot(items: unrelatedItems + payload.items)
            var links = current.seriesMembership.filter { $0.seriesID != incomingSeriesID }
            links.append(contentsOf: try payload.items.map { item in
                try CalendarSeriesLink(itemID: item.id.uuidString.lowercased(), seriesID: incomingSeriesID)
            })
            let inbox = existing.inbox + [operation]
            let entityVersion = SyncEntityVersion(
                entityID: operation.entityID,
                heads: [operation.mutationID],
                versionHash: operation.payload.hash,
                deleted: false
            )
            var entities = existing.entities
            if let entityIndex { entities[entityIndex] = entityVersion } else { entities.append(entityVersion) }
            guard inbox.count <= CalendarStoreEnvelope.maximumLedgerEntries,
                  entities.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
                throw SyncFailure.capacity
            }
            let receipt = SyncOperationReceipt(
                operationHash: operationHash,
                mutationID: operation.mutationID,
                entityVersion: operation.payload.hash,
                disposition: .applied
            )
            let replication = Self.replacing(
                existing,
                inbox: inbox,
                entities: entities,
                receipts: try Self.appendingReceipt(receipt, to: existing.receipts)
            )
            let updated = try CalendarStoreEnvelope(
                snapshot: snapshot,
                seriesMembership: links,
                replication: replication
            )
            let commitReceipt = SyncCommitReceipt(
                schemaVersion: SyncContractConstants.schemaVersion,
                mutationID: operation.mutationID,
                operationHash: operationHash,
                entityVersion: operation.payload.hash,
                disposition: .applied
            )
            return (updated, commitReceipt)
        }
    }

    public func recordAcknowledgement(_ acknowledgement: SyncAck) async throws {
        try await recordAcknowledgement(
            acknowledgement,
            verifiedOperation: nil,
            authenticatedRemote: false
        )
    }

    public func recordAuthenticatedRemoteAcknowledgement(_ acknowledgement: SyncAck) async throws {
        try await recordAcknowledgement(
            acknowledgement,
            verifiedOperation: nil,
            authenticatedRemote: true
        )
    }

    public func recordAcknowledgement(_ acknowledgement: SyncAck, for operation: SyncOperation) async throws {
        try await recordAcknowledgement(
            acknowledgement,
            verifiedOperation: operation,
            authenticatedRemote: false
        )
    }

    private func recordAcknowledgement(
        _ acknowledgement: SyncAck,
        verifiedOperation: SyncOperation?,
        authenticatedRemote: Bool
    ) async throws {
        try await ensureRecovered()
        try SyncWireCodec.validate(acknowledgement)
        guard acknowledgement.datasetID == datasetID,
              acknowledgement.epoch == epoch,
              acknowledgement.storeID == storeID else {
            throw SyncFailure.invalidInput
        }
        if let verifiedOperation {
            try SyncWireCodec.validate(verifiedOperation)
            guard verifiedOperation.datasetID == datasetID,
                  verifiedOperation.epoch == epoch,
                  verifiedOperation.storeID == storeID,
                  verifiedOperation.domain == .calendar else {
                throw SyncFailure.invalidInput
            }
        }
        let localDevice = try await identity.identity()
        let localPublicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(syncBase64URL: localDevice.publicKey)
        )
        let configuredAuthorizedApplyingReplicaIDs = authorizedApplyingReplicaIDs
        _ = try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            let isLocalAcknowledgement = acknowledgement.replicaID == existing.localOriginID
            if isLocalAcknowledgement {
                guard localDevice.deviceID == existing.localOriginID,
                      localDevice.role == .applying,
                      acknowledgement.keyID == localDevice.keyID else {
                    throw SyncFailure.unauthenticated
                }
                try SyncWireCodec.verifyAcknowledgement(
                    acknowledgement,
                    publicKey: localPublicKey
                )
            }
            // A remote ACK is trusted only at the authenticated response
            // boundary. The default adapter entry point is also used by
            // local callers, so it must reject a forged remote ACK before it
            // can look up a retained operation or affect retirement state.
            guard isLocalAcknowledgement || authenticatedRemote else {
                throw SyncFailure.unauthenticated
            }
            if let verifiedOperation {
                guard try SyncWireCodec.operationHash(for: verifiedOperation) == acknowledgement.operationHash,
                      verifiedOperation.mutationID == acknowledgement.mutationID else {
                    throw SyncFailure.unauthenticated
                }
            }
            let knownOperation = try? Self.operation(for: acknowledgement.operationHash, in: existing)
            let operation: SyncOperation
            var replayAnchor: SyncOperation? = nil
            if let knownOperation {
                operation = knownOperation
            } else if let verifiedOperation {
                guard isLocalAcknowledgement,
                      acknowledgement.level == .applied,
                      acknowledgement.resultHash == verifiedOperation.payload.hash,
                      Self.isCoveredByFrontier(verifiedOperation, frontier: existing.applied) else {
                    throw SyncFailure.operationUnknown
                }
                operation = verifiedOperation
                replayAnchor = verifiedOperation
            } else {
                // A response-authenticated ACK may arrive after its operation
                // was compacted locally. It is a cursor-only receipt in that
                // case: never retransmit it and never use it to retire local
                // state. Local ACKs still pass through the signature check
                // above; the authenticated response path is the only path
                // allowed to accept this compacted echo.
                guard authenticatedRemote else {
                    throw SyncFailure.operationUnknown
                }
                let matchesLocalOutbox = existing.outbox.contains { entry in
                    guard entry.operation.mutationID == acknowledgement.mutationID,
                          let hash = try? SyncWireCodec.operationHash(for: entry.operation) else {
                        return false
                    }
                    return hash == acknowledgement.operationHash
                }
                guard !matchesLocalOutbox else { throw SyncFailure.operationUnknown }
                return (current, ())
            }
            guard operation.mutationID == acknowledgement.mutationID else {
                throw SyncFailure.unauthenticated
            }
            switch acknowledgement.level {
            case .stored, .applied:
                guard acknowledgement.resultHash == operation.payload.hash else {
                    throw SyncFailure.unauthenticated
                }
            case .retainedConflict:
                // A retained conflict reports the applying replica's retained
                // entity hash, which is intentionally different from the
                // operation payload hash in the common concurrent-edit case.
                break
            }
            var inbox = existing.inbox
            if let replayAnchor {
                for knownOperation in Self.ledgerOperations(in: existing) {
                    if knownOperation.mutationID == replayAnchor.mutationID,
                       knownOperation != replayAnchor {
                        throw SyncFailure.operationReuse
                    }
                    if knownOperation.originID == replayAnchor.originID,
                       knownOperation.sequence == replayAnchor.sequence,
                       knownOperation != replayAnchor {
                        throw SyncFailure.operationReuse
                    }
                }
                guard inbox.count < CalendarStoreEnvelope.maximumLedgerEntries else {
                    throw SyncFailure.capacity
                }
                // This operation is already covered by the applied frontier.
                // Retain it only as authenticated evidence for the queued
                // ACK; never apply it to the calendar snapshot again.
                inbox.append(replayAnchor)
            }
            var acknowledgements = existing.acknowledgements
            var receivedAcknowledgements = existing.receivedAcknowledgements
            if isLocalAcknowledgement {
                acknowledgements = try Self.replacingWithStrongestAcknowledgement(
                    acknowledgement,
                    in: acknowledgements
                )
            } else {
                // A remote ACK is durable evidence for retirement and replay,
                // never an outbound message authored by this replica.
                receivedAcknowledgements = try Self.replacingWithStrongestAcknowledgement(
                    acknowledgement,
                    in: receivedAcknowledgements
                )
            }
            var outbox = existing.outbox
            if let index = outbox.firstIndex(where: { entry in
                guard let hash = try? SyncWireCodec.operationHash(for: entry.operation) else { return false }
                return hash == acknowledgement.operationHash
            }) {
                var entry = outbox[index]
                let entryAcknowledgements = try Self.replacingWithStrongestAcknowledgement(
                    acknowledgement,
                    in: entry.acknowledgements
                )
                let terminalAck = entryAcknowledgements.first { candidate in
                    candidate.replicaID != existing.localOriginID
                    && configuredAuthorizedApplyingReplicaIDs.contains(candidate.replicaID)
                    && (candidate.level == .applied || candidate.level == .retainedConflict)
                }
                let terminalForRemote = terminalAck != nil
                    && (gatewayCursorID == nil || entry.gatewayStoredBy.contains(gatewayCursorID ?? ""))
                if terminalForRemote {
                    var remainingOutbox = outbox
                    remainingOutbox.remove(at: index)
                    let operationHash = try SyncWireCodec.operationHash(for: entry.operation)
                    receivedAcknowledgements.removeAll { candidate in
                        candidate.operationHash == operationHash
                            && candidate.mutationID == entry.operation.mutationID
                    }
                    if !existing.inbox.contains(where: { operation in
                        guard let hash = try? SyncWireCodec.operationHash(for: operation) else { return false }
                        return hash == acknowledgement.operationHash
                    }) {
                        inbox.append(entry.operation)
                        let replication = Self.replacing(
                            existing,
                            outbox: remainingOutbox,
                            inbox: inbox,
                            acknowledgements: acknowledgements,
                            receivedAcknowledgements: receivedAcknowledgements
                        )
                        let updated = try CalendarStoreEnvelope(snapshot: current.snapshot, seriesMembership: current.seriesMembership, replication: replication)
                        return (updated, ())
                    }
                    outbox = remainingOutbox
                } else {
                    entry = SyncOutboxEntry(
                        schemaVersion: entry.schemaVersion,
                        operation: entry.operation,
                        state: .awaitingAcks,
                        attempts: entry.attempts,
                        lastError: entry.lastError,
                        acknowledgements: entryAcknowledgements,
                        gatewayStoredBy: entry.gatewayStoredBy
                    )
                    outbox[index] = entry
                }
            }
            let replication = Self.replacing(
                existing,
                outbox: outbox,
                inbox: inbox,
                acknowledgements: acknowledgements,
                receivedAcknowledgements: receivedAcknowledgements
            )
            let updated = try CalendarStoreEnvelope(snapshot: current.snapshot, seriesMembership: current.seriesMembership, replication: replication)
            return (updated, ())
        }
    }

    public func recordGatewayAcceptance(_ mutationIDs: [String], endpointID: String) async throws {
        try await ensureRecovered()
        try SyncContractValidation.requireUUID(endpointID)
        guard !mutationIDs.isEmpty,
              mutationIDs.count <= SyncContractConstants.maxPageOperations,
              Set(mutationIDs).count == mutationIDs.count else {
            throw SyncFailure.invalidInput
        }
        for mutationID in mutationIDs {
            try SyncContractValidation.requireUUID(mutationID)
        }
        guard gatewayCursorID == endpointID else {
            throw SyncFailure.invalidInput
        }
        let configuredEndpointID = endpointID
        let authorizedReplicas = authorizedApplyingReplicaIDs
        _ = try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            var outbox = existing.outbox
            var inbox = existing.inbox
            var retiredOperationHashes = Set<String>()
            var changed = false
            for mutationID in mutationIDs {
                guard let index = outbox.firstIndex(where: { $0.operation.mutationID == mutationID }) else {
                    continue
                }
                var entry = outbox[index]
                var endpoints = entry.gatewayStoredBy
                if !endpoints.contains(configuredEndpointID) {
                    guard endpoints.count < SyncContractConstants.maxMembers else {
                        throw SyncFailure.capacity
                    }
                    endpoints.append(configuredEndpointID)
                    endpoints.sort()
                }
                let entryAcknowledgements = try Self.deduplicatedAcknowledgements(entry.acknowledgements)
                let terminal = entryAcknowledgements.first { acknowledgement in
                    acknowledgement.replicaID != existing.localOriginID
                        && authorizedReplicas.contains(acknowledgement.replicaID)
                        && (acknowledgement.level == .applied || acknowledgement.level == .retainedConflict)
                }
                if terminal != nil {
                    retiredOperationHashes.insert(try SyncWireCodec.operationHash(for: entry.operation))
                    outbox.remove(at: index)
                    if !inbox.contains(where: { $0.mutationID == entry.operation.mutationID }) {
                        guard inbox.count < CalendarStoreEnvelope.maximumLedgerEntries else {
                            throw SyncFailure.capacity
                        }
                        inbox.append(entry.operation)
                    }
                } else {
                    entry = SyncOutboxEntry(
                        schemaVersion: entry.schemaVersion,
                        operation: entry.operation,
                        state: .awaitingAcks,
                        attempts: entry.attempts,
                        lastError: entry.lastError,
                        acknowledgements: entryAcknowledgements,
                        gatewayStoredBy: endpoints
                    )
                    outbox[index] = entry
                }
                changed = true
            }
            guard changed else { return (current, ()) }
            let receivedAcknowledgements = existing.receivedAcknowledgements.filter {
                !retiredOperationHashes.contains($0.operationHash)
            }
            let replication = Self.replacing(
                existing,
                outbox: outbox,
                inbox: inbox,
                receivedAcknowledgements: receivedAcknowledgements
            )
            let updated = try CalendarStoreEnvelope(
                snapshot: current.snapshot,
                seriesMembership: current.seriesMembership,
                replication: replication
            )
            return (updated, ())
        }
    }

    public func acknowledgePageDelivered(_ acknowledgements: [SyncAck]) async throws {
        try await ensureRecovered()
        guard acknowledgements.count <= SyncContractConstants.maxPageOperations else {
            throw SyncFailure.capacity
        }
        for acknowledgement in acknowledgements {
            try SyncWireCodec.validate(acknowledgement)
        }
        guard acknowledgements.allSatisfy({ acknowledgement in
            acknowledgement.datasetID == datasetID
                && acknowledgement.epoch == epoch
                && acknowledgement.storeID == storeID
                && acknowledgement.replicaID == originID
        }) else {
            throw SyncFailure.invalidInput
        }
        guard !acknowledgements.isEmpty else { return }
        _ = try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            let remaining = existing.acknowledgements.filter { !acknowledgements.contains($0) }
            guard remaining.count != existing.acknowledgements.count else {
                return (current, ())
            }
            let replication = Self.replacing(existing, acknowledgements: remaining)
            let updated = try CalendarStoreEnvelope(
                snapshot: current.snapshot,
                seriesMembership: current.seriesMembership,
                replication: replication
            )
            return (updated, ())
        }
    }

    public func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt {
        try await ensureRecovered()
        try SyncWireCodec.validate(frontier)
        let configuredStoreID = storeID
        let configuredOriginID = originID
        let configuredGatewayCursorID = gatewayCursorID
        return try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            for position in frontier.positions where position.stream.storeID != configuredStoreID {
                throw SyncFailure.invalidInput
            }
            guard frontier.positions.allSatisfy({ $0.stream.originID != Self.pageCursorOriginID }) else {
                throw SyncFailure.invalidInput
            }
            let received = try Self.filteredCheckpointFrontier(
                requested: frontier,
                existing: existing.received,
                envelope: existing,
                localOriginID: configuredOriginID,
                storeID: configuredStoreID,
                gatewayCursorID: configuredGatewayCursorID
            )
            let applied = try Self.filteredCheckpointFrontier(
                requested: frontier,
                existing: existing.applied,
                envelope: existing,
                localOriginID: configuredOriginID,
                storeID: configuredStoreID,
                gatewayCursorID: configuredGatewayCursorID
            )
            let (compacted, removedOperations) = try Self.compactCoveredLedger(
                existing,
                received: received,
                applied: applied
            )
            let replication = Self.replacing(compacted, received: received, applied: applied)
            let canonical = try SyncWireCodec.canonicalJSON(received, maximumBytes: SyncContractConstants.maxBodyBytes)
            let hash = try SyncWireCodec.hash(domain: "LifeOS/calendar-checkpoint/v1", canonical: canonical)
            let receipt = SyncCheckpointReceipt(
                schemaVersion: SyncContractConstants.schemaVersion,
                checkpointHash: hash,
                storeID: configuredStoreID,
                covered: received,
                removedOperations: removedOperations
            )
            let updated = try CalendarStoreEnvelope(snapshot: current.snapshot, seriesMembership: current.seriesMembership, replication: replication)
            return (updated, receipt)
        }
    }

    private func ensureRecovered() async throws {
        if !recovered { try await recover() }
    }

    private static func emptyEnvelope(
        storeID: String,
        datasetID: String,
        originID: String,
        epoch: String
    ) -> SyncAdapterEnvelope {
        SyncAdapterEnvelope(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: storeID,
            datasetID: datasetID,
            localOriginID: originID,
            epoch: epoch,
            nextSequence: "1",
            received: SyncFrontier(positions: []),
            applied: SyncFrontier(positions: []),
            outbox: [],
            inbox: [],
            entities: [],
            conflicts: [],
            acknowledgements: [],
            receivedAcknowledgements: [],
            receipts: []
        )
    }

    private static func validateLocalIdentity(_ envelope: SyncAdapterEnvelope, device: SyncDeviceIdentity) throws {
        let operations = envelope.inbox + envelope.outbox.map(\.operation) + envelope.conflicts.flatMap(\.branches)
        for operation in operations where operation.originID == device.deviceID {
            guard operation.keyID == device.keyID else { throw SyncFailure.corruptStore }
        }
    }

    private static func validateCalendarLedger(_ envelope: SyncAdapterEnvelope) throws {
        try SyncWireCodec.validate(envelope.received)
        try SyncWireCodec.validate(envelope.applied)
        let operations = envelope.inbox
            + envelope.outbox.map(\.operation)
            + envelope.conflicts.flatMap(\.branches)
        for operation in operations {
            guard operation.domain == .calendar,
                  operation.kind == .put || operation.kind == .bootstrap,
                  operation.payload.blobHash == nil,
                  let inline = operation.payload.inline else {
                throw SyncFailure.corruptStore
            }
            let bytes = try CalendarSyncBase64URL.decode(inline)
            guard bytes.count == operation.payload.byteCount,
                  SyncWireCodec.sha256(bytes) == operation.payload.hash else {
                throw SyncFailure.corruptStore
            }
            let payload = try CalendarPayloadCodec.decode(bytes)
            guard Self.entityID(for: payload.seriesID) == operation.entityID else {
                throw SyncFailure.corruptStore
            }
        }
        let mutationIDs = Set(operations.map(\.mutationID))
        for entity in envelope.entities {
            guard entity.heads.allSatisfy({ mutationIDs.contains($0) }) else {
                throw SyncFailure.corruptStore
            }
        }
    }

    private static func validateReceiptHashes(_ envelope: SyncAdapterEnvelope) throws {
        for receipt in envelope.receipts {
            guard let operation = try? operation(for: receipt.operationHash, in: envelope),
                  operation.mutationID == receipt.mutationID,
                  try SyncWireCodec.operationHash(for: operation) == receipt.operationHash else {
                throw SyncFailure.corruptStore
            }
        }
    }

    private static func migratedAcknowledgements(
        in envelope: SyncAdapterEnvelope
    ) throws -> SyncAdapterEnvelope {
        let localAcknowledgements = try deduplicatedAcknowledgements(envelope.acknowledgements.filter {
            $0.replicaID == envelope.localOriginID
        })
        let legacyRemoteAcknowledgements = envelope.acknowledgements.filter {
            $0.replicaID != envelope.localOriginID
        }
        let receivedAcknowledgements = try deduplicatedAcknowledgements(
            envelope.receivedAcknowledgements + legacyRemoteAcknowledgements
        )
        guard localAcknowledgements.count <= CalendarStoreEnvelope.maximumLedgerEntries,
              receivedAcknowledgements.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
            throw SyncFailure.capacity
        }
        return replacing(
            envelope,
            acknowledgements: localAcknowledgements,
            receivedAcknowledgements: receivedAcknowledgements
        )
    }

    private static func seriesGroups(
        snapshot: CalendarSnapshot,
        links: [CalendarSeriesLink]
    ) throws -> [String: [CalendarItem]] {
        var itemsByID: [String: CalendarItem] = [:]
        for item in snapshot.items {
            let key = item.id.uuidString.lowercased()
            guard itemsByID[key] == nil else { throw SyncFailure.corruptStore }
            itemsByID[key] = item
        }
        var groups: [String: [CalendarItem]] = [:]
        for link in links {
            guard let item = itemsByID[link.itemID] else { throw SyncFailure.corruptStore }
            groups[link.seriesID, default: []].append(item)
        }
        return groups.mapValues { $0.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() } }
    }

    private static func seriesItems(
        snapshot: CalendarSnapshot,
        links: [CalendarSeriesLink],
        seriesID: String
    ) throws -> [CalendarItem] {
        let itemsByID = Dictionary(
            snapshot.items.map { ($0.id.uuidString.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [CalendarItem] = []
        for link in links where link.seriesID == seriesID {
            guard let item = itemsByID[link.itemID] else { throw SyncFailure.corruptStore }
            items.append(item)
        }
        return items.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
    }

    private static func entityID(for seriesID: String) -> String {
        SyncWireCodec.sha256(Data("calendar\u{0}\(seriesID)".utf8))
    }

    private struct PendingCursor {
        let operation: UInt64
    }

    private static func pendingCursor(
        after frontier: SyncFrontier?,
        storeID: String,
        originID: String
    ) throws -> PendingCursor {
        guard let frontier else { return PendingCursor(operation: 0) }
        var operation: UInt64 = 0
        var seen = Set<String>()
        for position in frontier.positions {
            guard position.stream.storeID == storeID else { throw SyncFailure.invalidInput }
            guard seen.insert(position.stream.originID).inserted else { throw SyncFailure.invalidInput }
            let through = try SyncContractValidation.requireUnsigned(position.through)
            if position.stream.originID == originID {
                operation = through
            } else if position.stream.originID == pageCursorOriginID {
                // Older cursors carried an in-memory ACK offset. ACK pages
                // are now retired durably after transport success, so the
                // offset is deliberately ignored for source compatibility.
            } else {
                throw SyncFailure.invalidInput
            }
        }
        return PendingCursor(operation: operation)
    }

    private static func pageCursor(
        storeID: String,
        originID: String,
        operationThrough: UInt64
    ) -> SyncFrontier {
        SyncFrontier(positions: [
            SyncPosition(
                stream: SyncStream(storeID: storeID, originID: originID),
                through: String(operationThrough)
            )
        ])
    }

    private static func filteredCheckpointFrontier(
        requested: SyncFrontier,
        existing: SyncFrontier,
        envelope: SyncAdapterEnvelope,
        localOriginID: String,
        storeID: String,
        gatewayCursorID: String?
    ) throws -> SyncFrontier {
        let operationOrigins = Set(ledgerOperations(in: envelope).map(\.originID))
        var deviceOrigins = operationOrigins.union([localOriginID])
        deviceOrigins.formUnion(envelope.received.positions.map { $0.stream.originID })
        deviceOrigins.formUnion(envelope.applied.positions.map { $0.stream.originID })
        for position in requested.positions {
            let requestedOrigin = position.stream.originID
            if requestedOrigin == gatewayCursorID {
                continue
            }
            guard deviceOrigins.contains(requestedOrigin) else {
                throw SyncFailure.invalidInput
            }
        }
        for position in existing.positions {
            let existingOrigin = position.stream.originID
            guard existingOrigin == gatewayCursorID || deviceOrigins.contains(existingOrigin) else {
                throw SyncFailure.corruptStore
            }
        }
        let currentPositions = Dictionary(
            existing.positions
                .filter { $0.stream.originID != gatewayCursorID }
                .map { ($0.stream.originID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let requestedPositions = Dictionary(
            requested.positions
                .filter { $0.stream.originID != gatewayCursorID }
                .map { ($0.stream.originID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let origins = Set(currentPositions.keys).union(requestedPositions.keys).sorted()
        var positions: [SyncPosition] = []
        positions.reserveCapacity(origins.count)
        for originID in origins {
            let current = try currentPositions[originID].map {
                try SyncContractValidation.requireUnsigned($0.through)
            } ?? 0
            let target = try requestedPositions[originID].map {
                try SyncContractValidation.requireUnsigned($0.through)
            } ?? current
            guard target >= current else { throw SyncFailure.staleTarget }
            let durable = durableSequence(for: originID, in: envelope)
            guard target <= durable else { throw SyncFailure.staleTarget }
            positions.append(SyncPosition(
                stream: SyncStream(storeID: storeID, originID: originID),
                through: String(target)
            ))
        }
        let result = SyncFrontier(positions: positions)
        try SyncWireCodec.validate(result)
        return result
    }

    private static func deduplicatedAcknowledgements(_ values: [SyncAck]) throws -> [SyncAck] {
        var result: [SyncAck] = []
        for value in values {
            result = try replacingWithStrongestAcknowledgement(value, in: result)
        }
        return result
    }

    private static func acknowledgementIdentityKey(_ value: SyncAck) -> String {
        value.operationHash + "\u{0}" + value.mutationID + "\u{0}" + value.replicaID
    }

    private static func acknowledgementStrength(_ value: SyncAckLevel) -> Int {
        switch value {
        case .stored: return 0
        case .applied, .retainedConflict: return 1
        }
    }

    private static func replacingWithStrongestAcknowledgement(
        _ value: SyncAck,
        in values: [SyncAck]
    ) throws -> [SyncAck] {
        let key = acknowledgementIdentityKey(value)
        guard let index = values.firstIndex(where: { acknowledgementIdentityKey($0) == key }) else {
            var result = values
            result.append(value)
            guard result.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
                throw SyncFailure.capacity
            }
            return result
        }
        var result = values
        let current = result[index]
        let currentStrength = acknowledgementStrength(current.level)
        let newStrength = acknowledgementStrength(value.level)
        if currentStrength == newStrength {
            guard current == value else { throw SyncFailure.receiptIdentityConflict }
        } else if newStrength > currentStrength {
            result[index] = value
        }
        return result
    }

    private static func frontierThrough(_ originID: String, in frontier: SyncFrontier) -> UInt64 {
        frontier.positions
            .filter { $0.stream.originID == originID }
            .compactMap { UInt64($0.through) }
            .max() ?? 0
    }

    private static func isCoveredByFrontier(
        _ operation: SyncOperation,
        frontier: SyncFrontier
    ) -> Bool {
        guard let sequence = UInt64(operation.sequence) else { return false }
        return sequence <= frontierThrough(operation.originID, in: frontier)
    }

    private static func compactCoveredLedger(
        _ envelope: SyncAdapterEnvelope,
        received: SyncFrontier,
        applied: SyncFrontier
    ) throws -> (SyncAdapterEnvelope, Int) {
        let receivedThrough = Dictionary(
            received.positions.map { ($0.stream.originID, UInt64($0.through) ?? 0) },
            uniquingKeysWith: max
        )
        let appliedThrough = Dictionary(
            applied.positions.map { ($0.stream.originID, UInt64($0.through) ?? 0) },
            uniquingKeysWith: max
        )
        func covered(_ operation: SyncOperation) -> Bool {
            guard let sequence = UInt64(operation.sequence),
                  let receivedValue = receivedThrough[operation.originID],
                  let appliedValue = appliedThrough[operation.originID] else { return false }
            return sequence <= receivedValue && sequence <= appliedValue
        }

        var mustKeep = Set(envelope.outbox.map { $0.operation.mutationID })
        mustKeep.formUnion(envelope.conflicts.flatMap { $0.branches.map(\.mutationID) })
        mustKeep.formUnion(envelope.entities.flatMap(\.heads))
        mustKeep.formUnion(envelope.acknowledgements.map(\.mutationID))
        mustKeep.formUnion(
            envelope.receipts
                .filter { $0.disposition == .ambiguous }
                .map(\.mutationID)
        )
        mustKeep.formUnion(
            envelope.inbox
                .filter { !covered($0) }
                .map(\.mutationID)
        )

        let keptInbox = envelope.inbox.filter { !covered($0) || mustKeep.contains($0.mutationID) }
        let removedHashes = Set(
            envelope.inbox
                .filter { !keptInbox.contains($0) }
                .compactMap { try? SyncWireCodec.operationHash(for: $0) }
        )
        guard !removedHashes.isEmpty else {
            return (replacing(
                envelope,
                acknowledgements: try deduplicatedAcknowledgements(envelope.acknowledgements),
                receivedAcknowledgements: try deduplicatedAcknowledgements(envelope.receivedAcknowledgements)
            ), 0)
        }
        let candidate = replacing(envelope, inbox: keptInbox)
        let retainedHashes = Set(
            ledgerOperations(in: candidate)
                .compactMap { try? SyncWireCodec.operationHash(for: $0) }
        )
        let receipts = envelope.receipts.filter { retainedHashes.contains($0.operationHash) }
        let receivedAcknowledgements = try deduplicatedAcknowledgements(
            envelope.receivedAcknowledgements.filter { retainedHashes.contains($0.operationHash) }
        )
        let acknowledgements = try deduplicatedAcknowledgements(envelope.acknowledgements)
        return (
            replacing(
                candidate,
                acknowledgements: acknowledgements,
                receivedAcknowledgements: receivedAcknowledgements,
                receipts: receipts
            ),
            removedHashes.count
        )
    }

    private static func knownOperation(hash: String, in envelope: SyncAdapterEnvelope) -> SyncOperation? {
        if let value = ledgerOperations(in: envelope).first(where: { operation in
            guard let value = try? SyncWireCodec.operationHash(for: operation) else { return false }
            return value == hash
        }) { return value }
        return nil
    }

    private static func appendingReceipt(
        _ receipt: SyncOperationReceipt,
        to existing: [SyncOperationReceipt]
    ) throws -> [SyncOperationReceipt] {
        guard !existing.contains(where: { $0.operationHash == receipt.operationHash }) else {
            throw SyncFailure.corruptStore
        }
        var updated = existing
        updated.append(receipt)
        guard updated.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
            throw SyncFailure.capacity
        }
        return updated
    }

    private static func migratedReceipts(
        in envelope: SyncAdapterEnvelope,
        device: SyncDeviceIdentity
    ) throws -> SyncAdapterEnvelope {
        // The pre-receipt format stored operations and conflict branches but
        // not their application outcome. Only a verified local ACK is strong
        // enough to recover that outcome. Everything else is explicitly
        // ambiguous and therefore replay-blocking.
        let candidates = envelope.inbox + envelope.conflicts.flatMap(\.branches)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(syncBase64URL: device.publicKey))
        var seen = Set<String>()
        var receipts: [SyncOperationReceipt] = []
        receipts.reserveCapacity(candidates.count)
        for operation in candidates {
            let operationHash = try SyncWireCodec.operationHash(for: operation)
            guard seen.insert(operationHash).inserted else { continue }
            let evidence = (envelope.acknowledgements + envelope.outbox.flatMap(\.acknowledgements))
                .first { acknowledgement in
                    guard acknowledgement.replicaID == device.deviceID,
                          acknowledgement.keyID == device.keyID,
                          acknowledgement.operationHash == operationHash,
                          acknowledgement.mutationID == operation.mutationID else {
                        return false
                    }
                    return (try? SyncWireCodec.verifyAcknowledgement(acknowledgement, publicKey: publicKey)) != nil
                }
            let disposition: SyncDisposition
            let entityVersion: String
            switch evidence?.level {
            case .applied:
                disposition = .applied
                entityVersion = evidence?.resultHash ?? operation.payload.hash
            case .retainedConflict:
                disposition = .retainedConflict
                entityVersion = evidence?.resultHash ?? operation.payload.hash
            default:
                disposition = .ambiguous
                entityVersion = operation.payload.hash
            }
            receipts.append(SyncOperationReceipt(
                operationHash: operationHash,
                mutationID: operation.mutationID,
                entityVersion: entityVersion,
                disposition: disposition
            ))
        }
        receipts.sort { $0.operationHash < $1.operationHash }
        guard receipts.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
            throw SyncFailure.capacity
        }
        return replacing(envelope, receipts: receipts, receiptLedgerVersion: 1)
    }

    private static func operation(for hash: String, in envelope: SyncAdapterEnvelope) throws -> SyncOperation {
        if let value = ledgerOperations(in: envelope).first(where: { operation in
            guard let value = try? SyncWireCodec.operationHash(for: operation) else { return false }
            return value == hash
        }) { return value }
        throw SyncFailure.operationUnknown
    }

    private static func ledgerOperations(in envelope: SyncAdapterEnvelope) -> [SyncOperation] {
        envelope.inbox
            + envelope.outbox.map(\.operation)
            + envelope.conflicts.flatMap(\.branches)
    }

    private static func retainedConflict(
        current: CalendarStoreEnvelope,
        existing: SyncAdapterEnvelope,
        operation: SyncOperation,
        operationHash: String,
        entityVersion: String,
        reason: String,
        additionalBranches: [SyncOperation] = []
    ) throws -> (CalendarStoreEnvelope, SyncCommitReceipt) {
        var inbox = existing.inbox
        inbox.append(operation)
        var branchesByMutation: [String: SyncOperation] = [:]
        for branch in additionalBranches + [operation] {
            branchesByMutation[branch.mutationID] = branch
        }
        var conflicts = existing.conflicts
        conflicts.append(SyncConflict(
            schemaVersion: SyncContractConstants.schemaVersion,
            conflictID: UUID().uuidString.lowercased(),
            storeID: existing.storeID,
            entityID: operation.entityID,
            branches: branchesByMutation.values.sorted { lhs, rhs in
                lhs.mutationID < rhs.mutationID
            },
            reason: reason,
            resolutionID: nil
        ))
        guard inbox.count <= CalendarStoreEnvelope.maximumLedgerEntries,
              conflicts.count <= CalendarStoreEnvelope.maximumLedgerEntries else {
            throw SyncFailure.capacity
        }
        let receipt = SyncOperationReceipt(
            operationHash: operationHash,
            mutationID: operation.mutationID,
            entityVersion: entityVersion,
            disposition: .retainedConflict
        )
        let replication = replacing(
            existing,
            inbox: inbox,
            conflicts: conflicts,
            receipts: try appendingReceipt(receipt, to: existing.receipts)
        )
        let updated = try CalendarStoreEnvelope(
            snapshot: current.snapshot,
            seriesMembership: current.seriesMembership,
            replication: replication
        )
        let commitReceipt = SyncCommitReceipt(
            schemaVersion: SyncContractConstants.schemaVersion,
            mutationID: operation.mutationID,
            operationHash: operationHash,
            entityVersion: entityVersion,
            disposition: .retainedConflict
        )
        return (updated, commitReceipt)
    }

    private static func replacing(
        _ current: SyncAdapterEnvelope,
        received: SyncFrontier? = nil,
        applied: SyncFrontier? = nil,
        outbox: [SyncOutboxEntry]? = nil,
        inbox: [SyncOperation]? = nil,
        entities: [SyncEntityVersion]? = nil,
        conflicts: [SyncConflict]? = nil,
        acknowledgements: [SyncAck]? = nil,
        receivedAcknowledgements: [SyncAck]? = nil,
        receipts: [SyncOperationReceipt]? = nil,
        receiptLedgerVersion: Int? = nil
    ) -> SyncAdapterEnvelope {
        SyncAdapterEnvelope(
            schemaVersion: current.schemaVersion,
            storeID: current.storeID,
            datasetID: current.datasetID,
            localOriginID: current.localOriginID,
            epoch: current.epoch,
            nextSequence: current.nextSequence,
            received: received ?? current.received,
            applied: applied ?? current.applied,
            outbox: outbox ?? current.outbox,
            inbox: inbox ?? current.inbox,
            entities: entities ?? current.entities,
            conflicts: conflicts ?? current.conflicts,
            acknowledgements: acknowledgements ?? current.acknowledgements,
            receivedAcknowledgements: receivedAcknowledgements ?? current.receivedAcknowledgements,
            receipts: receipts ?? current.receipts,
            receiptLedgerVersion: receiptLedgerVersion ?? current.receiptLedgerVersion
        )
    }

    private static func durableSequence(for originID: String, in envelope: SyncAdapterEnvelope) -> UInt64 {
        let sequences = Set(
            ledgerOperations(in: envelope)
                .filter { $0.originID == originID }
                .compactMap { UInt64($0.sequence) }
        )
        var contiguous = max(
            frontierThrough(originID, in: envelope.received),
            frontierThrough(originID, in: envelope.applied)
        )
        while contiguous < UInt64.max, sequences.contains(contiguous + 1) {
            contiguous += 1
        }
        return contiguous
    }
}

private enum CalendarSyncBase64URL {
    static func encode(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        try SyncContractValidation.requireBase64URL(value)
    }
}
