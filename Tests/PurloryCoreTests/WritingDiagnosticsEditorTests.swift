@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WritingDiagnosticsEditorTests: XCTestCase {
    func testCorrectionIsOneUndoableEdit() throws {
        let original = "🙂 **됬다** 문장\n앞 $x$ 뒤\n![그림](asset.png)"
        let harness = WritingEditorHarness(original)
        defer { harness.close() }
        let finding = writingEditorFinding(harness, range: (original as NSString).range(of: "됬다"))
        let correction = WritingCorrection(finding: finding, expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
        let attributes = NSAttributedString(attributedString: try XCTUnwrap(harness.editor.textStorage))
        let resets = harness.editor.writingProjectionResetCount
        harness.window.makeFirstResponder(nil)
        XCTAssertEqual(harness.editor.applyWritingCorrection(correction, identity: harness.snapshot.identity), .applied)
        let expected = original.replacingOccurrences(of: "됬다", with: "됐다")
        XCTAssertEqual(harness.body, expected)
        XCTAssertEqual(harness.editor.serialize(), expected)
        XCTAssertEqual(harness.projectedSource, expected)
        XCTAssertEqual(harness.events.suffix(2), ["binding", "commit"], "The normal autosave binding and capture both run")
        XCTAssertTrue(harness.window.firstResponder === harness.editor)
        let native = (harness.editor.string as NSString).range(of: "됐다")
        XCTAssertEqual(harness.editor.selectedRange(), NSRange(location: native.upperBound, length: 0))
        XCTAssertEqual(harness.editor.writingProjectionResetCount, resets)
        harness.window.testUndo.undo()
        XCTAssertEqual(harness.body, original)
        XCTAssertTrue(harness.editor.textStorage!.isEqual(to: attributes))
        harness.window.testUndo.redo()
        XCTAssertEqual(harness.body, expected)
        XCTAssertEqual(harness.editor.serialize(), expected)
    }

    func testRefuseStaleDuplicateFormattedAndMarkedTargets() throws {
        let harness = WritingEditorHarness("됬다 🙂 됬다")
        defer { harness.close() }
        let finding = writingEditorFinding(harness, range: (harness.body as NSString).range(of: "됬다", options: .backwards))
        let correction = WritingCorrection(finding: finding, expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
        harness.edit("밖 ", range: .init(location: 0, length: 0))
        let unchanged = harness.body
        XCTAssertEqual(harness.editor.applyWritingCorrection(correction, identity: harness.snapshot.identity), .refused(reason: .stale))
        XCTAssertEqual(harness.body, unchanged, "An old duplicate quote is never searched for or guessed")
        let fresh = writingEditorFinding(harness, range: (harness.body as NSString).range(of: "됬다"))
        let invalidAlternative = WritingCorrection(finding: fresh, expectedSource: "됬다", expectedNative: "됬다", replacement: "다른 문장")
        XCTAssertEqual(harness.editor.applyWritingCorrection(invalidAlternative, identity: harness.snapshot.identity), .refused(reason: .stale))
        XCTAssertEqual(harness.body, unchanged)
        let formatted = WritingEditorHarness("됬**다**")
        defer { formatted.close() }
        let crossing = WritingCorrection(finding: writingEditorFinding(formatted, range: .init(location: 0, length: formatted.body.utf16.count)),
            expectedSource: formatted.body, expectedNative: "됬다", replacement: "됐다")
        XCTAssertEqual(formatted.editor.applyWritingCorrection(crossing, identity: formatted.snapshot.identity), .refused(reason: .formatting))
        XCTAssertEqual(formatted.body, "됬**다**")
        let composing = WritingCorrection(finding: fresh, expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
        harness.window.testUndo.beginUndoGrouping()
        harness.editor.setMarkedText("한", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: harness.editor.string.utf16.count, length: 0))
        let marked = harness.editor.string
        XCTAssertEqual(harness.editor.applyWritingCorrection(composing, identity: harness.snapshot.identity), .refused(reason: .composing))
        XCTAssertTrue(harness.editor.hasMarkedText())
        XCTAssertEqual(harness.editor.string, marked)
        harness.editor.unmarkText()
        harness.window.testUndo.endUndoGrouping()
    }

    func testAlternativesCannotIntroduceNativeMarkdownTransforms() throws {
        for alternative in ["**됐다**", "# 됐다", "- 됐다", "1. 됐다", "1.", "됐다\n문장"] {
            let harness = WritingEditorHarness("됬다 원고")
            defer { harness.close() }
            var finding = writingEditorFinding(harness, range: .init(location: 0, length: 2))
            finding.diagnostic.alternatives = [alternative]
            let correction = WritingCorrection(finding: finding, expectedSource: "됬다", expectedNative: "됬다", replacement: alternative)
            XCTAssertEqual(harness.editor.applyWritingCorrection(correction, identity: harness.snapshot.identity), .refused(reason: .formatting), alternative)
            XCTAssertEqual(harness.body, "됬다 원고")
        }
    }

    func testCorrectionRequiresUndoAndAttachedEditor() throws {
        for condition in 0..<3 {
            let harness = WritingEditorHarness("됬다")
            defer {
                if condition == 2 { harness.window.testUndo.enableUndoRegistration() }
                harness.close()
            }
            let correction = WritingCorrection(finding: writingEditorFinding(harness, range: .init(location: 0, length: 2)),
                expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
            switch condition {
            case 0: harness.editor.allowsUndo = false
            case 1: harness.window.contentView = nil
            default: harness.window.testUndo.disableUndoRegistration()
            }
            guard case .refused = harness.editor.applyWritingCorrection(correction, identity: harness.snapshot.identity) else {
                XCTFail("A correction requires its live native undo owner"); continue
            }
            XCTAssertEqual(harness.body, "됬다")
        }
    }

    func testNoneditableTransitionCannotApply() throws {
        let harness = WritingEditorHarness("됬다")
        defer { harness.close() }
        let correction = WritingCorrection(finding: writingEditorFinding(harness, range: .init(location: 0, length: 2)),
            expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
        harness.editor.isEditable = false
        guard case .refused = harness.editor.applyWritingCorrection(correction, identity: harness.snapshot.identity) else {
            return XCTFail("A transition-disabled editor cannot be mutated")
        }
        XCTAssertEqual(harness.body, "됬다")
    }

    func testMixedAttributesInsideWordAreRefusedWithoutMutation() throws {
        let harness = WritingEditorHarness("됬다")
        defer { harness.close() }
        harness.editor.textStorage?.addAttribute(.kern, value: 1.5, range: .init(location: 0, length: 1))
        harness.editor.didChangeText()
        let attributes = NSAttributedString(attributedString: try XCTUnwrap(harness.editor.textStorage))
        let correction = WritingCorrection(finding: writingEditorFinding(harness, range: .init(location: 0, length: 2)),
            expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
        XCTAssertEqual(harness.editor.applyWritingCorrection(correction, identity: harness.snapshot.identity), .refused(reason: .formatting))
        XCTAssertTrue(harness.editor.textStorage!.isEqual(to: attributes))
        XCTAssertEqual(harness.body, "됬다")
    }

    func testActionsResolveOnlyCurrentAlternativeAndRecheckFailedProof() async throws {
        let harness = WritingEditorHarness("됬다 문장", useBridge: true)
        let other = WritingEditorHarness("됬다 다른 프로젝트")
        defer { harness.close(); other.close() }
        let clock = ManualDiagnosticsClock()
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [WritingCorrectionProbe()]),
            clock: clock, currentSnapshot: { harness.snapshot })
        defer { controller.cancel() }
        let previous = harness.bridge.commitDidChange
        harness.bridge.commitDidChange = { commit, snapshot in
            previous?(commit, snapshot)
            controller.noteSnapshot(snapshot); controller.noteEditorCommit(commit, snapshot: snapshot)
        }
        controller.noteSnapshot(harness.snapshot)
        controller.noteEditorCommit(.init(baseIdentity: harness.snapshot.identity, nativeRevision: harness.editor.writingNativeRevision,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: harness.snapshot)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        var finding = try XCTUnwrap(controller.state.findings.first)
        var target = harness.editor
        let actions = WritingDiagnosticsActions(controller: controller, editor: { target }, currentSnapshot: { harness.snapshot })
        XCTAssertEqual(actions.apply(findingID: finding.id, alternativeIndex: 99), .refused(reason: .stale))
        XCTAssertEqual(harness.body, "됬다 문장")
        XCTAssertFalse(controller.state.coverage.dirty.isEmpty, "A failed proof schedules current work again")
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        finding = try XCTUnwrap(controller.state.findings.first)
        target = other.editor
        XCTAssertEqual(actions.apply(findingID: finding.id, alternativeIndex: 0), .refused(reason: .stale))
        XCTAssertEqual(other.body, "됬다 다른 프로젝트")
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        finding = try XCTUnwrap(controller.state.findings.first)
        target = harness.editor
        XCTAssertEqual(actions.apply(findingID: finding.id, alternativeIndex: 0), .applied)
        XCTAssertEqual(harness.body, "됐다 문장")
        XCTAssertEqual(harness.projectedSource, harness.body)
        XCTAssertTrue(controller.state.findings.isEmpty, "The normal native commit invalidates the applied finding")
        XCTAssertEqual(actions.apply(findingID: finding.id, alternativeIndex: 0), .refused(reason: .stale))
        XCTAssertEqual(harness.body, "됐다 문장")
    }

    func testProjectTransitionAndInvalidSourceProofCannotApply() throws {
        let harness = WritingEditorHarness("됬다")
        defer { harness.close() }
        let finding = writingEditorFinding(harness, range: .init(location: 0, length: 2))
        let wrong = WritingCorrection(finding: finding, expectedSource: "같다", expectedNative: "같다", replacement: "됐다")
        XCTAssertEqual(harness.editor.applyWritingCorrection(wrong, identity: harness.snapshot.identity), .refused(reason: .unmapped))
        let other = ProjectRuntimeIdentity(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1)
        let correction = WritingCorrection(finding: finding, expectedSource: "됬다", expectedNative: "됬다", replacement: "됐다")
        XCTAssertEqual(harness.editor.applyWritingCorrection(correction, identity: other), .refused(reason: .stale))
        XCTAssertEqual(harness.body, "됬다")
    }
}

@MainActor
func writingEditorFinding(_ harness: WritingEditorHarness, range: NSRange, category: WritingDiagnosticCategory = .correctness) -> WritingDiagnosticsFinding {
    let quote = (harness.body as NSString).substring(with: range)
    let diagnostic = WritingDiagnostic(id: UUID().uuidString, ruleID: "fixture.correctness", providerID: "probe", category: category,
        kind: category == .correctness ? .spelling : .repeatedWord, severity: category == .correctness ? .correctness : .suggestion,
        range: .init(range), message: "Synthetic editor proof fixture", alternatives: ["됐다"], languageTag: "ko")
    return WritingDiagnosticsFinding(id: diagnostic.id, diagnostic: diagnostic, sourceRanges: [.init(range)], relatedSourceRanges: [],
        evidence: .init(documentID: harness.key.documentID, quote: quote, utf16Hint: range.location),
        contextRange: .init(location: 0, length: harness.body.utf16.count),
        stamp: .init(runtime: harness.snapshot.identity, nativeRevision: harness.editor.writingNativeRevision,
            profileRevision: 1, providerRevision: "probe", ruleRevision: 1, windowDigest: "fixture"))
}

private struct WritingCorrectionProbe: WritingDiagnosticsProvider {
    let id = "native-action-probe"
    func analyze(_ request: WritingDiagnosticsRequest) async throws -> [WritingDiagnostic] {
        let range = (request.text as NSString).range(of: "됬다")
        guard range.location != NSNotFound else { return [] }
        return [.init(id: "synthetic", ruleID: "fixture.correctness", providerID: id, category: .correctness, kind: .spelling,
            severity: .correctness, range: .init(range), message: "Synthetic native action fixture", alternatives: ["됐다"], languageTag: "ko")]
    }
}
