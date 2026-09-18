# LifeOS decisions

Updated 2026-09-17 Europe/Berlin.

## Product boundary

- Native SwiftUI/WidgetKit on the Mac and iPhone is the product. Windows over
  Tailscale is the private structured-data/document boundary.
- Use truthful live data. Missing provider/device data stays unavailable; no
  silent fixtures in production.
- Calendar, Reminders, Obsidian, HealthKit/Zepp, and the private finance/tax
  ledger retain their own authority. Do not duplicate mutable ownership.
- No generic advisor or in-app conversational AI. Calorie-photo estimation is
  the only permitted AI flow.

## Design

- SF Pro/system typography, compact 4/8/12/16/24/32/48 spacing, semantic SF
  Symbols, distinct palette values from `colors.md`, green estimates, orange
  calories, restrained opacity/matched motion, and direct manipulation.
- Calendar owns iPhone vertical scrolling and Mac trackpad pinch zoom. Gesture
  ownership must remain separate from paging/editing.
- Route state has one native NavigationStack authority; do not reintroduce an
  AppKit raster/route host.

## Data and features

- Enable Banking is the live bank path; Trade Republic is manual import.
  Institution-aware CSV classification and explicit unknown-format mapping are
  required. Recurring candidates are deterministic; uncertain items expose
  auditable weekly/monthly/yearly Manage Payment controls.
- The pushed finance importer checkpoint `c871339` adds versioned institution
  fingerprints, fail-closed disabled/near-match handling, historical UUID
  compatibility, bounded multiline recovery, and content-free provenance.
  User mapping, recurring management, Robinhood/net-worth reconciliation, and
  live readback remain separate gates.
- Robinhood investments remain separate from bank transactions while verified
  holdings/cash contribute to net worth. NextSemis is optional after the direct
  import path is stable.
- LifeOS owns workout templates/history/reports; Zepp is a read-only source.
  Unsupported fields stay unavailable until evidence exists.
- Obsidian Canvas uses Markdown/YAML links as semantic authority and Canvas
  coordinates as presentation metadata; round-trip proof remains open.

## Security and operations

- Windows snapshots use protected ACLs, native identity-bound handles, bounded
  process I/O, job-tree cleanup, monotonic deadlines, and atomic publication.
  Disposable tests are evidence; canonical install is separate.
- Reader limits are bounded; errors preserve the primary failure and retain
  recovery artifacts when clean rollback cannot be proven.
- Apple build lanes are serialized, use owned DerivedData, shut down their
  simulator on exit, and run the storage floor guard before each lane.
- Storage cleanup is explicit and scoped; never delete source, personal data,
  final evidence, or a booted simulator. No background scheduler is used.

## Workflow

- Luna Max handles bounded implementation with exact file scope; Astra Medium
  reviews batches. Close workers/processes after use. Commit and push verified
  slices. Never promote source/disposable evidence to release acceptance.

## Current stability decision (2026-09-18)

- Treat `EXC_BAD_ACCESS` in a temporary `LifeOSMac` XCTest host as a real
  crash finding until reproduced and explained. The existing three reports
  are retained as historical evidence; a manual build survived a focused
  serial test and no new crash was produced. No speculative lifecycle change
  is allowed without a new stack-backed reproduction.
- Apple lanes run one process at a time with `-jobs 1` and
  `-parallel-testing-enabled NO`; a quiet compile is allowed to continue.
  Every result bundle is independently validated before it is used as
  evidence. Manual app processes and disposable test hosts use separate build
  paths.
