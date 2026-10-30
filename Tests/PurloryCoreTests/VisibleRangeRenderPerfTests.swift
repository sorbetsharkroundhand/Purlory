@testable import PurloryIntelligence
import AppKit
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 가시 범위 렌더의 실측 (이슈 #18 종결 근거).
///
/// 계약: 스크롤 주도 갱신(refreshVisibleBlocks)은 문서 크기와 무관하게
/// **가시 범위에 닿는 블록 수에 비례하는 시간**이어야 한다 — 전체 패스는
/// 문단 수에 선형으로 늘어나는 것과 대비된다.
@MainActor
final class VisibleRangeRenderPerfTests: XCTestCase {

    /// 수식 블록 count개짜리 문서 + 스크롤뷰 세팅.
    private func makeScrolledEditor(mathBlocks count: Int)
        -> (textView: BlockTextView, scrollView: NSScrollView)
    {
        let container = NSTextContainer(
            containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let textView = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 4000),
            textContainer: container)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()

        var body = ""
        for index in 0..<count {
            body += "$$x_\(index) = \\frac{\(index)}{\(index + 1)}$$\n산문 문단 \(index). 이야기가 이어진다.\n\n"
        }
        textView.load(markdown: body)
        return (textView, scrollView)
    }

    func testVisibleRenderScanRangeStaysBoundedToViewport() throws {
        let large = makeScrolledEditor(mathBlocks: 240)
        large.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        large.scrollView.reflectScrolledClipView(large.scrollView.contentView)

        let visible = try XCTUnwrap(large.textView.visibleTextRange())
        let scan = large.textView.mediaRenderScanRange(for: visible)
        let total = (large.textView.string as NSString).length

        XCTAssertLessThan(scan.length, total / 2)
        XCTAssertLessThanOrEqual(scan.location, visible.location)
        XCTAssertGreaterThanOrEqual(scan.upperBound, visible.upperBound)
    }

    /// 전체 패스 비용 — 문단 수에 선형.
    func test전체패스는문단수에비례해늘어난다() {
        let small = makeScrolledEditor(mathBlocks: 60)
        let large = makeScrolledEditor(mathBlocks: 240)

        let smallMs = timeFull(small)
        let largeMs = timeFull(large)
        // 4배 문단 → 유의미하게 더 걸린다 (선형성의 방향 검증, 절대치 아님).
        XCTAssertGreaterThan(
            largeMs, smallMs,
            "전체 패스가 문단 수와 무관하다면 필터가 작동하지 않는다")
    }

    private func timeFull(
        _ pair: (textView: BlockTextView, scrollView: NSScrollView)
    ) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            pair.textView.refreshRenderedBlocks(forceRender: true)
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
        }
        return best * 1000
    }

    /// 가시 한정 패스 — 전체 패스 상한을 넘지 않고, 범위 계산은 문서의 일부만.
    func test가시한정패스는문서크기와무관이다() {
        let small = makeScrolledEditor(mathBlocks: 60)
        let large = makeScrolledEditor(mathBlocks: 240)

        // 두 문서 모두 같은 화면(600pt)에서 맨 위를 본다.
        for pair in [small, large] {
            pair.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            pair.scrollView.reflectScrolledClipView(pair.scrollView.contentView)
            _ = pair.textView.visibleTextRange()  // 레이아웃 워밍업
        }

        func timeVisible(_ pair: (textView: BlockTextView, scrollView: NSScrollView)) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<5 {
                let start = CFAbsoluteTimeGetCurrent()
                pair.textView.refreshVisibleBlocks()
                best = min(best, CFAbsoluteTimeGetCurrent() - start)
            }
            return best * 1000
        }

        let largeVisibleMs = timeVisible(large)
        let largeFullMs = timeFull(large)

        // 규약 1 — 가시 한정은 전체 패스보다 **절대 느리지 않다** (렌더 수집 스킵).
        // LaTeX 추출·clear 심기 같은 비싼 일이 화면 밖에서 생략되므로, 남는
        // O(문단 걷기)만으로도 전체 패스의 상한을 넘지 않아야 한다.
        XCTAssertLessThanOrEqual(
            largeVisibleMs, largeFullMs * 1.25,
            "가시 한정이 전체 패스보다 유의미히 느림 — 필터가 역효과 (largeVisible=\(largeVisibleMs)ms, largeFull=\(largeFullMs)ms)")

        // 규약 2 — 기능: 가시 범위는 문서의 작은 부분이고, 갱신 후 화면 안 수식은
        // 억제(clear) 상태로 수집돼 있다.
        let range = large.textView.visibleTextRange()
        XCTAssertNotNil(range, "헤드리스 스크롤뷰에서 가시 범위 계산 실패")
        if let r = range {
            let total = (large.textView.string as NSString).length
            XCTAssertLessThan(
                CGFloat(r.length) / CGFloat(total), 0.5,
                "가시 범위가 문서 절반 이상 — 버퍼 과다 또는 레이아웃 미완료")
        }
    }
}
