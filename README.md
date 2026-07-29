# iPhone Life OS

A native SwiftUI + WidgetKit Life OS for iPhone and Mac. The branded interface follows system appearance with dark mode as a first-class visual target while retaining an adaptive light mode. Usage dashboards remain read-only and provenance-first; the calendar is a writable local task system with emoji or bounded local PNG/JPEG icons, progress, date/time ranges, and wide agenda widgets. Synthetic **Demo data** is used for account usage until authorized connectors exist; it is never presented as live telemetry.

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

The repository now contains shared iOS/macOS calendar, app, and WidgetKit source plus a macOS GitHub Actions validation path. Hosted validation runs iOS unit/UI tests with explicit light/dark screenshots and unsigned macOS headless light/dark snapshots. Local PNG/JPEG calendar icons are signature-validated, limited to 256 KiB, stored without filenames or paths, and retain emoji fallback. Local Windows checks still cannot run Xcode, Swift compilation, simulators, signing, or visual WidgetKit rendering; those claims require the hosted macOS workflow or a real Mac/iPhone. The App Group remains a build-setting placeholder and runtime validation fails closed until signing supplies a valid `group.*` identifier. Account usage is Demo-only; HealthKit, authorized external connectors, and Hermes voice capture remain blocked/unimplemented.

A free Apple Personal Team profile expires after seven days and Apple requires periodic reprovisioning. An installed app cannot replace its own signature. The app therefore reports signing state/guidance without claiming self-renewal; continuous free refresh requires an external workflow such as SideStore/AltStore, subject to their security and availability constraints.

## Privacy and publication policy

Publish only source, tests, synthetic Demo fixtures, `project.yml`, plists, entitlements, documentation, and the reference harness. Do not publish coordination/planning files, Hermes state, machine metadata, Xcode user/build products, runtime snapshots/databases/logs/caches, imports/exports, personal records, credentials/signing profiles, or audio/video/media. Review `git status --ignored` and `git check-ignore` before any public release. No open-source license is selected here; do not infer redistribution permission until the owner adds one.
