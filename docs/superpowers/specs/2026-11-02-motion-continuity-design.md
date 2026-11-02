# Interruptible workspace motion

The user approved improving the four findings from the Apple-design animation review.
Keep the existing native SwiftUI/AppKit appearance, timing curves and durations.

## Scope and approach

1. A pointer-down on a moving tile freezes its current visible frames. Drag geometry
   uses those frames; release/cancel resumes the pending layout from the same frames.
2. Tile snapshot completion may restore only the host hidden by that exact live
   transition. A canceled or older drag cannot change a newer drag's appearance.
3. Paragraph transfer uses a stationary insertion indicator. Remove animated edits
   to manuscript paragraph styles: the destination stays stable while being hit-tested.
4. Pouch collapse/restore retargets the visible snapshot frame and opacity on reversal,
   including repeated reversal. Keep the same editor, selection and first responder.

Alternatives considered: a new spring framework would change established behavior
and add unnecessary dependencies. Animating paragraph gaps continuously would retain
layout/hit-test feedback loops and transient edits to text storage. The existing
stationary insertion marker is the smaller, stable solution (implementation choice).

## Constraints

- macOS 14+, no new dependencies, no manuscript/storage/domain ownership changes.
- Preserve Hangul IME, Ghost keys, focus/selection, undo, autosave and format round-trip.
- System Reduce Motion continues to use immediate geometry and meaningful feedback.
- Project changes, detach and cancellation retire presentation work without stale writes.
- Run deterministic native fixture regressions with an isolated CFFIXED_USER_HOME.
- No Purlory app launch or actual-app/UI smoke during this implementation pass.

## Acceptance

Tests first reproduce the observed frame jump, stale opacity mutation, paragraph
spacing mutation and snapshot reversal jump. Fixes pass those tests plus the full
Swift suite and debug/bench builds. Actual motion feel, IME and accessibility remain
part of the owner's batched native verification, not inferred from fixture tests.
