# Phase 2: module boundaries and incremental editor sources

Status: implementation requested by the owner on 2026-10-29. Engineering decisions
below are implementation choices, not an invented owner performance acceptance.
Base: Phase 1 `3d6507a`; refreshed origin/main remains `35ee95e`.

## Contract

Implement the supplied roadmap's next phase: real SwiftPM boundaries, smaller
editor responsibilities and an incremental source representation that avoids
joining the entire Markdown document for each ordinary edit. Preserve all
existing manuscript formats, native input/undo/focus, Ghost keys, source anchors,
project generation fences and strict persistence/recovery checks. No model,
network, database or UI redesign is introduced.

The owner explicitly chose “Phase 2 implementation” and then “continue”. Execute
inline in bounded commits; do not repeat the implementation-approval question.
Current #99 asks for inline review without subagents and leaves actual native UX
acceptance to the owner. This branch builds on the completed local Phase 1 branch.

## Approach and tradeoffs

1. Chosen engineering approach: extract dependency leaves and enforce the DAG
   before changing editor data flow. Retain a thin PurloryCore compatibility
   export so app/test clients migrate without a second public API redesign.
2. Move directories mechanically into six targets: rejected because existing
   settings, context assembly, legacy codecs and editor bridges cross directory
   boundaries and would introduce module cycles.
3. Replace TextKit and every index in one rewrite: rejected because native text,
   Markdown source and eligible analysis prose have different coordinates and
   snapshot lifetimes. Preserve typed views while sharing persistent tree
   machinery and making the manuscript source authoritative.

## Modules

- PurloryFoundation: generic document/project identities and immutable values,
  shared source/tree primitives. No UI, Fiction, inference or third-party imports.
- PurloryStorage: generic project CAS, manifest, assets, import, backup and recovery
  primitives. Depends only on Foundation; legacy Fiction conversion stays above
  this boundary.
- PurloryDocumentEngine: Markdown/text structures, coordinate/index algorithms,
  native editor codec/rendering primitives and math integration. Its data
  contracts cannot depend on project UI controllers or the inference engine.
- PurloryInference: MLX/model/tokenizer lifecycle, generation and prompt cache;
  domain-specific context construction belongs to Intelligence/Workspace wiring.
- PurloryIntelligence: knowledge, source evidence and writing analysis. UI glue
  and concrete editor/session orchestration remain in WorkspaceUI where needed.
- PurloryWorkspaceUI: SwiftUI/AppKit presentation and composition of the above,
  including the project session, legacy migration adapters and editor coordinator.
- PurloryCore: compatibility exports only. Package-scoped interfaces are preferred
  to adding public APIs solely to cross a target boundary.

Resource lookup and developer/native bundle scripts must follow resource owners.
Keep the old public library product and app/benchmark entry points buildable.

## Editor responsibilities

Separate the native view's codec, decorations/layout drawing, attachment
lifecycle, overlays and input handling into focused files/components with explicit
state ownership. The SwiftUI coordinator belongs to the composition layer.
File extraction alone is not a performance claim. Do not broaden private state
into public API merely to move source text.

A persistent DocumentRopeIndex provides cached subtree lengths and immutable
snapshots. Its typed consumers retain native, Markdown and prose coordinate
contracts; derived projections must not become alternate manuscript owners.
Ordinary edits update only affected pieces. Full string materialization is lazy
at consumption/persistence boundaries and cached per immutable source version.
No timer may be the sole owner of accepted text: switching, quit, export, search
and save must observe all accepted edits even before the autosave delay expires.
Large structural edits and uncertain mappings may use the existing correct full
rebuild; explicitly measure that fallback instead of hiding it.

## Verification and review

- Fail-first tests for immutable source snapshots, UTF-16 boundaries, exact
  Unicode/CRLF text, range edits and bounded local mutation/materialization.
- Existing parser/serialization fuzz tests remain the oracle for headings,
  lists, code fences, media, math and inline styles.
- Preserve generation/owner rejection, same-document external replacement,
  A→B→A navigation, IME commit, save-before-switch/quit, failure retry and undo.
- Verify a native ordinary edit does not eagerly join the whole Markdown source;
  explicit consumers and saves still obtain the correct complete manuscript.
- Module graph checks ensure Storage has no UI/Fiction/MLX dependency and no
  target cycle. Test/build all targets and both app distribution paths affected
  by resource relocation.
- Required local checks: swift build, swift test, swift build --product
  PurloryBench, developer bundle/resource validation and isolated launch/quit.
  Human IME/Ghost/VoiceOver and Store signing remain separate owner evidence.

No unmeasured 0.05ms/O(log N) end-to-end input claim is accepted. TextKit work,
large paragraph processing and downstream consumers must be reported honestly.
