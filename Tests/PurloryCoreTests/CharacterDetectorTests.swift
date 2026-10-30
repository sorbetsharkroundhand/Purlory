@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 인물 후보 감지 회귀 테스트 (PLAN §7) — **품질 > 적극성**의 최전선.
/// 유정 신호(여격·호격·발화 귀속) 게이트와 신뢰도 등급, 별칭 병합이
/// 문서화된 대로 동작하는지 고정한다. 오탐 하나가 자동 등록으로 이어지면
/// 사용자 신뢰가 무너지므로(CLAUDE.md §3) 침묵 쪽을 넉넉하게 검증한다.
final class CharacterDetectorTests: XCTestCase {

    /// 씬 본문 배열 → 헤딩 있는 원문 + 아웃라인으로 감지 실행.
    private func detect(
        _ sceneBodies: [String], known: Set<String> = [],
        rejected: Set<String> = []
    ) -> [CharacterDetector.Candidate] {
        var body = ""
        for (index, text) in sceneBodies.enumerated() {
            body += "\n## s\(index)\n\(text)"
        }
        return CharacterDetector.detect(
            body: body, outline: .parse(body), known: known, rejected: rejected)
    }

    /// HIGH 픽스처 한 씬 — 서연: 언급 5·유정 2(호격+여격)·격역할 5.
    private static let seoyeonHigh =
        "서연은 창밖을 바라보았다. \"서연아, 이리 와.\" 그는 서연에게 커피를 건넸다. "
        + "서연이 일어섰다. 서연과 있고 싶었다."

    func test유정신호가_충분한_인물은_HIGH로_감지() {
        let candidates = detect(Array(repeating: Self.seoyeonHigh, count: 3))

        XCTAssertEqual(candidates.count, 1)
        let seoyeon = try! XCTUnwrap(candidates.first)
        XCTAssertEqual(seoyeon.name, "서연")
        XCTAssertEqual(seoyeon.confidence, .high)
        XCTAssertEqual(seoyeon.mentions, 15)
        XCTAssertEqual(seoyeon.sceneCount, 3)
        XCTAssertEqual(seoyeon.animacyHits, 6)   // 호격+여격 씬당 2
        XCTAssertEqual(seoyeon.caseRoleCount, 5)  // 보조·호·여·주·공동
    }

    func test유정신호가_하나도_없으면_침묵() {
        // 사물 명사 — 격조사는 취해도 사람 신호는 못 받는다. 정밀도의 핵심 레버.
        let lamp =
            "등불이 흔들렸다. 등불을 껐다. 등불의 그림자가 길어졌다. 벽에 등불이 비쳤다. 등불은 깜빡였다."
        let candidates = detect(Array(repeating: lamp, count: 3))

        XCTAssertTrue(candidates.isEmpty)
    }

