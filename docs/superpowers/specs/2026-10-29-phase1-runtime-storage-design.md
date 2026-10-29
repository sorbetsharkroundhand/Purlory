# Phase 1: Project-only runtime and incremental CAS saves

Status: proposed for owner review; implementation has not started.

## Intent and scope

The owner selected Phase 1 from the supplied architecture proposal: retire the
editable legacy runtime and reduce repeated whole-project disk reads during
autosave. Preserve access to every existing manuscript and writer decision.

Baseline: local `1e13d39` and refreshed `origin/main` `35ee95e` have the same
tree (`85127ea378fc6265a1c05ec9b68a2d2fd8359630`). Issue #118 is completed:
ProjectSession already owns normal editing, while LegacyWorkspaceController
enforces exclusive ownership when the explicit legacy workspace is opened.
Issue #151's recovery guarantees remain applicable. This change completes
runtime convergence rather than reproducing #118.

Implement two independently verifiable slices: incremental saves first, then
legacy import/startup and production runtime routing. No module split, editor
rope, event bus, Observation conversion, database migration or model change.

## Approaches

1. **Recommended: verified incremental saves and project-only editing.** Reuse
   the existing CAS format, importer, writer-data preparation and ProjectSession
   transition barriers. Replace the legacy editor entry point with import/open.
   This preserves existing recovery paths and limits schema changes.
2. **Dirty flags alone, followed by immediate legacy deletion.** This reduces
   code sooner, but can miss damaged unchanged files and remove recovery/data
   access paths. Rejected because the current safety contract requires both.
3. **Keep the legacy editor while optimizing saves.** Independently useful but
   insufficient for the owner's selected runtime-unification scope.

The owner selected the Phase 1 scope. The detailed approach and defaults below
are implementation proposals, not recorded owner decisions.

## Slice A: incremental CAS saves

- Keep `ProjectStore` as the actor and interprocess-lock owner. Keep immutable
  document/asset/UserData paths and atomic manifest replacement unchanged.
- Maintain a bounded, in-memory baseline for the most recently saved project:
  exact manifest bytes, document and UserData values, and verified file records.
  Do not retain a second copy of all image/asset bytes.
- Reuse unchanged records and their hashes. Changes to titles, document order,
  trash membership and project metadata update the manifest without rewriting
  manuscript blobs. A body/kind change computes the appropriate new record.
- Compare manuscript bytes exactly, including composed/decomposed Hangul and
  CRLF. Canonical-equivalent Swift String equality is not a byte identity proof.
- Validate paths on every use. A reusable verification requires an unchanged
  local-file identity/version signature, including device/inode, size, and
  nanosecond modification/change timestamps. A filesystem without reliable
  signatures uses strict verification. Do not infer trust from filenames alone.
- Warm autosaves avoid content reads and hashes for unchanged, already verified
  files. Changed/missing/replaced files are reverified or rejected. New writes
  are read back and verified before the manifest commits.
- External manifest changes, cache uncertainty and failed commits invalidate
  the baseline. Publish a new baseline only after successful commit.
- Opening, activation, import and recovery continue to read and hash all
  referenced durable content. Corrupt input must never become an active owner.
- Preserve `previous-project.json`, cancellation checkpoints and generation-aware
  flush behavior. Failure leaves the previous manifest and current dirty editor
  value available for retry.

### Performance and verification boundary

The target is content I/O proportional to changed blobs on a warm autosave.
Manifest serialization and metadata/path validation still scale with record
count; exact in-memory comparisons may scale with manuscript size. Do not claim
the entire save becomes O(changed documents), or promise unmeasured latency.

A metadata signature detects ordinary file mutation/replacement, not silent
storage corruption that leaves metadata unchanged. Strict open/activation and
recovery verification remain the checksum boundary for that case. If retaining
full checksum verification on every autosave is required, cross-save content
read elimination cannot be promised; only duplicate work within a save can be
removed. This tradeoff is explicitly part of the proposed design.

## Slice B: project-only production runtime

- Bootstrap loads a verified active project first. Never override an existing
  active project or reinterpret an unreadable marker as a fresh install.
