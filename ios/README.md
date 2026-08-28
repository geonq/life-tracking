# Native iOS + macOS foundation

This is the product track for the iPhone and Mac Life OS. It includes a dark-mode-first adaptive branded interface, a writable calendar/task system with emoji or bounded local PNG/JPEG icons, and read-only provenance-first dashboards. The React dashboard remains a visual/reference prototype only.

## macOS prerequisites

- macOS with Xcode 15.4+ (Swift 5.9, iOS 17 SDK)
- XcodeGen 2.46.0 (the hosted workflow downloads the upstream release and
  verifies SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`)
- An iPhone for eventual WidgetKit/device validation

## Generate and verify on macOS

From the repository root, the repeatable validation script generates the project,
runs the focused iOS logic lane by default, and validates its `.xcresult`
minimum count:

```sh
./scripts/validate_apple_on_mac.sh
```

UI lanes and their attachment export are explicit opt-ins:

```sh
./scripts/validate_apple_on_mac.sh ui   # iOS UI + macOS UI
./scripts/validate_apple_on_mac.sh all  # all five split debug lanes
```

Artifacts are written to `artifacts/apple-validation/` and remain untracked. The equivalent manual commands are:

```sh
xcodegen generate --spec ios/project.yml --project ios --project-root ios
python3 -B scripts/validate_xcodegen.py
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSLogic -showTestPlans
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSLogic -testPlan LifeOSLogic \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:LifeOSTests CODE_SIGNING_ALLOWED=NO test
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSMacLogic -testPlan LifeOSMacLogic \
  -destination 'platform=macOS' -only-testing:LifeOSMacSnapshotTests \
  CODE_SIGNING_ALLOWED=NO test
```

The split debug acceptance surface is seven lanes total: five hosted debug
lanes (`LifeOSLogic`, `LifeOSUI`, `LifeOSMacLogic`, `LifeOSMacUI`, and
`LifeOSWidgets`) plus the two Release prerelease lanes
(`LifeOSPrereleaseIOS` and `LifeOSPrereleaseMac`). The machine-readable
`scripts/native_lane_manifest.json` is the shared command contract for schemes,
test plans, configurations, target scopes, timeouts, result paths, and minimum
counts. The hosted workflow regenerates from `ios/project.yml` and rejects
empty/canceled/under-counted result bundles.

Run the Release pair with isolated per-platform DerivedData and result bundles:

```sh
./scripts/run_prerelease_lanes.sh build-for-testing
./scripts/run_prerelease_lanes.sh test-without-building
```

Hosted simulator results do not verify real-device signing, App Group
entitlements, peer discovery, or WidgetKit placement.

The checked-in project settings use automatic signing with the selected Apple
team (`8F6VSCQ9SZ`) and the approved private Tailscale host, so XcodeGen does
not reset the team or Sync & Storage configuration after edits. The App Group
remains a team-owned placeholder and `PROVISIONING_MODE` is `unknown` until
the real signed entitlement/profile is verified. A signed release environment
must create an ephemeral xcodebuild-settings/xcconfig file with any additional
release values and run:

```sh
python3 -B scripts/validate_native_release.py \
  --mode release --settings-file /private/path/to/ephemeral-settings.txt
```

Keep that file outside the repository and out of logs/artifacts. The validator
rejects unresolved variables, fixture build flags, placeholder/unknown signing,
and empty/non-`.ts.net` release allowlists; development mode preserves the
fail-closed source defaults.

For a signed device build after selecting a development team in Xcode:

```sh
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOS -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## Capability boundaries and provisioning steps

- HealthKit is read-only on the iPhone main app only. Life OS asks for access only through the explicit Settings prompt and reads only user-selected categories for source-backed fitness, sleep, activity, hydration, and caffeine data. Per-type read authorization is unknowable, so Life OS makes no per-type permission claim and does not treat an empty read as proof of denial or no data. There is no write path. Widgets, widget snapshot tests, macOS, and the Mac widget exclude HealthKit sources. The supported provenance path is Helio → Zepp → Apple Health → HealthKit, and physical-device proof is required before claiming Helio provenance or permission behavior.
- App Intents and Hermes voice capture remain discovery-only; no shortcut, token, upload route, or fake authorization is shipped.
- App Group entitlements are source-configured for app/widget targets using `$(APP_GROUP_IDENTIFIER)`, but the value is deliberately `group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID`. Replace it only with a signing-team-owned App Group and verify every app/widget profile contains the same mapped group. SideStore/AltStore may rewrite entitlements during free sideloading; inspect the installed result rather than assuming the source identifier survives unchanged.
- Apple Personal Team profiles expire after seven days and must be reprovisioned. The installed Life OS app cannot sign or reinstall itself. Xcode can rebuild/reinstall, AltStore can refresh while AltServer is reachable, and SideStore documents an on-device VPN-based refresh workflow; each is external to Life OS.
- Planned convenience workflow: an iPhone Shortcut may invoke one fixed Mac-side developer-refresh command. The Mac command must independently verify the paired target is physically connected over USB before it builds, signs, and installs with Xcode tooling; it must accept no arbitrary command or signing input from the phone. This does not change the seven-day Personal Team limit and remains unimplemented until the exact Team, App Group, device, and signed settings are supplied and validated.
- Widgets read only atomically replaced snapshots from their local App Group and fall back to an explicit unavailable/demo state. Cross-device synchronization is separate from the widget container and must be validated on signed iPhone/Mac builds.
- When the iOS app returns to the foreground after its initial live load, it concurrently refreshes Calendar, Usage, Finance, Clipper, Fitness, and then republishes widget snapshots. This is a foreground reconciliation path, not proof of OS background execution; WidgetKit background refresh still requires signed-device evidence.
- Required macOS gates: XcodeGen generation, simulator build/tests, signed device install, App Group atomic-write test, WidgetKit systemMedium rendering/privacy review, and HealthKit permission/sync test. None are claimed here.
