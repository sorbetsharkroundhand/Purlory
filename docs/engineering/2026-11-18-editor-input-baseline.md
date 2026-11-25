# Editor input baseline for #309

At 230,544 UTF-16 code units, the workspace's immediate synthetic Hangul dispatch p95 was 3.069 ms. Its storage-to-observed-draw p95 was 37.911 ms versus 4.244 ms in native TextKit 1. The workspace draw tail appeared after commits across all six sizes. At 230,544, the trace places most of that interval before draw entry. The reported real Korean IME batching and physical input-to-display latency remain unmeasured.

## Six-size middle-position run

Five bursts per host and recorder setting at each size, each with 12 synthetic marked-text and commit calls scheduled 30 ms apart. Each plain-text fixture had a 50-code-unit paragraph at the middle caret, and rendered length matched source length. The harness alternated host order by repetition. Windows hosted a native TextKit 1 text view and the General-mode workspace with completion disabled, no model, no diagnostics, default outline/position/chrome owners and 800 ms autosave. Prepared settings matched, including Noto Serif KR 18.5 pt, 680 pt text container, 952 × 648 pt viewport and noncontiguous layout enabled. The native host used `NSLayoutManager` and the workspace used `PurloryLayoutManager`.

The nine commands used clean source `1251dbe3867b1adfaac884f793018665d1f638ee` and the same debug test executable SHA-256 `d4c5d6eb0a0055d5e2b033486ef57d0b4da79b0d36e9bfbad6d7b901ce5e3bff`, verified inside XCTest. The arm64 Mac ran macOS 27.0.1 (26A434) and Apple Swift 6.3.3 on AC with Low Power Mode off. The display reported 2× backing scale and configured refresh of 120 Hz. All hosts reported a visible window, a nonempty visible rect and text-view first responder before and after each burst. The same checks reported `windowKey=false` and `occlusionVisible=false` in all 130 runs.

Values below are **n / p50 / p95 / p99 / max** in milliseconds except n. Quantiles are nearest rank over raw samples within each cell. With n ≤ 60, p99 equals the maximum. Dispatch is scheduled-call start to return. Scheduling delay is requested time to actual start on the main actor. Setup, warmup and integrity checks are outside the timed window. Draws and low-rate sentinel probes include a 250 ms observation tail after the last measured call. All elapsed values use system uptime. [Middle-position per-run quantiles](./2026-11-18-editor-input-middle-run-quantiles.csv)

