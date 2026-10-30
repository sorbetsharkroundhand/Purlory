@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 고스트 제안의 접근성 통합과 컨테이너 폭 줄바꿈 (이슈 #24 / #65 Phase 5).
///
/// 계약:
/// - 시각 고스트와 접근성 노출은 **같은 원천**(ghostText)에서 같은 세대로 읽힌다.
/// - 새 제안마다 세대가 오르고, 사라짐은 세대를 바꾸지 않는다.
/// - 커서 오른쪽 폭이 부족하면 줄바꿈으로 전환한다(순수 판정).
@MainActor
final class GhostAccessibilityTests: XCTestCase {

    func test세대는새제안에서만오르고시각과AX가같은원천이다() {
        let editor = BlockTextView()

        // 첫 제안 — 세대 1.
        editor.ghostText = "첫 번째 제안입니다"
        XCTAssertEqual(editor.ghostGeneration, 1)
        var snapshot = editor.ghostSnapshotForAccessibility()
        XCTAssertEqual(snapshot?.text, "첫 번째 제안입니다")
        XCTAssertEqual(snapshot?.generation, editor.ghostGeneration)

        // 내용 갱신(한 단어 수락 후 짧아짐) — 같은 제안의 생애주기, 세대 유지.
        editor.ghostText = "번째 제안입니다"
        XCTAssertEqual(editor.ghostGeneration, 1, "부분 수락이 세대를 올렸다")

        // 사라짐 — 세대 불변.
        editor.ghostText = nil
        XCTAssertEqual(editor.ghostGeneration, 1)
        XCTAssertNil(editor.ghostSnapshotForAccessibility())

        // 새 제안 — 세대 증가.
        editor.ghostText = "다음 제안"
        XCTAssertEqual(editor.ghostGeneration, 2)
        snapshot = editor.ghostSnapshotForAccessibility()
        XCTAssertEqual(snapshot?.generation, 2)
    }

    func test줄끝판정은남은폭으로결정된다() {
        // 넉넉하면 인라인.
        XCTAssertTrue(BlockTextView.ghostFitsInline(textWidth: 200, availableWidth: 400))
        // 남은 폭이 정확히 같으면 들어간다.
        XCTAssertTrue(BlockTextView.ghostFitsInline(textWidth: 400, availableWidth: 400))
        // 한 글자라도 넘치면 줄바꿈.
        XCTAssertFalse(BlockTextView.ghostFitsInline(textWidth: 401, availableWidth: 400))
        // 폭 계산 실패(0 이하)도 줄바꿈 경로로.
        XCTAssertFalse(BlockTextView.ghostFitsInline(textWidth: 10, availableWidth: 0))
    }

    func testAX값은제안내용과조작법을담고세대가일치한다() {
        let editor = BlockTextView()
        editor.string = "본문 텍스트"

        // 제안 없음 — 기본 값 경로.
        _ = editor.ghostAwareAccessibilityValue()

        // 제안 있음 — 내용·조작법·세대가 값에 들어간다.
        editor.ghostText = "이어질 문장 제안"
        let value = editor.ghostAwareAccessibilityValue() as? String ?? ""
        XCTAssertTrue(value.contains("AI 제안"), "제안 헤더가 없다: \(value)")
        XCTAssertTrue(value.contains("이어질 문장 제안"), "내용이 없다")
        XCTAssertTrue(value.contains("#\(editor.ghostGeneration)"), "세대 불일치")
        XCTAssertTrue(value.contains("Tab"), "수락 조작법이 없다")

        // IME 조합 중 — hasMarkedText 가드로 스냅샷 노출이 막힌다는 규약은
        // draw/accessibilityValue 양쪽에 동일하게 존재한다(실제 조합 상태는
        // 입력 컨텍스트 필요 — E2E 영역).
    }
    func testWrappedGhostOriginUsesNextTextKitVisualLine() {
        let storage = NSTextStorage(
            string: "alpha beta gamma delta epsilon",
            attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: 90, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let glyph = layout.glyphIndexForCharacter(at: 0)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertGreaterThan(fragment.height, 0)

        let originY: CGFloat = 44
        let fragmentInView = fragment.offsetBy(dx: 56, dy: originY)
        let caret = NSRect(
            x: fragmentInView.maxX - 1,
            y: fragmentInView.minY,
            width: 1,
            height: fragmentInView.height)

        let wrappedY = BlockTextView.ghostWrappedOriginY(
            currentLineFragment: fragmentInView,
            caretRect: caret,
            fallbackLineHeight: 20)

        XCTAssertEqual(wrappedY, fragmentInView.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(wrappedY, fragmentInView.minY)
    }

    func testWrappedGhostOriginFallbackNeverMovesUpward() {
        let caret = NSRect(x: 300, y: 120, width: 1, height: 22)
        XCTAssertEqual(
            BlockTextView.ghostWrappedOriginY(
                currentLineFragment: nil,
                caretRect: caret,
                fallbackLineHeight: 20),
            caret.maxY,
            accuracy: 0.001)

        let zeroHeightCaret = NSRect(x: 300, y: 120, width: 1, height: 0)
        XCTAssertEqual(
            BlockTextView.ghostWrappedOriginY(
                currentLineFragment: nil,
                caretRect: zeroHeightCaret,
                fallbackLineHeight: 20),
            140,
            accuracy: 0.001)
    }

}
