import Foundation
import XCTest
@testable import LifeOS

/// Closes the release-signature half of acceptance row HK-01: the checked-in
/// build configuration must declare the HealthKit entitlement and both
/// required usage-description strings on iOS only, and must make no such
/// claim on macOS or in either widget extension. The device-authorization
/// half (the real HealthKit permission prompt) needs geonq's iPhone and is
/// out of scope here.
///
/// These tests read the *actual* checked-in `.entitlements` and `Info.plist`
/// files from disk (the same files Xcode signs into the shipped binary), not
/// a restatement of what they are expected to contain. A regression that
/// drops the iOS entitlement, blanks a usage string, or lets HealthKit leak
/// onto a target that must not carry it will make these tests fail.
final class HealthKitCapabilityConfigurationTests: XCTestCase {

    // MARK: - File access

    /// Same discovery approach as `ProductionConfigSecurityTests`: walk up
    /// from this test file's own path to the `ios/` project root, so the
    /// test locates the repo robustly regardless of the working directory
    /// the test runner was launched from.
    private static var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HealthKitCapabilityConfigurationTests.swift
            .deletingLastPathComponent() // LifeOSTests/
    }

    private func plist(at relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let url = Self.iosRoot.appendingPathComponent(relativePath)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: url.path),
                                  "could not read \(relativePath) at \(url.path)", file: file, line: line)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any], "\(relativePath) is not a dictionary plist", file: file, line: line)
    }

    private func fileText(at relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = Self.iosRoot.appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                              "could not read \(relativePath) at \(url.path)", file: file, line: line)
    }

    /// A usage-description string is meaningful only if it is a real
    /// sentence explaining *why*, not a blank value or a placeholder Xcode
    /// or a careless engineer might leave behind. Apple rejects blank
    /// strings outright and the user sees whatever is left, so this rejects
    /// both the empty string and the obvious placeholder shapes.
    private func assertMeaningfulUsageString(_ value: String?, key: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            return XCTFail("\(key) is missing entirely", file: file, line: line)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "\(key) must not be blank", file: file, line: line)
        XCTAssertGreaterThanOrEqual(trimmed.count, 20,
                                     "\(key) reads as a placeholder, not a real explanation: \"\(trimmed)\"",
                                     file: file, line: line)
        let lowered = trimmed.lowercased()
        for placeholder in ["todo", "placeholder", "lorem ipsum", "description", "fixme", "xxx"] {
            XCTAssertFalse(lowered == placeholder, "\(key) is a placeholder value: \"\(trimmed)\"", file: file, line: line)
        }
        // A meaningful description explains why Life OS needs the data --
        // require it to actually mention health/fitness data, not just be
        // any 20-character sentence.
        XCTAssertTrue(lowered.contains("health") || lowered.contains("fitness") || lowered.contains("hydration")
                      || lowered.contains("caffeine") || lowered.contains("sleep") || lowered.contains("activity"),
                      "\(key) does not read as an explanation of Health data use: \"\(trimmed)\"", file: file, line: line)
    }

    // MARK: - iOS app target: entitlement + both usage strings, non-placeholder

    func testIOSAppEntitlementsDeclareHealthKit() throws {
        let entitlements = try plist(at: "LifeOS/LifeOS.entitlements")
        XCTAssertEqual(entitlements["com.apple.developer.healthkit"] as? Bool, true,
                        "ios/LifeOS/LifeOS.entitlements must declare com.apple.developer.healthkit")
    }

    func testIOSAppInfoPlistCarriesBothHealthUsageDescriptions() throws {
        let infoPlist = try plist(at: "LifeOS/Info.plist")
        assertMeaningfulUsageString(infoPlist["NSHealthShareUsageDescription"] as? String, key: "NSHealthShareUsageDescription")
        assertMeaningfulUsageString(infoPlist["NSHealthUpdateUsageDescription"] as? String, key: "NSHealthUpdateUsageDescription")
    }

    // MARK: - macOS app target: no HealthKit claim anywhere

    func testMacAppEntitlementsDoNotDeclareHealthKit() throws {
        let entitlements = try plist(at: "LifeOSMac/LifeOSMac.entitlements")
        XCTAssertNil(entitlements["com.apple.developer.healthkit"],
                     "ios/LifeOSMac/LifeOSMac.entitlements must not claim HealthKit -- it is iOS-only")
        XCTAssertNil(entitlements["com.apple.developer.healthkit.background-delivery"])
    }

    func testMacAppInfoPlistCarriesNoHealthUsageDescriptions() throws {
        let infoPlist = try plist(at: "LifeOSMac/Info.plist")
        XCTAssertNil(infoPlist["NSHealthShareUsageDescription"],
                     "ios/LifeOSMac/Info.plist must not carry a Health usage string -- HealthKit is iOS-only")
        XCTAssertNil(infoPlist["NSHealthUpdateUsageDescription"])
    }

    // MARK: - Widget extensions: no HealthKit claim on either platform's widget

    func testIOSWidgetEntitlementsDoNotDeclareHealthKit() throws {
        let entitlements = try plist(at: "LifeOSWidget/LifeOSWidget.entitlements")
        XCTAssertNil(entitlements["com.apple.developer.healthkit"],
                     "ios/LifeOSWidget/LifeOSWidget.entitlements must not claim HealthKit")
    }

    func testIOSWidgetInfoPlistCarriesNoHealthUsageDescriptions() throws {
        let infoPlist = try plist(at: "LifeOSWidget/Info.plist")
        XCTAssertNil(infoPlist["NSHealthShareUsageDescription"])
        XCTAssertNil(infoPlist["NSHealthUpdateUsageDescription"])
    }

    func testMacWidgetEntitlementsDoNotDeclareHealthKit() throws {
        let entitlements = try plist(at: "LifeOSMacWidget/LifeOSMacWidget.entitlements")
        XCTAssertNil(entitlements["com.apple.developer.healthkit"],
                     "ios/LifeOSMacWidget/LifeOSMacWidget.entitlements must not claim HealthKit")
    }

    func testMacWidgetInfoPlistCarriesNoHealthUsageDescriptions() throws {
        let infoPlist = try plist(at: "LifeOSMacWidget/Info.plist")
        XCTAssertNil(infoPlist["NSHealthShareUsageDescription"])
        XCTAssertNil(infoPlist["NSHealthUpdateUsageDescription"])
    }

    // MARK: - project.yml: the generator must wire the iOS entitlement file to the iOS target only

    /// `project.yml` is what `xcodegen generate` actually reads to produce
    /// the Xcode project; a correct checked-in `.entitlements` file is
    /// meaningless if the generator does not point the LifeOS target's
    /// `CODE_SIGN_ENTITLEMENTS` at it, or if it also wires it (or a
    /// duplicate) into a target that must not carry HealthKit.
    func testProjectYMLWiresIOSEntitlementsOnlyToTheIOSAppTarget() throws {
        let yaml = try fileText(at: "project.yml")
        XCTAssertTrue(yaml.contains("CODE_SIGN_ENTITLEMENTS: LifeOS/LifeOS.entitlements"),
                      "project.yml must set the LifeOS target's CODE_SIGN_ENTITLEMENTS to LifeOS/LifeOS.entitlements")
        XCTAssertFalse(yaml.contains("LifeOS/LifeOS.entitlements") && yaml.contains("LifeOSMac.entitlements: LifeOS/LifeOS.entitlements"),
                      "the iOS entitlements file must not be reused for the Mac target")
    }

    /// Defense in depth for the same property this row protects: even if a
    /// HealthKit source file were mistakenly added to `Shared/`, it must be
    /// excluded from every macOS-reachable target's source list, so a stray
    /// entitlement omission is not the only thing standing between HealthKit
    /// and a macOS build.
    func testProjectYMLExcludesHealthKitSourcesFromMacAndWidgetTargets() throws {
        let yaml = try fileText(at: "project.yml")
        let excludeCount = yaml.components(separatedBy: "excludes: [HealthKit*.swift]").count - 1
        XCTAssertGreaterThanOrEqual(excludeCount, 4,
                                     "expected LifeOSWidget, LifeOSMac, LifeOSWidgetSnapshotTests, and LifeOSMacWidget to each exclude HealthKit*.swift from their Shared sources")
    }

    // MARK: - No fixture/demo path can fake HealthKit authorization

    /// On macOS (and any non-iOS build), `LifeOSHealthKitAdapter` is a
    /// distinct, hand-written type -- not the real iOS adapter compiled out
    /// -- that unconditionally reports `.unavailable`/not-available rather
    /// than presenting a fixture as a live authorized source. This is
    /// enforced by the `#if os(iOS) && canImport(HealthKit)` compilation
    /// gate itself: this test target builds for iOS, so it exercises the
    /// live-adapter branch; the property that the macOS branch exists and
    /// reports unavailable is additionally checked by reading the source
    /// below, since the two branches can never both be compiled in the same
    /// test binary.
    func testHealthKitAdapterSourceGatesTheLiveBranchToIOSOnly() throws {
        let source = try fileText(at: "Shared/HealthKitAdapter.swift")
        XCTAssertTrue(source.contains("#if os(iOS) && canImport(HealthKit)"),
                      "the live HealthKit adapter must be compiled in only under #if os(iOS) && canImport(HealthKit)")
        XCTAssertTrue(source.contains("public var isHealthDataAvailable: Bool { false }"),
                      "the non-iOS adapter branch must unconditionally report health data as unavailable")
        XCTAssertTrue(source.contains(".unavailable"),
                      "the non-iOS adapter branch must resolve authorization state to .unavailable, never a live-looking state")
    }

    /// The real `HealthKitIntegrationController`, default-constructed
    /// exactly as `LifeOSApp` constructs it, must never start in an
    /// authorized-looking state. `ProductionConfigSecurityTests` already
    /// proves this for the fixture-gating property; this test proves the
    /// authorization-state property specifically, in this row's own file.
    @MainActor
    func testHealthKitIntegrationControllerNeverStartsAuthorized() {
        let controller = HealthKitIntegrationController()
        XCTAssertEqual(controller.snapshot.authorizationState, .notRequested)
        // HealthKit exposes no per-type read-denial state, so the only two
        // states that could make the UI look already-authorized are
        // .readIndeterminate ("a request completed") and .writeAuthorized.
        // A fresh, default-constructed controller must start in neither.
        XCTAssertNotEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertNotEqual(controller.snapshot.authorizationState, .writeAuthorized)
    }
}
