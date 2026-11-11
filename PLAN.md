# Purlory — Architecture and Context Index

Optional lookup, not a required startup read. Current scope: [#99](https://github.com/sorbetsharkroundhand/Purlory/issues/99); acceptance: the active issue; final RC: [#119](https://github.com/sorbetsharkroundhand/Purlory/issues/119).
Shared invariants and commands live only in `AGENTS.md`.

The previous full plan is preserved in [the historical snapshot](docs/archive/2026-09-10-pre-release-plan.md). September 0.2.0 specs/plans describe their original contracts, including deferred work; they do not override current issues. Section numbers below retain the meaning of legacy `PLAN §N` references.

## 1. Vision
Trustworthy local writing, Fiction First. First release proves editing, recovery and source-backed assistance. Broad platform intelligence is future scope.

## 2. Product decisions
Generic projects; optional local AI; durable writer decisions; quiet evidence-based assistance. #99 owns release scope; #155 owns commercial/version/support decisions.

## 3. Stack and constraints
Swift 6, SwiftUI/AppKit/TextKit, MLX, SwiftPM, SwiftMath. Inspect `Package.swift` and `Package.resolved` for current versions. #150/#152/#154 own distribution and measured hardware support.

## 4. Architecture
| Task | Start in |
| --- | --- |
| Foundation/shared types | `Sources/PurloryFoundation/` |
| Document outline, versions, markdown/image parsing | `Sources/PurloryDocumentEngine/` |
| Project lifecycle, storage, backups, Git | `Sources/PurloryStorage/`, `Sources/PurloryWorkspaceUI/Project/`, `Sources/Purlory/PurloryApp.swift` |
| Model loading, completion runtime, KV cache | `Sources/PurloryInference/` |
| Context assembly, knowledge, writing quality core | `Sources/PurloryIntelligence/Inference/`, `Sources/PurloryIntelligence/Knowledge/`, `Sources/PurloryIntelligence/WritingQuality/` |
| Editor, Ghost, workspace shell, indexing, export | `Sources/PurloryWorkspaceUI/Editor/`, `Workspace/`, `Knowledge/`, `Intelligence/`, `WritingQuality/`, `Export/`, `Media/`, `Storage/` |
| Compatibility umbrella target | `Sources/PurloryCore/` |
| Bench/build/release | `Sources/PurloryBench/`, `scripts/`, `.github/workflows/` |

Resolve paths against the modular targets under `Sources/` above. Search first; proposed components may not exist yet.

## 5. Document, project and workspace
#118 connects the real editor lifecycle; #111 persists writer decisions; #151 proves recovery. Existing project foundations are not proof that every runtime path uses them.

## 6. Knowledge
`HierarchicalMemory`, `KnowledgeSidecarRepository`, `EvidenceAnchor` and existing indexer code are the starting points. #108 delivers source retrieval without a mandatory temporal engine.

## 7. Characters
Existing extraction/lexicon code is reusable. Temporal character-state and canon work are tracked under [#99](https://github.com/sorbetsharkroundhand/Purlory/issues/99) and [#158](https://github.com/sorbetsharkroundhand/Purlory/issues/158) (resumed in current release scope).

## 8. Timeline
Discourse order and story time differ; unknown time remains unknown. Continuity/judging and temporal progression are tracked under [#99](https://github.com/sorbetsharkroundhand/Purlory/issues/99) and [#158](https://github.com/sorbetsharkroundhand/Purlory/issues/158).

## 9. Background understanding
`BackgroundIndexer` owns prepared snapshots. Consult cancellation tests and `docs/cancellation-stress-2026-08-23.md` only for related lifecycle work.

## 10. Prediction
`CompletionController` gates generation; `CompletionEngine` performs it. For editor geometry consult `docs/m3-ghost-text.md` and current tests selectively.

## 11. Context assembly
`ContextAssembler` consumes prepared context. #108/#112 define release source inspection. `docs/autocomplete-context.md` is historical rationale to compare against current code.

## 12. Cache/KV
#149 and [#99](https://github.com/sorbetsharkroundhand/Purlory/issues/99) track generalized prompt-state reuse; #154 owns release measurements. Historical warm replay does not prove append-typing reuse. Do not read old model reports as current measurements.

## 13. Evaluation
#154 owns quality and numeric performance budgets; #156 owns artifact-specific CI/support evidence. `docs/m5-replay-bench.md`, `docs/model-lineup-bench.md` and `docs/editor-perf.md` are dated evidence, read only for the affected metric.

## 14. Roadmap
Use [#99](https://github.com/sorbetsharkroundhand/Purlory/issues/99) and [#158](https://github.com/sorbetsharkroundhand/Purlory/issues/158) for execution order and current issues for status (earlier deferral notes in archived plans are historical context only). Do not duplicate completion counts or merge ledgers here.

## 15. Research
Historical `docs/m*.md` and `docs/superpowers/` are on-demand design/experiment records. Completed designs may explain existing code; deferred designs are not instructions to implement features.

## 16. Debt and verification
#18: dirty media rendering. #152: complete model installation. #153: native UX/accessibility. #150: sandbox/distribution. #119: integrated release gate.
See `docs/release/verification-and-support.md` for artifact identity, automated/manual boundaries and private support reports.
Select tests by the changed contract; preserve required CI/issue gates. Storage needs failure/recovery evidence; concurrency needs stale/cancel coverage; model changes need quality/trajectory evidence; UI needs real app/IME/accessibility evidence.
