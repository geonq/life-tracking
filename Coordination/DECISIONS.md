# DECISIONS — LifeOS native app

Updated 2026-09-10 09:45 Europe/Berlin.

## Product and design

- Use the native SF Pro/system facade, compact hierarchy, 4/8/12/16/24/32/48
  spacing, 12pt Home/Usage cards, semantic SF Symbols, and distinct palette
  values from `colors.md`. Estimates are green; calories are orange.
- Home shows one compact Usage lead surface and avoids duplicate provider rings.
  Usage is an operational monitoring surface with truthful live/demo provenance.
- Calendar owns iPhone vertical scrolling and Mac trackpad magnification.
  Paging, editing, and zoom must not compete for the same gesture.
- Use direct user motion and restrained transitions: Mac detail entry is 180ms
  with an 8pt offset, module transitions are 120ms, and outgoing detail opacity
  is 120ms. Rapid reversal starts from visible values.
- Remove Advisor and generic conversational AI from every product layer.
  Calorie photo tracking is the only permitted in-app AI behavior.

## State and data boundaries

- Scene-owned state retains Calendar position, Finance chart/detail choices,
  Fitness section, and Usage provider/graph/range across route replacement.
- Python remains Calendar authority; local edits persist an outbox receipt before
  sync. Missing records never imply deletion.
- Enable Banking is the live bank path; Trade Republic stays a manual import.
  HealthKit is the iPhone-owned workout evidence path.
- LifeOS owns workout templates, exercises, sessions, sets, history, PRs, and
  reports. Zepp is a read-only sync source; unsupported fields remain unavailable.
- Obsidian integration remains a future feasibility item tracked in issue #2.
  Markdown/YAML links are semantic source; Canvas coordinates are presentation
  metadata.

## Security and runtime

- Windows gateway access remains fail-closed with scoped credentials, protected
  snapshots, atomic recovery, identity-bound bounded reads, ACL checks, and
  journal-bound Node staging.
- Protected storage runs off the asyncio loop with four workers and four queued
  admissions. Full capacity and shutdown use one sanitized response. A caller
  cancellation cannot release its domain lock before the worker finishes.
- Keep secrets out of source, prompts, logs, and archives. Do not claim provider,
  Windows-native, physical-device, or visual evidence from source checks alone.
- Native Shortcuts may open Zepp and report LifeOS refresh/status; a public Zepp
  API is not assumed. Personal Team signing and seven-day renewal remain
  platform-managed steps.

## Workflow

- Use Luna Max for bounded implementation and Astra Medium for batched review.
  Keep write scopes disjoint, native builds serialized with `-jobs 1`, and close
  completed workers/processes immediately.
- Keep coordination files below 200 lines. Use live production reads and keep
  visual fixtures isolated from production paths.
- Do not add a Claude usage-limit watcher, overnight supervisor, demo fallback,
  or unrelated conversational AI.
- Do not merge PR #1 while Windows, provider, physical-device, and visual gates
  remain unverified, even when local automated suites are green.
