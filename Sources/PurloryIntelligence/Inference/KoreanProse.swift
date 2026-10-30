import Foundation

/// 한국어 산문 렌더링용 결정적 형태소 보조기 (PLAN §11 프롬프트 형식 개편).
///
/// 지식 블록을 `필드=값` 레코드가 아니라 자연 문장으로 펴 주는 재료다 —
/// 소설 코퍼스에 맞춰진 모델일수록 키-값 덤프보다 서술형 문장을 잘 흡수하고
/// 어투 누수가 적다는 실측(NovelAI lorebook 커뮤니티)과 연구(CHIRON의
/// QA시트 > 속성 나열, EMNLP 2024)가 일치한다.
/// 받침 판정은 유니코드 계산뿐 — 예측 경로 예산 안의 저비용 결정 로직이다
/// (CLAUDE.md §2-5, LLM 토큰을 쓰지 않는다).
package enum KoreanProse {

    /// 마지막 글자의 종성(받침) 유무. 한글 조합형 음절(AC00–D7A3) 밖의
    /// 문자(라틴·숫자·문장부호)는 받침 없음으로 취급한다 — 한글 소설 이름에서
    /// 이 경우는 드물고, 틀려도 어색함의 상한이 낮은 쪽이다 ("지우은"보다
    /// "Zion는" 식의 오류가 덜 눈에 박인다).
    package static func hasFinalConsonant(_ word: String) -> Bool {
        guard let scalar = word.unicodeScalars.last else { return false }
        // '가'(U+AC00)부터 11172개의 조합형 음절. 오프셋 % 28 != 0 → 종성 있음.
        guard scalar.value >= 0xAC00, scalar.value <= 0xD7A3 else { return false }
        return (scalar.value - 0xAC00) % 28 != 0
    }

    /// 주제 조사 — word + (은/는). 괄호 별칭이 붙은 이름에는 쓰지 말 것
    /// (마지막 글자 판정이 무너진다). 벌거벗은 이름만 넣는다.
    package static func topic(_ word: String) -> String {
        word + (hasFinalConsonant(word) ? "은" : "는")
    }

    /// 주격 조사 — word + (이/가).
    package static func subject(_ word: String) -> String {
        word + (hasFinalConsonant(word) ? "이" : "가")
    }

    /// 목적 조사 — word + (을/를).
    package static func object(_ word: String) -> String {
        word + (hasFinalConsonant(word) ? "을" : "를")
    }

    /// 서술격 어미 — 명사 + (이다/다). "불안" → "불안이다", "기쁨" → "기쁨이다".
    package static func copula(_ noun: String) -> String {
        noun + (hasFinalConsonant(noun) ? "이다" : "다")
    }

    /// 문장 끝 마침표 보장 — 추출 값이 이미 종결부호로 끝나면 두지 않는다.
    package static func terminated(_ sentence: String) -> String {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…。！？".contains(last) ? trimmed : trimmed + "."
    }
}
