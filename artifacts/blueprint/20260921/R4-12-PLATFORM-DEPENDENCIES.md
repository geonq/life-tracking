# Platform, package and target seal
P16 project.yml retains deployment iOS17.0/macOS14.0. No OS update/device prerequisite for implementing baseline logic.
SWIFT_VERSION remains5.9 (Swift5 language mode), SWIFT_STRICT_CONCURRENCY=complete for app/shared targets;
new actors/DTOs strictly Sendable, no global MainActor default/no @unchecked blanket suppression. Existing UI MainActor explicitly.
No new SwiftPM package. CryptoKit/Security/Foundation/SQLite/SwiftUI/WidgetKit/AppIntents/HealthKit are Apple frameworks.
New code under ios/Sync included app targets and signer only as explicit list, not directory glob into widgets/tests.
Widget target receives only shared model/projector/style files it needs; never app services, key store, network or full intent composition.
Signer target macOS command-line tool, sources SignerCLI.swift/SyncWireCodec.swift/SyncIdentityStore.swift/SyncContract.swift/DomainWireValues.swift,
linked Security/CryptoKit/Foundation; no HealthKit/UIKit. P01 owns definitions, P16 single target-membership writer.
Any test source kept test target only;8 existing graph candidates retained and reviewed as existing implementations of R2-P05 signatures.

## OS27 compiler-safe decision
R2 platform17 matrix remains researched authority; baseline modifiers always implemented first.
Do NOT add undefined SDK27 symbols to baseline compilation. PlatformVisualAdapter uses existing SwiftUI transition fallback on all builds.
Optional enhancement source PlatformVisualAdapter27.swift compiled ONLY explicitly configured SDK27 target flag LIFEOS_SDK27;
runtime availability guard inside file and matching baseline branch required. No selected SDK27 means omit this source and feature flag.
Adopt only already documented NavigationTransition iOS zoom>=18/crossFade>=27, glassEffect>=26; macOS fallback opacity/matched geometry
unless that exact member is documented for native Mac. No fake native Mac zoom from protocol availability alone.
Document/ReadableDocument/WritableDocument deferred: current coordinated journal remains sole Obsidian writer; no design gap.
New toolbar arrangement stays baseline ToolbarItem placement;27-specific placement is optional polish, not required functional path.
Unknown glyph chooses existing SF Symbol fallback in20. User OS27 upgrade does not raise minimum target or require developer membership.
PlatformVisualAdapter.route(reduceMotion:Bool)->AnyTransition = opacity (or identity reduced);
cardRadius(outer:CGFloat,inset:CGFloat)->CGFloat=max(0,outer-inset), pure; system container shape owns native outer corners.
Physical glass/crossfade captures are release evidence, no guessing of unavailable SDK declarations permitted.

## Exact pins already in repository, retained
Windows Python cryptography50.0.1 wheel SHA256 aed8db4f6d71c51efb89530e12d9464e7bf2923d46c3205dc794a2a93f8c0648,
file cryptography-50.0.1-cp311-abi3-win_amd64.whl in services/gateway/requirements.lock; Python3.12Windows supported by abi3 tag.
Keep existing requirements.txt/lock transitive versions/hashes; no new crypto dependency version picked by worker.
package-lock.json current resolved integrity strings remain exact authority; npm ci in execution, never broad npm update to resolve styling.
XcodeGen2.46.0 zip SHA2564d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806 retained;
checkout11bd71901bbe5b1630ceea73d27597364c9af683; upload-artifactea165f8d65b6e75b540449e92b4886f43607fa02 retained.
CI manual workflow/contents read unchanged, no fork secrets. No re-pin already immutable dependency merely to make a diff.
Mac relay uses Python stdlib plus native SignerCLI verification (R4-09 amendment); no Windows-wheel install on Mac.
transitions-dev/thinking-orbs are inspiration only; implement20 native equations, no source copy/runtime dependency.
If later copying snippets, preserve and review actual license first; current architecture requires no such license decision.

## Dead code/refactors
P15 writes reference manifest by symbol: compile target references, string deep links, AppIntent identifiers, Codable keys, widget kinds.
Only proven unreachable replaced symbols removable in later execution; source deletions forbidden in this planning phase.
Renaming persisted/wire field or changing business semantics is migration, not safe cosmetic refactor.
Keep existing validated constructors/receipt stores; DTO conversion isolation is justified transport adaptation, not duplicate model authority.
No O(n²) list matching: stable-ID dictionary once per revision, sweep overlap, indexed series lookup; actual worst case recorded per packet.
Review evidence may reveal bug; resolve with an amendment naming exact affected function before worker changes architecture.
