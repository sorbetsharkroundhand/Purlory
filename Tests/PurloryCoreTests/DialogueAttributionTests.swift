@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// 대화 귀속·존대 매트릭스·대화 모드 회귀 테스트 (M6, PLAN §6.4·§7·§10).
/// 전부 결정적 로직이라 모델 없이 돈다.
final class DialogueAttributionTests: XCTestCase {

    private let seoyeon = CharacterCard(name: "서연", aliases: "연이")
    private let minjun = CharacterCard(name: "민준")
    private var cards: [CharacterCard] { [seoyeon, minjun] }

    // MARK: - 존대 판정 (닫힌 종결어미 규칙)

    func test존댓말_판정() {
        XCTAssertEqual(DialogueAttribution.politeness(of: "알겠습니다."), .honorific)
        XCTAssertEqual(DialogueAttribution.politeness(of: "정말 괜찮으세요?"), .honorific)
        XCTAssertEqual(DialogueAttribution.politeness(of: "그렇게 하시죠."), .honorific)
        XCTAssertEqual(DialogueAttribution.politeness(of: "어디 가요"), .honorific)
    }

    func test반말_판정() {
        XCTAssertEqual(DialogueAttribution.politeness(of: "알겠어."), .plain)
        XCTAssertEqual(DialogueAttribution.politeness(of: "너 어디 가니?"), .plain)
        XCTAssertEqual(DialogueAttribution.politeness(of: "그건 내가 할게."), .plain)
        XCTAssertEqual(DialogueAttribution.politeness(of: "빨리 와, 늦었잖아."), .plain)
        XCTAssertEqual(DialogueAttribution.politeness(of: "나는 모른다."), .plain)
    }

    func test판정_불가는_nil() {
        // 명사 종결·판정 밖 어미 — 섣부른 신호보다 침묵 (CLAUDE.md §1-2).
        XCTAssertNil(DialogueAttribution.politeness(of: "глупость"))
        XCTAssertNil(DialogueAttribution.politeness(of: "설마…"))
    }

    func test혼재_발화는_nil() {
        XCTAssertEqual(
            DialogueAttribution.politeness(of: "알겠습니다. 근데 왜 그랬어?"), nil)
    }

    // MARK: - 귀속: 인접 서술

