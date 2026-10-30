# Phase 2 core structure verification — 2026-10-30

## Implemented scope

The owner requested the supplied roadmap's Phase 2. The local implementation is on
`codex/phase2-core-structure`, based on completed Phase 1 `3d6507a`. Source commit
`c8250f9fbab0de963ff366e0e8d4c11c5a080aea` was clean for both artifacts below.
Refreshed `origin/main` remains `35ee95e`; this report does not claim a main merge or remote CI run.

- Six implementation targets now own Foundation, Storage, DocumentEngine, Inference,
  Intelligence and WorkspaceUI. PurloryCore is a seven-line compatibility export.
  The CI boundary check validates dependencies and source imports, including the
  generic storage and UI-free analysis/execution boundaries.
- The native view owns its state in one place; codec, decorations/layout, attachment
  lifecycle, overlays and input handling live in five role extensions. The SwiftUI
  bridge and attachment values have separate files. Extraction preserved every
  statement apart from module access and file/import boundaries.
- DocumentRopeIndex shares immutable split/merge machinery across render, native row,
  prose and manuscript source trees. Typed native/source/prose projections retain
  their different coordinate contracts; they are not collapsed into one ambiguous map.
- DocumentSource keeps accepted edits in immutable snapshots immediately. Ordinary
  project bindings publish the source version without joining the whole Markdown
  document. Explicit consumers share a synchronized per-version string cache.
  Existing body APIs and the persisted body field remain compatible.
- The Markdown codec updates affected row/fence pieces. Metadata and native ownership
  checks use source/runtime identity. Background source preparation waits for idle
  before materializing same-document edits. Uncertain/structural native edits retain
  the verified full rebuild path.
- Font and icon resources belong to DocumentEngine and WorkspaceUI respectively.
  Developer bundling, native archive packaging and the audited notices inventory
  reference the owning modules.

## Automated evidence

| Check | Result |
|---|---|
| `swift build` | Passed |
| Isolated `swift test` | 1,509 tests, 4 explicit skips, 0 failures; 216.867 s |
| `swift build --product PurloryBench` | Passed |
| Module dependency/import guard | Passed; enabled in CI |
| Notices rejection regressions | 18 tests passed |
| Developer release bundle | Built and resource/privacy/icon validation passed |
| Isolated launch/quit smoke | Model-free boot, normal quit, no crash |
| Unsigned Xcode archive | Archive and resource/privacy/icon validation passed |
| Sandboxed storage probe | Container write/reopen passed; external write denied; unsandboxed control rejected |
| `git diff --check` | Passed |

Tests use disposable fixtures and CFFIXED_USER_HOME. The smoke app has an isolated
home and bundle identity. The storage probe removed its test data; macOS retained
only its protected container-manager record.

Regression evidence includes exact Unicode/CRLF snapshots, scalar-boundary rejection,
400 range-edit oracle steps, shared concurrent materialization, old snapshot retention,
20,000-piece local mutations below 256 tree visits, lazy native source publication,
actual mounted SwiftUI binding updates without reload/materialization, native undo,
retired activation rejection, unchanged Codable keys, and save-before-termination.
The full suite also covers Hangul marked text, Ghost keys, serialization fuzz,
math/media, source navigation, recovery and stale publication.

The source types and native commit API were observed failing before implementation.
A separate callback regression reproduced eager BackgroundIndexer materialization
before its idle preparation fix. Focused intermediate suites passed before the full run.

## Identified artifacts

Both artifacts report sourceDirty=false and the source revision above.

| Artifact | Path | Executable SHA-256 |
|---|---|---|
| Developer bundle | `build/Purlory.app` | `f0b98336f88f44b5c5bb2fdf10dd88d9834d5e9ee618633b71360f0e052ec5d5` |
| Unsigned native archive | `build/Purlory.xcarchive/Products/Applications/Purlory.app` | `a009ec67dddfeba186a3afbf43b99cbbaa23026907115ab608ae53d6df806184` |

## Limits and next work

No end-to-end 0.05 ms typing or O(log N) UI latency claim is made. Native TextKit,
large paragraph serialization, explicit full-source consumers and structural rebuilds
still have their existing costs. The locality proof concerns source-tree mutations
and removal of eager whole-Markdown joining from ordinary project commits.

These checks do not replace human IME/Ghost/VoiceOver acceptance, shipping-model
utility measurements, Store signing or App Store approval. The unsigned archive and
ad-hoc developer bundle are separate distribution evidence.

The owner subsequently authorized automatically continuing to Phase 3: Observation,
SQLite/FTS5 knowledge/search, pinned two-tier prompt cache, durable semantic scene
snapshots and model-free Kiwi cadence/voice analysis. That work is not claimed by
this Phase 2 report.
