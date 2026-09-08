# HANDOFF — life-tracking (LifeOS native app)

Updated 2026-09-08 09:40 Europe/Berlin.

## Current verdict

**NO-GO for completion.** The source foundation is broad, but the supplied
screenshots show a release-blocking visual quality gap. Advisor is explicitly
being removed; calorie photo tracking is the only permitted in-app AI flow.
No Codex/Claude watcher or overnight scheduler is active.

The implementation contract is [`tasks/design-overhaul-plan.md`](../tasks/design-overhaul-plan.md),
currently 116 lines. Astra Medium reviewed it and required measurable reference
states, shared component contracts, per-mode finance availability, explicit
calendar gesture ownership, nutrition draft semantics, and visual evidence.

## Source state

- Branch: `lifeos-foundation-checkpoint-20260812`.
- HEAD: `1f13b4b` (`Refine LifeOS design acceptance rules`).
- The worktree intentionally contains the earlier app/backend implementation
  batch. Do not reset or discard another worker's changes.
- Foundation/Advisor-removal and Windows-hardening Luna Max lanes are active;
  their file scopes are disjoint. Review and commit each batch before starting
  the next overlapping UI lane.

## Existing evidence to rerun after the redesign

- Focused unsigned iOS UI verification: 79/79 tests; iPhone 17 simulator build.
- Focused unsigned macOS/widget verification: 52/52 tests and builds.
- API: 179 tests plus build/typecheck passed in the latest backend review.
- Gateway: 442 Python tests passed in the latest hardening report.
- A later full iOS logic run reached 1,329 tests with one fixture-host failure;
  rerun after Advisor removal and inspect that failure rather than hiding it.
- `git diff --check` passed before the current worker batch.

## Product boundaries

- Use SF Pro/system fonts only; remove Inter/Space Grotesk registrations.
- Keep the brand blue ramp from `colors.md`; estimates/projections green and
  calories orange, with adjacent blue accents separated by hue/value.
- Preserve real banking, HealthKit/Zepp, Calendar sync, WidgetKit, and
  Trade Republic import semantics. Never invent provider data.
- Keep Personal Team signing, physical HealthKit/Zepp, widget appearance,
  live bank consent, Windows PowerShell, and Tailscale runtime as external
  evidence gates.

## Ordered work

1. Finish typography foundation and complete Advisor deletion.
2. Fix Calendar iPhone scroll geometry and Mac trackpad magnification.
3. Redesign Finance, Recovery, Biology, and Nutrition against the plan.
4. Rework shell, widgets, and motion; capture state/interaction evidence.
5. Resolve the five Windows deployment review blockers.
6. Run batched Astra Medium code review, then final Luna integration.

## Safety and release discipline

Keep secrets out of source, prompts, logs, and archives. Use unsigned Xcode
checks for simulator/macOS work. Update this handoff, `PHASE_STATUS.md`, and
`DECISIONS.md` after each coherent batch, then commit. Do not claim hardware,
provider, or remote runtime gates from source tests alone.
