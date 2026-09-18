# HANDOFF — LifeOS native app

Updated 2026-09-18 Europe/Berlin.

## Active task

Continue after the validated usage-management and LifeOSMac stability
tranches. Keep the release verdict honest; do not call the product done.

## Current truth

- Release is **NO-GO**. `main` is clean and pushed at `4db1eaa` (coordination
  checkpoint after `dfeab04`), on top of Mac Home `d2ece98` and Canvas `f53c77c`;
  earlier checkpoints: `4856fae`, `1d57435`, `5aa3fb1`, `1956569`, `273f4dd`.
- Windows verification uses disposable staging at
  `C:\Users\domke\lifeos-a2-snapshot-20260916`; canonical install/recovery remain
  untouched. `LifeOSGateway` is absent and `LifeOSAPI` stopped.
- Canonical SSH readback: Tailscale running, `LifeOSAPI` stopped, `LifeOSGateway`
  absent, no listener, legacy task Ready, BitLocker on C:/D:. Marker is active
  with an `artifacts-complete` journal and 31,401 units; recovery is separate.
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
- Storage guard `bash -n` and **10/10** tests pass. It reports and explicitly
  cleans only direct-child `lifeos-derived-*` caches, with trailing-slash,
  nested, symlink, and process-probe coverage. Seven old repo caches totaling
  about 14 GiB were removed; the post-cleanup check reports 33 GiB free,
  11 GiB Developer root, and 710 MiB global DerivedData. CoreSimulatorService
  is unavailable; the kept iPhone 17 entry remains.
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
- The manual Google AI Pro/Gemini subscription packet is committed at
  `1d57435`. It adds strict bounded manual readings, canonical used/remaining
  conversion, advancing freshness, provider-neutral reviewed actions, fixed
  HTTPS destinations, rollback-safe persistence, and coordinator
  persistence-before-publication. Focused macOS tests are **22/22**, the full
  serialized Mac logic suite is **192/192**, and the generic iOS device SDK
  build reports `BUILD SUCCEEDED`. Astra Medium re-review is **MERGE**;
  simulator/UI runtime remains unverified.
- The bounded Usage hierarchy follow-up is pushed at `4856fae`. It passes the
  focused Mac visual lane **4/4** with an independent xcresult check and the
  generic iPhone SDK build reports `BUILD SUCCEEDED`. It adds compact
  remaining/Used presentation, reset context, collapsed provenance, estimated
  versus observed color semantics, and a visible Settings action for an
  unavailable source. The disconnected fixture is verified; populated live
  registry rendering, simulator runtime, and whole-app visual acceptance
  remain open.
- After `4856fae`, the serialized full Mac logic lane completed **192/192**
  with exit 0 and `** TEST SUCCEEDED **`; `scripts/validate_xcresult.py`
  independently reported `192/192` passed. The test-host linkd/SceneStorage
  messages are environment warnings, not failures.
- Validated live finance readback is pushed at `1956569` and reviewed by Astra
  Medium **MERGE**. The packet canonicalizes recognized bank aliases before
  grouping, uses bounded content-type-checked readback parsing, keeps exact
  signed cents, separates current bank cash from non-live imports, preserves
  consent/failure/cancellation precedence, and ages account, transaction,
  wealth, metric, and row provenance timestamps. Controller evidence is
  macOS focused finance **25/25 passed** and iOS device SDK
  `build-for-testing` succeeded. Simulator execution remains unavailable.
- Tax parser security scanner is pushed at `f62ef9e` after Astra approval;
  actual-source probes and serial iOS SDK build-for-testing pass, including
  grouped/legacy labels, malformed boundaries, and oversized cancellation.
- Cross-process UsageHistory locking is pushed at `dfeab04`; Astra accepted
  after two reviews: 55 focused/160 full API tests and typecheck/build/diff
  pass; transaction serialization, monotonic deadlines, authenticated release
  and fail-closed orphan locks are covered.
- Canonical Windows read-only preflight is **STOP/NO-GO**; receipt:
  `artifacts/final/windows/preflight-4db1eaa-20260918.md`. SSH/local gates pass;
  journal/progress, ACL/reparse, writer provenance and candidate identity remain open.

## LifeOSMac stability receipt

