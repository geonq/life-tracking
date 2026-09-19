# Packet C — planning filesystem publication acceptance

Date: 2026-09-19 (Europe/Berlin)
Base revision: `490f39c435e1f6c01563f8548a7d91c62848a5ea`
Scope: descriptor-relative planning-vault access, bounded publication, crash recovery, cancellation, cleanup, cache, native picker, and probe harness.

## Acceptance

- Astra Medium: **ACCEPT** after source review of all Packet C files and prior findings.
- Focused Mac lane: **84/84 passed**, serial (`-jobs 1 -parallel-testing-enabled NO`): 57 durability tests and 27 filesystem tests.
- Fresh crash probe: **21/21 recovery cases passed** across create/replace/delete at p1–p7.
- Adversarial probe: same-inode conflict preserved; symlink, hardlink, FIFO, and parent-substitution attacks blocked; outside sentinel preserved.
- iOS device-SDK compile: `BUILD SUCCEEDED` with `CODE_SIGNING_ALLOWED=NO`.
- `git diff --check`: clean; no generated Xcode project staged.

The final regression covers cancellation after a journal `.prepared` row exists but before parent creation and manifest persistence, followed by reopen and successful recovery. Manifest reconstruction is allowed only for a nonlegacy prepared attempt with no witness/staged identity after immutable request and journal context validation. Existing manifests and witnessed/staged attempts use full lineage validation.

## Verification commands

```text
xcodebuild -project ios/LifeOS.xcodeproj -scheme LifeOSMacLogic -destination 'platform=macOS' -derivedDataPath /private/tmp/lifeos-packet-c-regression-mac-20260919 -resultBundlePath /private/tmp/lifeos-packet-c-regression-mac-20260919.xcresult -jobs 1 -parallel-testing-enabled NO -only-testing:LifeOSMacSnapshotTests/PlanningDurabilityTests -only-testing:LifeOSMacSnapshotTests/PlanningFilesystemTests CODE_SIGNING_ALLOWED=NO test
bash scripts/run_planning_packet_c_probes.sh prepare /private/tmp/lifeos-packet-c-final-probe-accept3
bash scripts/run_planning_packet_c_probes.sh crash /private/tmp/lifeos-packet-c-final-probe-accept3
xcodebuild -project ios/LifeOS.xcodeproj -target LifeOS -destination 'generic/platform=iOS' -sdk iphoneos -jobs 1 CODE_SIGNING_ALLOWED=NO build
```

## Accepted source hashes

```text
ios/Planning/PlanningMutationJournal.swift  fabd2bb0b15e27211ae777dce9e9798467ac52e22dab98f044a2abf6284b5c14  (3782 lines)
ios/Planning/PlanningPublicationDomain.swift  20e7feb3de22f36af64bbb9df4097ddb359876b4557ef1089add9be20a69882d  (629)
ios/Planning/PlanningFilesystemDomain.swift  413f3b60b12c20d468c933263a7da36142c6b931ef254b8c9140592bdd9536a6  (475)
ios/Planning/PlanningVaultAccess.swift  d44f5c7f31b3635a851eec03a99817eacd325cf6c9cf61d4f40da621eb11b2a0  (1031)
ios/Planning/PlanningSafeFileIO.swift  ebf70b71eb283f98b4c95d48a2859b7fb9c9a052c25d7e175db4c1e1f4486b3b  (1643)
ios/Planning/PlanningCoordinatedAccess.swift  612f5cb53f46bba52c6c69c0973f905b22f55bdff6dc684b006b82e8fc2b4d8e  (359)
ios/Planning/PlanningFilesystemPublication.swift  018c15f3bfec945cae05e2c069a3504ec61148b354344244207617e2e0f2ce2a  (2485)
ios/Planning/PlanningVaultCache.swift  c9a52bf6a2e2c3c25946d7ab88b7e6f12c152ff6e5926a771b2ac34179181451  (400)
ios/Planning/PlanningVaultStore.swift  5a1bf878d5ee12f2bcfef02e625167d4dcf80a1bffde3b1aa37e2cf28198c2dc  (376)
ios/Planning/PlanningNativeDocumentPicker.swift  627a8774945f554e6e6851f0a5e561e77d2ea78181cf5eb4633b8cc66bad8cfc  (104)
ios/LifeOSTests/PlanningFilesystemTests.swift  e7d013c02abbef19f5e9f6e38c4bd32e28af1d99d8f1580618e0b9adcf49220f  (166)
ios/LifeOSMacSnapshotTests/PlanningFilesystemTests.swift  c94f74f6b9d00f81294175931515f8ba1de84b3e6254719893d42811c04c06a0  (1461)
scripts/planning_packet_c_probe.swift  b89a2d05f1729dd2537cbad07cc02b298e97772dba6d13fea54f887fce77bfca  (554)
scripts/run_planning_packet_c_probes.sh  780e9fc681cb36df7b8629ae0c3f96f1522562b35cc1d095da54082fb256dcf0  (117)
```

## Boundaries

This acceptance is for Packet C’s locally verified filesystem adapter. Signed production entitlements, iCloud provider behavior, physical iPhone behavior, Windows/network integration, and full UI/animation visual QA remain separate release gates.
