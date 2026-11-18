# Synthetic editor input baseline

This opt-in XCTest suite compares a native TextKit 1 `NSTextView` in a scroll view with the real `FramedWorkspaceHarness` workspace. It records a reproducible software baseline for issue #309. It does not establish a cause, reproduce the reported visual stall, set a latency acceptance threshold, or close the issue.

## Run

Run from the checkout root with an existing resolved Swift package graph. No model, private manuscript, inference benchmark, or network setup is used. Keep the desktop available; do not interact with benchmark windows. Each output must be a new path. The runner builds the test executable, records its hash and source/build provenance, creates a temporary `CFFIXED_USER_HOME`, then uses `swift test --skip-build` against that build. It removes the temporary home on exit. Scratch project files are temporary synthetic fixtures.

```sh
# Smoke subset: 1k short/plain, middle, immediate Latin + synthetic Hangul,
# one repetition, both hosts. This is not performance acceptance.
scripts/benchmark-editor-input.sh --quick --output build/input-quick

# Complete supported synthetic matrix, five repetitions per cell, both hosts.
# 6 sizes × 2 shapes × 2 formats × 3 positions × 4 traces × 2 timings
# × 5 repetitions × 2 hosts = 5,760 runs. Expect a long local run.
scripts/benchmark-editor-input.sh --configuration release --output build/input-full

# Bounded 230,544-character comparison with at least five seconds of idle.
scripts/benchmark-editor-input.sh --sizes 230544 --shapes short --formats plain \
  --positions middle --traces latin,hangul --timings immediate,idle \
  --repetitions 5 --output build/input-230k

# Paired instrumentation overhead experiment: identical matrix and executable.
scripts/benchmark-editor-input.sh --quick --repetitions 5 \
  --instrumentation on --signposts off --output build/input-on
scripts/benchmark-editor-input.sh --quick --repetitions 5 \
  --instrumentation off --signposts off --output build/input-off
```

Verify that paired `provenance.json` files have identical executable hashes, source SHA/dirty state and configuration; discard the pair if they differ. Repeat in reverse on/off order to expose drift. Compare dispatch duration and synthetic scheduling delay per scenario/host/run; instrumentation-off deliberately has no recorder trace or recorder-derived metrics. The sentinel remains enabled in both conditions. Run a separate on/signposts-on comparison to quantify signpost overhead. `--signposts on` has an effect only with `--instrumentation on`.

Selections are comma-separated subsets: sizes `1000,10000,100000,230544,500000,1000000`; shapes `short,long`; formats `plain,markdown`; positions `start,middle,end`; traces `latin,hangul,editing,paste`; timings `immediate,idle`. `--cadence-ms` accepts 1–1000 (default 30), and repetitions accept 1–100 (default five, or one for quick). Invalid values and existing output paths are refused. The opt-in experiment skips when `PURLORY_INPUT_BENCHMARK_OUTPUT` is absent; deterministic regressions still run in ordinary tests.

The generator is versioned, deterministic and BMP-only: requested character count equals UTF-16 length. Exports include SHA256, UTF-8/UTF-16 lengths, paragraph count, source format/shape, rendered length and active paragraph length. Markdown source size differs from rendered size. For scaling, compare equal active-paragraph lengths where possible, and inspect these fields rather than assuming they match. `editing` covers newline, deletion, cursor movement and selection replacement. `paste` is separately labeled direct insertion, without clipboard services. Hangul uses synthetic marked-text replacement and commit calls; it is not the macOS Korean input method.

## Measurement contract and exports

`report.json` has schema version 1, configuration/provenance/environment/limitations and separate `runs`. Each run identifies scenario, repetition (`runID`), burst, target and actual effective settings. Distributions use nearest rank (`ceil(p*n)`, one-based): p50/p95/p99/max and n. Empty or invalid distributions are absent, never a fabricated zero. No pooling hides individual runs.

`trace.csv` contains raw numeric/enum samples with sequence, operation/parent IDs, character revision, time, range/delta, composition and main-thread flags, optional native timestamp and dirty rectangle. `schedule.csv` preserves action/requested/start/end; `probes.csv` preserves sentinel post/execution. Optional fields are empty cells or omitted JSON properties. IDs are scoped to a run/burst; join using schema/scenario/run/burst/target before ID. Exports are written after all measurements and integrity checks. Existing report/CSV files are not overwritten. A failure leaves the test log and returns nonzero; it must not be interpreted as a successful integrity result.

