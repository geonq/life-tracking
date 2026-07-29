from __future__ import annotations

import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    project = (IOS / "project.yml").read_text(encoding="utf-8")
    required_files = [
        "Shared/CalendarDomain.swift",
        "Shared/CalendarIconAsset.swift",
        "Shared/CalendarStore.swift",
        "Shared/CalendarViews.swift",
        "LifeOS/CalendarView.swift",
        "LifeOSWidget/CalendarWidget.swift",
        "LifeOSMac/LifeOSMacApp.swift",
        "LifeOSMac/Info.plist",
        "LifeOSMac/LifeOSMac.entitlements",
        "LifeOSMacWidget/LifeOSMacWidget.swift",
        "LifeOSMacWidget/Info.plist",
        "LifeOSMacWidget/LifeOSMacWidget.entitlements",
        "LifeOSTests/CalendarDomainTests.swift",
        "LifeOSTests/CalendarIconAssetTests.swift",
        "LifeOSMacUITests/LifeOSMacUITests.swift",
        "LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift",
        "Shared/SigningStatus.swift",
        "LifeOSTests/SigningStatusTests.swift",
        "Shared/CalendarPeerSync.swift",
        "LifeOSTests/CalendarPeerSyncTests.swift",
    ]
    missing = [relative for relative in required_files if not (IOS / relative).is_file()]
    require(not missing, f"missing native calendar/macOS files: {missing}")

    for token in ("LifeOSMac:", "LifeOSMacWidget:", 'macOS: "14.0"',
                  "CODE_SIGN_ENTITLEMENTS: LifeOS/LifeOS.entitlements",
                  "CODE_SIGN_ENTITLEMENTS: LifeOSWidget/LifeOSWidget.entitlements",
                  "CODE_SIGN_ENTITLEMENTS: LifeOSMac/LifeOSMac.entitlements",
                  "CODE_SIGN_ENTITLEMENTS: LifeOSMacWidget/LifeOSMacWidget.entitlements"):
        require(token in project, f"project.yml missing {token}")

    # Keep each executable target's entry point isolated.  In particular, the
    # macOS app must not accidentally compile the iOS app's @main, and widget
    # extensions must not compile either app entry point.
    require("sources: [LifeOS, Shared]" in project, "iOS app source membership changed")
    require("- LifeOSMac\n      - Shared" in project, "macOS app source membership changed")
    require("sources: [LifeOSWidget, Shared]" in project, "iOS widget source membership changed")
    require("- LifeOSMacWidget\n      - Shared" in project, "macOS widget source membership changed")
    require("- LifeOS/LifeOSApp.swift" not in project, "macOS target must not include iOS @main")
    require("- LifeOSMac/LifeOSMacApp.swift" not in project.split("LifeOSMacWidget:", 1)[-1], "macOS widget must not include macOS app @main")
    require(
        "testTargets: [LifeOSMacUITests, LifeOSMacSnapshotTests]" in project,
        "macOS scheme must capture visual evidence through UI and headless snapshot tests",
    )

    design_tokens = (IOS / "Shared/DesignTokens.swift").read_text(encoding="utf-8")
    for token in ("lifeOSDarkCanvas", "lifeOSLightCanvas", "traits.userInterfaceStyle == .dark", ".darkAqua"):
        require(token in design_tokens, f"adaptive light/dark design tokens missing {token}")

    ios_ui_tests = (IOS / "LifeOSUITests/LifeOSUITests.swift").read_text(encoding="utf-8")
    for token in ("testDarkModeScreenshots", '"dark-overview"', '"dark-usage"', '"dark-calendar"',
                  '"dark-tax-documents"', '"dark-settings"'):
        require(token in ios_ui_tests, f"iOS dark visual coverage missing {token}")

    mac_snapshots = (IOS / "LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift").read_text(encoding="utf-8")
    for token in ("testDarkModeSnapshots", "colorScheme: .dark", "LifeOSMacRootView-overview-dark",
                  "CalendarView-dark", "TaxDocumentsView-dark"):
        require(token in mac_snapshots, f"macOS dark snapshot coverage missing {token}")

    usage_widget = (IOS / "LifeOSWidget/UsageWidget.swift").read_text(encoding="utf-8")
    calendar_widget_source = (IOS / "LifeOSWidget/CalendarWidget.swift").read_text(encoding="utf-8")
    require("LifeOSTokens.surface" in usage_widget, "usage widget must use an adaptive branded surface")
    require("LifeOSTokens.surface" in calendar_widget_source, "calendar widget must use an adaptive branded surface")

    ios_widget = (IOS / "LifeOSWidget/LifeOSWidget.swift").read_text(encoding="utf-8")
    require("WidgetBundle" in ios_widget, "iOS widget entry point must bundle usage and calendar widgets")
    require("CalendarWidget()" in ios_widget, "iOS widget bundle must include CalendarWidget")

    mac_widget = (IOS / "LifeOSMacWidget/LifeOSMacWidget.swift").read_text(encoding="utf-8")
    require("WidgetBundle" in mac_widget, "macOS widget extension must define a WidgetBundle")
    require("CalendarWidget()" in mac_widget, "macOS widget bundle must include CalendarWidget")

    app = (IOS / "LifeOS/LifeOSApp.swift").read_text(encoding="utf-8")
    require("Calendar" in app or "RootTabView" in app, "iOS app must expose the calendar")

    parsed_plists = {}
    for relative in ("LifeOS/Info.plist", "LifeOSWidget/Info.plist", "LifeOSMac/Info.plist", "LifeOSMacWidget/Info.plist"):
        with (IOS / relative).open("rb") as handle:
            parsed_plists[relative] = plistlib.load(handle)

    # CalendarPeerSync uses MultipeerConnectivity's service type, while the
    # plist uses Bonjour's corresponding underscored TCP service name.
    peer_sync = (IOS / "Shared/CalendarPeerSync.swift").read_text(encoding="utf-8")
    require('serviceType = "lifeos-calendar"' in peer_sync, "CalendarPeerSync service type changed")
    bonjour_service = "_lifeos-calendar._tcp"
    for relative in ("LifeOS/Info.plist", "LifeOSMac/Info.plist"):
        plist = parsed_plists[relative]
        require(plist.get("NSLocalNetworkUsageDescription"), f"{relative} must explain local peer-sync access")
        require(bonjour_service in plist.get("NSBonjourServices", []), f"{relative} must advertise {bonjour_service}")

    entitlements = {}
    for relative in ("LifeOS/LifeOS.entitlements", "LifeOSWidget/LifeOSWidget.entitlements",
                     "LifeOSMac/LifeOSMac.entitlements", "LifeOSMacWidget/LifeOSMacWidget.entitlements"):
        with (IOS / relative).open("rb") as handle:
            entitlements[relative] = plistlib.load(handle)
        groups = entitlements[relative].get("com.apple.security.application-groups", [])
        require(groups == ["$(APP_GROUP_IDENTIFIER)"], f"{relative} must use the shared App Group build setting")
    mac_entitlements = entitlements["LifeOSMac/LifeOSMac.entitlements"]
    require(mac_entitlements.get("com.apple.security.app-sandbox") is True, "macOS app must enable App Sandbox")
    require(mac_entitlements.get("com.apple.security.network.client") is True, "macOS app needs sandbox outbound-network permission")
    require(mac_entitlements.get("com.apple.security.network.server") is True, "macOS app needs sandbox inbound-network permission")
    require("REPLACE_WITH_TEAM_CONFIGURED_ID" in project, "App Group configuration must remain explicit until team-configured")

    calendar_domain = (IOS / "Shared/CalendarDomain.swift").read_text(encoding="utf-8")
    for token in ("CalendarItem", "CalendarProgress", "CalendarSnapshot", "deletedAt", "deleting(at:", "iconAsset"):
        require(token in calendar_domain, f"calendar domain missing {token}")

    icon_asset = (IOS / "Shared/CalendarIconAsset.swift").read_text(encoding="utf-8")
    for token in ("maxBytes", "init(from decoder:", "deterministicKey"):
        require(token in icon_asset, f"calendar icon validation missing {token}")

    calendar_view = (IOS / "LifeOS/CalendarView.swift").read_text(encoding="utf-8")
    for token in ("fileImporter", ".png", ".jpeg", "startAccessingSecurityScopedResource", "Emoji remains the fallback"):
        require(token in calendar_view, f"calendar editor icon import missing {token}")

    shared_swift = "\n".join(path.read_text(encoding="utf-8") for path in (IOS / "Shared").glob("*.swift"))
    require(shared_swift.count("struct CalendarItem:") == 1, "CalendarItem must have one canonical shared declaration")
    require(shared_swift.count("enum CalendarProgress:") == 1, "CalendarProgress must have one canonical shared declaration")
    require(shared_swift.count("struct CalendarSnapshot:") == 1, "CalendarSnapshot must have one canonical shared declaration")

    calendar_widget = (IOS / "LifeOSWidget/CalendarWidget.swift").read_text(encoding="utf-8")
    require("systemMedium" in calendar_widget, "calendar widget must support the wide 2x4 family")

    print("native calendar/macOS source invariants: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"native calendar/macOS source invariants: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
