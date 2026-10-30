@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class EditorTypesettingTests: XCTestCase {
    func testFictionManuscriptIndentsOnlyItsFirstVisualLineThroughFontChanges() async throws {
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript,
            body: String(repeating: "원고의 첫 줄과 이어지는 줄을 구분한다. ", count: 8))
        defer { harness.close() }
        let editor = try await harness.editor()
        let original = editor.serialize()
        let selection = NSRange(location: 4, length: 3)
        editor.setSelectedRange(selection)
        let lines = try lineFragments(editor, width: 260)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines[0].rect.minX - lines[1].rect.minX, editor.baseFontSize, accuracy: 0.1)
        let style = try paragraphStyle(editor, at: 0)
        XCTAssertEqual(style.alignment, .left)
        XCTAssertEqual(style.paragraphSpacing, round(editor.baseFontSize * 0.22))

        harness.settings.editorFontSize = 24
        try await harness.waitUntil { editor.baseFontSize == 24 }
        let enlarged = try lineFragments(editor, width: 260)
        XCTAssertEqual(enlarged[0].rect.minX - enlarged[1].rect.minX, 24, accuracy: 0.1)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.serialize(), original, "Presentation must not rewrite the manuscript")
    }

    func testFictionWrapsAtHangulWordBoundariesAndStillFitsOversizedTokens() async throws {
        let body = String(repeating: "가나다라마 바사아자차 카타파하가 ", count: 8)
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript, body: body)
        defer { harness.close() }
        let editor = try await harness.editor()
        let lines = try lineFragments(editor, width: 150)
        XCTAssertGreaterThan(lines.count, 2)
        let ns = editor.string as NSString
        for fragment in lines.dropLast() {
            let end = fragment.characters.upperBound
            let before = ns.character(at: end - 1), after = ns.character(at: end)
            XCTAssertFalse(isHangul(before) && isHangul(after),
                "A word that fits the column must not split between Hangul syllables")
        }
        let longToken = String(repeating: "가", count: 200)
        editor.load(markdown: longToken)
        let tokenLines = try lineFragments(editor, width: 150)
        XCTAssertGreaterThan(tokenLines.count, 1)
        XCTAssertEqual(tokenLines.last?.characters.upperBound, 200)
        for fragment in tokenLines {
            XCTAssertLessThanOrEqual(fragment.rect.maxX, 150.5,
                "An oversized token must stay inside the editable column")
        }
        XCTAssertEqual(editor.serialize(), longToken)
    }

    func testEmptyFictionKeepsTypingLayoutThroughFontChanges() async throws {
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript, body: "")
        defer { harness.close() }
        let editor = try await harness.editor()
        let initial = try XCTUnwrap(editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(initial.firstLineHeadIndent, editor.baseFontSize)
        harness.settings.editorFontSize = 24
        try await harness.waitUntil { editor.baseFontSize == 24 }
        let updated = try XCTUnwrap(editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(updated.firstLineHeadIndent, 24)
        XCTAssertEqual(updated.paragraphSpacing, 5)
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize, 24)
        XCTAssertEqual(editor.serialize(), "")
    }

    func testDeletingFormattedProseKeepsInheritedBoldThroughEmptyRestyle() async throws {
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript, body: "**원고**")
        defer { harness.close() }
        let editor = try await harness.editor()
        harness.window.makeFirstResponder(editor)
        let undo = harness.window.testUndo
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.deleteBackward(nil)
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(editor.typingAttributes[.purloryBold] as? Bool, true)
        harness.settings.editorFontSize = 24
        try await harness.waitUntil { editor.baseFontSize == 24 }
        XCTAssertEqual(editor.typingAttributes[.purloryBold] as? Bool, true)
        undo.beginUndoGrouping()
        editor.insertText("다음", replacementRange: editor.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(editor.serialize(), "**다음**")
    }

    func testDeletingStyledProseRebuildsInheritedColorSizeAndAlignmentForFurtherTyping() async throws {
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript,
            body: "<p align=\"right\"><font color=\"#FF453A\" size=\"30\">***원고***</font></p>")
        defer { harness.close() }
        let editor = try await harness.editor()
        harness.window.makeFirstResponder(editor)
        let undo = harness.window.testUndo
        undo.beginUndoGrouping()
        editor.applyLineSpacing(12)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.deleteBackward(nil)
        undo.endUndoGrouping()
        XCTAssertEqual(editor.typingAttributes[.purloryAlign] as? String, "right")
        harness.settings.editorFontSize = 24
        try await harness.waitUntil { editor.baseFontSize == 24 }
        let attrs = editor.typingAttributes
        XCTAssertEqual(attrs[.purloryBold] as? Bool, true)
        XCTAssertEqual(attrs[.purloryItalic] as? Bool, true)
        XCTAssertEqual((attrs[.font] as? NSFont)?.pointSize, 30)
        XCTAssertEqual((attrs[.foregroundColor] as? NSColor)?.hexValue, 0xFF453A)
        XCTAssertEqual(attrs[.obliqueness] as? Double, 0.18)
        let style = try XCTUnwrap(attrs[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .right)
        XCTAssertEqual(style.lineSpacing, 12)
        undo.beginUndoGrouping()
        editor.insertText("다음", replacementRange: editor.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(editor.serialize(),
            "<p align=\"right\"><font color=\"#FF453A\" size=\"30\">***다음***</font></p>")
    }

    func testGeneralManuscriptsAndFictionNotesAndReferencesKeepSpacedLayout() async throws {
        for (mode, kind) in [(WritingMode.general, WritingDocument.Kind.manuscript),
                              (.fiction, .note), (.fiction, .reference)] {
            let harness = try await TypesettingHarness(mode: mode, kind: kind, body: "첫 문단\n다음 문단")
            defer { harness.close() }
            let editor = try await harness.editor()
            let style = try paragraphStyle(editor, at: 0)
            XCTAssertEqual(style.firstLineHeadIndent, 0)
            XCTAssertEqual(style.paragraphSpacing, round(editor.baseFontSize * 0.65))
        }
    }

    func testNewProseAfterHeadingUsesFictionLayoutAndUndoPreservesOriginal() async throws {
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript, body: "# 제목")
        defer { harness.close() }
        let editor = try await harness.editor()
        XCTAssertEqual(try paragraphStyle(editor, at: 0).firstLineHeadIndent, 0)
        harness.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertNewline(nil)
        let emptyStyle = try XCTUnwrap(editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(emptyStyle.firstLineHeadIndent, editor.baseFontSize)
        XCTAssertEqual(emptyStyle.paragraphSpacing, round(editor.baseFontSize * 0.22))
        harness.settings.editorFontSize = 24
        try await harness.waitUntil { editor.baseFontSize == 24 }
        let resized = try XCTUnwrap(editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(resized.firstLineHeadIndent, 24)
        editor.insertText("새 문단", replacementRange: editor.selectedRange())
        undo.endUndoGrouping()
        let endStyle = try paragraphStyle(editor, at: editor.string.utf16.count - 1)
        XCTAssertEqual(endStyle.firstLineHeadIndent, 24)
        XCTAssertEqual(editor.serialize(), "# 제목\n새 문단")
        undo.undo()
        XCTAssertEqual(editor.serialize(), "# 제목")
    }

    func testDocumentSwitchReusesEditorAndRestoresLayoutWithoutChangingExplicitFormatting() async throws {
        let harness = try await TypesettingHarness(mode: .fiction, kind: .manuscript,
            body: "**첫 문단**\n다음 문단")
        defer { harness.close() }
        let editor = try await harness.editor()
        harness.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        harness.window.testUndo.beginUndoGrouping()
        editor.applyAlignment("right")
        editor.applyLineSpacing(12)
        harness.window.testUndo.endUndoGrouping()
        harness.settings.editorFontSize = 24
        try await harness.waitUntil { editor.baseFontSize == 24 }
        XCTAssertEqual(try paragraphStyle(editor, at: 0).lineSpacing, 12)
        XCTAssertEqual(try paragraphStyle(editor, at: 0).alignment, .right)
        let formatted = editor.serialize()
        harness.session.selectDocument(harness.note.id)
        try await harness.waitUntil { editor.string == "참고 메모" }
        let reused = try await harness.editor()
        XCTAssertTrue(reused === editor)
        XCTAssertEqual(try paragraphStyle(editor, at: 0).firstLineHeadIndent, 0)
        harness.session.selectDocument(harness.document.id)
        try await harness.waitUntil { editor.string == "첫 문단\n다음 문단" }
        XCTAssertTrue(harness.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertEqual(editor.serialize(), formatted)
        let style = try paragraphStyle(editor, at: 0)
        XCTAssertEqual(style.firstLineHeadIndent, 24)
        XCTAssertEqual(style.alignment, .right)
        // Per-paragraph line spacing is presentation-only and is not serialized.
        XCTAssertTrue(editor.textStorage?.attribute(.purloryBold, at: 0, effectiveRange: nil) as? Bool == true)
    }

    private func paragraphStyle(_ editor: BlockTextView, at index: Int) throws -> NSParagraphStyle {
        try XCTUnwrap(editor.textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil)
            as? NSParagraphStyle)
    }

    private func isHangul(_ character: unichar) -> Bool { (0xAC00...0xD7A3).contains(character) }

    private func lineFragments(_ editor: BlockTextView, width: CGFloat) throws
        -> [(rect: NSRect, characters: NSRange)] {
        let container = try XCTUnwrap(editor.textContainer)
        let manager = try XCTUnwrap(editor.layoutManager)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        var result: [(NSRect, NSRange)] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            result.append((used, manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)))
        }
        return result
    }
}