All times are **seconds** in `ProcessInfo.processInfo.systemUptime`; durations are wall time, not CPU time. Native `NSEvent.timestamp` is kept separately in its original uptime seconds when finite. `eventTimestampComparable` records whether it is finite, nonnegative and no later than receipt. Invalid mappings cannot produce an event queue-delay claim; non-finite raw values are omitted so JSON remains valid. Synthetic calls have no native event ID/timestamp. Requested schedule to operation start is harness scheduling delay, not physical-key or OS event-queue latency.

Storage samples observe `NSTextStorage.didProcessEditing`, not the literal memory mutation. Only character edits advance the recorder revision. Nested operations restore parent attribution; changes outside an operation have no stale operation ID. The recorder is optional/nil by default, bounded at 100,000 samples per burst, reports drops, and freezes its finish snapshot. Instrumented phases include coordinator, serialization, binding, projection, edit forwarding and render refresh. Existing serialization/rebuild counters are sampled outside the measured burst.

A completed draw observes the revision captured at **draw start**. Two revisions can share one draw; an edit during a draw is not attributed to it. `storageToObservedDrawEnd` measures storage observation to that draw's return. It does not prove the changed glyph was drawn, the range was onscreen, or pixels reached the display. Unmatched revisions and missing draw observations stay explicit. Raw unpaired draw boundaries remain available. Buffer drops invalidate completeness claims.

Warmup, initial scroll/focus/layout and integrity checks are outside timing. No forced layout/display occurs between measured operations. Each measured burst is followed by a 250ms ordinary-run-loop observation tail; raw trace/probe times can therefore extend beyond the burst's `ended`. The 100ms background sentinel posts at most one outstanding main-queue callback, then stops and drains before export. Its delay describes sampled main-queue responsiveness; it is not a frame counter, continuous freeze duration, or physical screen measurement.

Each target’s effective settings are captured at the requested position after warmup and any idle wait, before the recorder is attached. The native target copies attributed content and settings from an equivalently prepared workspace reference. That reference flushes and closes before the native target warms up. Check reported differences in font, viewport/container dimensions, inset, paragraph spacing, substitutions and noncontiguous layout before comparing. Both targets share the noncontiguous-layout setting and use their own layout manager implementations. The workspace is General mode, completion disabled/no model, diagnostics nil, default outline/position/chrome owners and 800ms session autosave. It is not an all-features app experiment. Five-second idle measures elapsed idle/resume; background-job schedule/start/cancel/stop/application attribution is not captured. Scrolling is setup only; long continuous bursts, scroll-during-burst and feature-ablation matrices remain follow-on work.

Each run verifies final text/composition, undo/redo, and save/reopen outside timing. Workspace checks source binding, `ProjectSession.flush()` and `ProjectStore` reload; native checks a UTF-8 scratch file. This does not cover EPUB/media/math export. Reports contain no fixture text or input strings; local build/test logs and paths/provenance are separate artifacts. GPU and input source are `unknown` when unavailable. Maximum display FPS is not current refresh rate; configured refresh may also be unknown. `windowVisible`, `windowKey`, `occlusionVisible`, first responder and visible rect are observations, not proof of unobscured pixels. Keep false/unknown values; do not rewrite them into successful visibility claims.

## Instruments and signposts

[Apple's OSSignposter documentation](https://developer.apple.com/documentation/os/ossignposter) describes interval recording in Instruments. The recorder uses subsystem `com.purlory.input-benchmark`, category `EditorInput`, static interval name `EditorInput`, and numeric `correlation` metadata; match that value with raw sample IDs. [Apple's responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) describes main-thread work, hangs and hitches. Use stack samples plus controlled comparisons to test causes; these software intervals alone do not establish one.

Use a sufficiently long selected run to allow attachment. In terminal A:

