# Apple Motion Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline without subagents.

**Goal:** Make workspace motion directly controlled, gently damped and velocity-continuous.
**Architecture:** Immediate drag positions; a small analytic native spring shared by reflow and pouch presentation; native pressed-state colors.
**Tech Stack:** Swift, AppKit, SwiftUI, CADisplayLink, XCTest.
**Spec:** docs/superpowers/specs/2026-11-02-apple-motion-polish-design.md

## Global Constraints

- macOS 14+, no new dependency or manuscript/runtime ownership changes.
- Preserve IME, Ghost keys, focus/selection, undo and all format round-trips.
- No app launch or actual-app/UI smoke; use isolated synthetic fixtures.

## Review Focus

- Ordinary drags stay attached to the pointer at both motion settings.
- Reversal keeps position and velocity, then settles without decorative bounce.
- Long display gaps and 60/120 Hz sampling produce equivalent spring states.
- Preference changes/detach cannot leave a hidden window or an active idle clock.
- Pressed feedback preserves native click cancellation and editor focus.

### Task 1: Direct manipulation and press feedback

**Files:** WorkspacePointerSpring.swift, WorkspacePouchController.swift, WorkspaceHTMLStyle.swift, WorkspaceMotionContinuityTests.swift.
**Interfaces:** Existing move/beginDrag/updateDrag and NSButton.highlight.
- [ ] Add failing native tests for repeated pointer moves, pouch grab-offset tracking and immediate press color.
- [ ] Observe the failures, then remove spring following during active drags and add pressed color feedback.
- [ ] Verify both motion modes and existing drag/focus regressions, then commit.

### Task 2: Spring workspace reflow

**Files:** New WorkspaceSpring.swift; SpatialWorkspaceCanvas.swift; WorkspaceShellView.swift; motion tests.
**Interfaces:** A critically damped scalar/rect spring (response 0.32 s) retaining position/velocity; existing frameAnimationTime and stepFrames.
- [ ] Add a native regression proving a reversed reflow initially retains its previous velocity; observe failure.
- [ ] Implement analytic scalar/rect spring and reflow retargeting. Share the response/damping policy with navigator motion.
- [ ] Verify no-overshoot settling, cadence equivalence and delayed-frame recovery, plus reflow/drag identity regressions; commit.

### Task 3: Spring pouch presentation

**Files:** WorkspacePouchController.swift, WorkspacePouchTests.swift.
**Interfaces:** The same spring values plus existing snapshotAnimationTime/stepSnapshotAnimation.
- [ ] Add a failing velocity-handoff reversal test and preserve existing frame/opacity/focus/detach coverage.
- [ ] Carry frame/opacity/blur spring state through reversals and finish safely under Reduce Motion.
- [ ] Update fixed-time endpoint assertions to the new bounded spring-settling contract; verify and commit.

### Delivery

- [ ] Review the whole change inline against the spec and editor invariants.
- [ ] Run the full Swift suite, debug/bench builds and module-boundary check.
- [ ] Record exact evidence and remaining owner feel checks; preserve the local branch.
