# Input Measurement Cadence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep editor measurement publication bounded after its rolling sample window fills, as required by issue #309's measurement-first update.

**Architecture:** Separate the publication cadence from the bounded sample buffer size. Keep the existing recent-window statistics API and values.

**Tech Stack:** Swift, Observation, XCTest.

**Spec:** [Issue #309 measurement-first comment](https://github.com/sorbetsharkroundhand/Purlory/issues/309#issuecomment-6904776314), section 5. The latest comments supersede the issue body's unverified root-cause claims.

## Global Constraints

- No model/network setup required to write. Local inference only, no telemetry.
- Preserve Hangul IME; never generate Ghost during marked text.
- New behavior needs failing regression coverage before implementation.
- Do not claim handler or main-queue timing measures physical display completion.
- Use synthetic fixtures and isolated defaults/storage; UI test processes use `CFFIXED_USER_HOME`.
- English for repo docs, issues, PRs and implementation comments; localized UI/Korean-specific fixtures may use Korean.

### Task 1: Bound rolling statistics publication

**Files:**
- Modify: `Sources/PurloryWorkspaceUI/Editor/CompletionController.swift`
- Create: `Tests/PurloryCoreTests/KeystrokeMeasurementTests.swift`

**Interfaces:**
- Consumes: `CompletionController.noteKeystroke(handlerMs:totalMs:)` and `keystrokeStats`.
- Produces: the same public API; only publication cadence is corrected.

- [ ] **Step 1: Write a failing regression against the real controller.** Use an isolated `UserDefaults` suite with completion disabled. Feed 120 samples with `(handlerMs: 1, totalMs: 2)`, save the published snapshot, feed 19 samples with `(handlerMs: 50, totalMs: 100)`, and assert the published snapshot remains unchanged after each sample. Feed sample 140 and assert `samples == 120`, `handlerP95 == 50`, `totalP95 == 100`, `totalMax == 100`. Repeat across the next boundary (141–159 unchanged, 160 published) to catch a one-off fix. Assert no publication before sample 20. Independent literal expectations must be used.

```swift
for _ in 0..<120 { controller.noteKeystroke(handlerMs: 1, totalMs: 2) }
let snapshot = controller.keystrokeStats
for _ in 0..<19 {
    controller.noteKeystroke(handlerMs: 50, totalMs: 100)
    XCTAssertEqual(controller.keystrokeStats, snapshot)
}
controller.noteKeystroke(handlerMs: 50, totalMs: 100)
XCTAssertEqual(controller.keystrokeStats.samples, 120)
XCTAssertEqual(controller.keystrokeStats.totalP95, 100)
```

- [ ] **Step 2: Run `swift test --filter KeystrokeMeasurementTests` under a temporary `CFFIXED_USER_HOME`; preserve expected failing assertions.** Do not overlap SwiftPM builds with the controller's baseline run; wait for the controller to report that it is finished.
- [ ] **Step 3: Add a bounded non-observable cadence counter.** Increment once for each accepted sample and reset after every publication; do not derive cadence from the truncated arrays.

```swift
@ObservationIgnored private var samplesSinceKeystrokePublication = 0
// Inside noteKeystroke, after the rolling-window append/trim:
samplesSinceKeystrokePublication += 1
guard samplesSinceKeystrokePublication == 20 else { return }
samplesSinceKeystrokePublication = 0
```

- [ ] **Step 4: Correct touched documentation to call `totalMs` the time from the coordinator handler entry to a later main-queue callback.** It is neither event queue delay nor actual glass/display timing. Do not rename public properties or change unrelated product UI.
- [ ] **Step 5: Run the focused regression and relevant completion tests.** Preserve commands and outputs in the task report, self-review, then commit only the implementation and regression files. The controller runs the full integrated suite after all issue work.