| UTF-16 size | Host | Dispatch, on | Dispatch, off | Scheduling, on | Scheduling, off |
| ---: | --- | --- | --- | --- | --- |
| 1,000 | native | 60 / 1.000 / 1.561 / 2.340 / 2.340 | 60 / 0.921 / 1.385 / 1.873 / 1.873 | 60 / 1.889 / 2.022 / 2.058 / 2.058 | 60 / 1.896 / 2.039 / 2.149 / 2.149 |
| 1,000 | workspace | 60 / 0.924 / 1.973 / 1.997 / 1.997 | 60 / 0.871 / 1.896 / 1.951 / 1.951 | 60 / 1.777 / 9.910 / 11.640 / 11.640 | 60 / 1.625 / 6.553 / 8.688 / 8.688 |
| 10,000 | native | 60 / 1.067 / 1.584 / 2.522 / 2.522 | 60 / 0.944 / 1.374 / 1.539 / 1.539 | 60 / 1.885 / 2.012 / 2.069 / 2.069 | 60 / 1.874 / 1.991 / 2.025 / 2.025 |
| 10,000 | workspace | 60 / 0.918 / 2.963 / 3.024 / 3.024 | 60 / 0.923 / 2.984 / 3.056 / 3.056 | 60 / 1.728 / 7.211 / 11.905 / 11.905 | 60 / 1.734 / 9.465 / 11.743 / 11.743 |
| 100,000 | native | 60 / 0.911 / 1.413 / 1.523 / 1.523 | 60 / 0.965 / 1.359 / 1.545 / 1.545 | 60 / 1.674 / 2.030 / 16.849 / 16.849 | 60 / 1.879 / 1.982 / 2.140 / 2.140 |
| 100,000 | workspace | 60 / 0.950 / 3.030 / 3.120 / 3.120 | 60 / 0.978 / 3.009 / 3.171 / 3.171 | 60 / 1.887 / 9.725 / 10.460 / 10.460 | 60 / 1.807 / 9.651 / 14.124 / 14.124 |
| 230,544 | native | 60 / 2.913 / 3.845 / 3.937 / 3.937 | 60 / 3.075 / 4.061 / 4.483 / 4.483 | 60 / 1.742 / 1.877 / 1.899 / 1.899 | 60 / 1.708 / 1.924 / 1.930 / 1.930 |
| 230,544 | workspace | 60 / 1.064 / 3.069 / 3.304 / 3.304 | 60 / 0.869 / 3.187 / 3.533 / 3.533 | 60 / 1.795 / 8.945 / 11.364 / 11.364 | 60 / 1.717 / 9.055 / 12.280 / 12.280 |
| 500,000 | native | 60 / 3.060 / 4.746 / 5.140 / 5.140 | 60 / 3.228 / 4.640 / 5.328 / 5.328 | 60 / 1.664 / 1.859 / 1.902 / 1.902 | 60 / 1.697 / 1.920 / 1.937 / 1.937 |
| 500,000 | workspace | 60 / 0.982 / 3.400 / 3.462 / 3.462 | 60 / 0.961 / 3.070 / 3.200 / 3.200 | 60 / 1.911 / 8.623 / 11.983 / 11.983 | 60 / 1.887 / 8.229 / 9.386 / 9.386 |
| 1,000,000 | native | 60 / 3.184 / 4.520 / 5.042 / 5.042 | 60 / 3.096 / 5.130 / 5.362 / 5.362 | 60 / 1.731 / 1.876 / 2.172 / 2.172 | 60 / 1.691 / 1.885 / 1.951 / 1.951 |
| 1,000,000 | workspace | 60 / 0.960 / 3.346 / 3.447 / 3.447 | 60 / 0.884 / 3.111 / 3.172 / 3.172 | 60 / 1.897 / 9.265 / 12.119 / 12.119 | 60 / 1.710 / 8.872 / 12.545 / 12.545 |

Recorder-on versus recorder-off differences were mixed. At 230,544, workspace dispatch p95 was 3.069 ms on and 3.187 ms off, and scheduling p95 was 8.945 ms on and 9.055 ms off. These are sequential paired batches with alternating recorder order across chunks. A repeated same-size crossover would be needed to estimate recorder overhead independently of run-to-run variation. Draw and phase observations require the recorder.

### Storage to observed draw return

Each character revision was matched to the first completed draw that captured it at entry. Draw observation measures a software boundary. Onscreen glyph changes and physical presentation timestamps remain unmeasured. These recorder-on cells had zero unmatched or dropped revisions and zero shared draws.

| UTF-16 size | Timing | Native | Workspace |
| ---: | --- | --- | --- |
| 1,000 | immediate | 60 / 1.350 / 2.053 / 3.120 / 3.120 | 60 / 3.991 / 37.844 / 38.361 / 38.361 |
| 10,000 | immediate | 60 / 1.451 / 2.113 / 3.275 / 3.275 | 60 / 4.019 / 37.010 / 39.291 / 39.291 |
| 100,000 | immediate | 60 / 1.246 / 1.920 / 2.078 / 2.078 | 60 / 4.052 / 36.779 / 37.684 / 37.684 |
| 230,544 | immediate | 60 / 3.211 / 4.244 / 4.365 / 4.365 | 60 / 4.295 / 37.911 / 39.329 / 39.329 |
| 500,000 | immediate | 60 / 3.374 / 5.146 / 5.546 / 5.546 | 60 / 4.136 / 37.455 / 39.403 / 39.403 |
| 1,000,000 | immediate | 60 / 3.460 / 4.874 / 5.412 / 5.412 | 60 / 4.145 / 36.517 / 39.514 / 39.514 |
| 230,544 | idle | 60 / 5.260 / 7.227 / 8.551 / 8.551 | 60 / 4.252 / 37.719 / 47.032 / 47.032 |

