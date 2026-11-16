# Native tapered pouch index implementation

Spec: `docs/superpowers/specs/2026-11-14-pouch-index.md`.

Continue in the existing working checkout: this task depends on the owner's shared, uncommitted workspace changes. Preserve them, do not commit unrelated work, and review inline as directed by release epic #99. The owner already approved the design and implementation.

## Task 1: Native index and tool integration

1. Add a regression proving that a visible workspace exposes a top-aligned, nonactivating child index. Run it against the current implementation; expect failure because the index is absent.
2. Implement bounded geometry, continuous spring/drag presentation, icon accessibility, child-panel lifecycle, and existing tool routes. Replace the visible chrome trigger with a geometry-only anchor; retain direct tool commands.
3. Add geometry, drag interruption, reduced-motion, focus/marked-text, and lifecycle coverage. Update existing UI assertions and smoke navigation for the intentionally changed entry point.
4. Run focused pouch/workspace tests. Expect all checks green with editor identity and selection preserved.

## Task 2: Verification and delivery

1. Review the complete change inline, especially screen-edge placement, modal windows, transparent hit regions, action availability, and panel cleanup.
2. Run `swift build`, `swift test`, and `swift build --product PurloryBench`. Expect successful builds and zero test failures; report any unrelated baseline failure precisely.
3. Capture the native closed/open index in light/dark themes with synthetic data and isolated `CFFIXED_USER_HOME`. Inspect the taper and icon placement.
4. Build a local app bundle if the native checks pass. Do not replace or open the user's real workspace as part of testing.

No commit, publication, or release acceptance is implied by this local implementation request.
