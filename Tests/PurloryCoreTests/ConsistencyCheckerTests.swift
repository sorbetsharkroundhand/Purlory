@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// 일관성 경고 회귀 테스트 (M7) — 전부 결정적, 모델 없음.
final class ConsistencyCheckerTests: XCTestCase {

    private let seoyeon = CharacterCard(name: "서연")
    private let minjun = CharacterCard(name: "민준")
    private var cards: [CharacterCard] { [seoyeon, minjun] }

    /// 씬 2개 — 1장에서 민준 사망 델타, 2장은 이후 본문.
    private func makeSnapshot(
        utterances: [Utterance], deltas: Bool = true
    ) -> KnowledgeSnapshot {
        let body = """
            # 1장
            사고가 있었다. 민준은 돌아오지 못했다. 서연은 울었다.
            # 2장
            시간이 흘렀다. 거리는 그대로였다. 사람들이 오갔다.
            """
        let outline = DocumentOutline.parse(body)
        let hashes = outline.scenes.map(\.contentHash)
        var events: [String: [StoryEvent]] = [:]
        if deltas {
            events[hashes[0]] = [
                StoryEvent(
                    sceneHash: hashes[0], participants: [minjun.id],
                    summary: "민준이 사고로 세상을 떠났다", importance: 5,
                    deltas: [
                        StateDelta(
                            characterID: minjun.id, field: .vitality,
                            value: "사망", sceneHash: hashes[0])
                    ])
            ]
        }
        return KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            events: events, utterances: utterances)
    }

    /// 2장 안 위치 — 1장(사망 씬)이 끝난 뒤.
    private func chapter2Position(in snapshot: KnowledgeSnapshot) -> Int {
        snapshot.outline.scenes[1].utf16Range.lowerBound + 5
    }

    // MARK: - 죽은 인물 발화

    func test사망_이후_발화는_경고() {
        let snapshot0 = makeSnapshot(utterances: [])
        let position = chapter2Position(in: snapshot0)
        let snapshot = makeSnapshot(utterances: [
            Utterance(
                speakerID: minjun.id, text: "저 왔어요.", utf16Start: position,
                listenerID: seoyeon.id, politeness: .honorific)
        ])
        let warnings = ConsistencyChecker.check(snapshot: snapshot, characters: cards)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.kind, .deadSpeaker)
        XCTAssertEqual(warnings.first?.characterID, minjun.id)
        XCTAssertTrue(warnings.first?.message.contains("민준") ?? false)
    }

    func test사망_이전_발화는_정상() {
        // 죽기 전(1장 안) 발화 — 시점 fold가 아직 사망을 모른다.
        let snapshot = makeSnapshot(utterances: [
            Utterance(
                speakerID: minjun.id, text: "다녀올게.", utf16Start: 10,
                listenerID: seoyeon.id, politeness: .plain)
        ])
        XCTAssertTrue(ConsistencyChecker.check(snapshot: snapshot, characters: cards).isEmpty)
    }

    func test같은_인물_반복_경고는_한_번만() {
        let snapshot0 = makeSnapshot(utterances: [])
        let position = chapter2Position(in: snapshot0)
        let snapshot = makeSnapshot(utterances: [
            Utterance(speakerID: minjun.id, text: "하나.", utf16Start: position, listenerID: nil, politeness: nil),
            Utterance(speakerID: minjun.id, text: "둘이다.", utf16Start: position + 10, listenerID: nil, politeness: nil),
        ])
        XCTAssertEqual(ConsistencyChecker.check(snapshot: snapshot, characters: cards).count, 1)
    }

    func test살아있는_인물은_경고_없음() {
        let snapshot0 = makeSnapshot(utterances: [])
        let position = chapter2Position(in: snapshot0)
        let snapshot = makeSnapshot(utterances: [
            Utterance(
                speakerID: seoyeon.id, text: "잘 지냈어.", utf16Start: position,
                listenerID: nil, politeness: .plain)
        ])
        XCTAssertTrue(ConsistencyChecker.check(snapshot: snapshot, characters: cards).isEmpty)
    }

    // MARK: - 존대 붕괴

    private func utterance(
        _ speaker: CharacterCard, to listener: CharacterCard,
        _ politeness: Politeness, at position: Int
    ) -> Utterance {
        Utterance(
            speakerID: speaker.id, text: "대사", utf16Start: position,
            listenerID: listener.id, politeness: politeness)
    }

    func test확립된_존대가_무너지면_경고() {
        let snapshot = makeSnapshot(
            utterances: [
                utterance(minjun, to: seoyeon, .honorific, at: 10),
                utterance(minjun, to: seoyeon, .honorific, at: 20),
                utterance(minjun, to: seoyeon, .honorific, at: 30),
                utterance(minjun, to: seoyeon, .plain, at: 40),
            ], deltas: false)
        let warnings = ConsistencyChecker.check(snapshot: snapshot, characters: cards)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.kind, .honorificBreak)
        XCTAssertEqual(warnings.first?.utf16Position, 40)
    }

    func test두_번_일관으론_확립_아님() {
        // 3회 미만은 우연일 수 있다 — 침묵 (품질 > 적극성).
        let snapshot = makeSnapshot(
            utterances: [
                utterance(minjun, to: seoyeon, .honorific, at: 10),
                utterance(minjun, to: seoyeon, .honorific, at: 20),
                utterance(minjun, to: seoyeon, .plain, at: 30),
            ], deltas: false)
        XCTAssertTrue(ConsistencyChecker.check(snapshot: snapshot, characters: cards).isEmpty)
    }

    func test전환_후는_새_관계로_재경고_없음() {
        // 반말 트기 후 반말 유지 — 쌍당 경고는 첫 전환 한 번뿐.
        let snapshot = makeSnapshot(
            utterances: [
                utterance(minjun, to: seoyeon, .honorific, at: 10),
                utterance(minjun, to: seoyeon, .honorific, at: 20),
                utterance(minjun, to: seoyeon, .honorific, at: 30),
                utterance(minjun, to: seoyeon, .plain, at: 40),
                utterance(minjun, to: seoyeon, .plain, at: 50),
                utterance(minjun, to: seoyeon, .honorific, at: 60),
            ], deltas: false)
        XCTAssertEqual(ConsistencyChecker.check(snapshot: snapshot, characters: cards).count, 1)
    }

    func test방향이_다르면_별개_쌍() {
        // 서연→민준 반말 확립은 민준→서연 존댓말과 무관.
        let snapshot = makeSnapshot(
            utterances: [
                utterance(seoyeon, to: minjun, .plain, at: 10),
                utterance(seoyeon, to: minjun, .plain, at: 20),
                utterance(seoyeon, to: minjun, .plain, at: 30),
                utterance(minjun, to: seoyeon, .honorific, at: 40),
            ], deltas: false)
        XCTAssertTrue(ConsistencyChecker.check(snapshot: snapshot, characters: cards).isEmpty)
    }

    func test사망_판정_규칙() {
        XCTAssertTrue(ConsistencyChecker.isDead("사망"))
        XCTAssertTrue(ConsistencyChecker.isDead("사고로 사망"))
        XCTAssertTrue(ConsistencyChecker.isDead("죽음"))
        XCTAssertFalse(ConsistencyChecker.isDead("죽을 뻔함"))
        XCTAssertFalse(ConsistencyChecker.isDead("생존"))
        XCTAssertFalse(ConsistencyChecker.isDead("부상"))
    }
}