Workspace immediate dispatch p95 stayed in the 1.973–3.400 ms range as size increased. Workspace draw p95 stayed in the 36.517–37.911 ms range. Native dispatch p95 rose from 1.561 ms at 1,000 to 4.520 ms at 1,000,000. This scaling comparison holds active paragraph length constant.

At each immediate size, all 20 workspace commit draws returned later after storage observation than any of the 40 marked-text draws. At 230,544, both timing conditions had 20 commit calls. For immediate commits, dispatch, storage to draw entry and draw-body p95 were 3.211, 37.866 and 0.351 ms respectively. After idle, the same measures were 5.103, 42.175 and 0.389 ms. The p95 inclusive coordinator and projection intervals were 2.253 and 1.934 ms immediate, and 3.742 and 3.136 ms after idle (20 intervals of each phase per timing). Phase durations overlap. These boundaries locate the measured delay before draw entry without identifying its cause.

### First action after idle at 230,544

The first action starts synthetic marked text. Each idle window elapsed independently before the measured burst. The first-revision column measures the same storage-to-draw boundary as the table above. Each cell has five first-action samples. The immediate runs omitted the idle wait.

| Host | Timing | Idle range, seconds | First dispatch | First scheduling delay | First revision to observed draw |
| --- | --- | --- | --- | --- | --- |
| native | immediate | — | 5 / 3.845 / 3.937 / 3.937 / 3.937 | 5 / 0.011 / 0.027 / 0.027 / 0.027 | 5 / 4.158 / 4.266 / 4.266 / 4.266 |
| native | idle | 5.053–5.065 | 5 / 6.625 / 7.711 / 7.711 / 7.711 | 5 / 0.048 / 0.089 / 0.089 / 0.089 | 5 / 7.647 / 8.551 / 8.551 / 8.551 |
| workspace | immediate | — | 5 / 1.065 / 1.176 / 1.176 / 1.176 | 5 / 0.012 / 0.013 / 0.013 / 0.013 | 5 / 4.868 / 8.100 / 8.100 / 8.100 |
| workspace | idle | 5.047–5.056 | 5 / 2.620 / 3.408 / 3.408 / 3.408 | 5 / 0.030 / 0.045 / 0.045 / 0.045 | 5 / 12.048 / 13.146 / 13.146 / 13.146 |

## Targeted profile

The separate signposts-on run used the same debug executable and the 230,544 middle-position idle setting, with four repetitions per host. The combined 45.771-second Time Profiler and `os_signpost` capture attached to the actual benchmark XCTest process and covered five complete bursts (three native, two workspace). Exported tables contained 4,718 running CPU stack samples at a nominal 1 ms cadence, including 4,158 on the main thread, and 224 completed benchmark intervals with 448 begin/end events joined by burst and raw recorder ID. The remaining three bursts ran after the capture ended. All eight bursts passed integrity checks.

Of 29 sampled workspace main-thread stacks within commit operations, 19 contained `Coordinator.textDidChange` and 18 fell within projection intervals. Of 160 main-thread stacks within native operations, 129 contained glyph or layout frames. These counts describe sampled running CPU time in measured operation windows. For eight workspace commits in those two captured bursts, the gap from operation-end signpost to the matching draw-entry signpost was 31.391–41.546 ms. The gaps contained 225 running main-thread samples, all outside synthetic input operations. Inclusive stack counts were 164 in `GraphHost.flushTransactions`, 107 in `WorkspacePouchController.refresh`, 79 in `WorkspacePouchBridge.updateNSView`, 69 in `WorkspacePouchController.updateIndex`, and 51 in `SpatialWorkspaceCanvasView.layoutTiles`. Stacks can contribute to several counts. Pouch refresh appeared in every gap. The capture establishes that transaction and pouch work occurred in the sampled gaps. Its contribution to the delay remains open pending a controlled comparison.

