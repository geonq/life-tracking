# HANDOFF — LifeOS native app

Updated 2026-09-17 Europe/Berlin.

## Active task

Continue after the validated native AI usage watcher registry tranche.
Keep the release verdict honest; do not call the product done.

## Current truth

- Release is **NO-GO**. `main` and `origin/main` are at the latest pushed
  checkpoint `273f4dd774dd7ba9dd5669799a1549bb5dd98181` (`Add provider-neutral
  native usage watcher`). The 2026-09-17 native usage registry tranche is
  committed and pushed in that checkpoint.
- Windows verification uses disposable staging at
  `C:\Users\domke\lifeos-a2-snapshot-20260916`; canonical installation and
  recovery remain untouched. `LifeOSGateway` is absent and `LifeOSAPI` stopped.
- No generic advisor, conversational AI, or demo fallback is allowed. Calorie
  photo tracking is the only in-app AI feature. The Usage module retains the
  Claude watcher and now has a provider-neutral native registry over the
  validated v1 transport. Gemini subscription/Google AI Pro and Gemini API
  are cataloged honestly as manual/unsupported boundary rows with no
  fabricated quota or observations; automatic Gemini auth/quota transport
  remains open.

## Latest evidence

- Windows static, legacy Serve, native progress, native snapshot, and complete
  behavior suites pass on GEONQSERVER. Behavior has one explicit skip because
  the installed-service branch cannot run without `LifeOSGateway`.
- Native snapshot coverage includes job-tree cleanup, monotonic deadlines,
  restricted stdio handles, ACL/identity checks, ReplaceFileW states 1175/1176,
  partial 1177 recovery, and zero/one/multiple preserved-path diagnostics.
- Local deployment source harness: 75 passed, 2 environment skips. Native C#
  extraction/build: 0 errors, 31 nullable/platform warnings.
- Storage tests: 7 passed, 2 subtests. `bash -n` passes. Storage check reports
  25.1 GiB free, 16 GiB Developer root, 11 GiB device support, and one kept
  shutdown iPhone 17 simulator.
- Finance detector/importer: focused Astra Medium review **MERGE**; optimized
  DEBUG harnesses cover recovery, EOF, escaped quotes, Unicode whitespace,
  and 256/1024/3000-row scan bounds. Mac logic lane: 55/55 tests passed. The
  generic iOS test build succeeded; simulator execution remains unavailable.
- Finance mapping/preview, content-free provenance, mapped-v3 account and
  configuration identity, cross-device account relabeling, deterministic
  persistence, legacy attempted-request recovery, duplicate/reimport fences,
  and gateway identity validation are pushed at `5fe26a4`. The bounded Mac
  finance suite is 17/17; Mac build-for-testing, contracts (199/199), contract
  typecheck, Swift parse, gateway AST, and diff checks pass. The final Astra
  Medium review is **MERGE**.
- The local mapped-v3 recurring packet is pushed at `453d304`: bounded
  weekly/monthly/yearly detection, evidence and overrides, stale/cold/warm
  failure handling, Manage Payment ownership, and post-import refresh. The
  serial macOS build-for-testing passed; the latest recurring/import suites are
  56/56, and the final Astra Medium review is **MERGE**.
- Finance investment validation is pushed at `8c1a225`; the provider-neutral
  native usage watcher tranche is pushed at `273f4dd`. Robinhood activity import is
  strict and separate from
  net-worth evidence; stale FX, incomplete coverage, duplicate economic cash,
  linked-cash overlap, and decoded semantic tampering fail closed. The focused
  macOS finance suite is 21/21 with **TEST SUCCEEDED**. The Usage v2 registry
  retains Claude, models Gemini subscription usage as manual/unsupported until
  an official endpoint exists, and keeps Gemini API usage as a separate
  product; contracts typecheck, build, and pass 212/212 tests. Astra Medium
  final review is **MERGE**.
- Native AI usage watcher registry tranche pushed at `273f4dd` and validated
  2026-09-17: provider-neutral presentation, exact connection/window selection, evidence policy,
  preference bounds, atomic conversion failure handling, failure retention,
  and management reset/draft safety are implemented. Legacy GLM/DeepSeek/
  Google AI Studio observations remain visible as `legacyValidated`
  nonofficial data. Focused macOS registry/coordinator suite: **14/14
  passed** in the elevated lane; Mac compile passed; iPhone device SDK build
  passed. The iOS simulator build is environment-blocked because no runtime
  is available and `simdiskimaged` is unhealthy.

## Storage policy

- `scripts/maintain_macos_storage.sh` is report/dry-run by default; deletion
  requires `--apply`, uses scoped generated paths, skips booted simulators,
  refuses active or uncheckable `xcodebuild`, and fails build lanes below a
  15 GiB floor.
- Apple validation/prerelease lanes call the guard before every lane and use
  serialized `xcodebuild -jobs 1`. No scheduler was added.
- The guard is the required preflight for future Apple lanes. Generated
  DerivedData and validation artifacts have owned paths; source, personal
  data, final evidence, and the kept simulator are outside cleanup scope.

## Open gates

- Live-bank recurring reconciliation, Robinhood/net-worth verification, and
  live provider readback.
- Automatic Gemini authentication/quota transport and Google AI Pro
  subscription readback; the native boundary rows intentionally do not claim
  live quota.
- Canonical Windows install/listener/health/Serve/Enable Banking readback.
- Finance live connector/import/recurring/net-worth work; Zepp workouts;
  Obsidian Canvas round trip; widgets, Shortcuts, signing, physical iPhone.
- Whole-app visual/runtime acceptance remains open; current UI slices are
  evidence for those slices only, not product-wide approval.

## Next action

Use this pushed checkpoint as the source of truth. Dispatch the next bounded
finance packet for live recurring reconciliation and the verified
Robinhood/net-worth path. Keep each packet reviewed and reflected in these
short handoff files.

## Blockers

No blocker on source/disposable Windows evidence. Installed-service, canonical
deployment, simulator runtime, physical device, live providers, and final
visual acceptance are external or environment-bound and remain unverified.
