# iPhone Life OS

A native SwiftUI + WidgetKit Life OS for iPhone and Mac. The interface uses
SF Pro/system typography, dark mode as a first-class target, compact hierarchy,
provenance-first live data, and explicit unavailable states. The calendar is a
writable local task system with bounded icons, progress, date/time ranges, and
widgets. Synthetic **Demo data** is available only behind explicit visual-test
launch arguments and is never presented as live telemetry.

## Public-source boundary

This public repository is `geonq/life-tracking`. Native SwiftUI in `ios/` is the product implementation. The React/browser dashboard is reference-only and must not be treated as the iOS implementation. Public files include source, tests, reproducible Demo fixtures, contracts, project configuration, plists, and the local API harness.

Never commit personal exports/imports/uploads/audio/media, HealthKit/finance/account data, credentials, Hermes coordination or planning state, runtime databases/snapshots/logs, or machine-specific Xcode/build/signing files. `.gitignore` protects these classes globally; review additions before publishing. Demo fixtures are synthetic and must remain obviously labeled.

## Run and verify the reference harness

```sh
npm ci
npm run api       # API binds to localhost:8787
npm run dev       # reference dashboard (same-origin /api proxy)
npm run preview   # production build preview (run after npm run build)
npm test
npm run typecheck
npm run lint
npm run build
```

## Native status and limitations

The repository contains shared iOS/macOS calendar, app, finance, fitness,
usage and WidgetKit source plus a macOS validation path. The current serial
Mac logic lane passes 193/193; generic iOS SDK builds pass. CoreSimulator is
currently unavailable, so iOS interactions, physical HealthKit, App Group,
signing, background refresh and WidgetKit rendering remain device gates. Live
finance/backend deployment and the Obsidian Canvas durability/UI/transport
implementation are still open. The bounded Canvas/Markdown codec packet is
committed at `f53c77c` and passes focused round-trip checks. The usage registry
is provider-neutral: Claude remains supported,
Gemini subscription readings are manual until an official quota endpoint is
verified, and Gemini API usage is a separate product.

A free Apple Personal Team profile expires after seven days and Apple requires periodic reprovisioning. An installed app cannot replace its own signature. The app therefore reports signing state/guidance without claiming self-renewal; continuous free refresh requires an external workflow such as SideStore/AltStore, subject to their security and availability constraints.

## Privacy and publication policy

Publish only source, tests, synthetic Demo fixtures, `project.yml`, plists, entitlements, documentation, and the reference harness. Do not publish coordination/planning files, Hermes state, machine metadata, Xcode user/build products, runtime snapshots/databases/logs/caches, imports/exports, personal records, credentials/signing profiles, or audio/video/media. Review `git status --ignored` and `git check-ignore` before any public release. No open-source license is selected here; do not infer redistribution permission until the owner adds one.
