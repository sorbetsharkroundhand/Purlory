# Phase 1 Runtime and Storage Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, task by task. The owner approved the design and instructed implementation on 2026-10-29.

**Goal:** Make production editing project-only and avoid rereading unchanged CAS content during warm saves.

**Architecture:** Preserve the existing manifest format and strict open/activation checks. ProjectStore reuses verified records with file-version checks. Legacy startup and explicit opening copy data through the existing importer before ProjectSession adopts it.

**Tech Stack:** Swift 6, Foundation/Darwin, SwiftUI/AppKit, XCTest; no new dependency.

**Spec:** `docs/superpowers/specs/2026-10-29-phase1-runtime-storage-design.md`

## Global Constraints

- Never mutate legacy source data in place or activate an unverified project.
- Generic storage remains independent of Fiction-specific types.
- Preserve Hangul IME, selection, undo, cancellation and save-failure retry.
- No real manuscripts or model/network setup in tests; isolated preferences and temporary directories only.
- Keep current disk format and required CI. Full open/recovery verification remains strict.

## Review Focus

- Same-size replacement or restored modification time must invalidate cached file trust.
- Unicode-equivalent strings with different bytes must retain their exact representation.
- A failed manifest commit must not advance the reusable baseline.
- A corrupt legacy source must remain accessible for explicit recovery without silent fallback.
- Closing/saving during migration must not race ownership adoption or drop marked text.

### Task 1: Verified incremental CAS saves

**Files:** `Project/ProjectFileSystem.swift`, `Project/ProjectStore.swift`, new `Project/ProjectSaveBaseline.swift`; new `Tests/PurloryCoreTests/ProjectIncrementalSaveTests.swift`.

**Interfaces:** Add optional `ProjectFileSystem.version(of:) throws -> ProjectFileVersion?` with a strict default. Keep `ProjectStore.save`, `load`, activation and all public save callers unchanged. Store one project baseline with exact manifest bytes, snapshot values and file versions.

- [ ] Add and observe failing content-I/O tests for one edit in 1/100/120 documents, metadata/no-op saves and unchanged assets/UserData.
- [ ] Implement exact-byte record reuse, before/after file-version checks, strict fallback and baseline invalidation on failure/external change.
- [ ] Add corruption/replacement/symlink, Unicode, kind change, external-manifest and failed-commit/retry cases.
- [ ] Run `swift test --filter 'ProjectIncrementalSaveTests|ProjectStoreTests|ProjectFaultRecoveryTests|ProjectUserDataTests|ProjectSessionTests|ProjectUserDataSessionTests|LegacyProjectMigrationTests'`; require zero failures.
- [ ] Commit the independently testable storage slice.

### Task 2: Safe project startup from legacy data

**Files:** new `Onboarding/ProjectStartupCoordinator.swift`, `Project/LegacyProjectMigrator.swift`, `Onboarding/ImportProjectCoordinator.swift`; new `Tests/PurloryCoreTests/ProjectStartupTests.swift`.

**Interfaces:** `ProjectStartupCoordinator(session:store:storageLocation:)`, `bootstrap() async throws`, `openLegacyLibrary() async throws`; use existing session activation and writer-data preparation. Add read-only legacy source selection and preserve active document/order on first migration.

- [ ] Add and observe failing tests for automatic legacy startup, existing project precedence, exact original preservation and idempotent reopening.
- [ ] Implement configured-root-only startup/import; preserve selection, navigation and writer records; support explicit recovery-file import and old journal source without overwriting originals.
- [ ] Add bad marker/source, failed activation, changed source and recovered-source ambiguity regressions.
- [ ] Run focused startup, import, migration, writer-data and recovery suites; require zero failures.
- [ ] Commit the startup slice.

### Task 3: Route all production editing through ProjectSession

**Files:** `Sources/Purlory/PurloryApp.swift`, `PurloryCore/ContentView.swift`, `PurloryCore/AppCommands.swift`, `Project/ProjectTerminationCoordinator.swift`; relevant command/shutdown/editor-transition tests and release access documentation.

**Interfaces:** ContentView takes the startup coordinator instead of a legacy workspace. Commands and app lifecycle use ProjectSession directly. Termination calls the session's existing marked-text transition/flush boundary.

- [ ] Add and observe failing production-routing and migration-in-flight shutdown regressions.
- [ ] Replace legacy entry with verified project import/open; remove duplicated production view, consumer, save/export/command and lifecycle routes.
- [ ] Retain importer-required legacy value types and any compatibility tests still exercising useful contracts.
- [ ] Run focused command, shutdown, editor-transition, first-run and startup suites; require zero failures.
- [ ] Commit the runtime routing slice.

### Task 4: Integrated verification and review

- [ ] Review the complete diff against every spec invariant, including warm-cache fault cases and migration access.
- [ ] Run `swift build`, `swift test`, `swift build --product PurloryBench` and `git diff --check`.
- [ ] Follow the existing batched native-app policy; record precisely what was and was not exercised.
- [ ] Record measured content reads/writes and remaining metadata/manifest O(N) work in release evidence; report manual/Store limits accurately.

## Execution record

- Baseline: 39 relevant tests passed before implementation, commit `7bf0087` contains the proposed design.
- Owner approved that design and explicitly requested implementation. Continue inline without another approval handoff.
- Ruling: use the current clean, dedicated `codex/phase1-runtime-storage` checkout. No unrelated edits are present, and this keeps the existing prepared native dependencies available.
