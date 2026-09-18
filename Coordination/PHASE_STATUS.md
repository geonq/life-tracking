# PHASE STATUS — LifeOS

Updated 2026-09-18 Europe/Berlin.

- Release: **NO-GO**.
- Current pushed checkpoints are `4856fae` (`Refine usage registry hierarchy`),
  `1d57435` (`Add manual Gemini usage tracking`), and `5aa3fb1` (`Guard repo
  build cache cleanup`). Earlier finance and registry checkpoints are
  `1956569` and `273f4dd`.
- Windows disposable static, legacy Serve, native progress, native snapshot,
  and complete behavior suites pass. Behavior has one installed-service skip;
  canonical deployment remains unverified.
- Fresh canonical SSH readback shows Tailscale running, `LifeOSAPI` stopped,
  no `LifeOSGateway` service, no LifeOS listener, and only the legacy sync
  task in Ready state. The marker is still `active` with an
  `artifacts-complete` journal of 31,401 units; no recovery process is active.
  Canonical recovery remains unverified.
- Local source harness is 75 passed/2 skipped. Native C# compile has 0 errors.
- Storage guard `bash -n` and **10/10** tests pass. It now owns direct-child
  `lifeos-derived-*` caches and fail-closed process probes. Seven old caches
  totaling about 14 GiB were removed; the post-cleanup check reports 33 GiB
  free. CoreSimulatorService is unavailable; the kept iPhone 17 entry remains.
- Apple lanes check storage before every lane and serialize xcodebuild.
- Finance institution detection/importer is pushed and Astra Medium reviewed
  **MERGE**. Native Mac logic is 55/55; generic iOS test build succeeds;
  simulator execution remains unavailable.
- Finance mapping/preview, content-free provenance, mapped-v3 account and
  configuration identity, cross-device account relabeling, deterministic
  persistence, legacy attempted-request recovery, duplicate/reimport fences,
  and gateway identity validation are pushed at `5fe26a4`. The bounded Mac
  finance suite is 17/17; Mac build-for-testing, contracts (199/199),
  contract typecheck, Swift parse, gateway AST, and diff checks pass. Astra
  Medium returned **MERGE**.
- The local mapped-v3 recurring-payment packet is pushed at `453d304`. Its
  serial macOS build-for-testing and recurring/import suites pass 56/56;
  final Astra Medium review returned **MERGE**. Live-bank reconciliation is
  still separate.
- Finance investment validation is pushed at `8c1a225`; the provider-neutral
  native AI usage watcher registry tranche is pushed at `273f4dd`. The focused
  finance suite passes 21/21; contracts typecheck and build cleanly and pass
  212/212 tests. Astra Medium returned **MERGE**. The native AI usage watcher
  registry tranche is now validated:
  Claude remains supported; Gemini subscription/Google AI Pro and Gemini API
  are honest manual/unsupported boundary rows with no fabricated quota or
  observations; legacy GLM/DeepSeek/Google AI Studio observations remain
  visible as `legacyValidated` nonofficial data. Exact connection/window
  selection, evidence policy, bounded preferences, atomic conversion failure,
  failure retention, and reset/draft safety are covered. Focused macOS
  registry/coordinator tests pass 14/14 in the elevated lane; Mac compile and
  iPhone device SDK build pass. iOS simulator build remains environment-
  blocked because no runtime is available and `simdiskimaged` is unhealthy.
- Validated live finance readback is pushed at `1956569` and Astra Medium
  reviewed **MERGE**. Controller evidence: the focused macOS finance suite is
  **25/25 passed** and the iOS device SDK `build-for-testing` succeeded. The
  packet covers bounded readback parsing, source alias canonicalization, exact
  cents, bank-cash separation, source/row timestamp aging, and
  consent/failure/cancellation precedence. Simulator execution remains
  environment-blocked.
- The manual Google AI Pro/Gemini subscription watcher packet is committed at
  `1d57435`: bounded validated readings, used/remaining conversion, advancing
  freshness, fixed reviewed connection actions, rollback-safe UserDefaults,
  and persistence-before-publication. Focused Mac tests are **22/22**; the
  serialized full Mac suite is **192/192**; generic iOS device SDK build
  succeeds; Astra Medium re-review returned **MERGE**. Simulator/UI runtime
  remains unavailable.
- The Usage hierarchy follow-up is pushed at `4856fae`: focused Mac visual
  tests **4/4** passed with an independent xcresult check and the generic
  iPhone SDK build reports `BUILD SUCCEEDED`. The disconnected fixture is
  verified; populated live registry rendering and whole-app visual/runtime
  acceptance remain open.
- The post-visual full serialized Mac logic lane completed **192/192** with
  exit 0; the xcresult validator independently reports **192/192** passed.
  linkd/SceneStorage test-host messages are warnings only.
- Existing reviewed slices cover calendar security, Usage/Finance/Fitness,
  shell/navigation, tax accessibility, installer boundary, and API security.
- Open: live recurring reconciliation, Robinhood/net-worth, canonical Windows
  install/readback, live finance/providers, automatic Gemini auth/quota
  transport and subscription readback, workouts, Obsidian Canvas,
  widgets/Shortcuts/signing, physical iPhone, whole-app visual and runtime
  acceptance, final security review.
- Canonical Windows recovery is pending explicit operator approval because the
  transaction-bound rollback mutates services and restored files; automatic
  review blocked that action until approval.
- Astra Medium reviewed the corrected Windows/storage candidate **MERGE** with
  no blocking source findings. Canonical and concurrent-race evidence remain
  unverified.
- Next: continue live recurring reconciliation and verified Robinhood/net-worth
  work, then Zepp/workouts, Obsidian Canvas, widgets/Shortcuts/signing, visual
  acceptance, and final security. Every Apple lane must retain the storage
  preflight and use the repo-cache cleanup option when needed.

Keep the product boundary: truthful live data, SF Pro, compact Linear/Vercel
quality, no generic AI, and calorie-photo AI only.

Xcode lanes are serialized and must be polled to exit. Quiet Swift compile or
link phases can take several minutes; an interrupted lane is unverified and
must be rerun. Stop early only for a clear failure, proven hang, or resource
safety issue.
