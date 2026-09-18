# PHASE STATUS — LifeOS

Updated 2026-09-18 Europe/Berlin.

## Release state

- Release: **NO-GO**.
- `main` and `origin/main` are aligned at `d2ece98`.
- The acceptance registry remains frozen at 258 leaves, 7 aliases, and 0
  formally accepted leaves. This is an evidence ledger, not a percentage.
- The old `worker/t11a-shared-visual-foundation` branch is patch-equivalent to
  `main`; no unmerged source was found.

## Verified source and local evidence

- Windows disposable static, legacy Serve, native progress, native snapshot,
  and behavior suites pass: 75 source checks, 2 environment skips; native C#
  extraction has 0 errors and 31 nullable/platform warnings.
- Storage guard syntax and tests pass 10/10. Apple lanes are serialized and
  reject active builds or less than 15 GiB free space.
- Finance source packets cover institution mapping, bounded import/reimport,
  recurring suggestions and Manage Payment, investments/Robinhood validation,
  and bounded live-readback parsing. Recorded focused Mac counts are 17/17,
  56/56, 21/21, and 25/25; contract counts are 199/199 and 212/212.
- Usage source packets cover provider-neutral registry management and honest
  manual Gemini subscription readings. Focused counts are 14/14, 22/22, and
  4/4 for the hierarchy visual slice.
- The current serialized Mac logic lane completed **193/193** with exit 0 and
  independent xcresult validation.
- The isolated LifeOSMac stability lane completed **1/1**. A separately
  launched manual build remained alive throughout. The existing three
  `EXC_BAD_ACCESS` reports are temporary XCTest hosts. A separate `SIGABRT`
  came only from executing the Mach-O directly under the sandbox; the normal
  LaunchServices fixture produced no new crash. See
  `artifacts/final/stability/2026-09-18-lifeosmac.md`.
- Mac visual checks now use `scripts/launch_macos_visual_fixture.sh`, which
  stages an unsigned fixture under a dedicated bundle ID. A focused UI test
  failed its existing calendar assertion while the isolated fixture remained
  open before, during, and after the run; the host collision is fixed.
- The Mac Home repair is pushed at `d2ece98`. Geometry checks pass **2/2**;
  the exact dark 800x600, 1200x800, and 1512x982 populated/unavailable snapshot
  matrix passes **1/1** with six kept attachments and manual visual approval.
- Generic iOS device SDK/build-for-testing lanes compile. CoreSimulator is
  unavailable and `simdiskimaged` is unhealthy, so iOS interactions remain
  unexecuted.
- The Obsidian Canvas codec/binding packet is pushed at `f53c77c`. Focused
  codec tests are **31/31**, the independent smoke harness passed, and the
  post-commit serial Mac logic lane is **193/193** with independent xcresult
  validation. It is value-only: durable vault storage, UI, graph projection,
  gateway transport, and sync are still open.

## Backend state

- Tailscale and BitLocker are healthy on GEONQSERVER.
- Canonical `LifeOSAPI` is stopped, `LifeOSGateway` is absent, no LifeOS
  listener is bound, and the legacy `LifeOSSyncServer` task is Ready.
- Disposable staging exists at
  `C:\Users\domke\lifeos-a2-snapshot-20260916`; canonical install/recovery is
  still separate. A marker-bound recovery journal is recorded at
  `artifacts-complete`; no recovery process is active.
- The actual `.ts.net` SSH endpoint is
  `domke@geonqserver.tail5f8789.ts.net`; the earlier `tailscaleip` placeholder
  is not resolvable.

## Open gates

- Canonical Windows candidate verification, supervised recovery/install,
  service/ACL/Serve/health/readiness/listener readback, and rollback receipt.
- Real Enable Banking consent/readback, live recurring reconciliation, and
  verified Robinhood/Trade Republic/net-worth reconciliation.
- Obsidian Canvas codecs and value binding are source-complete and tested;
  durable vault store, conflict journal, graph/spatial index, native views,
  gateway route, and live round-trip wiring remain open.
- Zepp-to-HealthKit workout provenance and field accuracy require a physical
  iPhone and real samples. Zepp proprietary readiness/load/PAI/Training Effect
  remains unsupported without a legitimate source.
- Widgets, lock-screen rendering, App Group, personal signing renewal, native
  Shortcuts, background refresh, and physical iPhone behavior.
- Whole-app visual/motion acceptance and final batched security review,
  including tax regex/privacy, cross-process usage writes, and deployed
  identity-bound transport.
- Automatic Gemini subscription quota/authentication remains unsupported until
  an official endpoint is verified. Gemini API usage remains a separate
  product. No generic advisor AI is permitted.

## Operating rules

- One Luna Max implementation worker at a time; Astra Medium reviews actual
  diffs/evidence in batches. Exact file boundaries are mandatory.
- Every tranche gets focused tests, an Astra review, a commit, a push, and
  local/remote SHA parity before the next tranche.
- Use real data where available; unavailable states remain unavailable and
  fixtures are explicit only.
- Use `xcodebuild -jobs 1 -parallel-testing-enabled NO`; poll until exit. A
  quiet compile is not a stop condition. Record an interrupted lane as
  unverified and rerun it when relevant.
- Stop completed disposable apps/builds through targeted cleanup only. Never
  run broad `killall` or delete an active result/cache.