Run the 230,544 middle-position controls with `--timings idle --repetitions 4 --instrumentation on --signposts on`. While it runs, attach with `xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --attach <XCTest PID> --time-limit 45s --output <new.trace>`. Export `time-profile`, `os-signpost`, `os-signpost-arg` and `os-signpost-interval` tables and check correlation IDs against the signposted run's raw trace. The trace bundle, XML tables and `workspace-commit-gaps.csv` are local under `build/issue-309-evidence/final-profile/`.

## Editing at other positions

The 50 synthetic multi-position bursts on November 19 ran on clean source `de4066e76c27c089a7eea846c2182372b5fa99c1` and debug executable SHA-256 `6d4637af8f8b69cda47c0f99991fc4eb1b9f00fe5599900ab8d450c14ac0cec9`. This build added in-burst caret moves and v2 schedule columns. It recorded five repetitions per host in each cell, with the recorder on and signposts off. The fixed start and middle paragraphs had 50 UTF-16 code units. The end paragraph had 44. Both batches ran on battery with Low Power Mode off, and the display again reported 2× and configured 120 Hz.

The moving burst typed 12 synthetic actions at the start, moved and scrolled to the middle, typed 12 more, repeated at the end, then returned to the start for the final 12. Each move selected the requested UTF-16 offset and changed the vertical scroll origin. The next call began marked text at that destination. All 60 moves passed these checks. The same 30 ms cadence scheduled both moves and inputs. The idle condition waited 5.020–5.062 s before the first group at the start.

| UTF-16 size | Position | Timing | Host | Input dispatch | Input scheduling | Storage to observed draw |
| ---: | --- | --- | --- | --- | --- | --- |
| 230,544 | start | immediate | native | 60 / 3.147 / 4.969 / 5.415 / 5.415 | 60 / 1.729 / 1.886 / 1.931 / 1.931 | 60 / 3.431 / 5.294 / 5.768 / 5.768 |
| 230,544 | start | immediate | workspace | 60 / 0.931 / 2.784 / 2.853 / 2.853 | 60 / 1.681 / 6.304 / 7.850 / 7.850 | 60 / 4.050 / 35.048 / 38.536 / 38.536 |
| 230,544 | middle | immediate | native | 60 / 3.033 / 4.579 / 4.887 / 4.887 | 60 / 1.701 / 1.894 / 2.009 / 2.009 | 60 / 3.360 / 4.959 / 5.266 / 5.266 |
| 230,544 | middle | immediate | workspace | 60 / 0.926 / 2.937 / 3.016 / 3.016 | 60 / 1.871 / 6.010 / 10.837 / 10.837 | 60 / 4.177 / 35.550 / 37.914 / 37.914 |
| 230,544 | end | immediate | native | 60 / 0.930 / 1.555 / 2.293 / 2.293 | 60 / 1.888 / 1.966 / 1.996 / 1.996 | 60 / 1.239 / 2.040 / 3.005 / 3.005 |
| 230,544 | end | immediate | workspace | 60 / 0.871 / 1.954 / 2.079 / 2.079 | 60 / 1.685 / 6.036 / 7.845 / 7.845 | 60 / 4.027 / 33.481 / 36.211 / 36.211 |
| 230,544 | moving | immediate | native | 240 / 2.932 / 5.404 / 7.589 / 9.235 | 240 / 1.678 / 1.934 / 2.010 / 2.088 | 240 / 3.268 / 5.821 / 7.742 / 9.926 |
| 230,544 | moving | immediate | workspace | 240 / 0.912 / 2.883 / 3.083 / 3.130 | 240 / 1.757 / 7.923 / 9.881 / 11.803 | 240 / 4.090 / 35.807 / 38.431 / 39.241 |
| 230,544 | moving | idle | native | 240 / 3.018 / 6.107 / 7.775 / 8.917 | 240 / 1.652 / 1.956 / 2.050 / 2.088 | 240 / 3.348 / 6.535 / 8.228 / 8.983 |
| 230,544 | moving | idle | workspace | 240 / 0.804 / 3.256 / 5.274 / 5.456 | 240 / 1.896 / 8.705 / 16.895 / 19.013 | 240 / 3.822 / 36.315 / 43.783 / 45.127 |

