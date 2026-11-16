# Native tapered pouch index

Implemented the owner-approved index design as an AppKit child panel. The closed tab exposes 20 points; hover translates its surface six points without scaling. Opening reveals a rail 84 points wide with six 44-point icon targets. The lower contour uses a long cubic taper with a vertical ending tangent buried beneath the window edge. The rail follows the window top, opens inward at the display edge, and leaves document geometry unchanged.

Quick note, documents, characters, source search, manuscript history, and writing environment use existing local data paths. Environment retains the previous toolbox and overflow actions. The existing collapsed-workspace orb remains independent. Index panels cannot become key; detail cards remain in the main workspace. Escape continues to defer to marked text and Ghost handling.

Regression coverage includes parent attachment after hiding, top alignment, screen-edge fitting and detail-card clearance, continuous drag, interrupted spring motion, reduced motion, hidden-animation settlement, visible icon resources, IME/selection/undo preservation, and collapse/restore/detach. Light/dark, closed/open previews were captured from native Window Server groups using synthetic manuscripts and an isolated `CFFIXED_USER_HOME`.

The full verification pass also exposed three failures in the existing input-optimization work. Existing failing regressions now protect the corrections:

- `MathDisplayTypingTests.testMarkedDisplaySourceIsNotConsumedBeforeCommit`: semantic block attributes produced during composition commit must reach serialization caches.
- `ProjectEditorTransitionTests.testFirstProjectEditorMountRestoresPersistedCompositeSelection`: reveal the restored selection once the initially empty viewport has a real layout, retaining document and selection ownership checks.
- `WritingEditorProjectionTests.testBridgePairsOnlyPostBindingSnapshotAndAdoptsVerifiedProfileChanges`: rejected ownership clears the source used for initial authorization; identical bytes cannot revive a stale native editor.

An explicit bridge reattachment for a retained document tile separately verifies its document identity and exact native bytes before rebuilding the derived map. `WorkspaceCommandPaletteTests.testNativePaletteOpensAClosedSourceTileAtTheExactOriginal` covers returning to such a tile and then navigating to a closed original without relaxing stale-callback rejection.

These fixes preserve lazy layout and the incremental input path. Review was performed inline in accordance with release epic #99. Automated native marked-text fixtures are separate from a physical Korean keyboard/VoiceOver acceptance run.

## Verification on November 15

- `swift build`: passed.
- Focused native navigation, projection, editor transition, and index regressions: 47 tests, one opt-in capture skip, zero failures.
- Full `swift test`: 1,640 tests, nine skips, two elapsed-time assertions failed under concurrent system load. No functional assertions failed. The long-novel Hangul burst measured p95 14.50 ms against an 8 ms limit; narrative row layout measured 18.75 ms against 16.7 ms.
- Both timing tests passed on a separate, sequential rerun without code or threshold changes. The largest narrative layout case measured 6.42 ms. This is not an unqualified green full-suite run or physical IME latency acceptance.
- `swift build --product PurloryBench`: passed.
- `git diff --check` and shell syntax validation for the updated UI smoke script: passed.
- `scripts/build-purlory-app.sh`: passed, including privacy, notices (16 dependencies and 37 vendored/resource components), and icon checks. Repaired generated cache metadata that still referenced the previous `MINT` checkout location; no dependency versions or validation rules changed.
- `codesign --verify --deep --strict build/Purlory.app`: passed for the local ad-hoc bundle.
- `scripts/smoke-purlory-app.sh`: passed in an isolated home and uniquely identified app copy; clean no-model launch, normal termination, no crash report.
- Interactive UI smoke and physical Korean keyboard/VoiceOver acceptance remain part of the owner-triggered release batch described in `docs/release/verification-and-support.md`.

Native light/dark previews are in `build/pouch-index-preview/`. Logs and the RED/GREEN ledger are in `.superpowers/sdd/2026-11-14-pouch-index/`.

Local artifact: `build/Purlory.app`, source revision `54816549e9e3d5e7305fbf3f58c734e711fc73b5` with uncommitted workspace changes. Executable SHA-256: `12ae7c6451e0bf01751774a25b500fcf631cb209ae2ab68e6fc18c8f234d2e28`. This is a developer bundle, not Store distribution evidence.
