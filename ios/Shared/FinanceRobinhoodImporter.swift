import Foundation

// MARK: - Evidence-bound Robinhood activity CSV importer

public enum FinanceRobinhoodImportError: Error, Equatable, Sendable {
    case inputTooLarge
    case invalidUTF8
    case emptyInput
    case malformedCSV
    case unsupportedSchema
    case missingAccountIdentity
    case invalidObservedAt
    case tooManyRows
    case invalidRow(Int)
    case unsupportedActivityType(Int, String)
    case unsupportedCurrency(Int, String)
    case duplicateActivityIdentity
}

extension FinanceRobinhoodImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inputTooLarge: return "The Robinhood export exceeds the safe import limit."
        case .invalidUTF8: return "The Robinhood export is not valid UTF-8."
        case .emptyInput: return "The Robinhood export is empty."
        case .malformedCSV: return "The Robinhood export contains malformed CSV."
        case .unsupportedSchema: return "This Robinhood export schema is not verified."
        case .missingAccountIdentity: return "An explicit Robinhood account identity is required."
        case .invalidObservedAt: return "The import observation time is invalid."
        case .tooManyRows: return "The Robinhood export contains too many rows."
        case .invalidRow(let row): return "Robinhood row \(row) is invalid."
        case .unsupportedActivityType(let row, let type):
            return "Robinhood activity type \(type) on row \(row) is not verified."
        case .unsupportedCurrency(let row, let value):
            return "Robinhood currency \(value) on row \(row) is not verified."
        case .duplicateActivityIdentity: return "The Robinhood export contains ambiguous duplicate activities."
        }
    }
}

public struct FinanceRobinhoodImportResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidence: FinanceInvestmentImportEvidence
    public let activities: [FinanceInvestmentActivity]
    public let coverage: FinanceInvestmentDataCoverage
    public let productionGate: FinanceInvestmentProductionGate

    public init(
        evidence: FinanceInvestmentImportEvidence,
        activities: [FinanceInvestmentActivity]
    ) throws {
        try Self.validate(
            schemaVersion: FinanceInvestmentContract.schemaVersion,
            evidence: evidence,
            activities: activities
        )
        self.schemaVersion = FinanceInvestmentContract.schemaVersion
        self.evidence = evidence
        self.activities = activities.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.id < $1.id
        }
        self.coverage = .activitiesOnly
        self.productionGate = .blockedMissingAccountSnapshotAndValuationEvidence
    }

    private static func validate(
        schemaVersion: Int,
        evidence: FinanceInvestmentImportEvidence,
        activities: [FinanceInvestmentActivity]
    ) throws {
        for activity in activities {
            try FinanceRobinhoodImporter.validateDecodedActivity(activity)
        }
        let activityIDs = activities.map(\.id)
        let rowNumbers = activities.map(\.sourceRowNumber)
        guard schemaVersion == FinanceInvestmentContract.schemaVersion,
              evidence.source.schemaVersion == FinanceInvestmentContract.schemaVersion,
              evidence.headerFingerprint == FinanceInvestmentContract.robinhoodActivityHeaderFingerprint,
              !activities.isEmpty,
              activities.count <= FinanceInvestmentContract.maximumActivityCount,
              evidence.dataRowCount == activities.count,
              !evidence.dataRowCount.addingReportingOverflow(evidence.blankRowsSkipped).overflow,
              evidence.dataRowCount + evidence.blankRowsSkipped <= FinanceInvestmentContract.maximumRows,
              activities.allSatisfy({ $0.source == evidence.source }),
              activityIDs.allSatisfy(FinanceInvestmentHash.isSHA256),
              Set(activityIDs).count == activityIDs.count,
              rowNumbers.allSatisfy({ $0 >= 2 && $0 <= FinanceInvestmentContract.maximumRows + 1 }),
              Set(rowNumbers).count == rowNumbers.count else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, evidence, activities, coverage, productionGate
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases),
              try container.decode(FinanceInvestmentDataCoverage.self, forKey: .coverage) == .activitiesOnly,
              try container.decode(FinanceInvestmentProductionGate.self, forKey: .productionGate)
                    == .blockedMissingAccountSnapshotAndValuationEvidence else {
            throw FinanceInvestmentValidationError.unsupportedVersion
        }
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let evidence = try container.decode(FinanceInvestmentImportEvidence.self, forKey: .evidence)
        let activities = try container.decode([FinanceInvestmentActivity].self, forKey: .activities)
        try Self.validate(schemaVersion: schemaVersion, evidence: evidence, activities: activities)
        self.schemaVersion = schemaVersion
        self.evidence = evidence
        self.activities = activities.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.id < $1.id
        }
        self.coverage = .activitiesOnly
        self.productionGate = .blockedMissingAccountSnapshotAndValuationEvidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(activities, forKey: .activities)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(productionGate, forKey: .productionGate)
    }
}

