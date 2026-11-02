# Workspace Motion Continuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline, without subagents. Steps use checkbox syntax for tracking.

**Goal:** Preserve direct control when workspace motion is interrupted.
**Architecture:** Keep motion in existing native workspace controllers. Pause current tile frames, scope snapshot completion to its owner, retain stationary paragraph markers, and retarget pouch snapshots.
**Tech Stack:** Swift 6, SwiftUI, AppKit, Core Animation, XCTest.
**Spec:** docs/superpowers/specs/2026-11-02-motion-continuity-design.md

## Global Constraints

- macOS 14+, no new dependencies, no manuscript/storage/domain ownership changes.
- Preserve Hangul IME, Ghost keys, focus/selection, undo, autosave and format round-trip.
- No app launch/UI smoke; isolated synthetic native fixtures only.

## Review Focus

- Pointer-down followed by click release must resume the interrupted layout.
- Older transitions cannot alter a newer drag, including after cancellation/project change.
- Paragraph targeting must preserve rich paragraph attributes and undo state.
- Repeated pouch reversals preserve frame/alpha and restore editor focus.
- Reduced motion and detach must leave no invisible window or active transition.

### Task 1: Pause and resume tile reflow

**Files:** Sources/PurloryWorkspaceUI/Workspace/SpatialWorkspaceCanvas.swift; Tests/PurloryCoreTests/WorkspaceMotionContinuityTests.swift.
**Interfaces:** Existing beginPanelDrag, finishPanelDrag, stepFrames and frameAnimationTime.
- [ ] Add a real native fixture regression that presses a header at an intermediate reflow frame, asserts no frame change, then releases and checks final destination/editor identity.
- [ ] Run the test and observe the current frame jumping to its destination.
- [ ] Preserve current frames during pointer tracking; resume the pending layout on release/cancel.
- [ ] Rerun the regression and relevant spatial/fidelity tests; commit the task.

### Task 2: Own tile snapshot completion

**Files:** SpatialWorkspaceCanvas.swift; WorkspaceMotionContinuityTests.swift.
**Interfaces:** Existing real drag events and retained hosts.
- [ ] Add regression that keeps a source dim while dragging and starts another drag before a previous unfold completes; assert the newer appearance survives old completion.
- [ ] Observe failure, then scope completion to transition identity/generation and restore only the host that transition hid.
- [ ] Rerun focused drag regressions and commit.

### Task 3: Stable paragraph insertion feedback

**Files:** Workspace/WorkspaceEditorInteraction.swift; WorkspaceMotionContinuityTests.swift.
**Interfaces:** Existing mouseDown/mouseDragged/mouseUp and paragraphRect.
- [ ] Drag a paragraph across target positions and assert target paragraph styles, text and undo state remain unchanged before drop; confirm transfer/undo still work.
- [ ] Observe paragraph-style mutation with motion enabled.
- [ ] Retain the stationary insertion marker and remove animated paragraph-spacing mutation/task.
- [ ] Rerun paragraph transfer and editor regressions; commit.

### Task 4: Retarget pouch snapshots

**Files:** Workspace/WorkspacePouchController.swift; Tests/PurloryCoreTests/WorkspacePouchTests.swift.
**Interfaces:** Existing snapshotAnimationTime and stepSnapshotAnimation.
- [ ] Add intermediate-frame/alpha assertions for collapse→restore→collapse plus reduced-motion/detach behavior.
- [ ] Observe reversal restarting from the endpoint.
- [ ] Capture current snapshot frame/alpha before cancellation and reuse them as the next animation origin; preserve existing endpoint durations and focus behavior.
- [ ] Rerun pouch regressions and commit.

### Delivery

- [ ] Run swift test, swift build, swift build --product PurloryBench; inspect outputs.
- [ ] Review the complete branch inline against the spec and preserved editor invariants.
- [ ] Record evidence and remaining owner feel checks; deliver the local branch without merging or publishing.
