# iPhone Life OS

A native SwiftUI + WidgetKit Life OS for iPhone and Mac. The interface uses
SF Pro/system typography, dark mode as a first-class target, compact hierarchy,
provenance-first live data, and explicit unavailable states. Synthetic demo
data is only for explicit visual-test launch arguments and never represents
live telemetry.

## P00 execution checkpoint

The current local checkpoint is 328b18e16bcbb5856db40b0ffd3f90101a051096 on
main, matching the locally observed origin/main. Release remains NO-GO.
P00 recorded 258 frozen requirement leaves, 7 aliases, current source hashes,
receipt-scoped evidence, and host/profile capability facts in
artifacts/final/completion/requirements.json and capabilities.md.

The native source is the product. The React/browser dashboard is reference
only. The eight D1 planning files remain untracked candidate work awaiting P05
review. Windows was not contacted during P00; live providers, physical iPhone,
signing, App Group, widgets, iCloud and final visual/security gates remain
unverified.

## Run and verify the reference harness

    npm ci
    npm run api
    npm run dev
    npm run preview
    npm test
    npm run typecheck
    npm run lint
    npm run build

## Product boundary

Use truthful live data. Calendar, finance, HealthKit/Zepp, Obsidian, tax,
usage and widgets keep their own authority. No generic advisor or
conversational AI is allowed; calorie-photo estimation is the only in-app AI
flow. Windows over Tailscale is a private structured-data/document boundary.

A free Apple Personal Team profile expires after seven days and cannot renew
itself from the installed app. The app reports signing state and guidance; it
does not claim perpetual self-renewal.

## Privacy and publication policy

Do not publish personal exports/imports/uploads, HealthKit/finance/account
data, credentials, coordination state, runtime databases/snapshots/logs,
machine-specific build/signing files, or media. Demo fixtures stay synthetic
and visibly labelled. Review ignored files before any public release.
