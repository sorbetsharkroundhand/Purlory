@_spi(Benchmark) @testable import PurloryInference
import AppKit
import XCTest
@testable import PurloryCore

@MainActor final class WorkspaceAssistanceTests: XCTestCase {
    func testInlinePolishAppliesCapturedSelectionAndPreservesUndo() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("앞 문장. **고칠 문장.** 뒤 문장.")
        let editor = try await h.editor()
        editor.undoManager?.groupsByEvent = false
        editor.setSelectedRange((editor.string as NSString).range(of: "고칠 문장."))
        let original = h.fixture.session.selectedDocument?.body
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel()) { _, _ in
            AskAnswerGeneration { emit in try emit("다듬은 문장.") }
        }
        let applied = await model.runInline(.polish, editor: editor)
        XCTAssertTrue(applied)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "앞 문장. 다듬은 문장. 뒤 문장.")
        editor.undoManager?.undo(); await h.layout()
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, original)
    }

    func testInlineMarginAnchorsToActiveParagraphAndExpandsNewestCard() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("첫 문단.\n\n지금 쓰는 문단.")
        let editor = try await h.editor(), margin = LivingMarginModel()
        editor.setSelectedRange((editor.string as NSString).range(of: "지금"))
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: margin) { _, prompt in
            XCTAssertTrue(prompt.contains("지금 쓰는 문단."))
            return AskAnswerGeneration { emit in try emit("장면 전환 | 전환의 감각을 한 가지 더해 보세요.") }
        }
        let inserted = await model.runInline(.margin, editor: editor)
        XCTAssertTrue(inserted)
        let insight = try XCTUnwrap(margin.insights.first)
        XCTAssertEqual(insight.title, "장면 전환")
        XCTAssertEqual(insight.message, "전환의 감각을 한 가지 더해 보세요.")
        XCTAssertEqual(insight.evidence.first?.quote.trimmingCharacters(in: .whitespacesAndNewlines), "지금 쓰는 문단.")
        XCTAssertEqual(h.requests.spatialWorkspace?.expandedItem, "margin.\(insight.id)")
    }
    func testPolishAcrossAFormattingBoundaryPreservesUnselectedSourceAndUndo() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let original = "Before **한글🙂** after"
        h.fixture.session.updateSelectedDocumentBody(original)
        let editor = try await h.editor()
        editor.undoManager?.groupsByEvent = false
        editor.setSelectedRange((editor.string as NSString).range(of: "글🙂 after"))
        var suppliedContext = ""
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel()) { _, prompt in
            suppliedContext = prompt
            return AskAnswerGeneration { emit in try emit("다듬은 문장") }
        }
        try model.capture(.polish, editor: editor); await model.generate(prompt: "")
        XCTAssertTrue(suppliedContext.contains("**글🙂** after"))
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, original)
        XCTAssertTrue(model.insert())
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "Before **한**다듬은 문장")
        editor.undoManager?.undo(); await h.layout()
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, original)
    }
    func testExplicitMarginCreatesAnOriginalBackedSuggestionWithoutEditingTheManuscript() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let original = "Original evidence.\n\nSecond paragraph."
        h.fixture.session.updateSelectedDocumentBody(original)
        let editor = try await h.editor(), margin = LivingMarginModel()
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: margin) { _, _ in
            AskAnswerGeneration { emit in try emit("Consider a clearer transition.") }
        }
        try model.capture(.margin, editor: editor); await model.generate(prompt: "")
        XCTAssertTrue(margin.insights.isEmpty)
        XCTAssertTrue(model.insert())
        let insight = try XCTUnwrap(margin.insights.last)
        XCTAssertEqual(insight.kind, .suggestion)
        XCTAssertEqual(insight.evidence.first?.quote.trimmingCharacters(in: .whitespacesAndNewlines), "Original evidence.")
        XCTAssertEqual(insight.evidence.first?.documentID, h.fixture.session.selectedDocumentID)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, original)
        XCTAssertTrue(h.requests.spatialWorkspace?.layout.contains(.margin) == true)
    }
    func testEditingDuringAStreamCancelsTheProducerAndClearsTheBusyState() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let editor = try await h.editor()
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel()) { _, _ in
            AskAnswerGeneration { emit in
                try emit("Partial result")
                try await Task.sleep(for: .seconds(10))
                try emit(" must never publish")
            }
        }
        try model.capture(.coauthor, editor: editor)
        let work = Task { await model.generate(prompt: "Continue") }
        for _ in 0..<100 where model.result.isEmpty { await Task.yield() }
        XCTAssertTrue(model.generating)
        h.fixture.session.updateSelectedDocumentBody("Changed original")
        XCTAssertFalse(model.generating)
        XCTAssertEqual(model.result, "Partial result", "Keep the draft readable without authorizing a stale insertion")
        XCTAssertFalse(model.canInsertResult)
        XCTAssertFalse(model.insert())
        model.cancel(); await work.value
    }
    func testGeneratedTextRequiresExplicitInsertAndRejectsChangedOriginal() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true)
        defer { h.close() }
        let editor = try await h.editor()
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel(), generate: { _, _ in
            AskAnswerGeneration { emit in try emit("A local continuation.") }
        })
        try model.capture(.coauthor, editor: editor)
        let before = h.fixture.session.selectedDocument?.body
        await model.generate(prompt: "Continue")
        XCTAssertEqual(model.result, "A local continuation.")
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before)
        XCTAssertTrue(model.insert())
        XCTAssertTrue(h.fixture.session.selectedDocument?.body.contains("A local continuation.") == true)
        try model.capture(.coauthor, editor: editor)
        await model.generate(prompt: "Continue")
        h.fixture.session.updateSelectedDocumentBody("Changed while reading result")
        XCTAssertFalse(model.insert())
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "Changed while reading result")
    }

    func testUnavailableLocalModelLeavesOriginalUntouchedWithoutCreatingANote() async throws {
        let h = try await FramedWorkspaceHarness(reduceMotion: true)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("Before **한글🙂** after")
        let editor = try await h.editor()
        editor.setSelectedRange((editor.string as NSString).range(of: "한글🙂"))
        let before = h.fixture.session.selectedDocument?.body
        let documents = h.fixture.session.activeProject?.documents.map(\.id)
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel(), generate: { _, _ in
            throw CompletionEngine.ReadyInstructionError.modelUnavailable
        })
        try model.capture(.polish, editor: editor)
        await model.generate(prompt: "")
        XCTAssertFalse(model.errorMessage?.isEmpty ?? true)
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before)
        XCTAssertEqual(h.fixture.session.activeProject?.documents.map(\.id), documents)
    }
    func testSourceABACannotReviveACompletedResult() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        let editor = try await h.editor()
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel()) { _, _ in
            AskAnswerGeneration { emit in try emit("Proposed continuation") }
        }
        try model.capture(.coauthor, editor: editor); await model.generate(prompt: "Continue")
        let before = try XCTUnwrap(h.fixture.session.selectedDocument?.body)
        h.fixture.session.updateSelectedDocumentBody(before + "!")
        h.fixture.session.updateSelectedDocumentBody(before)
        XCTAssertFalse(model.insert())
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, before)
        XCTAssertEqual(model.result, "Proposed continuation")
        XCTAssertFalse(model.canInsertResult)
        XCTAssertNotNil(model.errorMessage)
    }
    func testExplicitCoauthorReadsTheDocumentAndAppendsAfterItsEnd() async throws {
        let h = try await FramedWorkspaceHarness(); defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("First paragraph.\n\nLast paragraph.")
        let editor = try await h.editor()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        var suppliedContext = ""
        let model = WorkspaceAssistance(session: h.fixture.session, requests: h.requests, margin: LivingMarginModel()) { _, prompt in
            suppliedContext = prompt
            return AskAnswerGeneration { emit in try emit("Next paragraph.") }
        }
        try model.capture(.coauthor, editor: editor); await model.generate(prompt: "Continue")
        XCTAssertTrue(suppliedContext.contains("First paragraph.\n\nLast paragraph."))
        XCTAssertTrue(model.insert())
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "First paragraph.\n\nLast paragraph.\n\nNext paragraph.")
    }
}
