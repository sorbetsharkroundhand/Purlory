@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class DocumentOutlineNavigationTests: XCTestCase {
    func testDuplicateFormattedHeadingJumpAndReturnPreserveNativeOwner() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let source = "# **😀 한**\nfirst\n" + String(repeating: "Body paragraph.\n", count: 60)
            + "```\n# hidden\n```\n$$\nx\n$$\n## **😀 한**\nlast"
        h.fixture.session.updateSelectedDocumentBody(source); await h.layout()
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager)
        let nativeOriginal = editor.serialize(), nativeText = editor.string
        undo.beginUndoGrouping()
        editor.insertText("!", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        undo.endUndoGrouping(); await h.layout()
        editor.setSelectedRange(NSRange(location: 3, length: 1))
        editor.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 200))
        let snapshot = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot)
        let projection = try await DocumentOutlineProjection.build(snapshot.body)
        let prepared = PreparedDocumentOutline(identity: snapshot.identity, projection: projection)
        XCTAssertEqual(projection.headings.count, 2)
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertGreaterThan(point.scrollOrigin.y, 0)
        XCTAssertTrue(h.requests.jump(to: projection.headings[1], prepared: prepared, in: h.fixture.session))
        await h.layout()
        let last = (editor.string as NSString).range(of: "😀 한", options: .backwards)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: last.location, length: 0))
        XCTAssertEqual(editor.outlineSourcePosition(identity: snapshot.identity), projection.headings[1].id)
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session)); await h.layout()
        let returned = try await h.editor()
        XCTAssertTrue(returned === editor); XCTAssertTrue(returned.undoManager === undo)
        XCTAssertEqual(returned.selectedRange(), point.selection)
        XCTAssertEqual(returned.enclosingScrollView?.contentView.bounds.origin, point.scrollOrigin)
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertTrue(undo.canUndo); undo.undo(); await h.layout()
        XCTAssertTrue(editor.serialize().utf16.elementsEqual(nativeOriginal.utf16))
        XCTAssertTrue(editor.string.utf16.elementsEqual(nativeText.utf16))
    }

    func testHeadingRefusesStaleOwnerMarkedTextAndMalformedCoordinates() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let editor = try await h.editor(), snapshot = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot)
        let projection = try await DocumentOutlineProjection.build(snapshot.body)
        let prepared = PreparedDocumentOutline(identity: snapshot.identity, projection: projection)
        let heading = try XCTUnwrap(projection.headings.first)
        func target(offset: Int? = nil, level: Int? = nil) -> OutlineSourceTarget {
            .init(identity: snapshot.identity, revision: projection.revision,
                  evidence: .init(documentID: snapshot.identity.key.documentID, quote: heading.quote,
                                  utf16Hint: offset ?? heading.id), level: level ?? heading.level,
                  sourceOffset: offset ?? heading.id)
        }
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let selection = editor.selectedRange()
        for invalid in [target(offset: -1), target(offset: Int.max), target(offset: 1), target(level: 4)] {
            XCTAssertFalse(editor.applySourceNavigation(.heading(invalid)))
            XCTAssertEqual(editor.selectedRange(), selection)
        }
        let owner = editor.writingDocumentIdentity
        editor.writingDocumentIdentity = .project(.init(projectID: WritingProjectID(), documentID: snapshot.identity.key.documentID))
        XCTAssertNil(editor.outlineSourcePosition(identity: snapshot.identity))
        XCTAssertFalse(editor.applySourceNavigation(.heading(target())))
        XCTAssertFalse(h.requests.jump(to: heading, prepared: prepared, in: h.fixture.session))
        XCTAssertNil(h.requests.sourceReturnPoint)
        editor.writingDocumentIdentity = owner
        let undo = try XCTUnwrap(editor.undoManager); undo.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: selection)
        let markedSelection = editor.selectedRange()
        XCTAssertFalse(editor.applySourceNavigation(.heading(target())))
        XCTAssertNil(editor.outlineSourcePosition(identity: snapshot.identity))
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.selectedRange(), markedSelection)
        editor.unmarkText(); editor.didChangeText(); undo.endUndoGrouping(); await h.layout()
        XCTAssertFalse(h.requests.jump(to: heading, prepared: prepared, in: h.fixture.session))
        XCTAssertFalse(editor.applySourceNavigation(.heading(target())))
        XCTAssertNil(editor.outlineSourcePosition(identity: snapshot.identity))
    }

    func testCurrentSectionUsesPreparedNativeRowsWithoutSerialization() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let source = "# First\n" + String(repeating: "a", count: 20_000) + "\n## Second\n한😀"
        h.fixture.session.updateSelectedDocumentBody(source); await h.layout()
        let editor = try await h.editor(), identity = try XCTUnwrap(h.fixture.session.runtimeIdentity)
        let serialization = editor.serializationInvocationCount, resets = editor.writingProjectionResetCount
        let last = (source as NSString).range(of: "한😀").location
        for _ in 0..<2_000 {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            XCTAssertEqual(editor.outlineSourcePosition(identity: identity), last)
        }
        XCTAssertEqual(editor.serializationInvocationCount, serialization)
        XCTAssertEqual(editor.writingProjectionResetCount, resets)
    }

    func testCanonicalRepresentationEditAdvancesOwnerAndSynchronizesNativeOffsets() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let original = "# 한\nneedle"
        let replacement = original.precomposedStringWithCanonicalMapping
        h.fixture.session.updateSelectedDocumentBody(original); await h.layout()
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager)
        let oldIdentity = try XCTUnwrap(h.fixture.session.runtimeIdentity)
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        h.requests.sourceReturnPoint = point
        h.fixture.session.updateSelectedDocumentBody(replacement); await h.layout()
        XCTAssertEqual(h.fixture.session.runtimeIdentity?.generation, oldIdentity.generation + 1)
        XCTAssertTrue(h.fixture.session.selectedDocument?.body.utf16.elementsEqual(replacement.utf16) == true)
        XCTAssertTrue(editor.serialize().utf16.elementsEqual(replacement.utf16))
        let current = try await h.editor()
        XCTAssertTrue(current === editor); XCTAssertTrue(current.undoManager === undo)
        XCTAssertNotNil(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertFalse(h.requests.returnToWriting(in: h.fixture.session))
        let newIdentity = h.fixture.session.runtimeIdentity
        h.fixture.session.updateSelectedDocumentBody(replacement)
        XCTAssertEqual(h.fixture.session.runtimeIdentity, newIdentity, "An identical original is still a no-op")
        try await h.fixture.session.flush()
        let reopened = try await h.fixture.store.load(id: oldIdentity.key.projectID)
        let saved = try XCTUnwrap(reopened.documents.first { $0.id == oldIdentity.key.documentID })
        XCTAssertTrue(saved.body.utf16.elementsEqual(replacement.utf16))
    }

    func testSourceCaptureRejectsCanonicalEquivalentUnownedNativeBytes() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let source = "# 한\nneedle"
        h.fixture.session.updateSelectedDocumentBody(source); await h.layout()
        let editor = try await h.editor()
        XCTAssertNotNil(h.requests.captureSourcePosition(in: h.fixture.session))
        editor.load(markdown: source.precomposedStringWithCanonicalMapping)
        XCTAssertNil(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertTrue(h.fixture.session.selectedDocument?.body.utf16.elementsEqual(source.utf16) == true)
    }

    func testReturnRejectsCanonicalEquivalentDifferentNativeOriginal() async throws {
        let h = try await SourceNavigationHarness(short: true)
        defer { h.close() }
        let source = "# 한\nneedle"
        h.fixture.session.updateSelectedDocumentBody(source); await h.layout()
        let editor = try await h.editor()
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        editor.load(markdown: source.precomposedStringWithCanonicalMapping)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let selection = editor.selectedRange()
        XCTAssertFalse(editor.applySourceNavigation(.returnTo(point)))
        XCTAssertEqual(editor.selectedRange(), selection)
    }
}