Moves are excluded from input dispatch and input scheduling distributions. The recorded draw observations had 0 unmatched revisions and 0 draws observing multiple revisions. The same visible-rect and first-responder checks passed, with window-key and occlusion-visible flags false. All 50 bursts passed text, composition, undo, redo and save/reopen checks. No recorder samples were dropped.

| UTF-16 size | Timing | Host | Caret move and scroll call | First input dispatch after move | First input scheduling after move |
| ---: | --- | --- | --- | --- | --- |
| 230,544 | immediate | native | 15 / 10.915 / 14.987 / 14.987 / 14.987 | 15 / 3.857 / 9.235 / 9.235 / 9.235 | 15 / 1.211 / 2.088 / 2.088 / 2.088 |
| 230,544 | immediate | workspace | 15 / 4.636 / 6.441 / 6.441 / 6.441 | 15 / 0.930 / 1.611 / 1.611 / 1.611 | 15 / 1.244 / 1.917 / 1.917 / 1.917 |
| 230,544 | idle | native | 15 / 9.171 / 17.381 / 17.381 / 17.381 | 15 / 3.785 / 8.917 / 8.917 / 8.917 | 15 / 1.352 / 2.052 / 2.052 / 2.052 |
| 230,544 | idle | workspace | 15 / 4.561 / 6.507 / 6.507 / 6.507 | 15 / 0.782 / 1.561 / 1.561 / 1.561 | 15 / 1.183 / 1.950 / 1.950 / 1.950 |

Workspace observed-draw p95 ranged from 33.481 to 35.550 ms at fixed positions and was 35.807 ms and 36.315 ms in the immediate and idle moving bursts. First post-move workspace dispatch p95 was 1.611 ms immediate and 1.561 ms after the initial idle.

Use the same runner arguments with `--sizes 230544 --positions start,middle,end,moving --timings immediate` and `--sizes 230544 --positions moving --timings idle` in separate commands. Raw local outputs are under `build/issue-309-evidence/movement-primary/` and `build/issue-309-evidence/movement-resume/`.


## Integrity and reproduction

All 130 middle-position bursts passed final-text, ended-composition, undo, redo and save/reopen checks. Workspace checks included source binding and project flush/reload. The 65 workspace bursts each recorded four serialization invocations and zero serialization-cache rebuilds, media-index rebuilds or projection resets between counter snapshots. The CSV exports matched 1,560 schedule, 787 probe and 8,460 trace rows in JSON. No recorder samples were dropped.

For the middle-position measurements, run from the measured checkout and use a new output directory each time. The runner handles `CFFIXED_USER_HOME` isolation.

```sh
scripts/benchmark-editor-input.sh --configuration debug --sizes 230544 \
  --shapes short --formats plain --positions middle --traces hangul \
  --timings immediate --repetitions 5 --cadence-ms 30 \
  --instrumentation on --signposts off --output build/input-230544-immediate-on
```

Run both recorder settings for the immediate size chunks `1000,10000,100000`, `230544`, `500000`, `1000000`, in on/off, off/on, on/off, off/on order respectively. Run 230,544 with `--timings idle --instrumentation on` once as a separate command. The same runner writes `report.json`, `schedule.csv`, `trace.csv`, `probes.csv`, `provenance.json` and logs to each output directory. The local middle-position outputs and audit live under `build/issue-309-evidence/final-matrix/`. The portable archive includes raw synthetic CSV samples and provenance from the 130 middle-position, 50 multi-position and eight signposted bursts. [Raw samples and provenance](./2026-11-18-editor-input-samples.zip)

This baseline has zero real Korean IME or external pixel samples. The initial 230,544-character manual comparison would use 120 bursts across two hosts, Latin and macOS Korean input, three fixed positions, immediate and ≥5 s idle, and five repetitions. Continuous input and scroll/resume need separate trials. Record final committed text and composition separately from fixed-region screen change or synchronized physical-key video. A release threshold and the cause of the reported display stall remain open. [Benchmark and manual verification procedure](../editor-input-benchmark.md)