- When no active project exists, inspect only the configured application storage
  root for legacy data. Do not scan unrelated directories or previous app roots.
  External installations remain accessible through the folder import picker.
- Copy valid legacy archives through `LegacyProjectMigrator`; preserve the
  original archive byte-for-byte, image bytes, document IDs, folders/order and
  writer-owned metadata. Reuse `ProjectWriterDataMigration` before activation.
- Preserve the last selected legacy document where valid. Existing
  `WritingPositionStore` legacy-ID fallback provides caret restoration without
  rewriting legacy position records.
- Use Fiction for an archive containing novel entries, otherwise General; retain
  the complete source archive and all writer records. This is a proposed default
  for the existing project-level mode model, not a new per-document mode system.
- Repeated import uses verified receipts without overwriting edits already made
  in the migrated project. A failed or cancelled migration never activates its
  partial target and leaves source data untouched.
- Inspect supported legacy recovery archives and the older `journal.md` case
  before removing their current entry point. Corrupt/ambiguous sources surface
  a recoverable error and an explicit file-selection path; do not silently pick
  stale recovered data or create an empty replacement.
- Replace "Open legacy library" with opening its verified project copy. An
  already active project is flushed before switching. Existing project
  creation, imports and source search stay model-free.
- Route ContentView, commands, background flush and termination directly through
  ProjectSession. Completion, indexing and diagnostics bind only to project
  snapshots. Remove production construction of EntryStore and the legacy
  workspace, plus their duplicated consumer wiring.
- Retain legacy decoding/value types and any compatibility code still required
  by imports. Retire unused legacy UI only after equivalent data access is proven.
  Generic project/storage code must not acquire Fiction-specific dependencies.
- Keep Hangul marked-text commit, selection, undo boundaries, stale-result
  rejection and save-failure retry behavior on the existing project path.

## Regression and acceptance evidence

Write failing regressions before behavior changes. Use synthetic temporary
projects and isolated preferences; never inspect real manuscripts.

Storage checks:

- Count content bytes/reads/writes for 1, 100 and 100+ document projects; a
  one-document edit must not reread or rewrite unrelated verified blob content.
- Metadata-only and no-op saves; note/manuscript kind changes; exact Unicode
  bytes; UserData edits/removal; shared asset references; bounded cache lifetime.
- Warm-cache corruption, missing blobs, same-size replacement, symlinks, external
  manifest changes and cross-store changes must not bypass validation.
- Faults during blob write/readback, backup write and manifest replacement keep
  the last valid project; a retry succeeds. Strict cold load rejects corruption.
- A newer edit arriving while a save is in flight remains dirty until persisted.

Runtime checks:

- Clean startup; valid legacy startup; existing project wins; duplicate migration;
  source changes during copying; corrupt source; recovery/import retry.
- Original archive/assets and writer decisions survive migration and relaunch;
  selected document/position and folder order remain accessible.
- Save/switch/quit after a Hangul composition commit retain the exact manuscript;
  failed save cancels the switch/quit and leaves editing available.
- Production startup and commands never create an editable EntryStore.
- Preserve deterministic recovery coverage when replacing obsolete legacy-editor
  routing assertions; do not weaken CI or erase still-applicable safety tests.

Run focused regressions, then `swift build`, `swift test` and
`swift build --product PurloryBench`. Follow repository release policy for the
batched actual-app/UI pass with an isolated `CFFIXED_USER_HOME`; do not claim
manual IME/accessibility or Store distribution evidence from automated tests.

## Delivery

Keep the two slices in separate reviewable commits/PRs where practical. Record
measured I/O counts and remaining O(N) work, rather than the proposal's unsupported
sub-millisecond targets. Main remains buildable. No issue is closed without its
merge and required CI evidence.

## Baseline verification (2026-10-29)

Before implementation, the focused test command below passed 39 tests with zero
failures. This verifies the existing baseline, not the proposed changes.

```sh
swift test --filter 'ProjectStoreTests|ProjectFaultRecoveryTests|LegacyProjectMigrationTests|ProjectShutdownTests|LegacyWorkspaceControllerTests'
```

The package build completed in 13.31 seconds and the selected tests in 1.197
seconds. No actual-app/UI, manual IME, accessibility or distribution acceptance
was performed during this design pass.
