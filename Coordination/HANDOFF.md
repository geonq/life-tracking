# HANDOFF — LifeOS native app

Updated 2026-09-18 Europe/Berlin.

## Active task

Continue after the validated usage-management and LifeOSMac stability
tranches. Keep the release verdict honest; do not call the product done.

## Current truth

- Release is **NO-GO**. `main` is clean and pushed at `58a0902` (`test:
  isolate Mac visual fixture from UI host`), on top of `f53c77c` (`feat: add
  bounded Obsidian Canvas codecs`). Earlier source checkpoints remain
  `4856fae`, `1d57435`, `5aa3fb1`, `1956569`, and `273f4dd`.
- Windows verification uses disposable staging at
  `C:\Users\domke\lifeos-a2-snapshot-20260916`; canonical installation and
  recovery remain untouched. `LifeOSGateway` is absent and `LifeOSAPI` stopped.
- Fresh canonical SSH readback confirms Tailscale is running, `LifeOSAPI` is
  stopped, `LifeOSGateway` is absent, no LifeOS listener is bound, and the
  legacy `LifeOSSyncServer` task is only Ready. BitLocker is on for C: and D:.
  The marker remains `active`; its bound journal is `artifacts-complete` with
  31,401 units and no recovery process is running. Canonical recovery is not
  complete and remains separate from disposable evidence.
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

## LifeOSMac stability receipt

- The current post-`f53c77c` serialized Mac logic lane completed **193/193**
  with exit 0; the independent validator passed. A focused stability lane
  completed **1/1** while an isolated manual LifeOSMac build stayed alive.
  The three older `EXC_BAD_ACCESS` reports are temporary XCTest hosts; no new
  LifeOSMac crash report appeared during reproduction. The visual fixture
  launcher now stages the manual app under
  `com.hermes.lifeos.mac.visual-fixture`, so UI-test terminate/relaunch calls
  cannot close the window under inspection. Receipt:
  `artifacts/final/stability/2026-09-18-lifeosmac.md`.

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
  subscription readback; the native manual boundary is complete but does not
  claim live quota.
- Canonical Windows install/listener/health/Serve/Enable Banking readback.
- Finance live connector/import/recurring/net-worth work; Zepp workouts;
- Obsidian Canvas durable store, conflict journal, graph/spatial index, native
  views, gateway route, widgets, Shortcuts, signing, physical iPhone.
- Whole-app visual/runtime acceptance remains open; current UI slices are
  evidence for those slices only, not product-wide approval.
- Canonical Windows recovery is pending explicit operator approval for the
  transaction-bound rollback command; automatic review blocked that mutating
  action until approval is present.

## Next action

Use `f53c77c` plus the stability and Canvas receipts as the source of truth. Continue with
the canonical Windows candidate/preflight and recovery packet, then live
finance/net-worth reconciliation, Canvas durability and native interaction,
Zepp/workout evidence, widgets/Shortcuts/signing, visual acceptance, and the
final batched security review. Do not rerun the full Mac suite without a code
change or a relevant failure.
Keep each packet reviewed and reflected in these short handoff files.

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
