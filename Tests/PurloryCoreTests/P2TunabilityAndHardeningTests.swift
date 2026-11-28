import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PurloryCore
@testable import PurloryFoundation
@testable import PurloryInference
@testable import PurloryIntelligence
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

final class P2TunabilityAndHardeningTests: XCTestCase {

    // MARK: - 1. ContextAssembler budget ladder preserves raw manuscript C before trimming

    func testContextAssemblerPreservesManuscriptWindowWhenDroppingKnowledgeFitsBudget() {
        // Word-based deterministic token counter (1 token per whitespace-separated word + 1).
        let counter = TokenCounter { text in
            text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count + 1
        }
        let entryID = UUID()
        let document = DocumentContext(
            title: "긴 소설",
            kind: .novel,
            genre: "미스터리",
            characters: (0..<5).map { idx in
                CharacterCard(
                    name: "인물\(idx)",
                    note: String(repeating: "성격설명\(idx) ", count: 25)
                )
            },
            entryID: entryID
        )
        let scenesBody = (0..<24).map { idx in
            "# \(idx)장\n장면 \(idx)에서 인물들이 만나 대화를 나누고 단서를 발견했다.\n"
        }.joined()
        let outline = DocumentOutline.parse(scenesBody)
        var summaries: [String: String] = [:]
        for scene in outline.scenes {
            summaries[scene.contentHash] =
                "요약 — 장면에서 핵심 사건이 일어났고 인물 관계가 크게 흔들렸으며 다음 단서가 남았다."
        }
        let knowledge = KnowledgeSnapshot(
            entryID: entryID,
            outline: outline,
            summariesByHash: summaries,
            characters: [],
            overrides: NarrativeOverrides([])
        )
        let cursorStart = outline.scenes.last?.utf16Range.upperBound ?? scenesBody.utf16.count
        let prefix = "UNIQUE_OPENING_MARKER " + String(repeating: "현재 장면의 생생한 문장이 계속 이어진다. ", count: 16)

        // Measure full ladder[0] cost vs ladder.last cost with untouched prefix.
        let fullOutcome = ContextAssembler.assembleCore(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: cursorStart, style: .continuation,
            knobs: ContextAssembler.BudgetKnobs.ladder[0], counter: counter
        )
        let reducedOutcome = ContextAssembler.assembleCore(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: cursorStart, style: .continuation,
            knobs: ContextAssembler.BudgetKnobs.ladder.last!, counter: counter
        )
        let fullTokens = fullOutcome.totalTokens ?? 0
        let reducedTokens = reducedOutcome.totalTokens ?? 0
        XCTAssertGreaterThan(fullTokens, reducedTokens, "Test fixture must have reducible knowledge tokens")

        // Pick a budget strictly below fullTokens but safely above reducedTokens so dropping knowledge
        // alone suffices — raw manuscript prefix C should NOT be trimmed prematurely.
        let budget = reducedTokens + max(1, (fullTokens - reducedTokens) / 2)
        let assembled = ContextAssembler.assembleWithReport(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: cursorStart, style: .continuation,
            tokenCounter: counter, tokenBudget: budget
        )
        guard case .continuation(let text) = assembled.prompt else {
            return XCTFail("Expected continuation prompt")
        }
        XCTAssertLessThanOrEqual(counter.count(text), budget)
        XCTAssertTrue(
            text.contains("UNIQUE_OPENING_MARKER"),
            "Manuscript window C must not be trimmed when reducing knowledge along BudgetKnobs.ladder already fits the token budget"
        )
    }

    // MARK: - 2. EpubExporter multi-line math trailing whitespace after $$

