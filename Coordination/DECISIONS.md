# DECISIONS — LifeOS native app

Updated 2026-09-09 18:34 Europe/Berlin.

## Product and design

- Use SF Pro/system typography and shared dark design tokens. Keep nearby blue
  accents separated by hue/value; estimates use green and calories use orange.
  Preserve transparent widget legibility on a grey wallpaper.
- Use shared page, card, status, button, selector, sheet, and motion recipes.
  Calendar owns iPhone vertical scrolling and Mac trackpad magnification;
  paging and editing must not compete with those gestures.
- Remove Advisor and generic conversational AI from every product layer.
  Calorie photo tracking is the only permitted in-app AI behavior.

## Data boundaries

- Python remains Calendar authority; local edits persist an outbox receipt
  before sync is called automatic. Missing records never imply deletion.
- Enable Banking is the live bank path; Trade Republic stays a manual import.
  HealthKit is the iPhone-owned workout evidence path.
- LifeOS owns workout templates, exercises, sessions, sets, history, PRs, and
  reports. Zepp is a read-only sync source; unsupported proprietary fields are
  shown as unavailable rather than inferred.
- Obsidian integration remains a future design/feasibility item tracked in issue
  #2. Markdown/YAML links are the semantic source; Canvas coordinates are
  presentation metadata. It is not part of this completion batch.

## Security and release

- Windows gateway access remains fail-closed with scoped credentials,
  protected snapshots, atomic recovery, identity-bound bounded reads, ACL
  checks, and journal-bound Node staging.
- Keep secrets out of source, prompts, logs, and archives. Do not claim
  physical-device, provider, Windows-native, or remote-runtime evidence from
  source checks alone.
- Personal Team signing and seven-day renewal remain platform-managed steps.
  Native Shortcuts can open Zepp and report LifeOS refresh/status; a public
  Zepp API is not assumed.

## Workflow

- Use Luna Max for bounded implementation and Astra Medium for batched review.
  Keep worker write scopes disjoint and commit coherent groups gradually.
- Keep coordination files below 200 lines. Do not add usage-limit watchers,
  overnight schedulers, or unrelated AI features.