@MainActor
private final class TypesettingHarness {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let session: ProjectSession
    let settings: CompletionSettings
    let completion: CompletionController
    let document: WritingDocument
    let note: WritingDocument
    let window: LegacyUndoWindow
    let host: NSHostingView<EditorPane>

    init(mode: WritingMode, kind: WritingDocument.Kind, body: String) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "Purlory-typesetting-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = CompletionSettings(defaults: defaults)
        settings.autocompleteEnabled = false
        completion = CompletionController(settings: settings)
        document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: body, kind: kind)
        note = WritingDocument(id: WritingDocumentID(), title: "Note", body: "참고 메모", kind: .note)
        let project = WritingProject(id: WritingProjectID(), title: "Test", mode: mode, documents: [document, note])
        let store = ProjectStore(root: root)
        try await store.save(project)
        session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        try await session.bootstrap()
        try await session.activateProject(id: project.id)
        window = LegacyUndoWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        host = NSHostingView(rootView: EditorPane(projectSession: session,
            editorRequests: ProjectEditorRequests(), completion: completion, settings: settings,
            theme: .light, positionStore: WritingPositionStore(defaults: defaults)))
        window.contentView = host
    }

    func editor() async throws -> BlockTextView {
        try await waitUntil { self.findEditor(self.host) != nil }
        return try XCTUnwrap(findEditor(host))
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Editor presentation did not update")
    }

    func close() {
        window.testUndo.removeAllActions()
        window.contentView = nil
        window.close()
        completion.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func findEditor(_ view: NSView) -> BlockTextView? {
        if let editor = view as? BlockTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor($0) }.first
    }
}
