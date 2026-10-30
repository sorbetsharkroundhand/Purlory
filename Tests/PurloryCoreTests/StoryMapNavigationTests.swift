@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class StoryMapNavigationTests: XCTestCase {
    func testRepeatedFormattedSceneJumpAndReturnKeepNativeSelectionScrollAndUndo() async throws {
        let h = try await SourceNavigationHarness(short: true, mode: .fiction); defer { h.close() }
        let source = "# **😀 한**\n" + String(repeating: "집필 위치를 보존하는 문단.\n", count: 60) + "# **😀 한**\n마지막 원문"
        h.fixture.session.updateSelectedDocumentBody(source); h.fixture.session.selectWorkspaceMode(.map); await h.layout()
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager), original = editor.serialize()
        undo.beginUndoGrouping(); editor.insertText("!", replacementRange: NSRange(location: editor.string.utf16.count, length: 0)); undo.endUndoGrouping()
        await h.layout(); editor.setSelectedRange(NSRange(location: 3, length: 1))
        editor.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 200))
        let document = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot)
        let map = try await StoryMapProjection.build(document), prepared = PreparedStoryMap(identity: document.identity, projection: map)
        let last = try XCTUnwrap(map.scenes.last), point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertGreaterThan(point.scrollOrigin.y, 0)
        XCTAssertTrue(h.requests.jump(to: last, prepared: prepared, in: h.fixture.session)); await h.layout()
        let expected = (editor.string as NSString).range(of: "😀 한", options: .backwards)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: expected.location, length: 0))
        let mapped = try XCTUnwrap(editor.storyMapSourcePosition(identity: document.identity))
        XCTAssertTrue(last.sourceRange.contains(mapped))
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session)); await h.layout()
        let returned = try await h.editor()
        XCTAssertTrue(returned === editor); XCTAssertTrue(returned.undoManager === undo)
        XCTAssertEqual(editor.selectedRange(), point.selection)
        XCTAssertEqual(editor.enclosingScrollView?.contentView.bounds.origin, point.scrollOrigin)
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertTrue(undo.canUndo); undo.undo(); await h.layout()
        XCTAssertTrue(editor.serialize().utf16.elementsEqual(original.utf16))
    }
    func testEventQuoteUsesItsExactNativeOccurrenceAcrossRepeatedPassages() async throws {
        let h = try await SourceNavigationHarness(short: true, mode: .fiction); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# 첫 장면\n같은 원문\n# 둘째 장면\n같은 원문"); h.fixture.session.selectWorkspaceMode(.map); await h.layout()
        let document = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot), outline = DocumentOutline.parse(document.body)
        let scope = StoryMemoryScope.project(projectID: document.identity.key.projectID, documentID: document.identity.key.documentID)
        let events = Dictionary(uniqueKeysWithValues: outline.scenes.enumerated().map { index, scene in
            (scene.contentHash, [StoryEvent(sceneHash: scene.contentHash, participants: [], summary: "사건 \(index)", importance: 3, quote: "같은 원문")])
        })
        let knowledge = KnowledgeSnapshot(entryID: document.identity.key.documentID.rawValue, outline: outline, summariesByHash: [:],
            storyKnowledge: .init(scope: scope, source: document.body, facts: [], entities: .init(characters: [])), events: events)
        let map = try await StoryMapProjection.build(document, knowledge: knowledge, knowledgeOrigin: document.identity)
        let event = try XCTUnwrap(map.rows.last { $0.kind == .event })
        XCTAssertTrue(h.requests.jump(to: event, prepared: .init(identity: document.identity, projection: map), in: h.fixture.session)); await h.layout()
        let editor = try await h.editor(), expected = (editor.string as NSString).range(of: "같은 원문", options: .backwards)
        XCTAssertEqual(editor.selectedRange(), expected)
        XCTAssertEqual(editor.storyMapSourcePosition(identity: document.identity), event.sourceRange.lowerBound)
    }
    func testRawOriginalProofStaleOwnerAndMarkedTextRefuseWithoutMovingSelection() async throws {
        let h = try await SourceNavigationHarness(short: true, mode: .fiction); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# 한\n원문"); h.fixture.session.selectWorkspaceMode(.map); await h.layout()
        let editor = try await h.editor(), document = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot)
        let map = try await StoryMapProjection.build(document), prepared = PreparedStoryMap(identity: document.identity, projection: map)
        let row = try XCTUnwrap(map.scenes.first), target = StoryMapSourceTarget(identity: document.identity, revision: map.revision, row: row)
        XCTAssertTrue(target.matchesSource(document.body))
        XCTAssertFalse(target.matchesSource(document.body.precomposedStringWithCanonicalMapping))
        let undo = try XCTUnwrap(editor.undoManager); undo.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        XCTAssertFalse(h.requests.jump(to: row, prepared: prepared, in: h.fixture.session))
        XCTAssertEqual(editor.selectedRange(), selection); XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText(); editor.didChangeText(); undo.endUndoGrouping(); await h.layout()
        let current = editor.selectedRange()
        XCTAssertFalse(h.requests.jump(to: row, prepared: prepared, in: h.fixture.session))
        XCTAssertEqual(editor.selectedRange(), current); XCTAssertFalse(editor.applyStoryMapSource(target))
    }
}
