# Apple-style workspace motion — 2026-11-02

## Implemented behavior

The owner explicitly requested animation refinement using `apple-design` after the
motion-continuity fixes. Base: `5c57ece`; product source candidate: `14dc817` on
`codex/purlory-motion-continuity`.

- Collapsed pouch and paragraph/tile drag markers follow every pointer event
  immediately, preserving existing grab offsets, drag thresholds and cancellation.
  Grabbing a settling orb stops its old motion. No new flick/throw gesture is added.
- Workspace reflow and pouch collapse/restore use an analytic critically damped
  spring. Damping ratio is 1; response is 0.32 seconds, not a fixed duration.
  Retargeting retains current position and velocity. Independent axes prevent
  one component's change from resetting another.
- Snapshot geometry, opacity and blur share that spring state, including repeated
  reversals. The material filter updates through its named layer key path.
- Chrome and compact-card buttons show immediate pressed color through native
  highlight handling; release/cancellation and keyboard focus remain native.
- Reduce Motion directly finishes active spatial transitions without another
  command. Existing display-linked clocks stop when settled or canceled.

The historical HTML fidelity constants are deliberately superseded for these
interactions by the owner's current request. The changed feel remains subject to
owner acceptance. Existing typography, materials, storage and model behavior are
outside this change.

## Regression and mathematical evidence

Observed failing native regressions before their corresponding repairs:

- A second pill pointer event left the marker at the previous event position.
- Normal-motion orb dragging lagged instead of preserving the grab offset.
- A highlighted chrome button retained its resting fill.
- Reversed reflow and pouch snapshots immediately discarded their prior velocity.
- Enabling Reduce Motion during reflow/restore left the transition active.

Focused verification: 61 native/motion/map tests passed. Additional coverage proves
monotonic settling without overshoot from rest, velocity handoff, and equivalent
spring states at 60 Hz, 120 Hz and after a delayed display frame. The named blur
filter retains its state and velocity across reversal. Existing native editor
identity, selection, rich paragraph transfer/undo, cancellation and detach checks
remain in force. Fixed-duration endpoint checks now assert an upper bounded
0.8-second spring settlement while retaining intermediate-frame assertions.

## Viewport regression found during full verification

The first complete run on `0b2ff55` executed 1564 tests with 6 skips and one
failure: `StoryMapShellTests.testActualFictionMapWorksWithAIOffAndKeepsEditorAcrossJumpReturnAndClose`.
Opening Map changed the reading scroll origin to zero. A focused rerun reproduced
it; temporary native bounds tracing identified AppKit's selection-forcing scroll
during `NSTextView` width changes. Temporary diagnostics were removed.

A new viewport regression also failed (180→159 and newer scroll input 260→258).
Workspace-owned frame presentation now preserves each live writing viewport
around native layout, without changing selection or text and without overriding
typewriter centering. It reads the current offset per frame, so it respects newer
scroll input and explicit source navigation. All original Map assertions remain.
The repair and original motion checks pass together (61 focused tests).

## Final checks

Final verification on `14dc817` passed:

| Check | Result |
| --- | --- |
| `swift test` | 1565 tests, 6 skipped, 0 failures (205 seconds) |
| `swift build` | exit 0 |
| `swift build --product PurloryBench` | exit 0 |
| `python3 scripts/check-module-boundaries.py` | exit 0 |

The six opt-in skips cover two explicit journal fixtures, two Metal tensor checks,
one live Ghost model check and native capture. Existing non-fatal macOS Contacts
service diagnostics remain in the logs. No test was disabled or weakened.

Complete logs, the initial failed run and final exit-code records are retained in
`build/apple-motion/`. Fixtures use an isolated `CFFIXED_USER_HOME`; local Swift
commands reuse dependency build inputs through
`--scratch-path /Users/ryujekyeong/Developer/MINT/.build`.
Final code review was performed inline under the current issue contract. This
report and plan-completion marks are documentation-only changes after the tested
source candidate.

## Verification limits

No Purlory app bundle launch, actual-app/UI smoke, physical IME, VoiceOver, live
shipping model or subjective visual acceptance was performed. Mathematical frame
cadence invariance does not establish actual 60/120 fps rendering performance.
The owner should feel-check direct dragging, rapid reflow toggles and repeated
pouch reversal in the batched native verification, including Reduce Motion.
This is local source/test evidence, not PR/main CI, Store distribution or RC proof.
