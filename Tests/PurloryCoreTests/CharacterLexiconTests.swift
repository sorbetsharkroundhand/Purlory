@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 감지 언어 지식(렉시콘) 회귀 테스트 (PLAN §7) — 조사 표의 정렬 불변식과
/// 제외 집합 병합을 고정한다. Apple 형태소 분석기가 한국어 품사를 못 주는
/// 환경에서 이 데이터가 곧 문법이므로, 데이터가 무너지면 감지가 무너진다.
final class CharacterLexiconTests: XCTestCase {

    func test조사표는_긴_표면형_먼저() {
        // 길이 내림차순 정렬 — "서연에게서"를 "서연" + "에서"로 잘못 벗기는
        // 짧은 조사 선매칭을 구조적으로 막는 불변식이다.
        let particles = CharacterLexicon.base.particles

        for (index, particle) in particles.enumerated() where index > 0 {
            XCTAssertGreaterThanOrEqual(
                particles[index - 1].suffix.count, particle.suffix.count,
                "\(particle.suffix)가 \(particles[index - 1].suffix)보다 앞에 있으면 안 된다")
        }

        let first = particles.first?.suffix
        XCTAssertEqual(first, "이에게서") // 최장 조사가 맨 앞
        XCTAssertTrue(particles.contains { $0.suffix == "에게" && $0.role == .dative })
        XCTAssertTrue(particles.contains { $0.suffix == "아" && $0.role == .vocative })
        XCTAssertTrue(particles.contains { $0.suffix == "의" && $0.role == .genitive })
    }

    func test제외집합은_세_부류의_합집합() {
        let excluded = CharacterLexicon.base.excluded

        // 대명사 — 구조 신호만으로 못 거르는 닫힌 부류.
        XCTAssertTrue(excluded.contains("그녀"))
        XCTAssertTrue(excluded.contains("당신"))
        // 호칭 — 발화 주어가 되므로 명시 제외가 필요한 부류.
        XCTAssertTrue(excluded.contains("선생님"))
        XCTAssertTrue(excluded.contains("소장님"))
        // 불용어 — 유정 신호를 우연히 통과하는 일반명사 안전망.
        XCTAssertTrue(excluded.contains("사람"))
        XCTAssertTrue(excluded.contains("천천히"))
    }

    func test동음이의_소리는_불용어가_아니다() {
        // 인물명일 수 있는 낱말은 발화 귀속 등 구조 신호가 판단한다 —
        // 불용어로 뭉개면 그 판단 자체가 사라진다 (레키콘 문서 참조).
        XCTAssertFalse(CharacterLexicon.base.excluded.contains("소리"))
    }

    func test사용자_불용어_병합() {
        let merged = CharacterLexicon.base.mergingUserStopwords(["위스키", "등대"])
        XCTAssertTrue(merged.excluded.contains("위스키"))
        XCTAssertTrue(merged.excluded.contains("등대"))
        XCTAssertTrue(merged.excluded.contains("그녀")) // 기본값 보존
        XCTAssertEqual(
            merged.particles.count, CharacterLexicon.base.particles.count) // 언어 구조는 불변

        // 빈 확장분은 원본 그대로 — 매 감지 패스의 할당을 아끼는 빠른 경로.
        let untouched = CharacterLexicon.base.mergingUserStopwords([])
        XCTAssertEqual(untouched.excluded, CharacterLexicon.base.excluded)
    }
}
