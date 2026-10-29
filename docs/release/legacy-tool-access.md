# Release tool access audit (#186)

## Project-only runtime update (2026-10-29)

Normal startup, explicit legacy opening, commands and termination now use
ProjectSession exclusively. Without an active project, a valid legacy archive in
the configured storage root is copied and verified before activation. The original
archive and images are not edited. Existing active projects take precedence.
The older `journal.md` format also imports as a project with its original bytes
retained. A corrupt primary or ambiguous recovery archive requires explicit choice.

File → Open previous library as project opens the verified copy. File → Select
previous manuscript file selects the containing folder, then an archive/recovery
file and project mode. Folder access includes adjacent images. The same recovery
route is available from first-run and the startup error screen. Project writer
data includes characters, corrections and recorded conversations before activation.
Legacy codecs and compatibility coverage remain; the production app no longer
constructs an editable EntryStore or switches between two workspace owners.

The historical audit below describes the earlier release demotion; its legacy
workspace routes are superseded by the project-copy routes above.

The #108/#112 candidate supplies original-source search and native jump/return.
The writing toolbar exposes search directly; Command-K opens it and
Command-Shift-K returns to the earlier writing position. Existing document
navigation, editing, backup and export routes remain available.

| Previous entry | Release route | Data and reason for retention |
| --- | --- | --- |
| Fiction badge / Story Bible | Saved settings and records → Characters and work information | Genre, character names, aliases, notes and rejected names are author-owned. Search cannot replace their editing/restoration. Existing records also remain accessible in General. |
| Narrative | Saved settings and records → Author corrections and records | Stored overrides, author decisions and recorded conversations remain readable/editable through their existing project-scoped tools. No map or automatic review is advertised. |
| AI Context | Saved settings and records → Content used by suggestions | Actual scoped suggestion evidence and saved context choices retain their original routes. Exclusions can be restored without a model; the corrections route also exposes saved pins and exclusions when no current report exists. |
| Legacy advanced-tool tabs | One secondary Saved settings and records menu | The explicitly opened legacy library retains its existing author-data views. Advanced tools no longer compete with manuscript navigation as primary tabs. |
| Legacy library | File → Open legacy library | The previous library remains accessible without modifying or migrating `entries.json` in place. |
| Empty Living Margin | No primary or compatibility menu entry | No deterministic release producer exists. Stored empty-margin selection does not expose a tool in the release workspace. |

The native menu has direct items and a stable accessibility identifier. Tool
titles describe the stored information actually available. Opening a compatibility
route changes presentation only; closing its existing panel restores editor focus.
The primary source-search button uses the same marked-text-safe native route as
Command-K. Search, editing and saved information do not require model activation.

No underlying records, codecs, generic storage or document identifiers are removed.
Blank General documents show a quiet empty state instead of Fiction setup. Saved
Fiction fields can still be edited after a project changes to General. This is a
bounded data-aware demotion, as permitted by the current #186 contract; no
Map/Review/Ask Purlory or derived Knowledge producer is added.

Verification covers real saved General fields, native toolbar accessibility and
search open/close preserving selection/focus, existing source navigation and IME
guards, stored-empty-margin visibility, full tests and local build/bundle smoke.
The UI smoke harness follows the secondary menu while keeping its existing field,
persistence and focus assertions. Actual unlocked keyboard/IME/VoiceOver checks,
the owner's information-reachability check, CI and main integration remain pending.
Developer bundle smoke is not Store distribution evidence.
