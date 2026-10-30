@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import AppKit
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 에디터 storage 편집으로서의 긴 문단 나누기 검증 (docs/editor-paragraph-split.md).
/// 순수 로직(ParagraphSplitterTests)과 별개로, 실제 storage·undo·직렬화를 몬다.
/// **최우선은 원고 무결성** — 나눈 뒤에도 글자가 그대로여야 한다.
final class ParagraphSplitEditorTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    @MainActor
    private func makeEditor() -> BlockTextView {
        let storage = NSTextStorage()
        let lm = PurloryLayoutManager()
        storage.addLayoutManager(lm)
        let c = NSTextContainer(
            containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(c)
        let v = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: c)
        storage.delegate = v
        v.allowsUndo = true
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        w.contentView?.addSubview(v)
        w.makeFirstResponder(v)
        windows.append(w)
        return v
    }

    private func longProse(_ sentences: Int) -> String {
        (1...sentences)
            .map { "이것은 \($0)번째 문장이며 대략 스물다섯 자 안팎의 길이를 가진다. " }
            .joined()
    }

    /// 나눈 뒤 직렬화 결과에서 개행을 빼면 원문에서 개행을 뺀 것과 같아야 한다.
    @MainActor func testSplitPreservesTextExactly() {
        let view = makeEditor()
        let body = "# 장\n\n" + longProse(400)  // 헤딩 + 거대 산문 문단
        view.load(markdown: body)

        let count = view.splitOversizedProseParagraphs()
        XCTAssertGreaterThan(count, 0, "긴 문단이 감지·분할되어야 한다")

        let after = view.serialize()
        XCTAssertEqual(
            after.replacingOccurrences(of: "\n", with: ""),
            body.replacingOccurrences(of: "\n", with: ""),
            "개행 외의 글자가 바뀌었다 — 원고 손상")
        // 실제로 문단이 늘었는지(나뉘었는지).
        XCTAssertGreaterThan(
            after.components(separatedBy: "\n\n").count,
            body.components(separatedBy: "\n\n").count)
    }

    /// 나눈 뒤 각 문단이 trigger 이하 — 랙의 근본 원인이 사라진다.
    @MainActor func testSplitResultsAreUnderTrigger() {
        let view = makeEditor()
        view.load(markdown: longProse(600))
        view.splitOversizedProseParagraphs()
        let ns = view.string as NSString
        var loc = 0
        while loc < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            XCTAssertLessThanOrEqual(
                p.length, ParagraphSplitter.trigger + 200,  // 마지막 병합 여유
                "나눈 뒤에도 trigger를 넘는 문단이 남았다")
            loc = p.upperBound
        }
    }

    /// ⌘Z(단일 undo 그룹)로 원문이 정확히 복원되어야 한다.
    @MainActor func testUndoRestoresOriginalExactly() {
        let view = makeEditor()
        let body = longProse(400)
        view.load(markdown: body)
        let before = view.serialize()

        view.splitOversizedProseParagraphs()
        XCTAssertNotEqual(view.serialize(), before, "나뉘어야 한다")

        view.undoManager?.undo()
        XCTAssertEqual(view.serialize(), before, "undo 후 원문이 정확히 복원되지 않았다")
    }

    /// 짧은 문단만 있는 문서는 건드리지 않는다.
    @MainActor func testShortDocumentUntouched() {
        let view = makeEditor()
        let body = "# 제목\n\n짧은 문단이다.\n\n또 다른 짧은 문단."
        view.load(markdown: body)
        XCTAssertEqual(view.splitOversizedProseParagraphs(), 0)
        XCTAssertEqual(view.serialize(), body)
    }

    /// 감지 수치가 UI 설명문과 맞는지 — 산문만, 크기 초과만 센다.
    @MainActor func testDetectionCountsProseOnly() {
        let view = makeEditor()
        // 거대 산문 1개 + 거대 코드블록 1개(코드는 대상 아님)
        let code = "```\n" + String(repeating: "let x = 1\n", count: 800) + "```"
        view.load(markdown: longProse(400) + "\n\n" + code)
        let (count, maxLen) = view.oversizedProseParagraphs()
        XCTAssertEqual(count, 1, "코드 블록은 나누기 대상이 아니다")
        XCTAssertGreaterThan(maxLen, ParagraphSplitter.trigger)
    }

    /// 나눈 뒤 이어서 편집·직렬화가 정상(캐시가 새 구조로 재구축).
    @MainActor func testEditingWorksAfterSplit() {
        let view = makeEditor()
        view.load(markdown: longProse(400))
        view.splitOversizedProseParagraphs()
        let mid = (view.string as NSString).length / 2
        view.setSelectedRange(NSRange(location: mid, length: 0))
        view.insertText("X", replacementRange: NSRange(location: mid, length: 0))
        // 새 에디터에 다시 열어 직렬화한 것과 일치(증분 캐시 정합).
        let inc = view.serialize()
        let fresh = makeEditor()
        fresh.load(markdown: inc)
        XCTAssertEqual(fresh.serialize(), inc)
    }
}
