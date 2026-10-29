@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore

/// 프롬프트 KV 재사용의 핵심 계산 — LCP 판정과 trim 양 (PLAN §12).
///
/// 지연의 최대 병목(프리필 재계산)을 없애는 로직이라, KV 캐시·모델 없이도
/// 결정적으로 검증돼야 한다. 시나리오는 실제 타이핑 궤적에서 온다:
/// 이어 치기(접두 유지) · 뒤로 지우기(요청이 기록보다 짧다) · 중간 편집
/// (갈라진 뒤 새 길이) · 생성 토큰 오염(offset > 기록) · 취소된 프리필
/// (offset < 기록).
final class PromptCacheMathTests: XCTestCase {

    // MARK: - reusablePrefix

    func test_완전동일_프롬프트는_마지막토큰만_다시_프리필한다() {
        let tokens = Array(0..<100)
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(offset: 100, recorded: tokens, requested: tokens),
            99,
            "빈 입력으론 생성을 시작할 수 없으므로 최소 1토큰은 남긴다")
    }

    func test_이어치기는_공통접두_전부를_재사용한다() {
        let recorded = Array(0..<100)
        var requested = recorded
        requested.append(contentsOf: [7, 7, 7])  // 타이핑 = 접두 + 몇 글자
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(offset: 100, recorded: recorded, requested: requested),
            100)
    }

    func test_뒤로지우기는_남은접두까지_재사용한다() {
        let recorded = Array(0..<10)
        let requested = Array(0..<6)  // 넉 자 지움 — 남은 여섯이 통째로 접두와 같다
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(offset: 10, recorded: recorded, requested: requested),
            5,
            "요청 전체가 접두와 일치해도 최소 1토큰은 다시 프리필한다 (n−1 규칙)")
    }

    func test_중간편집은_갈라진지점까지_재사용한다() {
        let recorded = [1, 2, 3, 4, 5]
        let requested = [1, 2, 9, 4, 5, 6]  // 세 번째 토큰부터 다르다
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(offset: 5, recorded: recorded, requested: requested),
            2)
    }

    func test_전혀다른_프롬프트는_재사용없음() {
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(
                offset: 5, recorded: [1, 2, 3], requested: [9, 8, 7]),
            0, "LCP 0 → 호출부가 새 캐시로 전체 프리필한다")
    }

    func test_생성토큰은_재사용에_안센다() {
        // 캐시엔 프롬프트 100 + 생성 20이 들어 있다(offset=120). 재사용 상한은
        // 기록된 프롬프트 길이 — 생성 토큰이 접두인 양 속이면 안 된다.
        let recorded = Array(0..<100)
        let requested = recorded + Array(200..<210)
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(offset: 120, recorded: recorded, requested: requested),
            100,
            "known = min(offset, recorded.count) 클램프")
    }

    func test_취소된_프리필_뒤에는_이어서_프리필한다() {
        // 협조 취소로 프리필이 40토큰에서 멈췄다 — commit은 전체 프롬프트를 기록.
        // 재사용은 캐시의 진실(40)까지만, trim은 0 — 나머지 60은 이어서 프리필.
        let recorded = Array(0..<100)
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(offset: 40, recorded: recorded, requested: recorded),
            40)
    }

    func test_기록보다_캐시가_짧으면_캐시가_한계다() {
        let recorded = Array(0..<100)
        XCTAssertEqual(
            PromptCacheMath.reusablePrefix(
                offset: 30, recorded: recorded, requested: Array(0..<80)),
            30, "offset이 기록보다 작으면 offset까지가 재사용 한계다")
    }

    // MARK: - trimAmount

    func test_trim양은_offset에서_재사용분을_뺀_나머지다() {
        XCTAssertEqual(PromptCacheMath.trimAmount(offset: 120, reused: 100), 20)
        XCTAssertEqual(PromptCacheMath.trimAmount(offset: 40, reused: 40), 0)
    }

    func test_재사용분은_offset을_넘지않아_trim이_음수가되지않는다() {
        // 불변조건: reusablePrefix ≤ offset. 어기면 trim이 음수가 되어
        // mlx trim 호출이 실패·전체 폐기로 빠진다.
        let samples: [(offset: Int, recorded: Int, divergence: Int)] = [
            (120, 100, 50), (5, 3, 0), (40, 100, 90), (10, 10, 10), (0, 5, 2),
        ]
        for sample in samples {
            let recorded = Array(repeating: 1, count: sample.recorded)
            let requested = Array(repeating: 1, count: max(sample.divergence, 0)) + [9]
                + Array(repeating: 2, count: 3)
            let reused = PromptCacheMath.reusablePrefix(
                offset: sample.offset, recorded: recorded, requested: requested)
            XCTAssertLessThanOrEqual(reused, sample.offset)
            XCTAssertGreaterThanOrEqual(PromptCacheMath.trimAmount(offset: sample.offset, reused: reused), 0)
        }
    }
}