    func test발화_동사_옆_이름이_화자() {
        let body = """
            "먼저 갈게." 서연이 말했다.
            """
        let result = DialogueAttribution.utterances(in: body, cards: cards)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.speakerID, seoyeon.id)
        XCTAssertEqual(result.first?.text, "먼저 갈게.")
        XCTAssertEqual(result.first?.politeness, .plain)
    }

    func test서술의_유일한_이름이_화자() {
        let body = """
            민준은 고개를 저었다. "그건 아닙니다."
            """
        let result = DialogueAttribution.utterances(in: body, cards: cards)
        XCTAssertEqual(result.first?.speakerID, minjun.id)
        XCTAssertEqual(result.first?.politeness, .honorific)
    }

    func test이름_둘이면_발화_동사에_가까운_쪽() {
        let body = """
            민준을 바라보던 서연이 말했다. "이제 그만하자."
            """
        let result = DialogueAttribution.utterances(in: body, cards: cards)
        XCTAssertEqual(result.first?.speakerID, seoyeon.id)
    }

    func test대사_안_이름은_귀속에_안_쓴다() {
        // 대사 속 "민준"은 호명이지 화자 단서가 아니다.
        let body = """
            "민준, 이리 와." 서연이 말했다.
            """
        let result = DialogueAttribution.utterances(in: body, cards: cards)
        XCTAssertEqual(result.first?.speakerID, seoyeon.id)
    }

    func test미등록_인물은_귀속_안_됨() {
        let body = """
            "안녕하세요." 지훈이 말했다.
            """
        XCTAssertTrue(DialogueAttribution.utterances(in: body, cards: cards).isEmpty)
    }

    // MARK: - 귀속: 교대 규칙 + 청자 방향

    private let conversation = """
        "먼저 가 있어." 서연이 말했다.
        "알겠습니다, 선배."
        서연은 잠시 망설였다.
        "정말 괜찮겠어?"
        "괜찮습니다." 민준이 대답했다.
        """

    func test교대_규칙으로_미귀속_채움() {
        let result = DialogueAttribution.utterances(in: conversation, cards: cards)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(
            result.map(\.speakerID),
            [seoyeon.id, minjun.id, seoyeon.id, minjun.id])
    }

    func test이인_런은_청자_방향이_붙는다() {
        let result = DialogueAttribution.utterances(in: conversation, cards: cards)
        XCTAssertEqual(result[0].listenerID, minjun.id)
        XCTAssertEqual(result[1].listenerID, seoyeon.id)
    }

    func test화자_하나뿐인_런은_교대_안_함() {
        let body = """
            "혼잣말이야."
            "누구한테 하는 말인지."
            서연이 중얼거렸다.
            """
        // 확정 화자가 1명 — 나머지를 추정으로 채우지 않는다 (품질 > 적극성).
        let result = DialogueAttribution.utterances(in: body, cards: cards)
        XCTAssertTrue(result.allSatisfy { $0.speakerID == seoyeon.id })
    }

    // MARK: - 스냅샷 질의: 매트릭스·프로필·다음 화자

    private func makeSnapshot(cursorBody: String? = nil) -> KnowledgeSnapshot {
        let body = cursorBody ?? conversation
        return KnowledgeSnapshot(
            entryID: UUID(),
            outline: DocumentOutline.parse(body),
            summariesByHash: [:],
            utterances: DialogueAttribution.utterances(in: body, cards: cards))
    }

    func test존대_매트릭스_비대칭() {
        let snapshot = makeSnapshot()
        // 서연→민준 반말, 민준→서연 존댓말 — PLAN §6.4의 핵심 신호.
        XCTAssertEqual(
            snapshot.honorific(from: seoyeon.id, to: minjun.id, before: .max), .plain)
        XCTAssertEqual(
            snapshot.honorific(from: minjun.id, to: seoyeon.id, before: .max), .honorific)
    }

    func test말투_프로필과_예문() {
        let snapshot = makeSnapshot()
        let profile = snapshot.speechProfile(of: minjun.id, before: .max)
        XCTAssertEqual(profile?.defaultPoliteness, .honorific)
        XCTAssertEqual(profile?.examples.last, "괜찮습니다.")
    }

    func test다음_화자는_직전_발화의_청자() {
        let snapshot = makeSnapshot()
        let expected = snapshot.expectedSpeaker(before: .max)
        // 마지막 발화가 민준 → 다음은 서연.
        XCTAssertEqual(expected?.speakerID, seoyeon.id)
        XCTAssertEqual(expected?.addresseeID, minjun.id)
    }

    func test시점_차단_커서_이전_발화만() {
        let snapshot = makeSnapshot()
        // 커서가 문서 맨 앞 — 아무 발화도 안 보인다.
        XCTAssertNil(snapshot.expectedSpeaker(before: 0))
        XCTAssertNil(snapshot.honorific(from: seoyeon.id, to: minjun.id, before: 0))
    }

    // MARK: - 대화 모드 게이트 (조립기)

    func test열린_따옴표_감지() {
        XCTAssertTrue(ContextAssembler.isInsideUtterance("서연이 물었다. \"그럼 이제"))
        XCTAssertTrue(ContextAssembler.isInsideUtterance("민준이 입을 열었다. “저는"))
        XCTAssertFalse(ContextAssembler.isInsideUtterance("\"끝난 대사야.\" 서연이 말했다."))
        XCTAssertFalse(ContextAssembler.isInsideUtterance("따옴표 없는 서술."))
        // 앞 문단의 짝 안 맞는 따옴표는 무시 — 마지막 문단만 본다.
        XCTAssertFalse(ContextAssembler.isInsideUtterance("\"앞 문단 오탈자\n지금 문단은 서술."))
    }

    func test대화_블록_조립() {
        let snapshot = makeSnapshot()
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: cards)
        let cursor = (conversation as NSString).length
        let block = ContextAssembler.dialogueText(
            snapshot, document: document, cursor: cursor)
        XCTAssertTrue(block.contains("다음 발화: 서연"), block)
        XCTAssertTrue(block.contains("민준에게 반말"), block)
        XCTAssertTrue(block.contains("말투 예"), block)
    }

    func test대화_블록_추정_불가면_빈_문자열() {
        let snapshot = makeSnapshot(cursorBody: "대사 없는 서술만 있는 본문.")
        let document = DocumentContext(
            title: "시험작", kind: .novel, characters: cards)
        XCTAssertEqual(
            ContextAssembler.dialogueText(snapshot, document: document, cursor: 100), "")
    }
}
