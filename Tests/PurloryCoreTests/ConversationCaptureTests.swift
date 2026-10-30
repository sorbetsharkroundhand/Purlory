@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 대화 캡처 회귀 테스트 (요구사항 §18–§21).
/// 실시간 감지기는 **결정적·LLM 금지 경로**라 키 입력 예산 안에서 정확해야 한다:
/// 문단 규칙(짧은 서술 허용·빈 줄 2연속·긴 서술 차단)과 기록의 재앵커를 고정한다.
final class ConversationCaptureTests: XCTestCase {

    private let seoyeon = UUID()
    private let minjun = UUID()

    /// 발화 3 + 짧은 서술 끼움 — 감지기가 받아야 하는 정형 대화.
    private var dialogueBody: String {
        """
        서두 서술이다.
        "안녕하세요." 서연이 인사했다.

        "어서 와요." 민준이 대답했다.
        민준이 의자를 권했다.
        "고마워. 앉을게."
        """
    }

    @MainActor
    private func makeNovelController(
        onRecord: ((RecordedConversation) -> Void)?
    ) -> CompletionController {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let completion = CompletionController(settings: settings)
        completion.documentContextProvider = {
            DocumentContext(title: "Novel", kind: .novel, entryID: UUID())
        }
        completion.onRecordConversation = onRecord
        return completion
    }

    @MainActor
    private func typeDialogue(into completion: CompletionController) {
        completion.noteEdit(
            prefix: dialogueBody,
            caretLocation: (dialogueBody as NSString).length,
            isComposing: false,
            caretAtParagraphEnd: true)
    }

    // MARK: - 블록 감지

    func test발화와_짧은서술끼움을_한_대화로_묶는다() throws {
        let body = dialogueBody as NSString
        let block = try XCTUnwrap(ConversationDetector.blockEnding(at: body.length, in: body))

        XCTAssertEqual(block.utteranceCount, 3)
        XCTAssertEqual(block.firstLine, "안녕하세요.")   // 따옴표 제외
        XCTAssertEqual(block.lastLine, "고마워. 앉을게.")
        XCTAssertEqual(
            block.utf16Range.lowerBound,
            body.range(of: "\"안녕하세요.").location)      // 첫 발화 문단에서 시작
        XCTAssertTrue(block.utf16Range.upperBound <= body.length)
        XCTAssertFalse(block.contentHash.isEmpty)
    }

    func test발화_하나면_대화가_아니다() {
        // 한 마디로는 "대화"가 아니다 — 품질 > 적극성.
        let body = "혼잣말이다.\n\"안녕.\"\n" as NSString
        XCTAssertNil(ConversationDetector.blockEnding(at: body.length, in: body))
    }

    func test빈줄_둘이면_끝난_대화다() {
        let body = "\"안녕.\" 서연이 말했다.\n\n\n\"그래.\" 민준이 답했다.\n" as NSString
        // 커서 아래(=문서 끝)에 빈 줄 2연속 — 대화가 끝난 지 오래됐다.
        XCTAssertNil(ConversationDetector.blockEnding(at: body.length, in: body))
    }

    func test긴_서술은_장면_전환으로_대화를_끊는다() throws {
        let longNarration = String(repeating: "서술이 이어진다.", count: 25) // >200자
        let body = "\"아까 그 얘기인데.\" 서연이 말했다.\n\(longNarration)\n\"응, 알아.\" 민준이 답했다.\n\"계속해 봐.\"\n"
            as NSString

        let block = try XCTUnwrap(ConversationDetector.blockEnding(at: body.length, in: body))

        XCTAssertEqual(block.utteranceCount, 2)
        XCTAssertEqual(block.firstLine, "응, 알아.") // 긴 서술 위쪽은 다른 장면
        XCTAssertNotEqual(block.firstLine, "아까 그 얘기인데.")
    }

    // MARK: - 기록 생성

