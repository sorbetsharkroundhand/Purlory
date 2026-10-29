# Bundled third-party notices

`inventory.json` records the exact `Package.resolved` revisions, original notice
hashes, vendored components, and distributed resource hashes. Builds generate
`Contents/Resources/ThirdPartyNotices.txt` (readable text) and
`ThirdPartyNotices.json` (source/provenance inventory). Open these files through
Finder's **Show Package Contents**; generation and validation never launch Purlory.

```sh
python3 scripts/test-purlory-notices.py
python3 scripts/purlory-notices.py --checkouts .build/checkouts --validate-app build/Purlory.app
scripts/validate-purlory-archive.sh
```

Native Xcode builds audit their own `SourcePackages/checkouts`, rather than the
separate CLI checkouts. Dependencies must be clean and match the lock revisions.
Every copied package resource must match its recorded original bytes. Generated
bundle metadata/signatures and MLX Metal output are separately identified.
Build-time dependencies are included conservatively.

The owner-selected body font, Noto Serif KR, is bundled unchanged in
`Purlory_PurloryDocumentEngine.bundle` from Google Fonts commit
`8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`. Its variable TTF and original OFL 1.1
text are hash-pinned in the inventory. Attribution retains both the embedded
Adobe copyright and the copyright in the original Google license file.
Repository resources receive the same source and packaged-byte audit as package
resources. Purlory registers the font for its own process only; it requires neither
system font installation nor a network connection.

The owner-selected UI family, Pretendard, is also bundled unchanged from release
1.3.9, commit `5c41199ea0024a9e0b2cb31735265056e5472d76`. The original variable TTF
and OFL 1.1 text retain their hashes and Kil Hyung-jin attribution. AppKit and
SwiftUI select the audited descriptor; view modifiers retain relative text
scaling. Neither font-family decision approves the accent palette or paragraph
typesetting in #153.

Original supplemental texts in `Texts/` retain immutable upstream provenance:
swift-xet's immediate successor adds the license without changing its compiled
source tree or package manifest; both original Git objects are checked. BoringSSL
texts match each vendor's recorded upstream revision. PocketFFT's header notice
and LPPL 1.3c supplement the pinned sources. Each math font retains its embedded
copyright and distinct OFL/GUST terms, independently of the library MIT notice.
Supplementary llhttp, uSHET macros, WIDE SHA1 and zlib terms are also preserved
for the conservatively inventoried optional networking dependencies.

The release contains no bundled model weights. Unknown resources and model
artifacts fail validation. Adding a model requires explicit #155/#180 approval
and an updated inventory/validator; this empty model list grants no model rights.
Final icon, SDK/model privacy wording, and distribution approval remain owner
checks in #185. This inventory is not App Store submission evidence.

The MLX 0.32.3 / MLX Swift LM 3.32.3 integration refreshes dependency revisions
and the PocketFFT submodule provenance while retaining the verified original
notice bytes. Packages absent from the current lockfile and their owned
components are no longer packaged. Supplemental files retained in `Texts/` are
only bundled when referenced by the current inventory.
