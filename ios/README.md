# Native iOS + macOS foundation

This is the product track for the iPhone and Mac Life OS. It includes a writable calendar/task system and read-only provenance-first dashboards. The React dashboard remains a visual/reference prototype only.

## macOS prerequisites

- macOS with Xcode 15.4+ (Swift 5.9, iOS 17 SDK)
- XcodeGen: `brew install xcodegen`
- An iPhone for eventual WidgetKit/device validation

## Generate and verify on macOS

From the repository root, the repeatable validation script generates the project, runs iOS unit/UI tests, preserves the `.xcresult` bundle and screenshot attachments, and builds the macOS app/widgets:

```sh
./scripts/validate_apple_on_mac.sh
```

Artifacts are written to `artifacts/apple-validation/` and remain untracked. The equivalent manual commands are:

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOS -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSMac -destination 'platform=macOS' build
```

The repository also runs unsigned source/build/test gates on a hosted macOS runner through `.github/workflows/native-apple.yml`. Hosted simulator results do not verify real-device signing, App Group entitlements, peer discovery, or WidgetKit placement.

For a signed device build after selecting a development team in Xcode:

```sh
xcodebuild -project LifeOS.xcodeproj -scheme LifeOS -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

These commands have **not** been run in this Windows workspace. Swift, Xcode, XcodeGen, simulator, signing, and device behavior remain unverified here.

## Capability boundaries and provisioning steps

- HealthKit is intentionally not entitled or requested; add permissions only after consent and real-device Zepp-to-HealthKit validation. HealthKit remains a later phase.
- App Intents and Hermes voice capture remain discovery-only; no shortcut, token, upload route, or fake authorization is shipped.
- App Group entitlements are source-configured for app/widget targets using `$(APP_GROUP_IDENTIFIER)`, but the value is deliberately `group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID`. Replace it only with a signing-team-owned App Group and verify every app/widget profile contains the same mapped group. SideStore/AltStore may rewrite entitlements during free sideloading; inspect the installed result rather than assuming the source identifier survives unchanged.
- Apple Personal Team profiles expire after seven days and must be reprovisioned. The installed Life OS app cannot sign or reinstall itself. Xcode can rebuild/reinstall, AltStore can refresh while AltServer is reachable, and SideStore documents an on-device VPN-based refresh workflow; each is external to Life OS.
- Widgets read only atomically replaced snapshots from their local App Group and fall back to an explicit unavailable/demo state. Cross-device synchronization is separate from the widget container and must be validated on signed iPhone/Mac builds.
- Required macOS gates: XcodeGen generation, simulator build/tests, signed device install, App Group atomic-write test, WidgetKit systemMedium rendering/privacy review, and HealthKit permission/sync test. None are claimed here.