    func test겹치는_발화의_화자들을_참여자로_모은다() throws {
        let body = dialogueBody as NSString
        let block = try XCTUnwrap(ConversationDetector.blockEnding(at: body.length, in: body))
        let utterances = [
            Utterance(
                speakerID: seoyeon, text: "안녕하세요.", utf16Start: block.utf16Range.lowerBound + 1,
                listenerID: minjun, politeness: nil),
            Utterance(
                speakerID: minjun, text: "어서 와요.",
                utf16Start: block.utf16Range.upperBound + 10,  // 블록 밖 — 제외 대상
                listenerID: nil, politeness: nil),
        ]

        let record = ConversationDetector.record(from: block, utterances: utterances)

        XCTAssertEqual(Set(record.participants), [seoyeon, minjun]) // 청자(minjun)도 포함
        XCTAssertEqual(record.firstLine, block.firstLine)
        XCTAssertEqual(record.contentHash, block.contentHash)
    }

    // MARK: - 재앵커 (PLAN §6.6)

    private func makeRecord(in body: NSString) throws -> RecordedConversation {
        let block = try XCTUnwrap(ConversationDetector.blockEnding(at: body.length, in: body))
        return RecordedConversation(
            utf16Start: block.utf16Range.lowerBound,
            utf16End: block.utf16Range.upperBound,
            firstLine: block.firstLine, lastLine: block.lastLine,
            contentHash: block.contentHash)
    }

    func test원문이_안_바뀌었으면_그대로_유지한다() throws {
        let body = dialogueBody as NSString
        let record = try makeRecord(in: body)

        XCTAssertEqual(ConversationDetector.reanchor(record, in: body), record)
    }

    func test앞에_문단이_추가되면_따라_밀린다() throws {
        let original = dialogueBody as NSString
        let record = try makeRecord(in: original)

        let prefix = "새로 추가된 머리말 문단이다.\n\n"
        let edited = (prefix + dialogueBody) as NSString
        let reanchored = try XCTUnwrap(ConversationDetector.reanchor(record, in: edited))

        let shift = (prefix as NSString).length
        XCTAssertEqual(reanchored.utf16Start, record.utf16Start + shift)
        XCTAssertEqual(reanchored.utf16End, record.utf16End + shift)
    }

    func test대화가_사라졌으면_포기를_한다() throws {
        // 엉뚱한 반복 대사에 조용히 잇는 것보다 nil이 낫다.
        let record = try makeRecord(in: dialogueBody as NSString)
        let emptied = "전혀 다른 내용의 원고다." as NSString

        XCTAssertNil(ConversationDetector.reanchor(record, in: emptied))
    }

    // MARK: - Controller persistence availability

    @MainActor
    func test기록핸들러가없으면소설대화제안을예약하거나승인하지않는다() async throws {
        let completion = makeNovelController(onRecord: nil)

        typeDialogue(into: completion)
        try await Task.sleep(for: CompletionController.conversationIdle + .milliseconds(100))

        XCTAssertFalse(completion.hasConversationSuggestion)
        XCTAssertFalse(completion.acceptConversationSuggestion())
    }

    @MainActor
    func test기록핸들러를제거하면기존대화제안도즉시비활성화된다() async throws {
        var recorded: [RecordedConversation] = []
        let completion = makeNovelController { recorded.append($0) }
        let published = expectation(description: "Conversation suggestion published")
        completion.conversationSuggestionDidChange = { block in
            if block != nil { published.fulfill() }
        }
        typeDialogue(into: completion)
        await fulfillment(of: [published], timeout: 5)
        XCTAssertTrue(
            completion.hasConversationSuggestion,
            "대화 캡처는 자동완성 마스터 스위치와 독립적이어야 한다")

        completion.onRecordConversation = nil

        XCTAssertFalse(completion.hasConversationSuggestion)
        XCTAssertFalse(completion.acceptConversationSuggestion())
        XCTAssertTrue(recorded.isEmpty)
    }

    @MainActor
    func test기록핸들러가있으면자동완성이꺼져도대화를승인해기록한다() async throws {
        var recorded: [RecordedConversation] = []
        let completion = makeNovelController { recorded.append($0) }
        let published = expectation(description: "Conversation suggestion published")
        completion.conversationSuggestionDidChange = { block in
            if block != nil { published.fulfill() }
        }

        typeDialogue(into: completion)
        await fulfillment(of: [published], timeout: 5)

        XCTAssertTrue(completion.acceptConversationSuggestion())
        XCTAssertEqual(recorded.count, 1)
    }
}
