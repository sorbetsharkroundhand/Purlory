# Phase 3 intelligence and runtime verification — 2026-11-01

## Implemented scope

The owner authorized all five Phase 3 outcomes after Phase 2. Work is on
`codex/phase3-intelligence-runtime`; the clean candidate source is `3467c117774c49efc2485a08c8db1da784d4d46d`.
Refreshed `origin/main` remained `35ee95e`. This report records local evidence,
not a main merge, remote CI run or release approval.

- ProjectSession, CompletionController, BackgroundIndexer and SpatialWorkspaceController
  use Observation. Metadata-only presentation reads avoid manuscript invalidation;
  narrow synchronous native events preserve stale-result retirement and ownership.
  Native synchronization reads the current project/activation owner directly; a queued
  SwiftUI Binding value cannot overwrite newer accepted keystrokes or reset the caret.
- Rebuildable knowledge uses validated SQLite WAL storage and scene-granular updates.
  Verified migration retains the legacy JSON. FTS5 narrows explicit source searches;
  every result is proved against current original text, with exact fallbacks for
  short/unproven Unicode queries, unsaved changes and unavailable indexes.
- The live KV cache has an additional independent A+B prefix slot, capped at 4,096
  tokens / 128 MiB. Exact tokens, model/configuration and drained lease ownership
  remain required. Simple and quantized full-prefix layers use independent tensor
  storage; unsupported topologies retain fresh prefill. Model retirement and memory
  pressure clear both tiers. Prompt truncation and tokenizer boundaries are checked.
- Explicit document/heading-section snapshots live in durable UserData records.
  The writing toolbox exposes saved/current original paragraphs and guarded
  per-change or whole-section restoration through native undo. Stable document IDs,
  snapshot UUIDs and scene/content revisions remain distinct. Ambiguous/stale targets
  refuse restoration; cache removal does not delete snapshots.
- Local Kiwi analysis adds narrative length variation and conservative attributed
  character voice shifts using existing morphology windows. Findings require
  sufficient samples and original evidence. Ambiguous attribution stays quiet.
  Margin navigation and explicit reports retain the original source anchors;
  author metadata changes retire stale findings. Preferences stay in WriterStyleProfile.

## Automated evidence

| Check | Result |
|---|---|
| `swift build` | Passed |
| Isolated full `swift test` | 1,548 tests, 4 existing explicit skips, 0 failures; 207.275 s |
| Focused regressions | 34 accessibility-related native tests and 44 source/ownership/editor tests passed |
| `swift build --product PurloryBench` | Passed |
| Module dependency/import guard and diff checks | Passed |
| Developer release bundle | Built; privacy, icon and notices validation passed |
| Final isolated launch/quit | Passed: model-free boot and normal quit |
| Final targeted actual-app checks | Passed through native computer use: fast typing, undo/redo, snapshot save/compare/restore, focus return and relaunch |
| Complete shell UI smoke | Not completed: foreground acquisition failed; no full-script pass is claimed |
| Final unsigned native archive | Built; resource/privacy/icon/notices validation passed |

The tools container identifier lives on its native host so SwiftUI does not
propagate it to child buttons. The actual-app regression checks those distinct
controls on the final artifact. Fast-keyboard UI checks additionally exposed a
queued Binding rollback: a one-character-old source replaced accepted input and
reset the caret. A live project/activation source provider fixes that path; a
deterministic mounted regression covers stale binding values, external replacement
and retired owners. All temporary tracing was removed before the final build.

Tests use disposable fixtures and CFFIXED_USER_HOME. Both actual KV tensor
copy-isolation tests ran using the prepared metallib; policy tests remain available
without opting into Metal. No model was selected or downloaded.

Regression coverage includes Observation fan-out, synchronous ownership retirement,
SQLite rollback/migration/path/symlink/corruption handling, unchanged-row writes,
original-source search parity and memoization, real simple/quantized KV copy
isolation, exact prefix boundaries, durable snapshot backup/purge/export, Unicode
paragraph differences, stale/ambiguous restore refusal, native undo/redo/IME,
Kiwi sample/window bounds, cancellation, quiet ambiguous speakers, Markdown evidence
mapping, author metadata invalidation and special-whitespace quote offsets.
New behaviors were observed failing before implementation. The initial app batch
also exposed accessibility identifier inheritance and queued-source rollback; both
were fixed before the final candidate batch.

## Identified artifacts

Both artifacts identify the clean source revision above with sourceDirty=false.
App version/build: 0.1.0 / 1. Environment: macOS 27.0.1
(26A434), arm64, 32 GiB memory. Final verification: 2026-11-01.
No LLM was selected or downloaded.

| Artifact | Path | Executable SHA-256 |
|---|---|---|
| Developer bundle | `build/Purlory.app` | `0aa59aac28774f0c938683b1dfb37dfb8a40b037f5c9c667018a962dbadf6c07` |
| Unsigned archive | `build/Purlory.xcarchive/Products/Applications/Purlory.app` | `5528f732e4afb30db99b87b4723205dde73e1e9640336e1afd3b783ec9254321` |

Private allowlisted support reports are in `build/phase3-support.json` and
`build/phase3-archive-support.json`. They do not collect manuscripts or logs.

## Actual-app check scope

The final developer artifact was copied to a unique bundle identity and synthetic
CFFIXED_USER_HOME. Native computer use verified rapid text entry without reordering,
typing undo/redo, distinct tool identifiers, opening the versions sheet, saving an
original, showing the exact changed suffix, restoring the whole document, undoing
and redoing restoration, and returning focus to the editor. The original snapshot
record was checked against the synthetic source bytes and its SHA-256 stayed
unchanged. After normal quit and isolated relaunch, the manuscript and saved version
remained present, and comparison reported zero changes. The test app was closed.

The complete AppleScript UI batch was attempted but its foreground-acquisition guard
stopped later runs before typing. It was not weakened or bypassed. Targeted native
computer use supplied the Phase 3 UI evidence above; this does not claim the full
script's image/math/navigation/recovery sequence passed on this candidate. Those
paths retain deterministic coverage in the passing full suite. The script now also
wakes the intentionally hidden typing chrome before opening tools, matching pointer
interaction. Complete scripted UI and human acceptance remain separate checks.

## Limits

Cadence needs at least 8 completed narrative sentences (12 at low sensitivity).
Voice comparison needs 8 earlier plus 4 recent explicitly attributed utterances
(12 earlier plus 4 recent at the existing low default), sufficient lexical evidence
and a stable earlier ending distribution. It does not infer speakers by alternation
or persist learned style as an author decision. Local windows may remain quiet;
an explicitly requested document report can carry evidence across analysis windows.

Snapshots use logical heading sections, not size-dependent indexing chunks.
Duplicate or renamed section targets require a fresh valid comparison. Comparisons
above 2,000 paragraphs use an exact whole-section fallback. Restoration requires
an available undo owner and exact current source/runtime proof.

No proposal sub-millisecond search, storage, typing or prefill latency is claimed.
These automated checks do not replace human Hangul IME/Ghost/VoiceOver acceptance,
shipping-model quality/latency evaluation, Store signing or App Store approval.
The unsigned archive and ad-hoc developer bundle are distinct artifacts.
