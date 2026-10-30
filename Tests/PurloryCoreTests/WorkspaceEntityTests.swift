@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspaceEntityTests: XCTestCase {
    func testEventPeekRejectsAChangedOriginal() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction); defer { h.close() }
        let session = h.fixture.session
        session.updateSelectedDocumentBody("1999년 12월 31일 — 파도가 높았다.")
        let editor = try await h.editor(), document = try XCTUnwrap(session.selectedDocument)
        let reference = try XCTUnwrap(OriginalSourceReference.exact(.init(documentID: document.id, quote: document.body, utf16Hint: 0), in: XCTUnwrap(session.activeProject)))
        let entities = WorkspaceEntityController(session: session, requests: h.requests)
        h.requests.spatialWorkspace?.entityEvents = [.init(name: "1999년 12월 31일", note: "당직 일지", reference: reference)]
        entities.hover(editor: editor, key: reference.key, nativeOffset: 2)
        XCTAssertEqual(entities.peek?.badge, "사건")
        entities.hide()
        session.updateSelectedDocumentBody("1999년 12월 31일 — 원문이 바뀌었다.")
        await h.layout()
        entities.hover(editor: editor, key: reference.key, nativeOffset: 2)
        XCTAssertNil(entities.peek)
    }
    func testResearchNoteHeadingProducesAnOriginalBackedPeekInAnotherDocument() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction); defer { h.close() }
        let session = h.fixture.session, manuscript = try XCTUnwrap(session.selectedDocumentID)
        session.updateSelectedDocumentBody("도경은 프레넬 렌즈를 닦았다.")
        let note = try XCTUnwrap(session.createDocument(title: "등대 고증", kind: .note))
        session.updateSelectedDocumentBody("## 프레넬 렌즈\n동심원 계단식 유리 프리즘.")
        session.selectDocument(manuscript); await h.layout()
        let editor = try await h.editor()
        let model = WorkspaceEntityController(session: session, requests: h.requests)
        model.hover(editor: editor, key: try XCTUnwrap(session.runtimeIdentity).key,
            nativeOffset: (editor.string as NSString).range(of: "프레넬 렌즈").location)
        XCTAssertEqual(model.peek?.name, "프레넬 렌즈")
        XCTAssertEqual(model.peek?.reference.key.documentID, note)
        model.hide()
    }
    func testPeekUsesNativeSourceMappingAcrossAnEarlierOpaqueMathOccurrence() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction); defer { h.close() }
        let session = h.fixture.session
        session.updateSelectedDocumentBody("$한도경$\n\n한도경은 바람을 들었다.")
        try ProjectWriterEditing.perform(.character(CharacterCard(name: "한도경", note: "등대지기")), in: session, identity: XCTUnwrap(session.runtimeIdentity))
        let editor = try await h.editor()
        let model = WorkspaceEntityController(session: session, requests: h.requests)
        let native = (editor.string as NSString).range(of: "한도경", options: .backwards)
        XCTAssertNotEqual(native.location, NSNotFound)
        model.hover(editor: editor, key: try XCTUnwrap(session.runtimeIdentity).key, nativeOffset: native.location)
        let reference = try XCTUnwrap(model.peek?.reference)
        XCTAssertEqual(reference.evidence.utf16Hint, (try XCTUnwrap(session.selectedDocument?.body) as NSString).range(of: "한도경", options: .backwards).location)
        model.hide()
    }
    func testOnlyAuthorRecordsWithAnExactOriginalProducePeeksAndDelayedHideCancelsOnEntry() async throws {
        let h = try await FramedWorkspaceHarness(mode: .fiction)
        defer { h.close() }
        let session = h.fixture.session
        session.updateSelectedDocumentBody("한도경은 바람을 들었다.")
        let identity = try XCTUnwrap(session.runtimeIdentity)
        try ProjectWriterEditing.perform(.character(CharacterCard(name: "한도경", note: "등대지기")), in: session, identity: identity)
        try ProjectWriterEditing.perform(.character(CharacterCard(name: "없는 인물", note: "아직 원문에 없음")), in: session, identity: XCTUnwrap(session.runtimeIdentity))
        await h.layout()
        let model = WorkspaceEntityController(session: session, requests: h.requests)
        let editor = try await h.editor()
        model.hover(editor: editor, key: identity.key, nativeOffset: 1)
        XCTAssertEqual(model.peek?.name, "한도경")
        XCTAssertEqual(h.requests.spatialWorkspace?.resonatingTerm, "한도경")
        model.scheduleHide(); model.keepAlive()
        try await Task.sleep(for: .milliseconds(210))
        XCTAssertNotNil(model.peek)
        model.scheduleHide(); try await Task.sleep(for: .milliseconds(210))
        XCTAssertNil(model.peek); XCTAssertNil(h.requests.spatialWorkspace?.resonatingTerm)
        h.requests.spatialWorkspace?.whisperTyping = true
        model.hover(editor: editor, key: identity.key, nativeOffset: 1)
        XCTAssertNil(model.peek)
    }
}
