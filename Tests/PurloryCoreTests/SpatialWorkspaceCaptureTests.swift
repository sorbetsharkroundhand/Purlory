@_spi(Benchmark) @testable import PurloryInference
import AppKit
import XCTest
@testable import PurloryCore

@MainActor final class SpatialWorkspaceCaptureTests: XCTestCase {
    func testCaptureSyntheticNativeSpatialWorkspace() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PURLORY_WORKSPACE_CAPTURE_DIR"] else { throw XCTSkip("Native capture is opt-in") }
        let customPalette = PaletteSettings.shared.enabled
        PaletteSettings.shared.enabled = false
        defer { PaletteSettings.shared.enabled = customPalette }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let sourceURL = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "json", subdirectory: "NativeWorkspaceHTML"))
        let source = try JSONDecoder().decode(HTMLCaptureFixture.self, from: Data(contentsOf: sourceURL))
        for dark in [false, true] {
            let h = try await FramedWorkspaceHarness(width: 1440, appearance: dark ? .dark : .light, reduceMotion: true, projectTitle: source.project.title, mode: .fiction)
            defer { h.close() }
            let session = h.fixture.session
            let a = try XCTUnwrap(session.selectedDocumentID)
            var ids: [String: WritingDocumentID] = [:]
            for (index, doc) in source.project.documents.enumerated() {
                let id = index == 0 ? a : try XCTUnwrap(session.createDocument(title: doc.title, kind: doc.id.contains("note") ? .note : .manuscript))
                ids[doc.id] = id
                session.selectDocument(id)
                session.renameDocument(try XCTUnwrap(session.runtimeIdentity).key, to: doc.title)
                session.updateSelectedDocumentBody(doc.paragraphs.map { paragraph in
                    (paragraph.block == "h1" ? "# " : paragraph.block == "h2" ? "## " : paragraph.block == "quote" ? "> " : "") + paragraph.text
                }.joined(separator: "\n"))
                for card in source.characters where card.docId == doc.id {
                    try ProjectWriterEditing.perform(.character(CharacterCard(name: card.name, note: card.note, role: card.role, traits: card.traits)), in: session, identity: XCTUnwrap(session.runtimeIdentity))
                }
            }
            let b = try XCTUnwrap(ids["doc-ch2"])
            await h.layout(); session.selectDocument(a); await h.layout()
            h.requests.spatialWorkspace?.open(b); h.requests.spatialWorkspace?.open(a)
            await h.layout()
            for doc in source.project.documents.dropFirst(2) { if let id = ids[doc.id] { _ = h.requests.spatialWorkspace?.close(.document(id)) } }
            await h.layout(); h.window.makeKeyAndOrderFront(nil); await h.layout()
            try capture(h.host, path: directory + "/initial-\(dark ? "dark" : "light").png")
            let activeEditor = try await h.editor(); h.window.makeFirstResponder(activeEditor)
            let model = try XCTUnwrap(h.requests.spatialWorkspace)
            model.toggle(.characters); model.toggle(.narrative); model.toggle(.margin)
            await h.layout(); h.window.makeKeyAndOrderFront(nil); await h.layout()
            try await Task.sleep(for: .milliseconds(400)); await h.layout()
            try capture(h.host, path: directory + "/workspace-\(dark ? "dark" : "light").png")
            if let pouch = h.requests.pouch?.panel?.contentView { try capture(pouch, path: directory + "/pouch-\(dark ? "dark" : "light").png") }
            let theme: PurloryTheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            let palette = try XCTUnwrap(WorkspaceQuickCommandPanel.present(session: session, requests: h.requests, theme: theme, toggleTheme: {}))
            await h.layout()
            try capture(try XCTUnwrap(palette.window?.contentView), path: directory + "/palette-\(suffix).png")
            palette.close(); await h.layout()
            h.window.makeFirstResponder(activeEditor)
            let assistance = WorkspaceAssistance(session: session, requests: h.requests, margin: LivingMarginModel()) { _, _ in
                AskAnswerGeneration { emit in try emit("도경은 천천히 면장갑을 벗었다. 창문 너머로 소리의 웃음이 파도처럼 밀려왔다.") }
            }
            WorkspaceAssistancePanel.present(.coauthor, model: assistance, requests: h.requests, theme: theme)
            await h.layout()
            let coauthor = try XCTUnwrap(NSApp.windows.first { $0.title == "공동 집필" && $0.isVisible })
            try capture(try XCTUnwrap(coauthor.contentView), path: directory + "/coauthor-idle-\(suffix).png")
            assistance.coauthorPrompt = "등대의 아침을 이어 써 주세요."
            await assistance.generate(prompt: assistance.coauthorPrompt); await h.layout()
            try capture(try XCTUnwrap(coauthor.contentView), path: directory + "/coauthor-result-\(suffix).png")
            coauthor.close(); await h.layout()
            h.window.makeFirstResponder(activeEditor)
            activeEditor.setSelectedRange((activeEditor.string as NSString).range(of: "한도경은"))
            activeEditor.updateSelectionToolbar(); try await Task.sleep(for: .milliseconds(350))
            h.requests.spatialWorkspace?.openPouchTools(); await h.layout()
            try capture(try XCTUnwrap(h.element("purlory.workspace.pouch.tools") as? NSView), path: directory + "/selection-\(suffix).png")
            h.requests.spatialWorkspace?.pouchSection = nil
            activeEditor.hideSelectionToolbar(); activeEditor.setSelectedRange(.init(location: 0, length: 0))
            let entities = WorkspaceEntityController(session: session, requests: h.requests)
            entities.hover(editor: activeEditor, key: try XCTUnwrap(session.runtimeIdentity).key,
                nativeOffset: (activeEditor.string as NSString).range(of: "한도경").location)
            try await Task.sleep(for: .milliseconds(250))
            if let peek = h.window.childWindows?.first(where: { $0.title == "인물·고증·사건" })?.contentView {
                try capture(peek, path: directory + "/entity-\(suffix).png")
            }
            entities.hide()
            let canvas = try XCTUnwrap(descendant(h.host, SpatialWorkspaceCanvasView.self))
            var split = model.layout; split.move(.document(b), to: .after(.document(a))); model.setLayout(split)
            model.open(a); await h.layout()
            let header = try XCTUnwrap(h.element("purlory.binder.tab.\(a.rawValue.uuidString)") as? NSView)
            let source = try XCTUnwrap(canvas.geometry.tiles[.document(a)])
            let target = try XCTUnwrap(canvas.geometry.tiles[.document(b)])
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 1,
                    windowNumber: h.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            let origin = model.layout
            header.mouseDown(with: try event(.leftMouseDown, CGPoint(x: source.midX, y: source.minY + 12)))
            header.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: target.midX, y: target.minY + 45)))
            await h.layout(); XCTAssertTrue(model.isDragging)
            try capture(h.host, path: directory + "/drag-preview-\(dark ? "dark" : "light").png")
            header.cancelOperation(nil); await h.layout(); XCTAssertEqual(model.layout, origin)
            let editor = try await h.editor(); h.window.makeFirstResponder(editor)
            model.typewriter = true; model.focusDimming = true; await h.layout()
            try capture(h.host, path: directory + "/writing-focus-\(dark ? "dark" : "light").png")
            h.requests.pouch?.collapse(); await h.layout()
            if let orb = h.requests.pouch?.panel?.contentView { try capture(orb, path: directory + "/collapsed-orb-\(dark ? "dark" : "light").png") }
            h.requests.pouch?.restore(); await h.layout()
            let retained = try await h.editor(); XCTAssertTrue(retained === editor)
            try capture(h.host, path: directory + "/restored-workspace-\(dark ? "dark" : "light").png")
        }
    }
    private func descendant<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
        (root as? T) ?? root.subviews.compactMap { descendant($0, type) }.first
    }
    private func capture(_ view: NSView, path: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

private struct HTMLCaptureFixture: Decodable {
    let project: Project
    let characters: [Character]
    struct Project: Decodable { let title: String; let documents: [Document] }
    struct Document: Decodable { let id: String; let title: String; let paragraphs: [Paragraph] }
    struct Paragraph: Decodable { let block: String; let text: String }
    struct Character: Decodable { let name: String; let role: String; let traits: [String]; let note: String; let docId: String }
}