    func testEpubMultiLineMathWithTrailingSpacesAfterClosingDelimiterRendersCleanMathML() async throws {
        let body = "# Math Chapter\n$$\nx^2 + y^2 = z^2 $$   \n"
        try await withExportedEpub(body: body) { archive in
            let chapterData = try epubMember("OEBPS/chapter0.xhtml", in: archive)
            let parser = XMLParser(data: chapterData)
            XCTAssertTrue(parser.parse(), "Exported XHTML must be valid XML: \(parser.parserError?.localizedDescription ?? "")")
            let xhtml = String(decoding: chapterData, as: UTF8.self)
            XCTAssertTrue(xhtml.contains("<math"), "Trailing spaces after closing $$ must still produce MathML: \(xhtml)")
            XCTAssertFalse(xhtml.contains("<mo>$</mo>"), "Trailing whitespace after $$ must not leak a stray $ into MathML: \(xhtml)")
            XCTAssertFalse(xhtml.contains("z^2 $"), "Raw LaTeX fallback with leaked $ must not appear: \(xhtml)")
        }
    }

    // MARK: - 3. EpubExporter XML 1.0 control chars and unsafe href scheme rejection

    func testEpubStripsIllegalXMLControlCharsAndRejectsUnsafeHrefSchemes() async throws {
        let body = """
        # Safety Chapter
        Normal text with control\u{0007}\u{000B}\u{001F}chars.
        [Bad link](javascript:alert(1)) and [Data link](data:text/html;base64,PHNjcmlwdD4=) and [Good link](https://example.test/ok) and [Anchor](#sec1).
        """
        try await withExportedEpub(body: body) { archive in
            let chapterData = try epubMember("OEBPS/chapter0.xhtml", in: archive)
            let parser = XMLParser(data: chapterData)
            XCTAssertTrue(
                parser.parse(),
                "Illegal XML 1.0 control characters must be stripped so XHTML parses cleanly: \(parser.parserError?.localizedDescription ?? "")"
            )
            let xhtml = String(decoding: chapterData, as: UTF8.self)
            XCTAssertFalse(xhtml.contains("javascript:"), "Unsafe javascript: href must not be emitted in EPUB XHTML")
            XCTAssertFalse(xhtml.contains("data:text/html"), "Unsafe data: href must not be emitted in EPUB XHTML")
            XCTAssertTrue(xhtml.contains("Bad link"), "Plain label text of rejected link should remain readable")
            XCTAssertTrue(xhtml.contains("href=\"https://example.test/ok\""), "Safe https link must be preserved")
            XCTAssertTrue(xhtml.contains("href=\"#sec1\""), "Fragment anchor link must be preserved")
        }
    }

    // MARK: - 4. EpubExporter ImageIO off-main-thread PNG transcoding

    func testEpubTranscodesNonStandardImageToPNGOffMainThread() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()

