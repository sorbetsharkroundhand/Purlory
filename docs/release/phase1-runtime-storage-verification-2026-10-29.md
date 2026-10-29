# Phase 1 runtime and storage verification — 2026-10-29

Local implementation evidence for the owner-approved Phase 1 design. This is
not a release gate, remote CI result, or Store distribution approval.

## Implemented behavior

- Production startup, editor commands, save/export, background flush and quit
  use ProjectSession. Compatibility legacy types remain for import and tests;
  the production app no longer constructs an editable EntryStore or routes to
  LegacyWorkspaceView.
- A valid active project takes precedence. With no active project, the configured
  legacy library is copied and fully verified before activation. The original
  archive and images remain untouched. Documents retain IDs, active selection,
  exact text bytes, sibling order, folders and writer-owned records.
- Explicit recovery selection is available from first run, startup errors and
  the File menu. Corrupt primary archives are not silently replaced by recovered
  files. Old journal.md content and empty libraries are supported. The folder
  picker grants access to adjacent images as well as the selected archive.
- Reopening a verified migration preserves subsequent project edits and added
  assets. Preparation fences editing and quit; failure preserves the prior
  owner. A concurrent process establishing an active project prevents initial
  migration from replacing its marker.
- Warm saves reuse unchanged CAS records after checking paths and file versions.
  Failed commits discard the baseline. Open, import, activation and recovery
  retain full content checksum verification.

## Regression evidence

Failing regressions were observed before the corresponding implementation:
whole-project reads on a one-document edit; lost legacy selection/order; save
missing pending editor text; quit during unresolved startup; empty migrated
libraries lacking an editable document; concurrent initial activation; mixed
folder ranks changing sibling order.

Focused results: storage and fault suites, 79 tests passed; startup/import/writer
data suites, 66 passed; command/shutdown/editor-transition suites, 47 passed;
final startup and legacy migration suites, 21 passed. These overlap and must not
be summed as a unique test count.

The final full suite passed: **1,499 tests, 4 skipped, 0 failures** in 212.214
seconds. Tests ran with a disposable CFFIXED_USER_HOME and synthetic data; no real
manuscript is an acceptance fixture. `swift build`,
`swift build --product PurloryBench` and `git diff --check` also passed.

The four intentional skips require an explicitly supplied synthetic journal
fixture (two tests), an owner-selected real model (one), or opt-in native capture
(one). None is counted as executed acceptance evidence.

## Developer bundle and launch evidence

`scripts/build-purlory-app.sh` passed, including release compilation, Metal
library preparation, privacy manifest, icon and notice validation. The packaged
inventory contains 16 dependencies and 37 vendored/resource components, with no
bundled LLM weights. `scripts/smoke-purlory-app.sh` passed: clean-home, no-model
startup, normal quit, no new crash report, no legacy entries.json creation and
no model download directory. The smoke script uses a temporary bundle copy with
a unique preferences identity and CFFIXED_USER_HOME.

The original developer artifact is `build/Purlory.app`:

| Field | Value |
| --- | --- |
| Source revision | `e9e6a3cf1e8eabe7b78172b0c2fbe6d1c01ddecc` |
| Source dirty | `false` |
| Version / build | `0.1.0` / `1` |
| Executable SHA-256 | `d3a9d456e0f7357bf5f59fda19bc52347dc45a1ae5c08bcd0c46df61a9412a3a` |
| Notice inventory SHA-256 | `a363da53b7d2c582237804a742c939cb5e84b3c5704afecdb4d3e8394b464f22` |
| Environment | macOS `27.0.1` (`26A434`), `arm64` |
| Model | None selected for this verification |
| Date | 2026-10-29, Asia/Seoul |

The allowlisted metadata collector also produced local
`build/phase1-support.json`; it does not collect writer data. Subsequent changes
to this report and the plan are documentation-only and do not rebuild the app.

## Measured storage work

The same counting filesystem wraps real local storage in
ProjectIncrementalSaveTests. Counts exclude manifest reads and filesystem
metadata operations. Each warm-edit sample changes one manuscript after a
successful save has established the baseline.

| Documents | Before: content reads per edit | After: content reads per edit | After: new blob writes |
| --- | ---: | ---: | ---: |
| 1 | 3 | at most 2 | 1 |
| 100 | 300 | at most 2 | 1 |
| 120 | 360 | at most 2 | 1 |

Metadata-only and no-op warm saves perform zero content reads and zero blob
writes. Unchanged assets and UserData are not reread. Tests cover corruption,
missing files, same-size replacements with restored modification time, symlinks,
external manifests, exact Unicode/CRLF bytes and failed manifest commit/retry.

This is a content-I/O result, not a latency benchmark or a claim that the entire
save is O(changes). Path/version checks and manifest work remain O(record count),
and in-memory comparisons can scale with manuscript size. File versions detect
ordinary mutations; corruption that leaves all file metadata unchanged is
detected at the strict open/activation/recovery checksum boundary.

## Acceptance limits

Automated editor regressions exercise marked text, focus, selection and undo.
Human Hangul IME, Ghost key behavior, VoiceOver and interaction-quality checks
remain owner checks on one identified candidate, as specified in
verification-and-support.md. No real model was selected or downloaded. Native
UI smoke, signed archive, sandbox/Store submission and remote CI are not claimed
by this local report.