- The bounded Mac Home repair is pushed at `d2ece98`: centered 1200pt
  composition, restrained native-SF hierarchy, equal-height cards, and a
  clean unavailable row. Geometry checks passed **2/2**; the dark acceptance
  snapshot passed **1/1** with six kept captures at 800x600, 1200x800, and
  1512x982; manual inspection accepted both states.
- The current post-`f53c77c` serialized Mac logic lane completed **193/193**
  with exit 0; the independent validator passed. A focused stability lane
  completed **1/1** while an isolated manual LifeOSMac build stayed alive.
  The three older `EXC_BAD_ACCESS` reports are temporary XCTest hosts. One
  additional `SIGABRT` was produced only by an invalid direct-Mach-O launch;
  its unified log shows sandbox-denied WindowServer/LaunchServices services.
  The normal LaunchServices fixture run produced no new crash. The visual
  fixture launcher now stages the manual app under
  `com.hermes.lifeos.mac.visual-fixture`, so UI-test terminate/relaunch calls
  cannot close the window under inspection. Receipt:
  `artifacts/final/stability/2026-09-18-lifeosmac.md`.

## Storage policy

- `scripts/maintain_macos_storage.sh` is report/dry-run by default; `--apply`
  deletion is scoped, skips booted simulators, refuses active/uncheckable
  `xcodebuild`, and fails build lanes below a 15 GiB floor.
- Apple lanes call the guard before every lane, use serialized
  `xcodebuild -jobs 1`, and have no scheduler.
- Guard is required before Apple lanes; generated DerivedData/evidence have
  owned paths, while source, personal data and the kept simulator are outside.

## Open gates

- Live-bank recurring reconciliation, Robinhood/net-worth verification, and
  live provider readback.
- Automatic Gemini authentication/quota transport and Google AI Pro readback
  remain open; the native manual boundary does not claim live quota.
- Canonical Windows preflight/recovery/install/listener/health/Serve/Enable
  Banking readback; the current diagnostic receipt is STOP/NO-GO.
- Finance live connector/import/recurring/net-worth work; Zepp workouts;
- Obsidian Canvas durable store, conflict journal, graph/spatial index, native
  views, gateway route, widgets, Shortcuts, signing, physical iPhone.
- Whole-app visual/runtime acceptance remains open; current UI slices are
  evidence for those slices only, not product-wide approval.
- Canonical Windows recovery is pending operator approval for the
  transaction-bound rollback; automatic review blocked the mutating action.

## Next action

Use `4db1eaa` plus the stability, Canvas, tax, usage-lock, and Windows preflight
receipts. Continue the strict disposable diagnostic, then canonical recovery,
live finance/net-worth, Canvas, fitness, widgets/Shortcuts/signing, visual
acceptance and final security; do not rerun the full Mac suite without a code
change or relevant failure.

## Validation discipline

Serialized Xcode lanes may be quiet for several minutes while Swift compiles
or links. Poll until the command exits and inspect its explicit success or
failure marker plus the result bundle. Stop only for a clear failure, a
proven hang, or a storage/process safety issue; an interrupted lane is
unverified and must be rerun before its result is used.

## Blockers

No blocker on source/disposable Windows evidence. Installed-service, canonical
deployment, simulator runtime, physical device, live providers, and final
visual acceptance are external or environment-bound and remain unverified.

## Obsidian Canvas codec receipt

- `f53c77c` adds the bounded JSON Canvas 1.0/Markdown codecs, value-only vault
  binding, source inclusion, and focused tests. Astra Medium approved the
  actual final diff after the lossless-number, path, YAML, extension, and
  quoted-key corrections.
- Focused codec evidence is **31/31**; an independent smoke harness passed
  empty/nodes-only Canvas, raw extension values, large numbers, escape-heavy
  text, CRLF Markdown, quoted duplicate-key fallback, and exact source
  retention. The harness was removed after the run.
- The post-commit serial `LifeOSMacLogic` lane is **193/193** with exit 0;
  `scripts/validate_xcresult.py` independently reports 193/193. The generic
  iOS lane remains compile-only because CoreSimulator has no runtime.
- This packet has no vault writes, durable store, UI, graph index, gateway
  route, conflict journal, or sync behavior. Those remain later packets.
