import Foundation
@testable import LifeOSMac

enum FinanceRecurringTestFixtureError: Error {
    case invalidDate
    case invalidUUID
}

enum FinanceRecurringTestFixtures {
    static let accountID = UUID(uuidString: "00000000-0000-4000-8000-000000000401")!

    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 9,
        timeZoneIdentifier: String = FinanceRecurringPaymentContract.defaultTimeZoneIdentifier
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw FinanceRecurringTestFixtureError.invalidDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) else {
            throw FinanceRecurringTestFixtureError.invalidDate
        }
        return date
    }

    static func transaction(
        id: UUID = UUID(),
        date: Date,
        amountCents: Int = -1_299,
        description: String = "Streaming Provider",
        accountID: UUID = accountID,
        identityScheme: FinanceImportedIdentityScheme = .mappedV3,
        hasMappedIdentity: Bool = true,
        category: String? = nil,
        sourceCategory: String? = nil,
        kind: FinanceImportedTransactionKind = .cash,
        investment: FinanceImportedInvestmentDetails? = nil
    ) throws -> FinanceImportedTransaction {
        let mappedIdentity: FinanceImportedMappedIdentity?
        if identityScheme == .mappedV3 && hasMappedIdentity {
            mappedIdentity = try FinanceImportedMappedIdentity(
                accountID: accountID,
                configurationDigest: String(repeating: "a", count: 64)
            )
        } else {
            mappedIdentity = nil
        }
        return FinanceImportedTransaction(
            id: id,
            bookedAt: date,
            amountCents: amountCents,
            description: description,
            category: category,
            source: .genericCSV,
            identityScheme: identityScheme,
            mappedIdentity: mappedIdentity,
            importedAt: date,
            sourceCategory: sourceCategory,
            kind: kind,
            investment: investment
        )
    }

    static func batch(
        for transactions: [FinanceImportedTransaction],
        id: UUID = UUID()
    ) throws -> FinanceImportBatchProvenance {
        let links = try transactions.enumerated().map { index, transaction in
            try FinanceImportRowProvenance(
                batchID: id,
                sourceRowNumber: index + 2,
                transactionID: transaction.id
            )
        }
        return try FinanceImportBatchProvenance(
            id: id,
            importedAt: try date(2026, 5, 1),
            sourceDigest: String(repeating: "b", count: 64),
            byteCount: 1,
            headerFingerprint: String(repeating: "c", count: 64),
            delimiter: .comma,
            headerRecordIndex: 0,
            mappingID: UUID(),
            originalDetection: .unknown,
            effectiveDetection: FinanceInstitutionDetection(state: .userMapped),
            rowLinks: links
        )
    }

    static func temporaryURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-recurring-\(label)-\(UUID().uuidString)", isDirectory: false)
    }
}