public enum FinanceRobinhoodImporter {
    private struct CSVRow {
        let values: [String]
        let sourceRowNumber: Int
    }

    private static let transactionKinds: [String: FinanceInvestmentActivityKind] = [
        "Crypto Deposit": .deposit,
        "Crypto Purchase": .buy,
        // The local evidence calls this a reward, but does not establish
        // dividend or interest semantics. Keep it auditable and unvalued.
        "Crypto Reward": .unknown,
        "Crypto Sale": .sell,
        "SEPA Deposit": .deposit,
        "Staking Earnings": .interest
    ]

    /// Revalidates the importer contract after Codable has reconstructed an
    /// activity. The generic activity initializer protects the data shape;
    /// this check protects the verified Robinhood schema and semantic ID.
    static func validateDecodedActivity(_ activity: FinanceInvestmentActivity) throws {
        guard activity.source.provider == .robinhood,
              activity.source.schemaVersion == FinanceInvestmentContract.schemaVersion,
              let expectedKind = transactionKinds[activity.rawTransactionType],
              expectedKind == activity.kind,
              let canonicalDate = canonicalActivityDate(activity.observedAt),
              parseDate(canonicalDate) == activity.observedAt else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
        let requiresInstrumentValues = activity.rawTransactionType != "SEPA Deposit"
        guard !requiresInstrumentValues || (activity.quantity != nil && activity.instrumentPrice != nil),
              activity.quantity.map({ $0.decimalValue > .zero }) ?? true,
              activity.instrumentPrice.map({ $0.amount.decimalValue > .zero }) ?? true else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
        let monies = [activity.instrumentPrice, activity.fees, activity.debit, activity.credit].compactMap { $0 }
        guard monies.allSatisfy({
                  $0.currency == "EUR" && $0.amount.decimalValue >= .zero
              }) else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
        let expectsDebit = activity.rawTransactionType == "Crypto Purchase"
        guard expectsDebit
            ? activity.debit != nil && activity.credit == nil
            : activity.credit != nil && activity.debit == nil else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
        let expectedID = semanticActivityID(
            source: activity.source,
            observedAt: canonicalDate,
            kind: activity.kind,
            rawTransactionType: activity.rawTransactionType,
            instrument: activity.instrument,
            quantity: activity.quantity,
            instrumentPrice: activity.instrumentPrice,
            fees: activity.fees,
            debit: activity.debit,
            credit: activity.credit
        )
        guard activity.id == expectedID else {
            throw FinanceInvestmentValidationError.invalidActivity
        }
    }

    /// Imports only the exact header layout observed in the local export.
    /// The caller must provide the account identity because the file does not.
    public static func importCSV(
        _ data: Data,
        accountID: String,
        observedAt: Date
    ) throws -> FinanceRobinhoodImportResult {
        guard data.count <= FinanceInvestmentContract.maximumImportBytes else {
            throw FinanceRobinhoodImportError.inputTooLarge
        }
        guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceRobinhoodImportError.invalidObservedAt
        }
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { throw FinanceRobinhoodImportError.missingAccountIdentity }

