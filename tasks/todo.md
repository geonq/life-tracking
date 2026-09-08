# TODO — LifeOS completion pass

Updated 2026-09-08 09:40 Europe/Berlin.

## Active queue

1. **Foundation and removal — active Luna Max lane**
   - Delete Advisor Swift/API/contracts/gateway/providers, routes, secrets,
     intents, deep links, tests, and Xcode references.
   - Migrate every custom font call/resource to the SF Pro/system facade.
   - Establish shared page, card, status, button, selector, and sheet tokens.
2. **Windows hardening — active Luna Max lane**
   - Fix Serve validator parity, safe rollback arguments, supported authority
     sidecar evolution, recovered transaction poisoning, and partial snapshots.
3. **Calendar — next Luna Max lane**
   - Give iPhone one bounded vertical timeline scroll region with reachable
     late-day content and one current-time marker assembly.
   - Add bounded Mac trackpad pinch zoom with focal-time preservation and tests.
   - Preserve secure manual pairing, outbox, and DST/cross-midnight semantics.
4. **Finance/Fitness/Nutrition — next Luna Max lane**
   - Apply shared hierarchy and compact truthful states to Finance, Recovery,
     Biology, and Nutrition. Define finance mode/range availability and meal
     draft/save semantics before styling controls.
5. **Widgets/shell/motion — next Luna Max lane**
   - Rework navigation icons, selected rows, all widget families/modes, grey
     wallpaper contrast, and interruptible state-correct animations.
6. **Batched review/integration — Astra Medium then Luna Max**
   - Review foundation+Windows, then Calendar+modules, then widgets/full diff.
   - Run all feasible tests/builds, capture state/interaction evidence, update
     coordination records, and record every remaining external gate.

## Verification commands

- `git diff --check`
- `npm test`
- API build/typecheck/tests and gateway pytest in `/private/tmp/lifeos-gateway-venv`
- Existing unsigned iOS simulator and macOS/widget schemes/scripts
- Widget snapshot tests and Windows source/static tests

## External acceptance gates

Physical iPhone 17 HealthKit/Zepp, Personal Team App Group/signing,
WidgetKit clear/tinted rendering, USB refresh, Enable Banking consent,
Windows PowerShell/service/Tailscale runtime, and durable Mac↔iPhone receipts.
Do not mark completion from simulator or source evidence alone.
