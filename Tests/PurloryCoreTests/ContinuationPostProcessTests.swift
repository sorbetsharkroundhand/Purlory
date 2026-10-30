@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 이어쓰기 후처리의 사고 태그 제거 (PLAN §10·§16-1 벤치 후속).
///
/// 사고(thinking) 학습 모델(Qwen3.5 계열)은 챗 템플릿 없는 이어쓰기에서도
/// 사고 태그를 내보낸다 — 2026-08-22 리플레이 벤치에서 Ternary-Bonsai의 제안이
/// "</think>" 그 자체로 나온 것이 계기. 일반 모델 출력은 한 글자도 건드리지
/// 않아야 한다(선행 공백은 어절 경계 정보).
final class ContinuationPostProcessTests: XCTestCase {

    func test_완결된_사고블록은_벗겨_본문만_남긴다() {
        XCTAssertEqual(
            CompletionEngine.stripContinuationThinking("<think>등불을 묘사할 것</think> 등불은"),
            "등불은")
    }

    func test_홀로_닫는태그도_제거한다() {
        XCTAssertEqual(
            CompletionEngine.stripContinuationThinking("</think>\n\n 등불은 돌았다"),
            "등불은 돌았다")
    }

    func test_앞공백이_있어도_태그를_찾는다() {
        XCTAssertEqual(
            CompletionEngine.stripContinuationThinking("  <think>사고</think>본문"),
            "본문")
    }

    func test_닫히지않은_사고블록은_빈제안() {
        XCTAssertEqual(
            CompletionEngine.stripContinuationThinking("<think>아직 생각 중"),
            "")
    }

    func test_일반출력은_한글자도_건드리지않는다() {
        // 선행 공백 = 어절 경계 정보 — 보존돼야 한다.
        XCTAssertEqual(
            CompletionEngine.stripContinuationThinking(" 등불은 십오 초에 한 번"),
            " 등불은 십오 초에 한 번")
        XCTAssertEqual(CompletionEngine.stripContinuationThinking(""), "")
    }

    func test_본문중간의_think문자열은_안건드린다() {
        let text = " 그는 </think>라고 적어 놓은 메모를 봤다"
        XCTAssertEqual(CompletionEngine.stripContinuationThinking(text), text)
    }
}
