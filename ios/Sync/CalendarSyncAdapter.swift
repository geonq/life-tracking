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
