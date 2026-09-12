# TODO — LifeOS completion gates

Updated 2026-09-12 Europe/Berlin.

Release state: **NO-GO**.

## Critical path

1. Implement a bounded AppKit route host/reducer.
2. Implement and wire a coherent Usage packet/reducer.
3. Obtain Astra review of both bounded UI changes.
4. Run real target builds/tests and runtime visual checks.
5. Complete Windows recovery, fresh install, resume/recovery, listener and
   health verification, Enable Banking readback, and Tailscale Serve readback.
6. Complete final security and product gates.

## Verified checkpoint

- Clean branch `lifeos-foundation-checkpoint-20260812`; HEAD and origin are
  `e919bed`, `Fix recovery success stream output`.
- Windows source suite with loopback permission: **61 passed, 1 skipped, 0
  failed**. The single skip is Windows PowerShell 5.1 unavailable on Mac.
  `Restore-ManifestArtifacts` success-stream values are suppressed at four
  call sites; Astra Medium Windows review is **GREEN**.
- Remote recovery is **NOT complete**. After the stopped recovery attempt
  (memory growth/stall), journal and backup were retained. Manual restoration
  of captured legacy state left replacement `LifeOSAPI` stopped,
  `LifeOSGateway` absent, `LifeOSSyncServer` Ready/enabled, and no replacement
  listeners verified.
- Native UI patch is **NOT merged** and is reverted to clean baseline. Astra
  Medium was **RED** for recursive live-destination rehosting/unbounded
  composition, Usage identity/reset defects, missing shell Home-detail anchor
  capture, and inadequate production sequence tests.

## Explicitly unverified

Do not claim live finance/provider data, Zepp workout accuracy/sync, Obsidian
mind-map behavior, real AppKit pixel continuity, physical iPhone/widget
behavior, signing renewal shortcuts, or final security GREEN until separately
evidenced.

Preserve prior GREEN source/security tranches and design references, including
shared foundation `6751bb5`, ChartKit/Usage `6713de1`, empty-state/icon/tax
privacy `82b4eb1`, Calendar density `b05c4fb`, Usage presentation `8c2c097`,
and source security review `eb9ca620…`.

Rejected artifacts:

- `/private/tmp/lifeos-rejected-ui-e919bed.patch`
- `/private/tmp/lifeos-usage-reducer-unintegrated-e919bed.patch`

No generic conversational assistant/advisor/AI or Claude usage watcher is part
of the product; calorie-photo tracking is the only permitted in-app AI flow.
