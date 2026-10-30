# Phase 2 Core Structure Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, task by task.
> The owner explicitly requested Phase 2 implementation and continuation.

**Goal:** Enforce module boundaries and remove eager full-source assembly from ordinary editor commits.
**Architecture:** Extract dependency leaves into six targets behind a compatibility facade; introduce an immutable source rope and preserve typed native/source/prose projections.
**Tech Stack:** Swift 6, Foundation, AppKit/TextKit, SwiftUI, existing MLX/SwiftMath/Kiwi dependencies.
**Spec:** `docs/superpowers/specs/2026-10-29-phase2-core-structure-design.md`.

## Global Constraints

- Preserve Phase 1 storage format, original legacy archives and strict open/recovery checks.
- No UI/Fiction dependency in generic storage; no new dependency/model/network operation.
- Accepted text is durable across switch/quit without waiting for a debounce timer.
- Preserve Hangul IME, native undo, focus, selection, Ghost keys and exact Unicode bytes.
- Inline review, synthetic test data and CFFIXED_USER_HOME isolation.

## Review Focus

- Same-text external replacement and A→B→A callbacks must retain ownership fencing.
- Source chunks must not split surrogate pairs or normalize Unicode/line endings.
- Code/math/media boundaries and source-only markup need exact coordinate mapping.
- Reentrant save and newer edits must not mutate an already captured source snapshot.
- Bundle resources and tests must use their new owning module, including release builds.

### Task 1: Foundation and generic storage boundaries

**Files:** `Package.swift`, new `Sources/PurloryFoundation/`, `Sources/PurloryStorage/`, compatibility imports and storage tests.
**Interfaces:** Existing public project/value/store APIs remain available through PurloryCore; internal cross-target collaboration uses package access.

- [x] Add and observe module-boundary regression before extraction.
- [x] Move generic values/storage, keeping legacy conversion and session/UI glue above Storage.
- [x] Run storage/import/recovery/session suites and build; review and commit.

### Task 2: Complete the dependency DAG

**Files:** new `Sources/PurloryDocumentEngine/`, `Sources/PurloryInference/`, `Sources/PurloryIntelligence/`, `Sources/PurloryWorkspaceUI/`; app resources, package/bundle scripts and tests.
**Interfaces:** PurloryCore becomes the compatibility export; generation accepts assembled prompts and domain context stays above model execution.

- [x] Extract domain-neutral prompt/configuration contracts and relocate domain assembly/bridges to avoid cycles.
- [x] Move editor primitives, analysis and UI composition to their owners with minimal package interfaces.
- [x] Update resource ownership and enforce dependency graph; run full build/test and commit.

### Task 3: Separate editor responsibilities

**Files:** existing giant `BlockTextView.swift` and new focused codec, decoration, attachment, overlay and input files.
**Interfaces:** Preserve existing editor call sites, delegate events and state ownership; coordinator remains in WorkspaceUI.

- [ ] Extract complete responsibility units without changing serialization/input behavior.
- [ ] Run serialization/fuzz, native editor, IME/undo/media and transition regressions; review and commit.

### Task 4: Incremental immutable document sources

**Files:** shared `DocumentRopeIndex.swift`, WritingDocument/snapshot/session source boundaries, editor codec/coordinator and typed index adapters; new source/commit regressions.
**Interfaces:** Immutable source snapshots support exact UTF-16 replacement and lazy cached materialization; typed index views preserve existing coordinate semantics.

- [ ] Observe failing snapshot/boundary/materialization and native ordinary-edit regressions.
- [ ] Implement shared persistent tree/source representation and local editor commits; retain verified full-rebuild fallbacks.
- [ ] Route persistence, external replacement and explicit consumers through current source snapshots.
- [ ] Run fuzz/oracle, long-document, IME/undo/switch/save/failure tests; review and commit.

### Task 5: Integrated evidence

- [ ] Review full branch for module cycles, stale source consumption, data ownership and resource regressions.
- [ ] Run swift build, swift test, swift build --product PurloryBench and git diff --check.
- [ ] Build developer bundle and run isolated launch/quit once after implementation.
- [ ] Record exact structural/performance results and remaining native/Store acceptance limits.
