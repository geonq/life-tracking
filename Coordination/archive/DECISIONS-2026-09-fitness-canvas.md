## P04 fitness payload checkpoint

- `b0e52e1` adds strict training serialization, bounded canonical JSON, NFC wire normalization, finite/fractional numeric handling, and parser/domain regressions; it is serialization only and CP-B still blocks durable store adapters.
- Astra static review passed. The Xcode 27 Mac lane passes 379/379 native
  tests and the iOS 27 simulator logic lane passes 1,837/1,837; signed UI and
  physical-device evidence remain open.

## 2026-09-22 P06-A native Canvas checkpoint

- `4ff27e3` is pushed on main and origin/main after Astra PASS. It adds the
  native viewport, AppKit/UIKit input bridge, owner tokens and touch quarantine,
  shared node/edge geometry, cached presentation queries, retry recovery, and
  focused platform regressions. Main macOS evidence is 405/405 full and 19/19
  focused; final worker iOS evidence is 18/18 focused plus generic build.
- This is a bounded Canvas tranche. Vault routing, inspector/document flows,
  Calendar integration, CP-B adapters, signed UI, physical-device input, and
  external provider evidence remain open.

## 2026-09-22 Apple lane resource hygiene

- Apple validation runs through `scripts/validate_apple_on_mac.sh` or
  `scripts/run_prerelease_lanes.sh`, never through multiple ad-hoc xcodebuild
  lanes. Keep `-jobs 1`, disable parallel test destinations, use one simulator,
  and preserve separate log/result/DerivedData paths.
- Both lane scripts own a simulator cleanup trap. If a command is interrupted,
  inspect the exact xcodebuild/xctest process tree, stop only the owned stalled
  process, then run `simctl shutdown` and verify no LifeOS test process or booted
  simulator remains before starting another lane.
- A long silent interval during first-use simulator runtime preparation is not
  evidence of a dead test. Read the owned log and process state first; do not
  start a second lane or kill Apple CoreSimulator daemons while preparation is
  progressing.