@MainActor
final class DocumentOutlineWorkspaceTests: XCTestCase {
    func testGeneralOutlinePanelKeepsEditorUndoAndSavedToolSelection() async throws {
        let h = try await FramedWorkspaceHarness(presentationDefaults: [
            "purlory.sidebarSection": "bible", "purlory.toolDockPosition": "right"])
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# Heading\nBody"); await h.layout()
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping(); editor.insertText("!", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        undo.endUndoGrouping(); editor.setSelectedRange(NSRange(location: 2, length: 1))
        let selection = editor.selectedRange()
        h.fixture.session.selectWorkspaceMode(.outline); await h.layout()
        XCTAssertEqual(h.fixture.session.workspaceMode, .outline)
        let current = try await h.editor()
        XCTAssertTrue(current === editor)
        XCTAssertTrue(current.undoManager === undo); XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(current.selectedRange(), selection)
        XCTAssertNotNil(h.element("purlory.document-outline"))
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), "bible")
        h.fixture.session.selectWorkspaceMode(.write); await h.layout()
        XCTAssertNil(h.element("purlory.document-outline"))
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.sidebarSection"), "bible")
        XCTAssertEqual(h.fixture.defaults.string(forKey: "purlory.toolDockPosition"), "right")
        h.fixture.session.selectWorkspaceMode(.outline); await h.layout()
        let menu = try XCTUnwrap(h.requests.pouch).moreMenu()
        let item = try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == "purlory.workspace.context" })
        _ = (item.target as? NSObject)?.perform(try XCTUnwrap(item.action), with: item)
        await h.layout()
        XCTAssertEqual(h.fixture.session.workspaceMode, .outline)
        XCTAssertNotNil(h.element("purlory.document-outline"))
        XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(.context) == true)
        XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(.characters) == true)
        XCTAssertEqual(editor.selectedRange(), selection)
    }
}
