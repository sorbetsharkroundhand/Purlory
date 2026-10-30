@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 리프레시 경로의 O(문서) 임시 속성 제거 제거 — 범위 한정 닦기 (이슈 #18).
///
/// 계약:
/// - 수식 문단이 산문으로 바뀌면(그룹 해체) clear 전경이 **남지 않는다** —
///   남으면 본문이 보이지 않는 치명적 결함.
/// - clear는 심긴 범위에만 존재한다 (문서 나머지는 무손성).
@MainActor
final class MathClearAttributeTests: XCTestCase {

    private func makeTextView() -> BlockTextView {
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                             textContainer: container)
    }

    func test그룹해체후_산문에clear가남지않는다() {
        let textView = makeTextView()

        // 수식 그룹으로 시작.
        let withMath = "$$E=mc^2$$\n뒤의 산문 문단입니다."
        textView.load(markdown: withMath)

        let ns = withMath as NSString
        let mathRange = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        // 렌더 후 해당 문단에 clear가 심겨 있어야 한다 (그리기 억제).
        XCTAssertEqual(
            textView.layoutManager?.temporaryAttribute(
                .foregroundColor, atCharacterIndex: mathRange.location,
                effectiveRange: nil) as? NSColor,
            NSColor.clear,
            "수식 문단에 clear 억제가 없다")

        // 그룹 해체 — 수식 줄을 산문으로 편집.
        let proseOnly = "E=mc^2는 공식이다\n뒤의 산문 문단입니다."
        textView.load(markdown: proseOnly)

        let ns2 = proseOnly as NSString
        for location in [0, ns2.length - 1] {
            let attr = textView.layoutManager?.temporaryAttribute(
                .foregroundColor, atCharacterIndex: location, effectiveRange: nil
            ) as? NSColor
            XCTAssertNotEqual(
                attr, NSColor.clear,
                "위치 \(location): 산문에 clear 잔상 — 본문이 안 보인다")
        }
    }
}
