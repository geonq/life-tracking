# Windows preflight — 2026-09-18

- Baseline: `4db1eaa35766fecce7cbdfa48309db4bf9f89f24`
- Remote: `domke@geonqserver.tail5f8789.ts.net`
- Decision: **STOP / NO-GO**
- Canonical mutations: none
- Receipt source: sanitized worker output; raw diagnostic remains in the
  owned temporary directory `/private/tmp/lifeos-windows-preflight-4db1eaa-20260918/`.

## Verified

- SSH reached `geonqserver`; remote identity was the expected Windows account.
- `LifeOSAPI` was stopped, `LifeOSGateway` was absent, and the legacy
  `LifeOSSyncServer` task was Ready. No LifeOS listener was bound on 8420,
  8421, or 8787.
- Tailscale backend status was Running. Serve returned successfully but had no
  LifeOS route for 8420/8421.
- The marker was present and active; its schema-2 manifest and canonical paths
  passed bounded identity checks. The journal declared `artifacts-complete`,
  31,401 complete units, and released writers.
- Local release builder checks passed 16/16; service-host build passed;
  service-host tests passed 27/27; shell syntax passed.

## Unverified or blocked

- The first diagnostic parsed the journal in 286.9 seconds, beyond its
  180-second bound. It reported 31,400 nonempty backup references, 31,166
  present matching hashes, and 234 absent references, but that accounting is
  not accepted: destination-only removals can legitimately have `post=absent`.
- Progress-frame integrity, ACL principals/rights/inheritance, ancestor
  reparse protection, writer/task provenance, and source-bound candidate
  identity were not accepted.
- The disposable snapshot has no demonstrated source SHA or candidate
  manifest for this baseline. Health/readiness was skipped because no verified
  LifeOS listener was present.
- The disposable inspector was rejected for permissive/chunk-fragile parsing,
  incorrect backup accounting, overstated path guarantees, and missing hard
  deadlines. No verified streaming parser was available on the host, and the
  v2 tooling packet did not start; the original tool and receipt remain
  preserved for audit history.

## Required next packet

Create and test a separate strict `inspector_v2` with streaming identity,
missing-backup classification, progress-frame replay, ACL/reparse checks,
writer provenance, output limits, monotonic deadlines, nonzero STOP results,
and sanitized evidence. Run those probes separately. Do not recover, install,
clear the marker, relabel the snapshot, or change services/tasks until the
receipt is accepted by Astra.
