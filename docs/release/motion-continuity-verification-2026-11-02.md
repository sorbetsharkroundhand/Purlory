# Workspace motion continuity verification — 2026-11-02

## Scope

The owner requested implementation of the four findings from an Apple-design
animation review. This bounded repair keeps the existing SwiftUI/AppKit workspace,
curves, timing budgets, local-only behavior and persistent editor identity.

- Pause visible tile frames on pointer-down, including before the drag threshold;
  resume on release/cancel. Capture column drop boundaries from the same visible frames.
- Only the still-owning tile snapshot may restore a host it hid. Old completion
  handlers cannot change the opacity of a newer drag.
- Paragraph insertion uses its stationary line without changing attributed text,
  paragraph spacing or target layout during the gesture.
- Pouch reversal preserves the snapshot's visible frame and opacity; repeated
  reversal, restored focus/selection, reduced-motion interruption and detach are covered.

Base: `aa0d9b2`. Product source candidate: `04f8ecc` on
`codex/purlory-motion-continuity`. Later documentation-only commits do not change
these tested product sources. The original main checkout is unchanged.

## Regression evidence

Each repair was preceded by an observed failing native fixture regression:

| Regression | Original failure | Fixed result |
| --- | --- | --- |
| Grab during reflow | Visible width jumped from approximately 1043 to 948 points on pointer-down | Frame stays unchanged; release reaches destination with the same editor |
| Snapshot completion ownership | New drag opacity changed from 0.35 to 1 after an older completion | New drag remains dim until its own completion/cancel |
| Paragraph target retargeting | Target paragraph attributes changed at both tested insertion positions | Rich text and paragraph geometry remain unchanged |
| Repeated pouch reversal | Every reversal reset the visible frame/opacity to an endpoint | Frame/opacity continue from the prior visible snapshot |
| Visible column hit boundaries | Column used the 948-point destination while its tile remained about 1043 points wide | Column and tile use the same visible geometry |

Focused native/spatial review verification: 38 tests, 0 failures.

## Final checks

All final checks passed on the product source candidate above:

| Check | Result |
| --- | --- |
| `swift test` | 1553 tests, 6 skipped, 0 failures (219 seconds) |
| `swift build` | exit 0 |
| `swift build --product PurloryBench` | exit 0 |
| `python3 scripts/check-module-boundaries.py` | exit 0 |

Local commands used `--scratch-path /Users/ryujekyeong/Developer/MINT/.build` to
reuse dependency build inputs. Full logs and exit-code records remain in
`build/motion-continuity/`. The six opt-in skips cover two explicit journal
fixtures, two Metal tensor checks, one live Ghost model check and native capture.
Non-fatal macOS Contacts service diagnostics appear in the full-suite logs.

Final source review was performed inline, as required by the current issue
contract. Its one additional geometry finding was reproduced and fixed before
this final complete verification.
Tests use synthetic projects and an isolated `CFFIXED_USER_HOME`; no shipping model
is selected, downloaded or executed. Prepared lexical backend build inputs reuse
the checksum-pinned package preparation workflow.

## Remaining owner verification

No Purlory application bundle was launched and no actual-app/UI smoke, physical
IME, VoiceOver or subjective motion acceptance was performed. Check rapid panel
grab/release, paragraph insertion-line legibility, and repeated pouch reversal in
the owner's batched native checks, including system Reduce Motion. This is local
source/test evidence, not Store distribution, RC identity or main/PR CI evidence.
