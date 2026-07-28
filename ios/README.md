# Native iOS foundation

This is the product track for iPhone Life OS. The React dashboard remains a visual/reference prototype only.

## macOS prerequisites

- macOS with Xcode 15.4+ (Swift 5.9, iOS 17 SDK)
- XcodeGen: `brew install xcodegen`
- An iPhone for eventual WidgetKit/device validation

## Generate and verify on macOS

From the repository root:

```sh
cd iphone-automation/ios
xcodegen generate
xcodebuild -project LifeOS.xcodeproj -scheme LifeOS -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' test
xcodebuild -project LifeOS.xcodeproj -scheme LifeOS -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' build
```

For a signed device build after selecting a development team in Xcode:

```sh
xcodebuild -project LifeOS.xcodeproj -scheme LifeOS -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

These commands have **not** been run in this Windows workspace. Swift, Xcode, XcodeGen, simulator, signing, and device behavior remain unverified here.

## Capability boundaries and provisioning steps

- HealthKit is intentionally not entitled or requested; add permissions only after consent and real-device Zepp-to-HealthKit validation. HealthKit remains a later phase.
- App Intents and Hermes voice capture remain discovery-only; no shortcut, token, upload route, or fake authorization is shipped.
- App Group entitlements are source-configured for both targets using `$(APP_GROUP_IDENTIFIER)`, but the value is deliberately `group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID`. On macOS, replace it with a team-owned App Group in `project.yml`, create/select the matching capability for both targets in Xcode, and ensure provisioning profiles contain it before device testing.
- The widget reads only the atomically replaced `widget-snapshot.json` from that App Group and falls back to explicitly labeled demo data. It does not fetch network data or expose private values in `systemMedium`.
- Required macOS gates: XcodeGen generation, simulator build/tests, signed device install, App Group atomic-write test, WidgetKit systemMedium rendering/privacy review, and HealthKit permission/sync test. None are claimed here.
