# Phase 3 Implementation Plan

**Execution:** inline, regression first, no subagents. The owner authorized all five tasks and automatic continuation.
**Design:** `docs/superpowers/specs/2026-10-30-phase3-intelligence-runtime-design.md`.

## 1. Observation and narrow presentation dependencies

- [x] Add failing regressions for metadata/source/save invalidation and synchronous stale-result retirement.
- [x] Migrate the four state owners and SwiftUI wrappers; preserve typed native event ordering.
- [x] Separate metadata reads in navigator, tabs and chrome; keep body readers current.
- [x] Run focused native/ownership/pressure/Observation suites, review and commit.

## 2. SQLite sidecars and indexed original-source search

- [x] Verify bundled SQLite capabilities; add migration/transaction/path/search regressions.
- [x] Implement schema, safe connection lifecycle, scene upserts and verified JSON import.
- [x] Integrate FTS candidates with exact-source fallback into real search surfaces.
- [x] Verify incremental writes, recovery, removal and search completeness; review and commit.

## 3. Pinned two-tier prefix cache

- [x] Inspect pinned MLX state/clone APIs and add isolation/owner/token/capability regressions.
- [x] Capture and restore a bounded exact A+B snapshot without mutable aliasing.
- [x] Integrate prompt boundaries, lease retirement and pressure cleanup; review and commit.

## 4. Durable semantic scene snapshots

- [x] Add version/scene identity, storage, comparison and stale/undo regressions.
- [x] Implement durable capture and original paragraph comparison.
- [x] Expose capture/list/compare/apply in the writing workspace with guarded transactions.
- [x] Verify backup/cache-purge survival, navigation and native undo; review and commit.

## 5. Kiwi cadence and attributed character voice

- [ ] Add sufficiently sampled cadence/voice fixtures plus quiet ambiguous/short cases.
- [ ] Implement bounded Kiwi analysis, distribution comparison and evidence anchors.
- [ ] Integrate diagnostics/report/navigation with cursor and foreground priority fences.
- [ ] Verify local/model-free behavior and writer preferences; review and commit.

## 6. Integrated evidence

- [ ] Review module/data/evidence/ownership invariants across the branch.
- [ ] Run module checks, swift build, swift test, swift build --product PurloryBench and diff checks.
- [ ] Build developer bundle, run isolated launch/quit and record artifact identity and remaining owner acceptance.
