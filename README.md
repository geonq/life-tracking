# iPhone Life OS

A native SwiftUI + WidgetKit read-only dashboard foundation for a private iPhone Life OS. The current slice serves clearly labeled **Demo data** from typed contracts; it is not live Codex, HealthKit, finance, or Clipper data and is not a system of record.

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

Native generation, Swift compilation, XCTest, signing, widget rendering, and device validation require macOS/Xcode and a real iPhone; this Windows environment cannot validate them. The App Group is deliberately a build setting placeholder and runtime validation fails closed until a real team-configured `group.*` identifier is supplied. HealthKit, App Intents, authorized external connectors, and Hermes voice capture remain blocked/unimplemented. No live metric or connector value is claimed: displayed metrics expose source, freshness, quality, and connector state, and forecasts are explicitly estimates.

## Privacy and publication policy

Publish only source, tests, synthetic Demo fixtures, `project.yml`, plists, entitlements, documentation, and the reference harness. Do not publish coordination/planning files, Hermes state, machine metadata, Xcode user/build products, runtime snapshots/databases/logs/caches, imports/exports, personal records, credentials/signing profiles, or audio/video/media. Review `git status --ignored` and `git check-ignore` before any public release. No open-source license is selected here; do not infer redistribution permission until the owner adds one.
