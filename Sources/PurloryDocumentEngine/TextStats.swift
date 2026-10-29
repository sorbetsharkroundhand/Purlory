import Foundation

/// 본문 통계 (단어·글자 수) — 상태 바 표시용.
///
/// **왜 별도 타입인가**: 상태 바가 렌더마다 `filter`·`split`으로 문서 전체를
/// 3번 훑었다 — 키 입력마다 88k자에서 ~18ms·300k에서 ~62ms (릴리즈 실측,
/// docs/editor-perf.md). "키 입력당 O(문서) 금지"(PLAN §16)를 상태 바가 어기고
/// 있었던 것. 계산을 단일 패스로 합치고, 호출은 디바운스 + 백그라운드로 옮긴다.
public struct TextStats: Equatable, Sendable {
    /// 공백 제외 글자 수 (국문 관례).
    public var characters = 0
    /// 공백으로 나뉜 어절/단어 수.
    public var words = 0

    public static let empty = TextStats()

    /// 한 번의 패스로 두 값을 다 센다 — Character(자소 클러스터) 단위라
    /// 기존 `filter`/`split` 결과와 동일하다 (동등성은 테스트로 고정).
    public static func compute(_ text: String) -> TextStats {
        var characters = 0
        var words = 0
        var inWord = false
        for char in text {
            if char.isWhitespace {
                inWord = false
            } else {
                characters += 1
                if !inWord {
                    words += 1
                    inWord = true
                }
            }
        }
        return TextStats(characters: characters, words: words)
    }

    public init(characters: Int = 0, words: Int = 0) {
        self.characters = characters
        self.words = words
    }

    /// 읽는 데 걸리는 대략 시간 — 한글 기준 분당 약 500자.
    public var readingLabel: String {
        guard characters > 0 else { return "" }
        let minutes = Double(characters) / 500
        if minutes < 1 { return "1분 미만" }
        return "약 \(Int(minutes.rounded()))분"
    }
}
