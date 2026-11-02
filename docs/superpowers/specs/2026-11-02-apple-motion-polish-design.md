# Apple-style native workspace motion

The owner explicitly requested animation refinement using apple-design after the
interruption correctness fixes. The current branch is the baseline. The earlier
HTML timing/drag-follow constants are historical reference, superseded here by the
owner's request for direct manipulation and velocity-continuous motion.

## Chosen behavior

- During a drag, pills and the collapsed pouch track the pointer immediately,
  retaining their existing grab offsets and drag thresholds. Ordinary macOS drags
  stop where released; do not add a new throw/flick gesture.
- Workspace reflow and pouch collapse/restore use critically damped native scalar
  springs (damping ratio 1, response 0.32 s). Retarget the current position and
  velocity. No decorative overshoot. Independent x/y/width/height springs preserve
  interrupted trajectories. Response is a spring parameter, not a fixed duration.
- Pouch opacity and blur follow the same spring state and survive reversal. Keep
  one display-linked clock, stop when settled, and preserve editor identity/focus.
- Native chrome buttons show a pressed color immediately and release normally.
  Keep typing, caret, Hangul IME and Ghost free of these animations.
- Reduce Motion uses direct geometry and existing meaningful state feedback.
  A preference change also finishes active motion safely.

## Alternatives

Keeping fixed-duration tweens would retain a speed discontinuity on retarget.
Adding a third-party animation library would duplicate native display scheduling.
A small analytic critically damped spring is the implementation choice; it is
stable at 60/120 Hz and catches up after a delayed frame without Euler substeps.

## Boundaries and acceptance

No storage/model/network changes, new dependency, app launch or actual-app smoke.
Use test-first native fixtures to prove immediate drag tracking, preserved velocity,
frame-cadence-independent spring behavior, bounded settling, press feedback and
Reduce Motion. Run the full Swift suite and debug/bench builds once the changes
and inline review are complete. Subjective motion/IME/VoiceOver remain owner checks.