        let rows = try parseRows(data)
        guard let header = rows.first else { throw FinanceRobinhoodImportError.emptyInput }
        guard header.values == FinanceInvestmentContract.robinhoodActivityCSVHeader else {
            throw FinanceRobinhoodImportError.unsupportedSchema
        }
        let source: FinanceInvestmentSourceIdentity
        do {
            source = try FinanceInvestmentSourceIdentity(accountID: account)
        } catch {
            throw FinanceRobinhoodImportError.missingAccountIdentity
        }

        var activities: [FinanceInvestmentActivity] = []
        activities.reserveCapacity(min(rows.count - 1, FinanceInvestmentContract.maximumRows))
        var blankRowsSkipped = 0

        let dataRows = Array(rows.dropFirst())
        var seenActivityIDs: Set<String> = []
        seenActivityIDs.reserveCapacity(min(dataRows.count, FinanceInvestmentContract.maximumRows))

        for (index, row) in dataRows.enumerated() {
            if row.values.isEmpty {
                blankRowsSkipped += 1
                continue
            }
            if isFooter(row.values) {
                guard index == dataRows.index(before: dataRows.endIndex) else {
                    throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
                }
                // The footer is schema metadata only. Its text is deliberately
                // never copied into an activity, evidence field, or log.
                continue
            }

            guard activities.count < FinanceInvestmentContract.maximumRows else {
                throw FinanceRobinhoodImportError.tooManyRows
            }
            guard row.values.count == FinanceInvestmentContract.robinhoodActivityCSVHeader.count,
                  row.values.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
                throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
            }

