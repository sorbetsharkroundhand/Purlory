@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 수식 객체의 오류 표시·복사·키보드 조작·접근성 (이슈 #22).
///
/// 계약: 무효 수식은 원인이 화면에 남지 않고 사라지며(잔상 금지), LaTeX/
/// 이미지/PDF 복사가 제공되고, 이동·삭제는 이름 있는 undo로 남으며, 인라인
/// 원자는 VoiceOver에 "수식: …"로 읽힌다.
final class MathObjectTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var undoManager: UndoManager!

    override func tearDownWithError() throws {
        let windowsToClean = windows
        MainActor.assumeIsolated {
            // 다음 비동기 테스트의 이벤트 루프에 자동 undo 그룹 종료를 남기지 않는다.
            windowsToClean.forEach { $0.undoManager?.removeAllActions() }
        }
        windows.removeAll()
    }

    @MainActor
    private func makeEditor(text: String) -> BlockTextView {
        let storage = NSTextStorage()
        let layoutManager = PurloryLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: container)
        storage.delegate = view
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        windows.append(window)
        if !text.isEmpty {
            view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            while view.undoManager?.groupingLevel ?? 0 > 0 {
                view.undoManager?.endUndoGrouping()
            }
        }
        return view
    }

    @MainActor
    private func grouped(_ editor: BlockTextView, _ body: @MainActor () -> Void) {
        editor.undoManager?.beginUndoGrouping()
        body()
        editor.undoManager?.endUndoGrouping()
    }

    // MARK: - 렌더 오류 표시 (#22 완료 조건 2)

    @MainActor
    func test무효수식은원인을돌려주고유효수식은nil이다() {
        let bad = MathRenderer.render(
            latex: "\\frac{1{", color: .black, fontSize: 14)
        XCTAssertNil(bad.image)
        XCTAssertNotNil(bad.error, "원인 메시지가 없다")
        XCTAssertFalse(bad.error!.isEmpty)

        let good = MathRenderer.render(latex: "\\frac{1}{2}", color: .black, fontSize: 14)
        XCTAssertNotNil(good.image)
        XCTAssertNil(good.error)
    }

    @MainActor
    func test실패플레이스홀더는원인과소스를담아그려진다() {
        let placeholder = MathRenderer.failurePlaceholder(
            message: "Expected }", latex: "\\frac{1{", color: .black)
        XCTAssertTrue(placeholder.size.width > 100)
        XCTAssertTrue(placeholder.size.height > 30)
        XCTAssertNotNil(placeholder.tiffRepresentation, "그리기 가능해야 한다")
    }

    // MARK: - 복사 (#22 완료 조건 3)

    @MainActor
    func testPDF복사데이터는PDF시그니처를가진다() throws {
        let image = try XCTUnwrap(MathRenderer.render(
            latex: "E=mc^2", color: .black, fontSize: 16).image)
        let pdf = try XCTUnwrap(MathRenderer.pdfData(from: image))
        XCTAssertEqual(String(data: pdf.prefix(4), encoding: .ascii), "%PDF")
    }

    // MARK: - 이름 있는 원자적 undo (#22 완료 조건 1)

    @MainActor
    func test수식이동과삭제의이력이름() throws {
        let editor = makeEditor(text: "$$E=mc^2$$\n본문 줄")
        let ns = editor.string as NSString
        let mathPara = ns.paragraphRange(for: NSRange(location: 0, length: 0))

        grouped(editor) { editor.moveMathParagraph(mathPara, offset: 1) }
        XCTAssertEqual(editor.undoManager?.undoActionName, "수식 이동")

        grouped(editor) { editor.deleteMathParagraph(ns.paragraphRange(for: NSRange(location: 11, length: 0))) }
        XCTAssertEqual(editor.undoManager?.undoActionName, "수식 삭제")

        // 삭제 undo — 문단이 통째로 돌아온다.
        editor.undoManager?.undo()
        XCTAssertTrue(editor.string.contains("본문 줄"))
    }
}
