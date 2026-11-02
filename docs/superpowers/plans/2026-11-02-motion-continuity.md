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
- [x] Add a real native fixture regression that presses a header at an intermediate reflow frame, asserts no frame change, then releases and checks final destination/editor identity.
- [x] Run the test and observe the current frame jumping to its destination.
- [x] Preserve current frames during pointer tracking; resume the pending layout on release/cancel.
- [x] Rerun the regression and relevant spatial/fidelity tests; commit the task.

### Task 2: Own tile snapshot completion

**Files:** SpatialWorkspaceCanvas.swift; WorkspaceMotionContinuityTests.swift.
**Interfaces:** Existing real drag events and retained hosts.
- [x] Add regression that keeps a source dim while dragging and starts another drag before a previous unfold completes; assert the newer appearance survives old completion.
- [x] Observe failure, then scope completion to transition identity/generation and restore only the host that transition hid.
- [x] Rerun focused drag regressions and commit.

### Task 3: Stable paragraph insertion feedback

**Files:** Workspace/WorkspaceEditorInteraction.swift; WorkspaceMotionContinuityTests.swift.
**Interfaces:** Existing mouseDown/mouseDragged/mouseUp and paragraphRect.
- [x] Drag a paragraph across target positions and assert target paragraph styles, text and undo state remain unchanged before drop; confirm transfer/undo still work.
- [x] Observe paragraph-style mutation with motion enabled.
- [x] Retain the stationary insertion marker and remove animated paragraph-spacing mutation/task.
- [x] Rerun paragraph transfer and editor regressions; commit.

### Task 4: Retarget pouch snapshots

**Files:** Workspace/WorkspacePouchController.swift; Tests/PurloryCoreTests/WorkspacePouchTests.swift.
**Interfaces:** Existing snapshotAnimationTime and stepSnapshotAnimation.
- [x] Add intermediate-frame/alpha assertions for collapse→restore→collapse plus reduced-motion/detach behavior.
- [x] Observe reversal restarting from the endpoint.
- [x] Capture current snapshot frame/alpha before cancellation and reuse them as the next animation origin; preserve existing endpoint durations and focus behavior.
- [x] Rerun pouch regressions and commit.

### Delivery

- [x] Run swift test, swift build, swift build --product PurloryBench; inspect outputs.
- [x] Review the complete branch inline against the spec and preserved editor invariants.
- [x] Record evidence and remaining owner feel checks; deliver the local branch without merging or publishing.
