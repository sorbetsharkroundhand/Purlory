# Phase 3: Intelligence and Runtime

The owner authorized Phase 3 after Phase 2, including continued implementation without another approval checkpoint. The contract is the five-item roadmap in the supplied proposal. Current release epic #99 permits this expanded scope and requires inline review. The completed #149 cache contract remains the baseline for capability and lease safety.

## Outcomes and boundaries

1. Move ProjectSession, CompletionController, BackgroundIndexer and SpatialWorkspaceController to Observation. Separate project presentation dependencies from manuscript dependencies; changing a body must not invalidate title/list/chrome readers. Preserve synchronous native invalidation using narrow typed change streams where controllers need ordered events. Keep unrelated settings/controllers on Combine. Observation must not turn execution state, caches or callbacks into view dependencies.
2. Store rebuildable knowledge in SQLite WAL with scene-granular rows and FTS5 source search. ProjectStore owns generic safe file access; Intelligence owns the schema and queries. Preserve the old JSON until migration is verified. Use original-source proofs and a fallback for missing/stale/unindexed source, unsupported short queries and tokenizer differences. Never index in editor or prediction hot paths.
3. Add one bounded immutable A+B prefix slot alongside the live request cache. Exact token IDs, model/config ownership and proven all-layer clone/trim capability govern reuse. Mutable live caches must never alias pinned state. Unsupported topologies retain fresh prefill. Clear both tiers on model retirement and memory pressure.
4. Add explicit durable scene/document snapshots, comparison and paragraph/scene restoration. Store writer-owned versions in UserData/CAS, outside Intelligence. Keep stable document identity separate from scene/source revision. All restoration uses current original-source proof, runtime ownership and the existing undoable document transaction. Ambiguous or stale targets refuse application.
5. Extend existing Kiwi sentence diagnostics with cadence variation and conservative character voice fingerprints. Reuse sentence endings/rhythm rules and explicit dialogue attribution. Require sufficient samples, original evidence and bounded analysis. Keep uncertain attribution quiet. Integrate findings into existing diagnostics/report/navigation, and keep preferences in WriterStyleProfile.

## Implementation details

Observation uses property access tracking for SwiftUI and explicit typed native change streams only for existing synchronous ownership/policy consumers. Project presentation reads are a documented metadata-only view of the current value; source-bearing reads retain their full invalidation. No cached stale project copy becomes an editing authority. Source revisions remain immutable.

SQLite opens only validated derived-storage paths, including its WAL/SHM companions. Transactions update changed scene rows and metadata, with exact hashes to skip identical payloads. A successful read-back verifies migration before the database becomes authoritative. Corrupt derived state may be rebuilt; neither manuscripts nor UserData are recovery targets. Search candidates are checked against the captured current source before evidence is exposed.

Cache pinning is capability-gated against the checked-in MLX implementation. Only an independently cloned and trimmed prefix is retained, with a bounded token budget. Rehydrating a pin creates another independent live cache. The pin can save prefix work on cursor changes without treating generated tails as source truth. Quantization defaults, speculative decoding and grammar masks are outside this phase.

Snapshots are explicit writer actions. Comparison is deterministic and shows saved/current original paragraphs. A chosen replacement is applied only to the document/version shown, through WorkspaceDocumentTransaction. No automatic merge, no duplicate live manuscript in the knowledge graph, and no snapshot deletion during cache cleanup.

Cadence and voice are local and model-free. Foreground completion has priority. Background work observes cancellation, project/generation ownership, thermal and low-power policy. Cursor-bounded help never uses later dialogue; an explicitly requested whole-project report has a separate scope.

## Inline design review

- A macro-only Observation conversion would retain whole-project fan-out; presentation and source dependencies must be tested separately.
- Asynchronous Observation rearming alone could miss ownership transitions; native invalidation retains synchronous typed events.
- FTS alone cannot safely represent unsaved text or all Korean substrings; exact current-source fallback is required.
- A shallow KV array copy could alias live mutation; clone proof and mutation tests precede reuse.
- Snapshots are writer decisions, so Intelligence eviction and rebuild must leave them intact.
- Voice findings without sufficient attributed dialogue would violate the evidence-first contract; silence is the default.

## Verification

Each new behavior starts with a failing deterministic regression. Include observation fan-out and stale-action tests, SQLite migration/rollback/symlink/search parity, cache ownership/clone/unsupported topology tests, snapshot persistence/undo/stale-proof tests, and cadence/voice evidence fixtures. Finish with module-boundary checks, swift build, swift test, Bench build, developer bundle and isolated launch/quit. Record exact evidence; no proposal latency estimates, shipping-model inference or Store acceptance claims without measurement.
