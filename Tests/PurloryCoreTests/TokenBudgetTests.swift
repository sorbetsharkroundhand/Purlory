@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 토큰 기반 컨텍스트 예산 (이슈 #43 / #65 Phase 4).
///
/// 계약:
/// - 카운터 미주입 시 결과는 기존 문자 상수 경로와 **바이트까지 동일**하다
///   (동작 불변 — 무측정 전환 금지의 안전망).
/// - 카운터 주입 시 전체 프롬프트가 예산 안으로 접히고, 삭감은 사건 → 카드
///   3→2장 → 요약 축소 순서를 따른다. A(고정 헤더)는 항상 산다.
/// - C 창 축소는 어절 경계를 존중한다 — 단어 중간 절단 금지.
final class TokenBudgetTests: XCTestCase {

    /// 결정적 의사 토크나이저 — 공백 분해 + 고정 패널티. 테스트 재현성용.
    private func makeCounter() -> TokenCounter {
        TokenCounter { text in
            text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count * 2 + 1
        }
    }

    private func makeDocument(cards: Int) -> DocumentContext {
        DocumentContext(
            title: "긴 작품",
            kind: .novel,
            genre: "판타지",
            characters: (0..<cards).map { index in
                CharacterCard(
                    name: "인물\(index)",
                    note: String(repeating: "성격\(index) ", count: 20))
            },
            entryID: UUID())
    }

    /// 큰 요약 지식을 가진 스냅샷 — B 블록이 예산을 누르게.
    private func makeKnowledge(entryID: UUID, scenes: Int = 40) -> KnowledgeSnapshot {
        let body = (0..<scenes).map { index in
            "# \(index)장\n어떤 일이 벌어졌다 그리고 또 벌어졌다 장면이 이어졌다 내용이 충분히 길어야 한다\n"
        }.joined()
        let outline = DocumentOutline.parse(body)
        var summaries: [String: String] = [:]
        for scene in outline.scenes {
            summaries[scene.contentHash] =
                "요약 — 어떤 사건이 있었고 인물들이 움직였으며 결과가 남았다"
        }
        return KnowledgeSnapshot(
            entryID: entryID, outline: outline, summariesByHash: summaries,
            characters: [], overrides: NarrativeOverrides([]))
    }

    // MARK: - 동작 불변 (nil 경로)

    func test카운터미주입은기존문자경로와동일하다() {
        let document = makeDocument(cards: 3)
        let knowledge = makeKnowledge(entryID: document.entryID!)
        let prefix = String(repeating: "본문 내용 ", count: 100)

        // 파라미터 없음 = 구버전 시그니처와 동일한 호출.
        let legacy = ContextAssembler.assembleWithReport(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: 0, style: .continuation)
        // 명시적 nil — 새 오버로드의 기본값과 같은 값.
        let explicit = ContextAssembler.assembleCore(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: 0, style: .continuation,
            knobs: .defaults, counter: nil)
        XCTAssertEqual(legacy.prompt, explicit.result.prompt)
        XCTAssertEqual(legacy.report.items.count, explicit.result.report.items.count)
        XCTAssertNil(explicit.totalTokens)
    }

    // MARK: - 토큰 예산

    func test카운터주입시프롬프트가토큰예산안으로접힌다() {
        let counter = makeCounter()
        let document = makeDocument(cards: 5)
        let knowledge = makeKnowledge(entryID: document.entryID!)
        let prefix = String(repeating: "어절 토큰 본문 ", count: 400)

        let budget = 900
        // 공개 계약 — assembleWithReport의 토큰 경로(사다리 + 최후 C 축소 수렴).
        let outcome = ContextAssembler.assembleWithReport(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: 0, style: .continuation,
            tokenCounter: counter, tokenBudget: budget)

        guard case .continuation(let text) = outcome.prompt else {
            return XCTFail("continuation 스타일이어야 한다")
        }
        XCTAssertLessThanOrEqual(
            counter.count(text), budget,
            "최후 C 축소까지 돌고도 예산을 넘었다")
        // A(고정 헤더)는 항상 산다 — 제목·종류 줄이 남아 있어야 한다.
        XCTAssertTrue(text.contains("종류: 소설"), "사다리가 A 헤더까지 깎았다")
    }

    func test삭감순서는흐름사건부터다() {
        let counter = makeCounter()
        let document = makeDocument(cards: 3)
        // 회상 집필 위치 — 흐름 사건이 주입되는 자리.
        let knowledge = makeKnowledge(entryID: document.entryID!, scenes: 10)
        let cursorSceneEnd =
            knowledge.outline.scenes[knowledge.outline.scenes.count - 1].utf16Range.upperBound
        let full = ContextAssembler.assembleCore(
            prefix: String(repeating: "본문 ", count: 50),
            document: document, knowledge: knowledge,
            prefixStartUTF16: cursorSceneEnd, style: .continuation,
            knobs: .defaults, counter: counter)
        let reduced = ContextAssembler.assembleCore(
            prefix: String(repeating: "본문 ", count: 50),
            document: document, knowledge: knowledge,
            prefixStartUTF16: cursorSceneEnd, style: .continuation,
            knobs: ContextAssembler.BudgetKnobs(includeFlowEvents: false), counter: counter)
        if case .continuation(let a) = full.result.prompt,
            case .continuation(let b) = reduced.result.prompt
        {
            XCTAssertGreaterThanOrEqual(
                counter.count(a), counter.count(b),
                "흐름 사건 제외가 토큰을 늘렸다 — 사다리 순서 규약 위반")
        } else {
            XCTFail("두 결과 모두 continuation이어야 한다")
        }
    }

    func testC창축소는어절경계에서자른다() {
        let text = "첫째 어절  둘째어절 셋째 넷째 다섯째 여섯째"
        let trimmed = ContextAssembler.wordBoundaryTrimmed(text, keepingFraction: 0.5)
        XCTAssertTrue(trimmed.hasSuffix("째") || trimmed.contains("어절"),
            "어절 중간에서 잘렸다: \(trimmed)")
        // 잘린 결과는 원문의 연속 부분 문자열(경계에서 시작)이다.
        XCTAssertTrue(text.contains(trimmed))
        XCTAssertLessThan(trimmed.count, text.count)
        // 과축소 방지 — 최소 한 어절은 남는다.
        let extreme = ContextAssembler.wordBoundaryTrimmed("가 나 다", keepingFraction: 0.01)
        XCTAssertFalse(extreme.isEmpty)
    }

    func test토큰카운터스냅샷은값객체로동작한다() {
        let box = CaptureBox()
        let counter = TokenCounter { text in
            box.store(text)
            return text.utf8.count
        }
        XCTAssertEqual(counter.count("abc"), 3)
        XCTAssertEqual(box.load(), "abc")
    }
}

/// @Sendable 클로저 캡처용 상자.
private final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func store(_ text: String) {
        lock.lock()
        value = text
        lock.unlock()
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
