@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 상태 바 통계 회귀 테스트 — 단일 패스 `TextStats.compute`가 기존 상태 바
/// 공식(`filter`/`split` 각각 문서 전체 순회)과 **결과 동일**함을 고정한다.
/// 그 공식들이 키 입력마다 3번 돌던 것이 대형 문서 타이핑 랙의 주범이었다
/// (docs/editor-perf.md).
final class TextStatsTests: XCTestCase {

    /// 기존 상태 바 공식 그대로 — 비교 기준.
    private func legacy(_ text: String) -> (chars: Int, words: Int) {
        (
            text.filter { !$0.isWhitespace }.count,
            text.split(whereSeparator: { $0.isWhitespace }).count
        )
    }

    private func assertMatches(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let stats = TextStats.compute(text)
        let expected = legacy(text)
        XCTAssertEqual(stats.characters, expected.chars, "글자 수 불일치", file: file, line: line)
        XCTAssertEqual(stats.words, expected.words, "단어 수 불일치", file: file, line: line)
    }

    func test기존_공식과_동일() {
        assertMatches("")
        assertMatches("   \n\t  ")
        assertMatches("서연은 창밖을 바라보았다.")
        assertMatches("한 단어")
        assertMatches("공백  여러   개와\n개행\n\n혼합\t탭까지 ")
        assertMatches("English words mixed 한국어 어절 123 !?")
        assertMatches(String(repeating: "가나다 라마바사. ", count: 500))
    }

    func test자모_연타_입력() {
        // 실제 랙 재현 입력 — 조합 안 되는 자음 연쇄.
        assertMatches("ㅁㄴㅇㄹㅁㄴㅇㄹㅁㄴㅇㄹㅁㄴㅇㄹ")
    }

    func test읽기_시간_라벨() {
        XCTAssertEqual(TextStats(characters: 0).readingLabel, "")
        XCTAssertEqual(TextStats(characters: 100).readingLabel, "1분 미만")
        XCTAssertEqual(TextStats(characters: 1_500).readingLabel, "약 3분")
    }
}
