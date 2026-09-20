# LifeOS completion blueprint — 2026-09-21
Status: PLANNING DELIVERABLE; implementation requires geonq's final go.
Repository: /Users/georgdomke/Developer/life-tracking
Baseline: d3e62b7d265259dd3954c719365d161328aa32dd plus eight untracked D1 candidates.
Author: sole architecture planner, synthesizing three supplied read-only research reports and source inspection.
No completion percentage, new runtime evidence, or error-free implementation guarantee is implied.

## Read order
1. [Baseline and decisions](01-BASELINE.md)
2. [Architecture and outage protocol](02-SYNC-ARCHITECTURE.md)
3. [Design and motion contract](03-DESIGN.md)
4. [Screen compositions](04-SCREENS.md)
5. [Apple API matrix](05-APPLE-APIS.md)
6. [Domain contracts](06-DOMAINS.md)
7. [Core implementation packets](07-CORE-PACKETS.md)
8. [Product implementation packets](08-PRODUCT-PACKETS.md)
9. [Integration, security and operations packets](09-INTEGRATION-PACKETS.md)
10. [Verification and release gates](10-RELEASE.md)
11. [Worker dispatch instructions](11-WORKER-PROMPTS.md)
12. [Sources and reference policy](12-REFERENCES.md)
13. [Source anchors](13-SOURCE-ANCHORS.md)
14. [Ownership manifest](14-OWNERSHIP.json)
15. [Protocol algorithms](15-PROTOCOL-ALGORITHMS.md)

## How to execute after approval
Use P00 first. Read the packet plus its referenced contracts, then send its generated prompt.
14-OWNERSHIP.json is the exact file allowlist; N denotes new files, E existing.
Workers receive current SHA and fingerprints, not stale line numbers as edit instructions.
13-SOURCE-ANCHORS.md records present line anchors; search the named symbol before editing.
New names in packets are proposed APIs, not claims that they already exist.
Each file has one owner. Integration requests are returned to that owner rather than edited by another worker.
One Luna implementation worker at a time; one Apple build lane; no idle workers or polling services.
Astra reviews at cohesive wave boundaries defined in 10-RELEASE.md.
Plan before implementation does not eliminate the need to verify concurrency, security or visual behavior.
Run no builds, source edits, deployment, commits or pushes as part of this planning delivery.

## Scope preserved
Home, calendar/planning, finance/imports/wealth, fitness/training/nutrition/supplements/lifestyle,
tax/documents, usage providers, Clipper observations, settings, widgets, automation and offline recovery.
Retain existing feature/reference requirements; do not close an unavailable feature by hiding it.
No generic AI or advisor. Calorie-photo proposal generation is the sole in-app AI operation.
NextSemis, EventKit mirroring, ActivityKit and Spotlight are explicitly optional, outside required completion.
Unavailable proprietary Zepp values and unsupported provider quotas are capability limits, not invented data.
These limits require visible honest states and must not masquerade as implemented automatic integrations.

## Planning limits
Source and existing receipts were inspected; no tests/builds ran in this phase.
Historical Windows state is not current proof: Windows is unavailable for at least a week.
Git origin/main here is the locally stored remote-tracking ref; no fresh remote fetch was performed.
The requested result is detailed instructions for completion; release remains gated on execution evidence.