    func test유정신호가_약하면_MEDIUM() {
        // HIGH 요건(유정 2+ **그리고** 격 역할 2+) 중 격 다양성이 미달 —
        // 보조사 하나로만 쓰인 이름은 유정 신호가 있어도 medium이다.
        let weak =
            "서연은 말했다. 서연은 웃었다. 서연은 걸었다. 서연은 문을 닫았다. 서연은 돌아섰다."
        let candidates = detect(Array(repeating: weak, count: 3))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.name, "서연")
        XCTAssertEqual(candidates.first?.confidence, .medium)
    }

    func test동음이의는_발화귀속이_있을때만_후보() {
        // "소리" — 불용어로 뭉개지 않고 구조 신호로만 갈린다 (레키콘 문서 참조).
        let withSpeech =
            "낯선 소리가 말했다. 소리는 계속되었다. 소리를 따라갔다. 소리의 주인은 보이지 않았다. 소리와 함께 밤이 깊었다."
        XCTAssertFalse(detect(Array(repeating: withSpeech, count: 3)).isEmpty)

        // 같은 빈도, 같은 격 — 발화 동사만 없으면 침묵한다.
        let withoutSpeech = withSpeech.replacingOccurrences(
            of: "소리가 말했다", with: "소리가 울렸다")
        XCTAssertTrue(detect(Array(repeating: withoutSpeech, count: 3)).isEmpty)
    }

    func test대명사와_호칭은_제외된다() {
        let line =
            "그녀는 조용히 말했다. 선생님이 고개를 끄덕였다. 그녀를 바라보았다. 선생님께 물었다. "
            + "그녀와 눈이 마주쳤다. 선생님은 자리를 비웠다."
        let candidates = detect(Array(repeating: line, count: 3))

        XCTAssertTrue(candidates.isEmpty)
    }

    func test언급과_씬수_임계_미달은_침묵() {
        // 언급 부족 — 씬은 3개지만 총 2회.
        let sparse = ["서연은 웃었다. 서연이 말했다.", "다른 이야기였다.", "또 다른 이야기였다."]
        XCTAssertTrue(detect(sparse).isEmpty)

        // 씬 수 부족 — 언급은 충분해도 한 씬에 몰려 있으면 안 된다.
        let concentrated = [
            "서연은 창밖을 보았다. \"서연아, 이리 와.\" 서연에게 커피를 건넸다. 서연이 웃었다. 서연과 걸었다.",
            "전혀 다른 장면이다.",
            "또 다른 장면이다.",
        ]
        XCTAssertTrue(detect(concentrated).isEmpty)
    }

    func test짧은_원고는_씬수_임계가_문서에_맞춰_내려간다() {
        // 씬 1개 문서 — 임계가 min(3, 1) = 1로 낮아진다.
        let candidates = detect([Self.seoyeonHigh])
        XCTAssertEqual(candidates.first?.name, "서연")
        XCTAssertEqual(candidates.first?.sceneCount, 1)
    }

    func test등록됨과_거절됨은_후보에서_제외() {
        XCTAssertTrue(
            detect(Array(repeating: Self.seoyeonHigh, count: 3), known: ["서연"]).isEmpty)
        XCTAssertTrue(
            detect(Array(repeating: Self.seoyeonHigh, count: 3), rejected: ["서연"]).isEmpty)
    }

    func test이미_등록된_인물의_별칭은_표시만_한다() {
        // 자동 병합 금지 — 병합은 사용자 결정(요구사항 §17).
        let candidates = detect(
            Array(repeating: Self.seoyeonHigh, count: 3), known: ["김서연"])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.name, "서연")
        XCTAssertEqual(candidates.first?.aliasOfKnown, "김서연")
        // HIGH여도 별칭 후보는 새 인물 자동 등록 대상이 아니므로 medium으로 강등.
        XCTAssertEqual(candidates.first?.confidence, .medium)
    }

    func test표기변형은_긴형태_대표로_병합된다() {
        // 김재형 / 재형 / 재형이 — 연쇄 변형이 한 인물로 묶인다.
        let line =
            "김재형은 문을 열었다. \"김재형아, 들어와.\" 그는 김재형에게 말을 걸었다. 김재형이 웃었다. "
            + "재형이가 고개를 끄덕였다. \"재형아!\" 재형에게 전화했다. 재형은 창가로 갔다."
        let candidates = detect(Array(repeating: line, count: 3))

        XCTAssertEqual(candidates.count, 1)
        let merged = try! XCTUnwrap(candidates.first)
        XCTAssertEqual(merged.name, "김재형")       // 가장 긴 표기가 대표
        XCTAssertEqual(merged.aliasForms, ["재형"]) // 재형이는 재형에 흡수된 상태
        XCTAssertEqual(merged.confidence, .high)
        // 김재형 12 + 재형 9 — "재형이가"는 매개 이 벗기기 대상이 아니라
        // (주격 이 제외) 임계 5 미만 증거가 되어 병합 전에 걸러진다.
        XCTAssertEqual(merged.mentions, 21)
    }

    func test후보는_최대_다섯명만() {
        // 질문 줄을 세우지 않는다(품질 > 적극성) — 7명이 자격을 갖춰도 5명 컷.
        let names = ["가온", "나래", "다솜", "라온", "마루", "바다", "사랑"]
        let scene = names.map { name in
            "\(name)에게 말을 걸었다. \"\(name)아, 와.\" \(name)는 웃었다. \(name)이 앉았다. \(name)과 헤어졌다."
        }.joined()
        let candidates = detect(Array(repeating: scene, count: 3))

        XCTAssertEqual(candidates.count, 5)
    }

    func test빈_아웃라인은_침묵() {
        let candidates = CharacterDetector.detect(
            body: "", outline: .parse(""), known: [], rejected: [])
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - 병합 로직 단위

    private func candidate(
        _ name: String, mentions: Int, confidence: CharacterDetector.Confidence
    ) -> CharacterDetector.Candidate {
        .init(
            name: name, mentions: mentions, sceneCount: 3, animacyHits: 2,
            caseRoleCount: 2, confidence: confidence)
    }

    func test별칭_모양_판정() {
        // 성+이름 접미 관계.
        XCTAssertTrue(CharacterDetector.isAliasShape("재형", of: "김재형"))
        XCTAssertTrue(CharacterDetector.isAliasShape("도경", of: "김도경"))
        // 애칭 조사 형태 — 양방향.
        XCTAssertTrue(CharacterDetector.isAliasShape("재형이", of: "재형"))
        XCTAssertTrue(CharacterDetector.isAliasShape("재형", of: "재형이"))
        // 동일·무관·글자 수 차이 초과.
        XCTAssertFalse(CharacterDetector.isAliasShape("김재형", of: "김재형"))
        XCTAssertFalse(CharacterDetector.isAliasShape("수아", of: "민준"))
        XCTAssertFalse(CharacterDetector.isAliasShape("재형", of: "김수재형"))
    }

    func test병합은_증거를_합산하고_대표를_긴형태로() {
        let long = candidate("김재형", mentions: 10, confidence: .high)
        let short = candidate("재형", mentions: 6, confidence: .medium)

        let merged = CharacterDetector.mergeAliasForms([long, short])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "김재형")
        XCTAssertEqual(merged[0].mentions, 16)
        XCTAssertEqual(merged[0].aliasForms, ["재형"])
        XCTAssertEqual(merged[0].confidence, .high) // 하나라도 HIGH면 HIGH
    }

    func test병합은_연쇄를_추이적으로_묶는다() {
        let full = candidate("김재형", mentions: 5, confidence: .medium)
        let bare = candidate("재형", mentions: 5, confidence: .medium)
        let pet = candidate("재형이", mentions: 5, confidence: .medium)

        let merged = CharacterDetector.mergeAliasForms([full, bare, pet])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "김재형")
        XCTAssertEqual(merged[0].aliasForms, ["재형", "재형이"]) // 정렬된 별칭
        XCTAssertEqual(merged[0].mentions, 15)
    }

    func test무관한_후보는_병합하지_않는다() {
        let a = candidate("서연", mentions: 5, confidence: .medium)
        let b = candidate("민준", mentions: 5, confidence: .medium)

        XCTAssertEqual(CharacterDetector.mergeAliasForms([a, b]).count, 2)
        XCTAssertEqual(CharacterDetector.mergeAliasForms([a]).count, 1)
    }
}