            let activity = try makeActivity(row: row, source: source)
            guard seenActivityIDs.insert(activity.id).inserted else {
                throw FinanceRobinhoodImportError.duplicateActivityIdentity
            }
            activities.append(activity)
        }

        guard !activities.isEmpty else { throw FinanceRobinhoodImportError.emptyInput }
        let evidence = try FinanceInvestmentImportEvidence(
            source: source,
            fileSHA256: FinanceInvestmentHash.sha256(data),
            byteCount: data.count,
            headerFingerprint: FinanceInvestmentContract.robinhoodActivityHeaderFingerprint,
            observedAt: observedAt,
            dataRowCount: activities.count,
            blankRowsSkipped: blankRowsSkipped
        )
        return try FinanceRobinhoodImportResult(evidence: evidence, activities: activities)
    }

    private static func makeActivity(
        row: CSVRow,
        source: FinanceInvestmentSourceIdentity
    ) throws -> FinanceInvestmentActivity {
        guard row.values.count == FinanceInvestmentContract.robinhoodActivityCSVHeader.count else {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }
        let values = row.values
        let rawDate = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let observedAt = parseDate(rawDate) else {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }
        let rawType = values[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = transactionKinds[rawType] else {
            throw FinanceRobinhoodImportError.unsupportedActivityType(row.sourceRowNumber, rawType)
        }
        let instrument = values[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instrument.isEmpty,
              instrument.utf8.count <= FinanceInvestmentContract.maximumInstrumentBytes else {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }

        let quantity = try parseDecimal(values[3], row: row.sourceRowNumber, required: rawType != "SEPA Deposit")
        let instrumentPrice = try parseMoney(values[4], row: row.sourceRowNumber, required: rawType != "SEPA Deposit")
        let fees = try parseMoney(values[5], row: row.sourceRowNumber, required: false)
        let debit = try parseMoney(values[6], row: row.sourceRowNumber, required: false)
        let credit = try parseMoney(values[7], row: row.sourceRowNumber, required: false)
        guard !(debit != nil && credit != nil), debit != nil || credit != nil else {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }

        let expectsDebit = rawType == "Crypto Purchase"
        guard expectsDebit ? debit != nil && credit == nil : credit != nil && debit == nil else {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }
        if let quantity {
            guard quantity.decimalValue > .zero else {
                throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
            }
        }
        if let instrumentPrice {
            guard instrumentPrice.amount.decimalValue > .zero else {
                throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
            }
        }
        let nonNegativeMonies = [fees, debit, credit].compactMap { $0 }
        guard nonNegativeMonies.allSatisfy({ $0.amount.decimalValue >= .zero }) else {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }
        let monies = [instrumentPrice, fees, debit, credit].compactMap { $0 }
        guard monies.allSatisfy({ $0.currency == "EUR" }) else {
            let currency = monies.first(where: { $0.currency != "EUR" })?.currency ?? "unknown"
            throw FinanceRobinhoodImportError.unsupportedCurrency(row.sourceRowNumber, currency)
        }
        let id = semanticActivityID(
            source: source,
            observedAt: rawDate,
            kind: kind,
            rawTransactionType: rawType,
            instrument: instrument,
            quantity: quantity,
            instrumentPrice: instrumentPrice,
            fees: fees,
            debit: debit,
            credit: credit
        )
        do {
            let activity = try FinanceInvestmentActivity(
                id: id,
                source: source,
                observedAt: observedAt,
                kind: kind,
                rawTransactionType: rawType,
                instrument: instrument,
                quantity: quantity,
                instrumentPrice: instrumentPrice,
                fees: fees,
                debit: debit,
                credit: credit,
                sourceRowNumber: row.sourceRowNumber
            )
            try validateDecodedActivity(activity)
            return activity
        } catch {
            throw FinanceRobinhoodImportError.invalidRow(row.sourceRowNumber)
        }
    }

    private static func canonicalActivityDate(_ date: Date) -> String? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let reconstructed = calendar.date(from: DateComponents(
                  calendar: calendar,
                  timeZone: calendar.timeZone,
                  year: year,
                  month: month,
                  day: day
              )),
              reconstructed == date else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parseDate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (byte >= 48 && byte <= 57)
              }) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = Int(value.prefix(4))
        components.month = Int(value.dropFirst(5).prefix(2))
        components.day = Int(value.dropFirst(8).prefix(2))
        guard let date = components.calendar?.date(from: components) else {
            return nil
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == components.year,
              roundTrip.month == components.month,
              roundTrip.day == components.day else {
            return nil
        }
        return date
    }

    private static func parseDecimal(
        _ value: String,
        row: Int,
        required: Bool
    ) throws -> FinanceExactDecimal? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "-" {
            guard !required else { throw FinanceRobinhoodImportError.invalidRow(row) }
            return nil
        }
        guard !trimmed.isEmpty || !required else {
            throw FinanceRobinhoodImportError.invalidRow(row)
        }
        guard !trimmed.isEmpty else { return nil }
        do { return try FinanceExactDecimal(trimmed) }
        catch { throw FinanceRobinhoodImportError.invalidRow(row) }
    }

    private static func parseMoney(
        _ value: String,
        row: Int,
        required: Bool
    ) throws -> FinanceInvestmentMoney? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "-" {
            guard !required else { throw FinanceRobinhoodImportError.invalidRow(row) }
            return nil
        }
        guard !trimmed.isEmpty || !required else {
            throw FinanceRobinhoodImportError.invalidRow(row)
        }
        guard !trimmed.isEmpty, trimmed.first == "€" else {
            if trimmed.isEmpty && !required { return nil }
            throw FinanceRobinhoodImportError.unsupportedCurrency(row, trimmed.isEmpty ? "empty" : trimmed)
        }
        let rawAmount = String(trimmed.dropFirst())
        do {
            return try FinanceInvestmentMoney(amount: rawAmount, currency: "EUR")
        } catch {
            throw FinanceRobinhoodImportError.invalidRow(row)
        }
    }

    private static func isFooter(_ values: [String]) -> Bool {
        guard values.count == FinanceInvestmentContract.robinhoodActivityCSVHeader.count,
              let footer = values.last,
              !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return values.dropLast().allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func semanticActivityID(
        source: FinanceInvestmentSourceIdentity,
        observedAt: String,
        kind: FinanceInvestmentActivityKind,
        rawTransactionType: String,
        instrument: String,
        quantity: FinanceExactDecimal?,
        instrumentPrice: FinanceInvestmentMoney?,
        fees: FinanceInvestmentMoney?,
        debit: FinanceInvestmentMoney?,
        credit: FinanceInvestmentMoney?
    ) -> String {
        let fields = [
            source.stableKey,
            observedAt,
            kind.rawValue,
            rawTransactionType,
            instrument.uppercased(),
            quantity?.canonicalValue ?? "",
            canonicalMoney(instrumentPrice),
            canonicalMoney(fees),
            canonicalMoney(debit),
            canonicalMoney(credit)
        ]
        let lengthDelimited = fields
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return FinanceInvestmentHash.sha256(lengthDelimited)
    }

    private static func canonicalMoney(_ money: FinanceInvestmentMoney?) -> String {
        guard let money else { return "" }
        return "\(money.currency):\(money.amount.canonicalValue)"
    }

    /// Small bounded CSV state machine. It accepts quoted commas and doubled
    /// quotes, rejects quote injection and inconsistent row widths, and keeps
    /// the raw field text intact until the schema-specific validators run.
    private static func parseRows(_ data: Data) throws -> [CSVRow] {
        guard !data.isEmpty else { throw FinanceRobinhoodImportError.emptyInput }
        var bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        guard !bytes.isEmpty, !bytes.contains(0) else {
            throw FinanceRobinhoodImportError.invalidUTF8
        }

        var rows: [CSVRow] = []
        var fields: [String] = []
        var fieldBytes: [UInt8] = []
        var inQuotes = false
        var closedQuote = false
        var sourceRowNumber = 1
        var index = 0

        func appendField() throws {
            guard fieldBytes.count <= FinanceInvestmentContract.maximumFieldBytes,
                  let field = String(bytes: fieldBytes, encoding: .utf8) else {
                throw FinanceRobinhoodImportError.invalidUTF8
            }
            fields.append(field)
            fieldBytes.removeAll(keepingCapacity: true)
            closedQuote = false
        }

        func finishRow() throws {
            try appendField()
            if fields.count == 1,
               fields[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(CSVRow(values: [], sourceRowNumber: sourceRowNumber))
                guard rows.count <= FinanceInvestmentContract.maximumRows + 1 else {
                    throw FinanceRobinhoodImportError.tooManyRows
                }
                fields.removeAll(keepingCapacity: true)
                sourceRowNumber += 1
                return
            }
            guard fields.count == FinanceInvestmentContract.robinhoodActivityCSVHeader.count else {
                throw FinanceRobinhoodImportError.malformedCSV
            }
            rows.append(CSVRow(values: fields, sourceRowNumber: sourceRowNumber))
            guard rows.count <= FinanceInvestmentContract.maximumRows + 1 else {
                throw FinanceRobinhoodImportError.tooManyRows
            }
            fields.removeAll(keepingCapacity: true)
            sourceRowNumber += 1
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 {
                        fieldBytes.append(34)
                        index += 2
                    } else {
                        inQuotes = false
                        closedQuote = true
                        index += 1
                    }
                } else {
                    fieldBytes.append(byte)
                    index += 1
                }
                continue
            }

            if closedQuote {
                if byte == 44 {
                    try appendField()
                    index += 1
                } else if byte == 10 || byte == 13 {
                    try finishRow()
                    if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                    index += 1
                } else {
                    throw FinanceRobinhoodImportError.malformedCSV
                }
            } else if byte == 34 && fieldBytes.isEmpty {
                inQuotes = true
                index += 1
            } else if byte == 34 {
                throw FinanceRobinhoodImportError.malformedCSV
            } else if byte == 44 {
                try appendField()
                index += 1
            } else if byte == 10 || byte == 13 {
                try finishRow()
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                index += 1
            } else {
                fieldBytes.append(byte)
                index += 1
            }
        }

        guard !inQuotes else { throw FinanceRobinhoodImportError.malformedCSV }
        if !fields.isEmpty || !fieldBytes.isEmpty {
            try finishRow()
        }
        guard !rows.isEmpty else { throw FinanceRobinhoodImportError.emptyInput }
        return rows
    }
}
