@testable import PurloryIntelligence
import AppKit
import CryptoKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class OriginalSourceNavigationTests: XCTestCase {
    private func reference(_ quote: String, in document: ProjectDocumentSnapshot, last: Bool = false) -> OriginalSourceReference {
        let range = (document.body as NSString).range(of: quote, options: last ? .backwards : [])
        return .init(key: document.identity.key, revision: SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined(),
            evidence: .init(documentID: document.identity.key.documentID, quote: quote, utf16Hint: range.location), selection: .passage)
    }
    func testOriginalProofRefusesSurrogateRepairCanonicalChangeWrongScopeAndOverflow() async throws {
        let f = try await LegacyBoundaryFixture(mode: .fiction); defer { f.cleanUp() }
        f.session.updateSelectedDocumentBody("😀 한 원문")
        let document = try XCTUnwrap(f.session.selectedDocumentSnapshot)
        let valid = reference("한", in: document)
        XCTAssertTrue(valid.matchesSource(document.body))
        XCTAssertFalse(valid.matchesSource(document.body.precomposedStringWithCanonicalMapping))
        for (quote, hint) in [("�", 0), ("�", 1), ("원문", Int.max), ("원문", -1), ("", 0)] {
            let forged = OriginalSourceReference(key: valid.key, revision: valid.revision,
                evidence: .init(documentID: valid.key.documentID, quote: quote, utf16Hint: hint), selection: .passage)
            XCTAssertFalse(forged.matchesSource(document.body))
        }
        let wrong = OriginalSourceReference(key: valid.key, revision: valid.revision,
            evidence: .init(documentID: WritingDocumentID(), quote: "한", utf16Hint: 3), selection: .passage)
        XCTAssertFalse(wrong.matchesSource(document.body))
        let target = OriginalSourceTarget(identity: .init(key: .init(projectID: WritingProjectID(), documentID: valid.key.documentID), generation: 1), reference: valid)
        XCTAssertFalse(target.matchesSource(document.body))
    }
    func testSameDocumentFormattedMultilineOriginalUsesExactOccurrenceAndPreservesUndoReturn() async throws {
        let h = try await SourceNavigationHarness(short: true, mode: .fiction); defer { h.close() }
        let passage = "**😀 한**은 문을 열었다.\n다음 원문이다."
        h.fixture.session.updateSelectedDocumentBody("# 첫 장면\n" + passage + "\n# 다음 장면\n" + passage)
        await h.layout()
        let editor = try await h.editor(), undo = try XCTUnwrap(editor.undoManager), before = editor.serialize()
        undo.beginUndoGrouping(); editor.insertText("!", replacementRange: NSRange(location: editor.string.utf16.count, length: 0)); undo.endUndoGrouping()
        await h.layout(); editor.setSelectedRange(NSRange(location: 2, length: 1))
        let document = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot), source = document.body as NSString
        // Native font runs may serialize adjacent bold spans separately. Evidence always
        // comes from the current captured manuscript, never the pre-edit fixture spelling.
        let start = source.range(of: "# 다음 장면\n", options: .backwards).upperBound
        let end = source.range(of: "다음 원문이다.", options: .backwards).upperBound
        let capturedPassage = source.substring(with: NSRange(location: start, length: end - start))
        let ref = reference(capturedPassage, in: document, last: true)
        let inspection = ProjectSourceInspection(session: h.fixture.session), token = try XCTUnwrap(inspection.capture())
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session))
        XCTAssertTrue(ref.matchesSource(document.body))
        XCTAssertTrue(editor.ownsOriginalSource(document.identity))
        XCTAssertTrue(inspection.isCurrent(token, in: h.fixture.session))
        XCTAssertTrue(h.requests.jump(to: ref, inspection: inspection, token: token, in: h.fixture.session)); await h.layout()
        let expected = (editor.string as NSString).range(of: "😀 한은 문을 열었다.\n다음 원문이다.", options: .backwards)
        XCTAssertNotEqual(expected.location, NSNotFound); XCTAssertEqual(editor.selectedRange(), expected)
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session)); await h.layout()
        let returned = try await h.editor(); XCTAssertTrue(returned === editor); XCTAssertTrue(editor.undoManager === undo)
        XCTAssertEqual(editor.selectedRange(), point.selection); XCTAssertTrue(undo.canUndo)
        undo.undo(); await h.layout(); XCTAssertTrue(editor.serialize().utf16.elementsEqual(before.utf16))
    }
    func testPinnedInspectionCrossDocumentNavigationReturnsWithoutRetiringButMutationABARefuses() async throws {
        let h = try await SourceNavigationHarness(mode: .fiction); defer { h.close() }
        let first = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot), firstEditor = try await h.editor()
        let oldTarget = OriginalSourceTarget(identity: first.identity, reference: reference("Paragraph 0", in: first))
        firstEditor.setSelectedRange(NSRange(location: 3000, length: 6))
        firstEditor.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 400))
        let point = try XCTUnwrap(h.requests.captureSourcePosition(in: h.fixture.session)), undo = try XCTUnwrap(firstEditor.undoManager)
        let project = try XCTUnwrap(h.fixture.session.activeProject), other = try XCTUnwrap(project.documents.last)
        let otherIdentity = ProjectRuntimeIdentity(key: .init(projectID: project.id, documentID: other.id), generation: first.identity.generation)
        let snapshot = ProjectDocumentSnapshot(identity: otherIdentity, title: other.title, body: other.body, kind: other.kind, mode: .fiction)
        let ref = reference("needle", in: snapshot), inspection = ProjectSourceInspection(session: h.fixture.session)
        let token = try XCTUnwrap(inspection.capture())
        XCTAssertTrue(h.requests.jump(to: ref, inspection: inspection, token: token, in: h.fixture.session)); await h.layout()
        XCTAssertTrue(inspection.isCurrent(token, in: h.fixture.session))
        let destination = try await h.editor()
        XCTAssertEqual((destination.string as NSString).substring(with: destination.selectedRange()), "needle")
        XCTAssertEqual(h.fixture.session.selectedDocumentID, other.id)
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session)); await h.layout()
        XCTAssertTrue(inspection.isCurrent(token, in: h.fixture.session))
        let returned = try await h.editor()
        XCTAssertTrue(returned === firstEditor)
        XCTAssertFalse(returned.applyOriginalSource(oldTarget), "Returning to identical source cannot revive an old editor runtime")
        XCTAssertEqual(returned.selectedRange(), point.selection)
        XCTAssertEqual(returned.enclosingScrollView?.contentView.bounds.origin, point.scrollOrigin)
        XCTAssertTrue(returned.undoManager === undo); XCTAssertEqual(returned.serialize(), first.body)
        h.fixture.session.updateSelectedDocumentBody(first.body + "!"); h.fixture.session.updateSelectedDocumentBody(first.body); await h.layout()
        let selection = returned.selectedRange()
        XCTAssertFalse(inspection.isCurrent(token, in: h.fixture.session))
        XCTAssertFalse(h.requests.jump(to: ref, inspection: inspection, token: token, in: h.fixture.session))
        XCTAssertEqual(h.fixture.session.selectedDocumentID, first.identity.key.documentID); XCTAssertEqual(returned.selectedRange(), selection)
        XCTAssertNotNil(h.requests.sourceNavigationError)
    }
    func testMarkedTextStaleNativeRuntimeAndRetiredInspectionRefuse() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let editor = try await h.editor(), document = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot)
        let ref = reference("needle", in: document), target = OriginalSourceTarget(identity: document.identity, reference: ref)
        let inspection = ProjectSourceInspection(session: h.fixture.session), token = try XCTUnwrap(inspection.capture())
        let undo = try XCTUnwrap(editor.undoManager); undo.beginUndoGrouping()
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        XCTAssertFalse(editor.applyOriginalSource(target)); XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(h.requests.jump(to: ref, inspection: inspection, token: token, in: h.fixture.session))
        XCTAssertEqual(editor.selectedRange(), selection)
        editor.unmarkText(); editor.didChangeText(); undo.endUndoGrouping(); await h.layout()
        XCTAssertFalse(editor.applyOriginalSource(target))
        let current = try XCTUnwrap(inspection.capture()); inspection.retire()
        XCTAssertFalse(inspection.isCurrent(current, in: h.fixture.session))
    }

    func testInspectionOwnerUserDataAndSameDocumentIDInAnotherProjectRemainIsolated() async throws {
        let f = try await LegacyBoundaryFixture(mode: .fiction); defer { f.cleanUp() }
        let inspection = ProjectSourceInspection(session: f.session), other = ProjectSourceInspection(session: f.session)
        let token = try XCTUnwrap(inspection.capture()), document = try XCTUnwrap(f.session.selectedDocumentSnapshot)
        XCTAssertFalse(other.isCurrent(token, in: f.session))
        try f.session.updateUserData(Data("writer choice".utf8), for: WritingStyleRepository.key, identity: document.identity)
        XCTAssertFalse(inspection.isCurrent(token, in: f.session))
        let next = try XCTUnwrap(inspection.capture())
        let foreign = WritingProject(id: WritingProjectID(), title: "Other", mode: .fiction,
            documents: [.init(id: document.identity.key.documentID, title: document.title, body: document.body, kind: document.kind)])
        try await f.session.saveAndActivate(foreign)
        XCTAssertFalse(inspection.isCurrent(next, in: f.session))
        let fresh = try XCTUnwrap(inspection.capture())
        XCTAssertEqual(fresh.projectID, foreign.id); XCTAssertTrue(inspection.isCurrent(fresh, in: f.session))
    }

    func testOpaqueMathOriginalFailsWithSourceErrorWithoutMovingOrChangingTheEditor() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# 원문\n앞 문장 $x$ 뒤 문장"); await h.layout()
        let editor = try await h.editor(), document = try XCTUnwrap(h.fixture.session.selectedDocumentSnapshot)
        let ref = reference("$x$", in: document), inspection = ProjectSourceInspection(session: h.fixture.session)
        let token = try XCTUnwrap(inspection.capture()), selection = editor.selectedRange(), undo = editor.undoManager
        XCTAssertTrue(ref.matchesSource(document.body))
        XCTAssertTrue(h.requests.jump(to: ref, inspection: inspection, token: token, in: h.fixture.session)); await h.layout()
        XCTAssertNotNil(h.requests.sourceNavigationError)
        XCTAssertEqual(editor.selectedRange(), selection); XCTAssertTrue(editor.undoManager === undo)
        XCTAssertTrue(editor.serialize().utf16.elementsEqual(document.body.utf16))
    }
}
