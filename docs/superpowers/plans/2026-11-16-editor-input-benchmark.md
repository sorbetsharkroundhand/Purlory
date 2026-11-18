# Editor Input Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce executable native/workspace input baselines with raw timelines, bounded opt-in instrumentation and honest measurement semantics for issue #309.

**Architecture:** An opt-in XCTest runner reuses the real workspace harness and compares it to a matched native TextKit 1 editor. A nullable per-editor recorder measures existing code without changing editing behavior. Fixtures, report aggregation, main-queue probes and export stay in test utilities; an isolated shell runner records provenance and drives the matrix.

**Tech Stack:** Swift/AppKit/XCTest, OSSignposter, shell and JSON/CSV.

**Spec:** [Issue #309 measurement contract](https://github.com/sorbetsharkroundhand/Purlory/issues/309#issuecomment-6907517903). Follow the latest measurement-first comments, not the original speculative remediation list.

## Global Constraints

- Editor first; no model/network setup required to write. Local inference only, no telemetry.
- Preserve Hangul IME; never generate Ghost during marked text.
- Preserve Ghost Tab accept / right-arrow partial / Esc reject, cursor-line highlight, undo, autosave/recovery and Markdown/EPUB/media/math round-trip.
- New behavior needs failing regression coverage before implementation.
- Isolate UI tests with CFFIXED_USER_HOME, not HOME alone; never use real manuscripts.
- No manuscript text or input characters in measurement logs. Numeric IDs, lengths, ranges, revisions, enum phase names and times only.
- Synthetic direct calls do not validate macOS Korean IME. Draw completion, main-queue callbacks and probe delays do not measure physical presentation or frame rate.
- No guessed absolute latency pass/fail threshold and no production optimization or background-delay change in this measurement task.
- Default production recording is nil; disabled recording schedules no work and performs no file I/O/statistics publication.
- English for repo docs, issues, PRs and implementation comments; localized UI/Korean-specific fixtures may use Korean.

### Task 1: Implement the synthetic input baseline suite

**Difficulty/model:** High: timing semantics, AppKit lifecycle, nesting/revision correlation and real editor integration. Use GPT-6 Astra with high reasoning.

**Files:**
- Create: `Sources/PurloryWorkspaceUI/Benchmark/EditorInputTraceRecorder.swift`
- Modify narrowly: `Editor/BlockTextView.swift`, `Editor/BlockTextView+Input.swift`, `Editor/BlockTextView+Attachments.swift`, `Editor/BlockTextView+Overlays.swift`, `Editor/PurloryBlockEditor.swift` under `Sources/PurloryWorkspaceUI/`.
- Create: `Tests/PurloryCoreTests/EditorInputBenchmarkTests.swift`, `Tests/PurloryCoreTests/EditorInputBenchmarkSupport.swift` (split report/harness into focused test files if necessary).
- Modify narrowly: `Tests/PurloryCoreTests/LegacyWorkspaceControllerTests.swift` and `Tests/PurloryCoreTests/FramedWorkspaceTests.swift`: add an optional `autosaveDelay: Duration = .seconds(3600)` to their fixture/harness initializers and forward it; the benchmark passes `.milliseconds(800)` to match production while existing tests retain their current defaults.
- Create: `scripts/benchmark-editor-input.sh`, `docs/editor-input-benchmark.md`.
- Do not edit `CompletionController.swift`; its cadence correction is a separate preceding task.

**Interfaces:**
- Consume `FramedWorkspaceHarness`, its `fixture.session`, `completion`, `window` and `editor()` only for setup/verification; its forced-layout helper must not run between measured operations.
- Produce internal `@MainActor EditorInputTraceRecorder` with bounded samples, explicit dropped count, optional signposts, fake-clock injection, safe nested tokens and immutable finish snapshot. Expose only an optional internal `BlockTextView.inputTraceRecorder` for @testable attachment.

```swift
@MainActor final class EditorInputTraceRecorder {
    // Value models and tokens live with the recorder; no public API needed.
    func beginOperation(kind: OperationKind, eventTimestamp: Double? = nil) -> OperationToken
    func endOperation(_ token: OperationToken)
    func storageProcessed(range: NSRange, delta: Int, editedCharacters: Bool)
    func beginPhase(_ phase: Phase) -> PhaseToken
    func endPhase(_ token: PhaseToken)
    func drawBegan(_ rect: NSRect) -> DrawToken
    func drawEnded(_ token: DrawToken)
    func finish() -> EditorInputTrace
}
```

- [ ] **Step 1: Write deterministic failing recorder/report regressions first.** Inject times from an array. Model two edits before one draw and assert two distinct changed revisions correlate with a single draw batch; inputs with no observed draw remain unmatched. A draw token must capture its start revision, so an edit during draw is not falsely reported painted. Nested commit/marked calls restore the parent operation; post-operation storage changes have no stale operation ID. Capacity overflow increments a dropped counter. Attribute-only storage edits do not increment character revision. Disabled recorder preserves editing results and creates no samples. Report nearest-rank statistics on `[1, 2, 3, 4, 100]` must be p50=3, p95=100, p99=100, max=100, n=5; empty metrics remain absent, never zero.

```swift
let values = [1.0, 2, 3, 4, 100]
// Independent expected values for the report's nearest-rank policy.
XCTAssertEqual(summary(values).p50, 3)
XCTAssertEqual(summary(values).p95, 100)
```

- [ ] **Step 2: Run focused failing tests, then implement recorder and hooks.** Use monotonic uptime throughout (`ProcessInfo.processInfo.systemUptime`), keeping optional NSEvent timestamps separate and refusing invalid mapping. Synthetic calls have no native event ID. Record operation entry/exit for keyDown, insertText, setMarkedText and unmarkText; storage observation; coordinator serialization/binding/projection/forwarding; draw start/end. Preserve early returns and nesting with defer. Add static-name OSSignposter intervals using numeric IDs and no text. Capture existing rebuild/serialization counters outside the burst. The existing coordinator's legacy timer can be changed to the same monotonic clock and its comment corrected.

```swift
let recorder = inputTraceRecorder
let token = recorder?.beginOperation(kind: .insertText)
defer { if let token { recorder?.endOperation(token) } }
// Existing production operation remains unchanged.
```

- [ ] **Step 3: Build deterministic fixture/scenario/report utilities with tests.** Exact BMP character/UTF-16 sizes: 1,000; 10,000; 100,000; 230,544; 500,000; 1,000,000. Support short paragraphs and one long paragraph, plain and Markdown fixtures, start/middle/end positions. Record fixture hash/version/shape, UTF-8 and UTF-16 sizes, paragraph count and active paragraph length. Trace modes include Latin insert, synthetic Hangul marked/commit, delete/newline/cursor/selection replacement; paste is separately labeled. Include warmup, measured burst, immediate and at least 5-second idle-resume scenarios. No fixture corpus or private input in exports.
- [ ] **Step 4: Implement opt-in `EditorInputBenchmarkTests.testRecordBaseline`.** Require `PURLORY_INPUT_BENCHMARK_OUTPUT` (new directory); missing opt-in skips only this experiment. Default repetitions are five. Record each run separately. Use matched native NSTextView TextKit 1 stack in a scroll view and real workspace. Match effective font, width, inset, paragraph style and substitutions; export actual settings and identify differences. Workspace scope must explicitly list enabled owners (default no-model workspace, diagnostics nil); never imply all AI/background features are active. Set up and warm up before recording, make window visible/focused, then schedule paced operations using the normal run loop. Do not call layout/display forcing during a burst. Record requested schedule and actual operation start as synthetic scheduling delay. A low-rate background timer posts at most one outstanding main-queue probe; stop and drain it before export. Probe delay is not physical freeze/frame evidence. Preserve pending/unmatched draws and visibility uncertainty. Record final-text, undo/redo and session flush/reopen integrity outside timings. Failure must fail the experiment instead of writing a successful integrity claim.
- [ ] **Step 5: Export and isolate execution.** JSON includes schema/version, per-scenario/run/burst distributions and raw samples; CSV contains raw numeric/enum rows. Preserve original timestamp units and correlation IDs. Include source SHA/dirty/configuration and executable SHA256, OS/hardware/available display refresh/backing scale, power mode and input source (unknown when not obtainable), feature settings and explicit unmeasured external visual/IME status. Refuse report overwrite. Write files only after measurement. Script validates matrix parameters, records provenance after building, creates isolated CFFIXED_USER_HOME, then runs the recorded test binary via `swift test --skip-build --filter EditorInputBenchmarkTests/testRecordBaseline`. Provide `--quick`, matrix selection and instrumentation on/off controls; quick must say it is a smoke subset. Keep build logs/provenance with output. Do not use inference-oriented PurloryBench or add package dependencies.
- [ ] **Step 6: Add a runnable protocol document.** Provide exact quick/full/paired-on-off commands, schema/clock definitions, interpretation limits, Time Profiler/signpost capture command against the test executable, Typometer fixed-ROI controls, and separate real Korean IME/manual final-text/video procedure. Cite official Apple signpost/responsiveness docs and Typometer README. Mark missing external evidence clearly; no diagnosis or issue-close claim without measurements.
- [ ] **Step 7: Run focused deterministic tests and one quick benchmark.** Check files exist, parse successfully, omit manuscript text, have finite ordered times, record both hosts and missing observations honestly, and preserve integrity. Run module-boundary check. Self-review and commit scoped files. Full suite, expanded matrix and final report are controller responsibilities.
