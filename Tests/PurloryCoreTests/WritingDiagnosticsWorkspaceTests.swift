@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI
@testable import PurloryKoreanBackend

@MainActor
final class WritingDiagnosticsWorkspaceTests: XCTestCase {
    func testFocusDimmingClearsAndImmediatelyRestoresEditorDecorations() async throws {
        try await withWorkspaceDiagnosticsFixture(body: "🙂 됬다.\n둘째 문단이다.") { fixture in
            try await fixture.settle()
            let fullRange = NSRange(location: 0, length: fixture.editor.string.utf16.count)
            let expectedRange = (fixture.editor.string as NSString).range(of: "됬다")
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange), [expectedRange])
            XCTAssertFalse(fixture.margin.visibleInsights(for: .general).isEmpty)

            fixture.spatial.focusDimming = true
            XCTAssertTrue(fixture.editor.writingDecorationRanges(visible: fullRange).isEmpty,
                "Enabling focusDimming must clear editor diagnostic underlines for quiet drafting")
            XCTAssertFalse(fixture.margin.visibleInsights(for: .general).isEmpty,
                "Prepared margin insights remain available even while editor underlines are hidden")

            fixture.spatial.toggle(.margin)
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange), [expectedRange],
                "Opening the margin note panel reveals diagnostic underlines even during focusDimming")

            fixture.spatial.toggle(.margin)
            XCTAssertTrue(fixture.editor.writingDecorationRanges(visible: fullRange).isEmpty)

            fixture.spatial.focusDimming = false
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange), [expectedRange],
                "Disabling focusDimming must immediately restore editor diagnostic underlines")
        }
    }

    func testActiveParagraphQuietWindowDefersCurrentParagraphUnderlinesUntilCursorLeaves() async throws {
        try await withWorkspaceDiagnosticsFixture(body: "첫째 문단이다.\n🙂 됬다.") { fixture in
            try await fixture.settle()
            let fullRange = { NSRange(location: 0, length: fixture.editor.string.utf16.count) }
            let secondRangeBefore = (fixture.editor.string as NSString).range(of: "됬다")
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange()), [secondRangeBefore])

            let firstParagraphEnd = (fixture.editor.string as NSString).range(of: "\n").location
            fixture.editor.setSelectedRange(NSRange(location: firstParagraphEnd, length: 0))
            fixture.edit(" 됬다.", range: NSRange(location: firstParagraphEnd, length: 0))
            try await fixture.settle()

            let firstTypoRange = (fixture.editor.string as NSString).range(of: "됬다")
            let secondTypoRange = (fixture.editor.string as NSString).range(of: "됬다", options: .backwards)
            XCTAssertNotEqual(firstTypoRange.location, secondTypoRange.location)

            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange()), [secondTypoRange],
                "Active paragraph where the writer is typing defers its underline while other paragraphs remain decorated")
            XCTAssertEqual(fixture.margin.visibleInsights(for: .general).count, 2)

            fixture.editor.setSelectedRange(NSRange(location: secondTypoRange.location, length: 0))
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange()), [firstTypoRange, secondTypoRange],
                "Moving the cursor out of the edited paragraph immediately reveals its deferred underline")
        }
    }

    func testShowsWritingDiagnosticsInEditorSettingTogglesUnderlines() async throws {
        try await withWorkspaceDiagnosticsFixture(body: "🙂 됬다.\n둘째 문단이다.") { fixture in
            try await fixture.settle()
            let fullRange = NSRange(location: 0, length: fixture.editor.string.utf16.count)
            let expectedRange = (fixture.editor.string as NSString).range(of: "됬다")
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange), [expectedRange])

            fixture.settings.showsWritingDiagnosticsInEditor = false
            XCTAssertTrue(fixture.editor.writingDecorationRanges(visible: fullRange).isEmpty)

            fixture.spatial.toggle(.margin)
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange), [expectedRange])

            fixture.spatial.toggle(.margin)
            XCTAssertTrue(fixture.editor.writingDecorationRanges(visible: fullRange).isEmpty)

            fixture.settings.showsWritingDiagnosticsInEditor = true
            XCTAssertEqual(fixture.editor.writingDecorationRanges(visible: fullRange), [expectedRange])
        }
    }

    private func withWorkspaceDiagnosticsFixture(
        body: String,
        run: @MainActor (WorkspaceDiagnosticsFixture) async throws -> Void
    ) async throws {
        let fixture = try await WorkspaceDiagnosticsFixture(body: body)
        do { try await run(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }
}

@MainActor
private final class WorkspaceDiagnosticsFixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "purlory.writing-workspace-diagnostics.\(UUID())"
    let store: ProjectStore
    let session: ProjectSession
    let settings: CompletionSettings
    let spatial: SpatialWorkspaceController
    let requests = ProjectEditorRequests()
    let clock = ManualDiagnosticsClock()
    let runtime: WritingDiagnosticsRuntime
    let bridge = ProjectEditorBridge()
    let margin = LivingMarginModel()
    let window = LegacyUndoWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    let editor: BlockTextView
    private var coordinator: PurloryBlockEditor.Coordinator!

    init(body: String) async throws {
        root = try temporaryProjectRoot()
        defaults = UserDefaults(suiteName: suite)!
        store = ProjectStore(root: root)
        session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        settings = CompletionSettings(defaults: defaults)
        spatial = SpatialWorkspaceController(defaults: defaults)
        var project = projectFixture()
        project.mode = .general
        project.documents[0].body = body
        try await session.saveAndActivate(project)
        spatial.configure(project: project, selected: session.selectedDocumentID, defaults: defaults)
        requests.spatialWorkspace = spatial

        runtime = WritingDiagnosticsRuntime(
            worker: KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL),
            observeEnergy: false,
            clock: clock)
        let storage = NSTextStorage(), layout = PurloryLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .init(width: 650, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        editor = BlockTextView(frame: .init(x: 0, y: 0, width: 650, height: 450), textContainer: container)
        storage.delegate = editor; editor.allowsUndo = true
        window.isReleasedWhenClosed = false; window.testUndo.groupsByEvent = false; window.contentView = editor
        let binding = Binding<String>(
            get: { [unowned self] in session.selectedDocument?.body ?? "" },
            set: { [unowned self] in session.updateSelectedDocumentBody($0) })
        let key = try XCTUnwrap(session.runtimeIdentity?.key)
        coordinator = PurloryBlockEditor(text: binding, documentIdentity: .project(key)).makeCoordinator()
        editor.delegate = coordinator
        requests.register(editor, for: key, session: session)
        requests.nativeEditor = editor
        requests.nativeEditorKey = key
        session.documentDidChange = { [weak bridge] in bridge?.noteSnapshot($0) }
        runtime.connect(session: session, editorBridge: bridge, livingMargin: margin, spatial: spatial, settings: settings)
        bridge.connect(editor, currentSnapshot: { [weak session] in session?.selectedDocumentSnapshot })
        window.testUndo.beginUndoGrouping()
        editor.load(markdown: body)
        coordinator.lastSyncedText = body; coordinator.loadedDocumentIdentity = .project(key); coordinator.attach(to: editor)
        window.testUndo.endUndoGrouping(); window.testUndo.removeAllActions(); window.makeFirstResponder(editor)
    }

    func settle() async throws {
        _ = try XCTUnwrap(runtime.controller.workTask)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350))
        await runtime.controller.waitForCurrentWork(); await runtime.waitForPresentation()
    }

    func edit(_ value: String, range: NSRange) {
        window.testUndo.beginUndoGrouping()
        editor.insertText(value, replacementRange: range)
        window.testUndo.endUndoGrouping()
    }

    func close() async {
        await runtime.prepareForTermination(); bridge.disconnect(editor)
        session.documentDidChange = nil
        try? await session.flush()
        while window.testUndo.groupingLevel > 0 { window.testUndo.endUndoGrouping() }
        window.testUndo.removeAllActions(); window.testUndo.disableUndoRegistration(); window.contentView = nil; window.close()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
    }
}