```sh
scripts/benchmark-editor-input.sh --sizes 230544 --shapes short --formats plain \
  --positions middle --traces latin,hangul --timings idle --repetitions 10 \
  --cadence-ms 200 --signposts on --output build/input-profile
```

Once the test process exists, in terminal B:

```sh
pgrep -fl PurloryPackageTests
# Replace 12345 with the actual test executable PID, not swift-test or the shell.
xcrun xctrace record --template 'Time Profiler' --attach 12345 \
  --time-limit 30s --output build/input-profile-time.trace
```

For combined capture, create an Instruments template with Time Profiler and the `os_signposts` instrument, save it, and attach the same way:

```sh
xcrun xctrace record --template /absolute/path/InputBaseline.tracetemplate \
  --attach 12345 --time-limit 30s --output build/input-profile-combined.trace
xcrun xctrace export --input build/input-profile-combined.trace --toc \
  --output build/input-profile-toc.xml
```

Confirm the capture contains the intended test process, measured bursts, signpost correlation IDs and nonempty stack samples; a `.trace` directory alone is not evidence. Attaching late can miss early bursts. Prefer `--attach`: `--launch` with a time limit can terminate the launched target before export/integrity completes. Record tooling/permission failures explicitly. A successful availability probe on an unrelated process is not a Purlory profile. Keep profiled results separate from unprofiled timing baselines.

## External typing-to-visual-change procedure

[Typometer's README](https://github.com/pavelfatin/typometer#readme) explains its generated dot pattern, screen sampling and synchronous/asynchronous modes. It measures generated input to observed pixel change. This XCTest runner is not a stable manual comparator UI; provision a separate interactive native TextKit 1 comparator and isolated Purlory app scratch project before this external experiment. Until then, external evidence is **unmeasured**.

1. Record exact app/comparator binaries and SHA256, fixture hash, machine/power/display/scale, font, viewport, paragraph/wrap settings and Typometer version/mode/cadence/count. Use the same screen position and fixed short/empty line in both targets. Use a solid background and prevent dot-to-ellipsis substitution consistently.
2. Fix the observation region/pattern coordinates away from caret blink, highlight animations, window chrome and overlays. Record screen coordinates and backing scale. Keep the target unobscured and focused. Prevent wrapping and scrolling during each run. If glyphs leave the fixed region, reject that run rather than move it mid-run.
3. Confirm visually that detected pixels are the intended glyphs. Do not count caret blink or unrelated redraws as character display. Keep synchronous and asynchronous runs separate; asynchronous is useful for investigating batched display. Repeat each matched condition at least five times, alternate host order, and retain raw CSV, p50/p95/p99/max/n and capture settings.
4. Report screen capture/pixel sampling limitations and denied permissions or failed pattern recognition. Do not equate Typometer with synchronized hardware keystroke-to-glass measurement or real Korean IME validation.

## Separate real Korean IME and visual verification

Use an isolated actual app bundle/scratch project, with `CFFIXED_USER_HOME` and a deterministic synthetic fixture (or an explicitly authorized private local copy kept out of exports). Record source/binary/configuration, macOS Korean input source/layout, display and effective app settings. Keep completion/diagnostics/background settings explicit. Compare Latin and Korean at start/middle/end of 230,544 characters, then larger sizes and a long paragraph; include immediate typing, continuous typing, scrolling followed by typing, and resume after at least five seconds idle.

Manually type `동해물과 백두산이` through the actual macOS Korean input method. Record the physical key sequence, composition/commit behavior, correction/delete/newline, observed batching/stalls and final expected-text comparison, then undo/redo and flush/reopen. Check missing, duplicate and decomposed jamo separately from latency. Capture synchronized high-frame-rate video of physical key actuation and the fixed document region where possible; state frame rate, synchronization uncertainty and sample count. Ordinary screen recording alone does not timestamp physical input. Keep any private video/text local.

Attach a valid Instruments/signpost capture for the same scenario if diagnosing main-thread, composition or layout work. Until external pixels/video, real IME correctness and stack evidence are collected, mark them **unmeasured/unconfirmed**. Synthetic smoke success supports tool operation and tested integrity only. Set performance goals after same-device native baselines and display conditions are measured; do not reuse historical numbers or claim #309 is fixed.