        // Generate a tiny 2x2 TIFF using CoreGraphics + ImageIO (no AppKit needed).
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let cgImage = try XCTUnwrap(ctx.makeImage())
        let tiffData = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(tiffData, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        project.documents[0].body = "# Image\n![alt](assets/sample.heic)\n"
        try await store.save(project)
        try await store.addAsset(tiffData as Data, reference: "assets/sample.heic", to: project.id)
        let catalog = try await store.assetCatalog(id: project.id)
        let archive = root.appendingPathComponent("image.epub")
        try await EpubExporter.exportAsync(project.documents[0], assets: catalog, to: archive)

        let pngData = try epubMember("OEBPS/images/sample.png", in: archive)
        XCTAssertGreaterThanOrEqual(pngData.count, 8)
        XCTAssertEqual(Array(pngData.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "Transcoded image must be a valid PNG")
    }

    // MARK: - 5. WorkspacePouchIndexView layout does not hardcode index 5 separator

    @MainActor
    func testWorkspacePouchIndexDoesNotHardcodeSeparatorAtIndexFive() {
        let view = WorkspacePouchIndexView(frame: CGRect(x: 0, y: 0, width: 84, height: 500))
        let geometry = WorkspacePouchIndexGeometry(
            window: CGRect(x: 200, y: 100, width: 900, height: 600),
            screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
            progress: 1,
            hover: 0
        )
        let actions = (0..<6).map { i in
            WorkspacePouchAction(id: "action.\(i)", label: "Action \(i)", symbol: "circle") {}
        }
        view.configure(theme: .light, actions: actions)
        view.update(geometry: geometry, progress: 1, expanded: true)
        view.layoutSubtreeIfNeeded()

        let scroll = try? XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let buttons = scroll?.documentView?.subviews.compactMap { $0 as? NSButton } ?? []
        XCTAssertEqual(buttons.count, 6)
        // Without explicit separator metadata on index 5, button 5 must sit on the regular 52pt pitch (260pt),
        // not shifted by a hardcoded `i == 5 ? 12 : 0` offset (272pt).
        XCTAssertEqual(buttons[5].frame.origin.y, 260, accuracy: 0.5)

        // With explicit separator metadata on index 2, button 2 shifts by +12pt and subsequent buttons follow.
        var separated = actions
        separated[2].showsLeadingSeparator = true
        view.configure(theme: .light, actions: separated)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(buttons[1].frame.origin.y, 52, accuracy: 0.5)
        XCTAssertEqual(buttons[2].frame.origin.y, 116, accuracy: 0.5)
        XCTAssertEqual(buttons[5].frame.origin.y, 272, accuracy: 0.5)
    }

    // MARK: - 6. WorkspaceEditorInteraction honors CompletionSettings toggle across UserDefaults suites

    @MainActor
    func testWorkspaceEditorInteractionHonorsSettingsToggleAcrossUserDefaultsSuites() async throws {
        let suiteAName = "P2SuiteA.\(UUID().uuidString)"
        let suiteBName = "P2SuiteB.\(UUID().uuidString)"
        let suiteA = try XCTUnwrap(UserDefaults(suiteName: suiteAName))
        let suiteB = try XCTUnwrap(UserDefaults(suiteName: suiteBName))
        defer {
            suiteA.removePersistentDomain(forName: suiteAName)
            suiteB.removePersistentDomain(forName: suiteBName)
        }

        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let project = projectFixture()
        try await store.save(project)

        let session = ProjectSession(store: store, defaults: suiteA, autosaveDelay: .seconds(3600))
        try await session.saveAndActivate(project)
        let settings = CompletionSettings(defaults: suiteB)
        settings.showsWritingDiagnosticsInEditor = false

        let spatial = SpatialWorkspaceController(defaults: suiteA)
        let requests = ProjectEditorRequests()
        requests.spatialWorkspace = spatial
        let bridge = ProjectEditorBridge()
        let editor = BlockTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        bridge.editor = editor
        let key = try XCTUnwrap(session.runtimeIdentity?.key)
        requests.installSpatialInteraction(editor, key: key, session: session)

        let runtime = WritingDiagnosticsRuntime(observeEnergy: false)
        let margin = LivingMarginModel()
        runtime.connect(
            session: session,
            editorBridge: bridge,
            livingMargin: margin,
            spatial: spatial,
            settings: settings
        )

        let suppressed = editor.isWritingDiagnosticsSuppressedByWorkspace
        await runtime.prepareForTermination()
        XCTAssertTrue(
            suppressed,
            "WorkspaceEditorInteraction must honor CompletionSettings.showsWritingDiagnosticsInEditor even when stored in a different UserDefaults suite than session.presentationPreferences"
        )
    }

    // MARK: - Helpers

    private func withExportedEpub(body: String, inspect: (URL) throws -> Void) async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.documents[0].title = "Test"
        project.documents[0].body = body
        try await store.save(project)
        let catalog = try await store.assetCatalog(id: project.id)
        let archive = root.appendingPathComponent("test.epub")
        try await EpubExporter.exportAsync(project.documents[0], assets: catalog, to: archive)
        try inspect(archive)
    }
}
