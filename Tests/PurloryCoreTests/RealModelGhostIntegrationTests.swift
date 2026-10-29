@_spi(Benchmark) @testable import PurloryInference
import AppKit
import Darwin
import XCTest
@testable import PurloryCore

/// Opt-in hardware evidence. Normal CI does not download weights or run Metal inference.
@MainActor final class RealModelGhostIntegrationTests: XCTestCase {
    func testRealCandidateGeneratesGhostInRedesignAndTabAcceptsWithUndo() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelID = environment["PURLORY_REAL_MODEL_ID"] else {
            throw XCTSkip("Set PURLORY_REAL_MODEL_ID and an isolated CFFIXED_USER_HOME for physical-model evidence")
        }
        let home = try XCTUnwrap(environment["CFFIXED_USER_HOME"])
        let isolated = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
        let account = try XCTUnwrap(getpwuid(getuid()))
        let accountHome = String(cString: account.pointee.pw_dir)
        _ = try XCTUnwrap(isolated.path != accountHome ? true : nil,
            "Real-model UI checks require a separate home")
        _ = try XCTUnwrap(PurloryStorageLocation.standard.rootDirectory.resolvingSymlinksInPath().path.hasPrefix(isolated.path + "/") ? true : nil,
            "Purlory storage must resolve inside the isolated home")
        let budget = try XCTUnwrap(ModelMemoryPolicy.current.hardware.budgetBytes)
        let engine = CompletionEngine(memoryPolicy: ModelMemoryPolicy.current.evaluatingCandidates(peakBytes: budget))
        let h = try await FramedWorkspaceHarness(width: 1180, reduceMotion: true, completionEngine: engine)
        defer { h.completion.shutdown(); h.close() }
        let settings = h.completion.settings
        settings.modelID = modelID
        let style = try XCTUnwrap(PromptStyle(rawValue: environment["PURLORY_REAL_PROMPT_STYLE"] ?? "continuation"))
        settings.promptStyle = style
        settings.temperature = 0
        settings.maxTokens = 32
        settings.debounceMilliseconds = 20
        h.completion.setAutocompleteEnabled(true)
        try await waitFor("model readiness: \(modelID)") { h.completion.engineState == .ready }

        let prefix = style == .instruct ? "도경은 문을 열었다. 방 안에는" : "도경은 문을 열었다. 방 안에"
        let committed = style == .instruct ? " " : "는"
        h.fixture.session.updateSelectedDocumentBody(prefix)
        let editor = try await h.editor()
        h.window.makeKeyAndOrderFront(nil)
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(committed, replacementRange: editor.selectedRange())
        try await waitFor("visible Korean Ghost: \(modelID)") { !(editor.ghostText ?? "").isEmpty }
        let ghost = try XCTUnwrap(editor.ghostText)
        let before = editor.serialize()
        XCTAssertEqual(before, prefix + committed)
        XCTAssertEqual(h.completion.suggestion, ghost)
        XCTAssertTrue(ghost.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) })
        XCTAssertFalse(ghost.contains("<think>"))
        XCTAssertFalse(ghost.contains("<|"))
        if let path = environment["PURLORY_REAL_MODEL_CAPTURE_PATH"] {
            editor.layoutSubtreeIfNeeded()
            editor.displayIfNeeded()
            let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            // The native view is transparent over SwiftUI's opaque manuscript surface.
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
            graphics.setBlendMode(.destinationOver)
            graphics.setFillColor(PurloryTheme.light.editorSurface.cgColor)
            graphics.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path))
        }

        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        editor.keyDown(with: tab)
        h.completion.setAutocompleteEnabled(false)
        await h.layout()
        XCTAssertEqual(editor.serialize(), before + ghost)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before + ghost)
        XCTAssertNil(editor.ghostText)
        editor.undoManager?.undo()
        await h.layout()
        XCTAssertEqual(editor.serialize(), before)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before)
        try await h.fixture.session.flush()
        if editor.serialize() == before, h.fixture.session.selectedDocument?.body == before {
            print("REAL_GHOST model=\(modelID) style=\(style.rawValue) prefix=\(before) suggestion=\(ghost) tab=accepted undo=restored")
        }
        try await engine.unload()
    }

    private func waitFor(_ description: String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try XCTUnwrap(ready() ? true : nil, description)
    }
}
