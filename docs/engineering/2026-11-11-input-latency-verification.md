# Long-note input latency verification

## Scope

Reviewed the current working tree based on `54816549`, including concurrent input,
source-coordinate, entity-cache and resume-brief optimizations. This is local
debug-build evidence, not a release artifact or an installed-app acceptance claim.

The reported document's structure was inspected read-only: approximately 237k
characters, 6,600 lines, longest paragraph 1,538 characters, stored as a note.
No user manuscript was modified or used as an editable test fixture.

## Findings and corrections

- `caretLineGeometry` asked for `numberOfGlyphs`, which generated offscreen glyphs
  through the whole document. Sampling captured this call during delayed layout.
  The local validity query now generates no more glyphs than the native local
  layout baseline. The regression previously generated all 300,000 characters.
- Entity-card preparation materialized and hashed large notes in the synchronous
  project-change callback. Notes now invalidate immediately, compare immutable
  source versions, and prepare/cache records on explicit inspection. Both a
  committed Hangul edit and an equal-length replacement leave the source
  unmaterialized. Updated and deleted references retire correctly.
- Cached source-coordinate lookup agrees with the uncached path for headings,
  inline formatting, code fences, math, images, lists and terminal blank lines.
  Streaming source helpers preserve UTF-8 distinctions and tag lines across
  chunk/newline boundaries without joining the source.
- The added resume-brief regression initially did not compile because required
  initializer arguments were absent. Test setup was corrected; product behavior
  was not changed during the review phase.

## Measurements

`PURLORY_INPUT_BENCHMARK=1 swift test --filter LongDocumentInputLatencyTests/testWorkspaceInputComparison`

Synthetic note, one heading, repeated Korean paragraphs, 40 updates at the middle
of the document: 30 marked-text updates and 10 committed insertions. The mounted
workspace includes the real source binding and entity consumers. “Settled” includes
the harness's layout/yield cycle and `displayIfNeeded`; it is not a hardware
key-to-photon or real input-method measurement. Values are milliseconds, p95.

| Approximate characters | Before: input handler | After: input handler | Before: settled | After: settled |
| --- | ---: | ---: | ---: | ---: |
| 10,000 | 4.305 | 3.536 | 16.058 | 11.186 |
| 237,000 | 10.008 | 3.984 | 37.730 | 13.832 |
| 1,000,000 | 28.835 | 3.870 | 542.693 | 12.926 |

After-values are from the isolated benchmark invocation, not the run immediately
following unrelated AppKit tests. The latter showed scheduling noise even for the
10k fixture; wall-clock thresholds are therefore supplementary to deterministic
glyph-work, materialization and correctness regressions.

A separate single-paragraph control remains expensive: at 300k characters, native
`NSTextView` input was about 59ms p95 and Purlory about 64ms. This change does not
remove TextKit's very-long-paragraph cost. The reported note does not have that
structure. Native input-method interaction and subjective feel remain manual
checks against the final app artifact.

## Verification

- `swift build`: passed.
- Focused review: 36 tests passed, including the opt-in native/workspace measurements.
- Full `swift test` with an isolated `CFFIXED_USER_HOME`: 1,631 tests, 8 skipped,
  0 failures (237 seconds). The two input benchmarks skipped in this default run
  were executed separately above. Other skips require optional fixtures, Metal,
  a real model or native capture.
- `swift build --product PurloryBench`: passed.
- `git diff --check`: passed.

No remaining correctness defect was identified in this review. Builds retain
dependency warnings; AppKit tests emitted contact-service connection diagnostics
without test failures. The installed app, physical keyboard/OS IME latency and
release packaging were not validated by this run.

Reviewed source fingerprints (SHA-256):

- `BlockTextView+Codec.swift`: `836ea69a9fdcbb4eedb28b859426a2581c825c54c8469a7e7d10e12b3a0f8588`
- `WorkspaceEntityController.swift`: `dbcd52e41b168238c0064a6c002bb9c2b6aba91800fcede23c6726254bd63926`
- `DocumentSource.swift`: `cb0adc096f7ce312910a75351020f5260b53aa7170e57e1717831fa8e9ff10b2`
