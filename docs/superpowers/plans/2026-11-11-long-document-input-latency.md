# Long-document input latency implementation plan

> **For agentic workers:** Execute inline with superpowers:executing-plans; the current release directive requires inline review without subagents.

**Goal:** Remove document-sized work from ordinary typing and Hangul composition, including long research notes.

**Architecture:** Preserve the existing native text view and immediate durable source publication. Limit caret glyph work to the current line. Prepare research-note entity records on explicit inspection, with immediate invalidation and source-version caching.

**Tech Stack:** Swift, AppKit/TextKit 1, SwiftUI, XCTest.

**Spec:** Current user report and AGENTS.md editor/data invariants. The reported document is a roughly 237k-character note with 6,600 lines, so synthetic note fixtures must accompany manuscript coverage.

## Constraints and review focus

- Preserve IME ownership, selection, Undo/Redo, Ghost semantics and immediate autosave capture.
- Do not edit or launch tests against user manuscripts.
- Changed/deleted notes and project switches must retire stale references immediately.
- Equal-length Hangul replacement must not compare/materialize whole sources.
- Heading-derived entity cards must still become available after typing settles or explicit inspection.
- Keep ordinary native caret geometry, including empty final lines and mixed-script text.

## Task 1: Bounded input and note preparation

Files: `BlockTextView+Overlays.swift`, `WorkspaceEntityController.swift`, `LongDocumentInputLatencyTests.swift`, `WorkspaceEntityTests.swift`.

- [x] Add and run regressions for offscreen glyph generation and note-source materialization on marked-text updates; observe RED.
- [x] Replace the total-glyph query with local validated character/glyph lookup.
- [x] Compare note versions by identity; retire changed records synchronously and prepare note records on explicit inspection. Keep explicit hover functional and reject stale snapshots.
- [x] Verify source publication, heading refresh, project/deletion invalidation and existing entity/IME/undo tests.
- [x] Compare synthetic native and mounted workspace input timings before/after, separating handler work from layout/paint and long-single-paragraph limits.
- [x] Run `swift build`, `swift test`, `swift build --product PurloryBench`; review the complete diff inline. Record measured evidence and limitations.

## Investigation ledger

- Baseline is main `54816549`, refreshed against origin; unrelated untracked user document preserved.
- Native multi-paragraph input remains about 0.2ms at 1M characters. Mounted workspace p95 stalls reach 469ms; sampling identifies `caretLineGeometry` -> `numberOfGlyphs` -> whole-document glyph generation.
- Research notes are synchronously materialized and hashed in the entity subscription on every edit; existing long-novel tests exercise manuscript documents and miss this path.
- Single 300k-character paragraphs are slow in both the native baseline (~50ms) and Purlory (~60ms), a separate TextKit paragraph-layout limit; do not claim to have removed it.

## Review handoff

The user asked to verify changes made concurrently elsewhere. Product changes are now under review rather than further implementation. The workspace contains those additional source optimizations alongside the caret fix and tests added here. Review-only coverage compares indexed/uncached source coordinates and streaming Unicode/chunk behavior. The newly added resume-brief test had invalid constructor arguments; test setup was corrected to enable validation. The focused 36-test run passed, including note edit invalidation and source coordinate equivalence.

Ruling: prepare note records only on explicit hover inspection, rather than adding an idle background task. Their terms are used only for Option inspection; this avoids idle work competing with typing while preserving exact-source validation.

Final verification: isolated full suite completed with 1,631 tests, 8 skips and no failures. Application and benchmark-product builds passed. Standalone synthetic workspace p95 settled time fell from 37.730ms to 13.832ms at 237k characters and from 542.693ms to 12.926ms at 1M. See [verification report](../../engineering/2026-11-11-input-latency-verification.md) for scope, methodology and remaining native IME limitations.
