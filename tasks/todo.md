# TODO — LifeOS completion gates

Updated 2026-09-12 Europe/Berlin. Release: **NO-GO**.

## Ordered work

1. **Done for source:** the native macOS route reducer/NavigationStack is in
   `070b7db`, with bounded Home history, stale-mount rejection, Calendar
   callback retirement, and Astra GREEN review. Interactive route reversal and
   deferred-editor runtime evidence remain open.
2. Continue serialized native runtime captures. The Usage visual slice is
   checked in at `fce94b9`; finish hierarchy, SF Symbols, motion, calendar
   scroll/pinch, and widget states against the approved design plan.
3. Run Windows recovery/install and verify service listeners, health, ACLs,
   Tailscale Serve, and live Enable Banking reads on the reachable PC.
4. Verify iPhone install, App Group/HealthKit, personal signing renewal, and
   the native Shortcut flows.
5. Resolve Zepp/workout evidence and implement the Obsidian Canvas mind-map
   plan from GitHub issue #2.
6. Run the batched Astra security/product review and close every acceptance
   registry row before changing the release verdict.

## Verified checkpoint

`87e7db6` is pushed. Usage visual/source, macOS route, personal installer
security slices are Astra-reviewed GREEN; iPhone focused tests are 95/95; macOS route tests are
2/2 with exit 0; the Usage settled and breakpoint renders are 1/1 each;
the full macOS snapshot run executed 51/51 cases with zero test failures before
result-archive I/O failure. Windows source tests are 61 passed, 1 skipped.
The installer has 13/13 tests and `bash -n`; this does not prove physical
signing, installation, or whole-product completion. Backend boundary security
is also Astra-reviewed GREEN at `87e7db6` with 148/148 API tests; native
Windows execution and deployment ACLs remain open. Calendar repair is still
uncommitted and RED pending two P1 fixes.
These results do not prove live, runtime, device, visual, or operational
completion.

Keep generic advisor/AI and the Claude usage watcher out of the product.
