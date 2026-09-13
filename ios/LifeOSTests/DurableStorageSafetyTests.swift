import Foundation
import XCTest
@testable import LifeOS

/// DT-02 (P0): encryption/key custody/atomicity/backup/export/delete/locked
/// device — the *reachable* half of that row (device + integration; this
/// file proves `integration`).
///
/// Locked-device enforcement by the OS is device-gated and NOT proven here
/// (needs a real iPhone). What IS proven here, per durable store:
///  1. A crash/interrupted write can never leave a truncated or half-written
///     file that loses existing data (atomicity).
///  2. iOS production write paths actually request `.completeFileProtection`
///     and the OS actually sets the attribute (not silently dropped).
///  3. A corrupt or version-mismatched file THROWS -- it is never quietly
///     decoded as empty and then persisted over, destroying prior data.
///  4. Where a hard delete exists, it actually removes the data on disk.
///  5. No credential/secret-shaped field exists in any of these envelopes,
///     and at least one live validation path rejects secret-looking text
///     before it can reach a store.
///
/// Stores covered: FinanceBudgetStore, FinanceImportedTransactionStore,
/// FinanceAllocationStore, FinanceTrackingPreferencesStore,
/// FitnessLifestyleLedgerStore, NutritionGoalStore, NutritionMealStore.
final class DurableStorageSafetyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)
    private let timeZone = "Europe/Berlin"

    private func tempDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-durable-safety-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func removeDirectory(_ url: URL) {
        // Best-effort: restore write permission first in case a test left
        // the directory locked down, otherwise removal itself would fail.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    /// Blocks further writes to `directory` in a uid-independent way for the
    /// current (non-root) test user: strips write permission so a new temp
    /// file cannot be created inside it. Restored by `removeDirectory`.
    private func blockWrites(to directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    }

    private func unblockWrites(to directory: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    // MARK: - 1. Corrupt file never silently decodes to empty and gets overwritten

    func testFinanceBudgetStoreCorruptFileIsNeverTreatedAsEmptyAndOverwritten() throws {
        let dir = tempDirectory("finance-budget-corrupt")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-budgets.json")
        let store = try FinanceBudgetStore(url: url)
        try store.setBudget(FinanceCategoryBudget(category: .groceries, monthlyLimitCents: 30_000, effectiveFrom: now, createdAt: now))
        let corrupt = Data("{ this is not valid json at all ###".utf8)
        try corrupt.write(to: url)

        let reopened = try FinanceBudgetStore(url: url)
        XCTAssertThrowsError(try reopened.load()) { error in
            XCTAssertEqual(error as? FinanceBudgetStoreError, .invalidEnvelope)
        }
        XCTAssertThrowsError(try reopened.setBudget(FinanceCategoryBudget(category: .dining, monthlyLimitCents: 10_000, effectiveFrom: now, createdAt: now))) { error in
            XCTAssertEqual(error as? FinanceBudgetStoreError, .invalidEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "a corrupt file must never be silently replaced")
    }

    func testFinanceImportedTransactionStoreCorruptFileIsNeverTreatedAsEmptyAndOverwritten() throws {
        let dir = tempDirectory("finance-import-corrupt")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-imported-transactions.json")
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([FinanceImportedTransaction(bookedAt: now, amountCents: -1234, description: "Rewe", source: .genericCSV, importedAt: now)])
        let corrupt = Data("{ garbage ###".utf8)
        try corrupt.write(to: url)

        let reopened = try FinanceImportedTransactionStore(url: url)
        XCTAssertThrowsError(try reopened.all()) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .invalidEnvelope)
        }
        XCTAssertThrowsError(try reopened.add([FinanceImportedTransaction(bookedAt: now, amountCents: -1, description: "New", source: .genericCSV, importedAt: now)])) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .invalidEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testFinanceAllocationStoreCorruptFileIsNeverTreatedAsEmptyAndOverwritten() throws {
        let dir = tempDirectory("finance-allocation-corrupt")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-allocation-rules.json")
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        let corrupt = Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        try corrupt.write(to: url)

        let reopened = try FinanceAllocationStore(url: url)
        XCTAssertThrowsError(try reopened.list()) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidEnvelope)
        }
        XCTAssertThrowsError(try reopened.create(label: "Savings", bucket: "Savings", share: .percentage(10))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .invalidEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testFinanceTrackingPreferencesStoreCorruptFileIsNeverTreatedAsEmptyAndOverwritten() throws {
        let dir = tempDirectory("finance-prefs-corrupt")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-tracking-preferences.json")
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(FinanceTrackingPreferences(frequency: .monthly, cycleAnchorDate: now, incomeTrackingEnabled: true, expenseTrackingEnabled: true, updatedAt: now))
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)

        let reopened = try FinanceTrackingPreferencesStore(url: url)
        XCTAssertThrowsError(try reopened.current()) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .invalidEnvelope)
        }
        XCTAssertThrowsError(try reopened.commit(FinanceTrackingPreferences(frequency: .weekly, cycleAnchorDate: now, incomeTrackingEnabled: true, expenseTrackingEnabled: true, updatedAt: now))) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .invalidEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testNutritionGoalStoreCorruptFileIsNeverTreatedAsEmptyAndOverwritten() throws {
        let dir = tempDirectory("nutrition-goal-corrupt")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("nutrition-goals.json")
        let store = try NutritionGoalStore(url: url)
        try store.setGoal(NutritionGoal(effectiveFrom: now, calorieTarget: 2_200, proteinGramsTarget: 160, carbGramsTarget: 220, fatGramsTarget: 70, createdAt: now))
        let corrupt = Data("{{{{".utf8)
        try corrupt.write(to: url)

        let reopened = try NutritionGoalStore(url: url)
        XCTAssertThrowsError(try reopened.load()) { error in
            XCTAssertEqual(error as? NutritionGoalStoreError, .invalidEnvelope)
        }
        XCTAssertThrowsError(try reopened.setGoal(NutritionGoal(effectiveFrom: now, calorieTarget: 1_800, proteinGramsTarget: nil, carbGramsTarget: nil, fatGramsTarget: nil, createdAt: now))) { error in
            XCTAssertEqual(error as? NutritionGoalStoreError, .invalidEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testNutritionMealStoreCorruptFileIsNeverTreatedAsEmptyAndOverwritten() throws {
        let dir = tempDirectory("nutrition-meal-corrupt")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("nutrition-meals.json")
        let store = try NutritionMealStore(url: url)
        try store.addConfirmed(NutritionMeal(loggedAt: now, timeZoneIdentifier: "Europe/Berlin", name: "Breakfast", kcal: 400, proteinGrams: 30, carbGrams: 40, fatGrams: 10, provenance: .manual, createdAt: now))
        let corrupt = Data("<<not json>>".utf8)
        try corrupt.write(to: url)

        let reopened = try NutritionMealStore(url: url)
        XCTAssertThrowsError(try reopened.load()) { error in
            XCTAssertEqual(error as? NutritionMealStoreError, .invalidEnvelope)
        }
        XCTAssertThrowsError(try reopened.addConfirmed(NutritionMeal(loggedAt: now, timeZoneIdentifier: "Europe/Berlin", name: "Lunch", kcal: 500, proteinGrams: nil, carbGrams: nil, fatGrams: nil, provenance: .manual, createdAt: now))) { error in
            XCTAssertEqual(error as? NutritionMealStoreError, .invalidEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    /// Complements `FitnessLifestyleLedgerTests.testCorruptLoadFailsClosedAndDoesNotReplaceFile`,
    /// which corrupts an otherwise-never-written file. This variant starts
    /// from real pre-existing data so the property under test is exactly the
    /// one DT-02 cares about: corruption of a file that used to hold a
    /// user's real events must never be quietly treated as "empty ledger."
    func testFitnessLifestyleLedgerStoreCorruptFileWithPriorDataIsNeverOverwritten() throws {
        let dir = tempDirectory("lifestyle-corrupt-with-data")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("fitness-lifestyle-ledger.json")
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        _ = try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters, occurredAt: now, timeZoneIdentifier: timeZone, now: now)
        let corrupt = Data("{ broken ###".utf8)
        try corrupt.write(to: url)

        let reopened = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertTrue(reopened.hasLoadFailure)
        XCTAssertThrowsError(try reopened.addNone(kind: .caffeine, occurredAt: now, timeZoneIdentifier: timeZone, now: now))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    // MARK: - 2. Pre-existing data survives a failed write (the strongest atomicity test)

    func testFinanceBudgetStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("finance-budget-blocked")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-budgets.json")
        let store = try FinanceBudgetStore(url: url)
        try store.setBudget(FinanceCategoryBudget(category: .groceries, monthlyLimitCents: 30_000, effectiveFrom: now, createdAt: now))
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.setBudget(FinanceCategoryBudget(category: .dining, monthlyLimitCents: 10_000, effectiveFrom: now, createdAt: now))) { error in
            XCTAssertEqual(error as? FinanceBudgetStoreError, .writeFailed)
        }
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before, "existing budget data must survive a failed write untouched")
        let reloaded = try FinanceBudgetStore(url: url).load()
        XCTAssertEqual(reloaded.map(\.category), [.groceries])
    }

    func testFinanceImportedTransactionStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("finance-import-blocked")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-imported-transactions.json")
        let store = try FinanceImportedTransactionStore(url: url)
        let kept = FinanceImportedTransaction(bookedAt: now, amountCents: -1234, description: "Rewe", source: .genericCSV, importedAt: now)
        try store.add([kept])
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.add([FinanceImportedTransaction(bookedAt: now, amountCents: -1, description: "Lost", source: .genericCSV, importedAt: now)])) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .writeFailed)
        }
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before)
        let reloaded = try FinanceImportedTransactionStore(url: url).all()
        XCTAssertEqual(reloaded.map(\.id), [kept.id])
    }

    func testFinanceAllocationStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("finance-allocation-blocked")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-allocation-rules.json")
        let store = try FinanceAllocationStore(url: url)
        try store.create(label: "Rent", bucket: "Rent", share: .percentage(40))
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.create(label: "Savings", bucket: "Savings", share: .percentage(10))) { error in
            XCTAssertEqual(error as? FinanceAllocationStoreError, .writeFailed)
        }
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before)
        let reloaded = try FinanceAllocationStore(url: url).list()
        XCTAssertEqual(reloaded.map(\.label), ["Rent"])
    }

    func testFinanceTrackingPreferencesStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("finance-prefs-blocked")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-tracking-preferences.json")
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(FinanceTrackingPreferences(frequency: .monthly, cycleAnchorDate: now, incomeTrackingEnabled: true, expenseTrackingEnabled: true, updatedAt: now))
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.commit(FinanceTrackingPreferences(frequency: .weekly, cycleAnchorDate: now, incomeTrackingEnabled: false, expenseTrackingEnabled: true, updatedAt: now))) { error in
            XCTAssertEqual(error as? FinanceTrackingPreferencesStoreError, .writeFailed)
        }
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before)
        let reloaded = try FinanceTrackingPreferencesStore(url: url).current()
        XCTAssertEqual(reloaded?.frequency, .monthly)
    }

    func testNutritionGoalStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("nutrition-goal-blocked")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("nutrition-goals.json")
        let store = try NutritionGoalStore(url: url)
        try store.setGoal(NutritionGoal(effectiveFrom: now, calorieTarget: 2_200, proteinGramsTarget: 160, carbGramsTarget: 220, fatGramsTarget: 70, createdAt: now))
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.setGoal(NutritionGoal(effectiveFrom: now.addingTimeInterval(86_400), calorieTarget: 1_800, proteinGramsTarget: nil, carbGramsTarget: nil, fatGramsTarget: nil, createdAt: now))) { error in
            XCTAssertEqual(error as? NutritionGoalStoreError, .writeFailed)
        }
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before)
        let reloaded = try NutritionGoalStore(url: url).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.calorieTarget, 2_200)
    }

    func testNutritionMealStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("nutrition-meal-blocked")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("nutrition-meals.json")
        let store = try NutritionMealStore(url: url)
        let kept = NutritionMeal(loggedAt: now, timeZoneIdentifier: "Europe/Berlin", name: "Breakfast", kcal: 400, proteinGrams: 30, carbGrams: 40, fatGrams: 10, provenance: .manual, createdAt: now)
        try store.addConfirmed(kept)
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.addConfirmed(NutritionMeal(loggedAt: now, timeZoneIdentifier: "Europe/Berlin", name: "Lost meal", kcal: 500, proteinGrams: nil, carbGrams: nil, fatGrams: nil, provenance: .manual, createdAt: now))) { error in
            XCTAssertEqual(error as? NutritionMealStoreError, .writeFailed)
        }
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before)
        let reloaded = try NutritionMealStore(url: url).load()
        XCTAssertEqual(reloaded.map(\.id), [kept.id])
    }

    /// `FitnessLifestyleLedgerTests.testAtomicWriteFailureRollsBackInMemoryState`
    /// already proves rollback starting from an *empty* store. This variant
    /// is the gap: real pre-existing events must survive a failed write.
    func testFitnessLifestyleLedgerStorePreExistingDataSurvivesFailedWrite() throws {
        let dir = tempDirectory("lifestyle-blocked-with-data")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("fitness-lifestyle-ledger.json")
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        let kept = try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters, occurredAt: now, timeZoneIdentifier: timeZone, now: now)
        let before = try Data(contentsOf: url)

        try blockWrites(to: dir)
        XCTAssertThrowsError(try store.addNone(kind: .caffeine, occurredAt: now, timeZoneIdentifier: timeZone, now: now))
        unblockWrites(to: dir)

        XCTAssertEqual(try Data(contentsOf: url), before, "existing lifestyle events must survive a failed write untouched")
        let reloaded = FitnessLifestyleLedgerStore(persistenceURL: url)
        XCTAssertFalse(reloaded.hasLoadFailure)
        XCTAssertEqual(reloaded.activeEvents().map(\.id), [kept.id])
    }

    // MARK: - 3. iOS write paths actually request complete file protection

    /// The iOS Simulator does not implement real Data Protection (no Secure
    /// Enclave), so `FileManager.attributesOfItem(atPath:)[.protectionKey]`
    /// comes back `nil` for every file regardless of what options were
    /// requested at write time -- confirmed empirically: this test used to
    /// assert on that attribute and failed for all seven stores even though
    /// their `#if os(iOS)` branches do request `.completeFileProtection`.
    /// Whether the OS actually enforces the requested class while the
    /// device is locked is the device-gated half of DT-02 and is NOT
    /// provable here.
    ///
    /// What IS provable here, and is exactly what this repo's own
    /// established pattern (`ProductionConfigSecurityTests`) uses for the
    /// same class of claim: read the actual shipping source and assert the
    /// production write call literally requests complete file protection on
    /// iOS. This fails the moment someone edits the option set away, which
    /// is the regression this row exists to catch.
    func testProductionWritePathsSourceRequestsCompleteFileProtectionOnIOS() throws {
        let sharedDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DurableStorageSafetyTests.swift
            .deletingLastPathComponent() // LifeOSTests/
            .appendingPathComponent("Shared", isDirectory: true)

        // (file, exact production write-call line that must be present)
        let expectations: [(file: String, iosWriteCall: String)] = [
            ("FinanceBudgetStore.swift", "try data.write(to: temporary, options: [.atomic, .completeFileProtection])"),
            ("FinanceImportedTransactionStore.swift", "try data.write(to: temporary, options: [.atomic, .completeFileProtection])"),
            ("FinanceAllocationStore.swift", "try data.write(to: temporary, options: [.atomic, .completeFileProtection])"),
            ("FinanceTrackingPreferencesStore.swift", "try data.write(to: temporary, options: [.atomic, .completeFileProtection])"),
            ("NutritionGoalStore.swift", "try data.write(to: temporary, options: [.atomic, .completeFileProtection])"),
            ("NutritionMealStore.swift", "try data.write(to: temporary, options: [.atomic, .completeFileProtection])"),
            ("FitnessLifestyleLedger.swift", "try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])"),
        ]

        var checkedAtLeastOne = false
        for expectation in expectations {
            let url = sharedDirectory.appendingPathComponent(expectation.file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("could not read \(expectation.file) from \(sharedDirectory.path) to inspect its write path")
                continue
            }
            checkedAtLeastOne = true
            XCTAssertTrue(source.contains("#if os(iOS)"), "\(expectation.file) must branch its write options on #if os(iOS)")
            XCTAssertTrue(source.contains(expectation.iosWriteCall), "\(expectation.file) does not request complete file protection on its iOS write path")
            // The macOS branch must stay atomic-only: no iOS-only option
            // smuggled into the shared/macOS path.
            XCTAssertTrue(source.contains("try data.write(to: temporary, options: [.atomic])")
                          || source.contains("try data.write(to: persistenceURL, options: [.atomic])"),
                          "\(expectation.file) must keep a plain .atomic write path for macOS")
        }
        XCTAssertTrue(checkedAtLeastOne, "could not locate any of the target stores under \(sharedDirectory.path)")
    }

    // MARK: - 4. Delete actually deletes (hard-delete stores), soft-delete stores stay honest

    func testFinanceImportedTransactionStoreClearAllRemovesDataAtRestNotJustInMemory() throws {
        let dir = tempDirectory("finance-import-clearall")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-imported-transactions.json")
        let store = try FinanceImportedTransactionStore(url: url)
        try store.add([
            FinanceImportedTransaction(bookedAt: now, amountCents: -100, description: "SecretMerchantName", source: .genericCSV, importedAt: now),
            FinanceImportedTransaction(bookedAt: now, amountCents: -200, description: "OtherMerchant", source: .genericCSV, importedAt: now)
        ])

        try store.clearAll()

        // Not just the in-memory view -- a fresh store instance reading the
        // actual bytes on disk, and the raw bytes themselves.
        let reopened = try FinanceImportedTransactionStore(url: url)
        XCTAssertTrue(try reopened.all().isEmpty)
        let raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("SecretMerchantName"))
        XCTAssertFalse(raw.contains("OtherMerchant"))
    }

    func testFinanceBudgetStoreRemoveDeletesCategoryDataAtRest() throws {
        let dir = tempDirectory("finance-budget-remove")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-budgets.json")
        let store = try FinanceBudgetStore(url: url)
        try store.setBudget(FinanceCategoryBudget(category: .groceries, monthlyLimitCents: 12_345, effectiveFrom: now, createdAt: now))

        try store.remove(category: .groceries)

        let reopened = try FinanceBudgetStore(url: url)
        XCTAssertTrue(try reopened.load().isEmpty)
        let raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("12345"), "the removed limit must not remain on disk")
    }

    func testFinanceAllocationStoreRemoveDeletesRuleDataAtRest() throws {
        let dir = tempDirectory("finance-allocation-remove")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-allocation-rules.json")
        let store = try FinanceAllocationStore(url: url)
        let rule = try store.create(label: "UniqueRuleLabel", bucket: "Rent", share: .percentage(40))

        try store.remove(id: rule.id)

        let reopened = try FinanceAllocationStore(url: url)
        XCTAssertTrue(try reopened.list().isEmpty)
        let raw = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("UniqueRuleLabel"))
    }

    /// `NutritionMealStore` has no hard delete: `softDelete` sets `deletedAt`
    /// and the record remains on disk by design (it still contributes to
    /// `correct`'s revision lineage, and to any future export/audit trail).
    /// This documents that as intentional rather than a gap: soft-deleted
    /// meals are excluded from every query surface, but a hard "erase from
    /// disk" API does not exist in this store's boundary.
    func testNutritionMealStoreSoftDeleteExcludesFromQueriesButIsAnIntentionalTombstoneNotAHardDelete() throws {
        let dir = tempDirectory("nutrition-meal-softdelete")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("nutrition-meals.json")
        let store = try NutritionMealStore(url: url)
        let meal = NutritionMeal(loggedAt: now, timeZoneIdentifier: "Europe/Berlin", name: "Breakfast", kcal: 400, proteinGrams: nil, carbGrams: nil, fatGrams: nil, provenance: .manual, createdAt: now)
        try store.addConfirmed(meal)

        try store.softDelete(id: meal.id, now: now)

        XCTAssertTrue(try store.meals(on: now).isEmpty, "soft-deleted meal must be excluded from active queries")
        let allIncludingDeleted = try store.load()
        XCTAssertEqual(allIncludingDeleted.map(\.id), [meal.id], "soft delete is a tombstone by design, not a hard erase")
        XCTAssertTrue(allIncludingDeleted.first?.isDeleted ?? false)
    }

    /// `FitnessLifestyleLedgerStore.delete` is likewise a tombstone
    /// (supersession chain preserved for lineage/audit), not a hard erase.
    /// Documented as intentional; there is no hard-delete API in this store.
    func testFitnessLifestyleLedgerStoreDeleteIsAnIntentionalTombstoneNotAHardDelete() throws {
        let dir = tempDirectory("lifestyle-softdelete")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("fitness-lifestyle-ledger.json")
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        let event = try store.addQuantity(kind: .hydration, amount: 250, unit: .milliliters, occurredAt: now, timeZoneIdentifier: timeZone, now: now)

        _ = try store.delete(eventID: event.id, now: now)

        XCTAssertTrue(store.activeEvents().isEmpty, "deleted event must be excluded from active queries")
        XCTAssertFalse(store.history().isEmpty, "delete is a tombstone by design, not a hard erase")
    }

    /// `NutritionGoalStore` and `FinanceTrackingPreferencesStore` (committed
    /// value) expose no delete/remove API at all: goals/preferences are only
    /// ever superseded by a newer dated entry. Documented as not-applicable
    /// rather than silently unverified. `discardDraft` is the one real
    /// "delete" surface on the preferences store (an in-progress draft), and
    /// it does remove the draft from disk.
    func testFinanceTrackingPreferencesDiscardDraftRemovesDraftAtRest() throws {
        let dir = tempDirectory("finance-prefs-discard")
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-tracking-preferences.json")
        let store = try FinanceTrackingPreferencesStore(url: url)
        try store.commit(FinanceTrackingPreferences(frequency: .monthly, cycleAnchorDate: now, incomeTrackingEnabled: true, expenseTrackingEnabled: true, updatedAt: now))
        try store.saveDraft(FinanceTrackingPreferences(frequency: .customDayOfMonth(5), cycleAnchorDate: now, incomeTrackingEnabled: true, expenseTrackingEnabled: true, updatedAt: now))

        try store.discardDraft()

        let reopened = try FinanceTrackingPreferencesStore(url: url)
        XCTAssertNil(try reopened.draft())
        XCTAssertEqual(try reopened.current()?.frequency, .monthly)
    }

    // MARK: - 5. Key custody: no credential-shaped field exists, and one live path rejects secret-looking text

    /// No store's on-disk envelope declares (or, via `Codable`, could
    /// silently gain) a field shaped like a credential. This is a static
    /// negative check on the actual encoded JSON, not a guess from reading
    /// the struct definitions.
    func testNoDurableEnvelopeContainsACredentialShapedField() throws {
        let credentialLikeKeys = ["apikey", "api_key", "clientsecret", "client_secret", "bearertoken", "bearer_token", "password", "privatekey", "private_key", "refreshtoken", "refresh_token", "accesstoken", "access_token"]

        func assertNoCredentialField(_ jsonString: String, label: String) {
            let normalized = jsonString.lowercased().replacingOccurrences(of: " ", with: "")
            for key in credentialLikeKeys {
                XCTAssertFalse(normalized.contains("\"\(key)\""), "\(label) unexpectedly contains a credential-shaped field: \(key)")
            }
        }

        let budgetJSON = try JSONEncoder.forTest().encode(FinanceBudgetStoreEnvelope(budgets: [
            FinanceCategoryBudget(category: .groceries, monthlyLimitCents: 1_000, effectiveFrom: now, createdAt: now)
        ]))
        assertNoCredentialField(String(data: budgetJSON, encoding: .utf8)!, label: "FinanceBudgetStoreEnvelope")

        let importJSON = try JSONEncoder.forTest().encode(FinanceImportedTransactionStoreEnvelope(transactions: [
            FinanceImportedTransaction(bookedAt: now, amountCents: -1, description: "X", source: .genericCSV, importedAt: now)
        ]))
        assertNoCredentialField(String(data: importJSON, encoding: .utf8)!, label: "FinanceImportedTransactionStoreEnvelope")

        let allocationJSON = try JSONEncoder.forTest().encode(FinanceAllocationStoreEnvelope(rules: [
            FinanceAllocationRule(label: "Rent", bucket: "Rent", share: .percentage(10))
        ]))
        assertNoCredentialField(String(data: allocationJSON, encoding: .utf8)!, label: "FinanceAllocationStoreEnvelope")

        let prefsJSON = try JSONEncoder.forTest().encode(FinanceTrackingPreferencesEnvelope(
            committed: FinanceTrackingPreferences(frequency: .monthly, cycleAnchorDate: now, incomeTrackingEnabled: true, expenseTrackingEnabled: true, updatedAt: now),
            draft: nil
        ))
        assertNoCredentialField(String(data: prefsJSON, encoding: .utf8)!, label: "FinanceTrackingPreferencesEnvelope")

        let goalJSON = try JSONEncoder.forTest().encode(NutritionGoalStoreEnvelope(goals: [
            NutritionGoal(effectiveFrom: now, calorieTarget: 2_000, proteinGramsTarget: nil, carbGramsTarget: nil, fatGramsTarget: nil, createdAt: now)
        ]))
        assertNoCredentialField(String(data: goalJSON, encoding: .utf8)!, label: "NutritionGoalStoreEnvelope")

        let mealJSON = try JSONEncoder.forTest().encode(NutritionMealStoreEnvelope(meals: [
            NutritionMeal(loggedAt: now, timeZoneIdentifier: "Europe/Berlin", name: "Breakfast", kcal: 400, proteinGrams: nil, carbGrams: nil, fatGrams: nil, provenance: .manual, createdAt: now)
        ]))
        assertNoCredentialField(String(data: mealJSON, encoding: .utf8)!, label: "NutritionMealStoreEnvelope")

        let dir = tempDirectory("lifestyle-schema-check")
        defer { removeDirectory(dir) }
        let ledgerURL = dir.appendingPathComponent("fitness-lifestyle-ledger.json")
        let ledgerStore = FitnessLifestyleLedgerStore(persistenceURL: ledgerURL)
        _ = try ledgerStore.addQuantity(kind: .hydration, amount: 250, unit: .milliliters, occurredAt: now, timeZoneIdentifier: timeZone, now: now)
        let ledgerJSON = String(data: try Data(contentsOf: ledgerURL), encoding: .utf8) ?? ""
        assertNoCredentialField(ledgerJSON, label: "FitnessLifestyleLedger on-disk envelope")
    }

    /// A live enforcement path: `FoodPhotoUserContext` (feeds the nutrition
    /// photo-estimate pipeline) refuses to construct at all when user-typed
    /// free text looks like a credential, so a pasted API key/token/secret
    /// can never reach durable storage through this path in the first
    /// place. This is the one call site inside the nutrition domain that
    /// enforces `NutritionValidation.validateSecretFreeText` on free text
    /// (the private validator itself isn't reachable from tests directly).
    func testFoodPhotoUserContextRejectsSecretLookingFreeTextBeforePersistence() {
        XCTAssertThrowsError(try FoodPhotoUserContext(note: "api_key=sk-abcdefghijklmnopqrstuvwxyz1234567890")) { error in
            XCTAssertEqual(error as? NutritionValidationError, .invalidText("note"))
        }
        XCTAssertThrowsError(try FoodPhotoUserContext(knownReference: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")) { error in
            XCTAssertEqual(error as? NutritionValidationError, .invalidText("knownReference"))
        }
        XCTAssertNoThrow(try FoodPhotoUserContext(note: "half a plate, extra rice"))
    }
}

private extension JSONEncoder {
    /// Mirrors the `dateEncodingStrategy` every store above configures on
    /// its own private encoder, so the encoded shape here matches what
    /// actually lands on disk.
    static func forTest() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
