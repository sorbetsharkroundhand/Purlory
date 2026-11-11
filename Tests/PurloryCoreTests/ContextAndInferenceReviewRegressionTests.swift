import Combine
import Foundation
@testable import PurloryCore
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryIntelligence
@testable import PurloryWorkspaceUI
import XCTest

final class ContextAndInferenceReviewRegressionTests: XCTestCase {

    // MARK: - F08: Duplicate scene contentHash in ContextAssembler

    func testF08_duplicateSceneHashesDoNotTrapInNormalAndFlashbackAssembly() {
        let repeatedScene = "# 장면\n같은 내용이다. 비가 내리고 창문이 흔들렸다.\n"
        let thirdScene = "# 결말\n마지막 장면에 이르렀다. 날이 밝았다.\n"
        let body = repeatedScene + "\n" + repeatedScene + "\n" + thirdScene
        let outline = DocumentOutline.parse(body)
        XCTAssertEqual(outline.scenes.count, 3)
        XCTAssertEqual(outline.scenes[0].contentHash, outline.scenes[1].contentHash)

        let dupHash = outline.scenes[0].contentHash
        let lastHash = outline.scenes[2].contentHash
        let husband = CharacterCard(name: "남편")

        let summaries: [String: String] = [
            dupHash: "비가 내리는 같은 장면 요약.",
            lastHash: "날이 밝은 결말 요약.",
        ]
        let normalSceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            dupHash: .init(
                contentHash: dupHash, headingPath: ["장면"],
                summary: "비가 내리는 같은 장면 요약.", title: "비 오는 창가"),
            lastHash: .init(
                contentHash: lastHash, headingPath: ["결말"],
                summary: "날이 밝은 결말 요약.", title: "새벽"),
        ]
        let flashbackSceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            dupHash: .init(
                contentHash: dupHash, headingPath: ["장면"],
                summary: "비가 내리는 같은 장면 요약.", title: "비 오는 창가"),
            lastHash: .init(
                contentHash: lastHash, headingPath: ["결말"],
                summary: "날이 밝은 결말 요약.", title: "새벽", narrativeType: "회상"),
        ]
        let segments: [String: SceneSegmentation] = [
            lastHash: SceneSegmentation(segments: [
                NarrativeSegment(
                    sceneHash: lastHash, localStart: 0, localEnd: 200,
                    startQuote: "마지막 장면에 이르렀다",
                    layer: .flashback, depth: 1, subjectCharacter: "남편")
            ])
        ]
        let normalSnapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: summaries,
            sceneSummaries: normalSceneSummaries,
            characters: [husband]
        )
        let flashbackSnapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: summaries,
            sceneSummaries: flashbackSceneSummaries,
            segments: segments,
            characters: [husband],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .sceneType, key: lastHash, value: "회상")
            ])
        )
        let document = DocumentContext(
            title: "반복 장면 시험", kind: .novel, characters: [husband])

        // 1) Normal discourse order assembly with duplicate prior scene hashes
        let normalCursorStart = outline.scenes[2].utf16Range.lowerBound
        let normalResult = ContextAssembler.assembleWithReport(
            prefix: "마지막 장면에 이르렀다.",
            document: document,
            knowledge: normalSnapshot,
            prefixStartUTF16: normalCursorStart,
            style: .continuation
        )
        guard case .continuation(let normalText) = normalResult.prompt else {
            return XCTFail("Expected continuation prompt")
        }
        XCTAssertTrue(normalText.contains("비가 내리는 같은 장면 요약."))

        // 2) Flashback (writingInPast / chronologicalSceneOrder) assembly with duplicate hashes
        var flashbackReport: [ContextReport.Item] = []
        let flashbackPos = flashbackSnapshot.position(at: normalCursorStart + 5)
        XCTAssertEqual(flashbackPos.chrono, .before)
        let pinnedControls = ContextAssembler.Controls(pins: ["scene|\(dupHash)"])
        let block = ContextAssembler.knowledgeText(
            flashbackSnapshot,
            before: normalCursorStart,
            cursor: normalCursorStart + 5,
            window: "마지막 장면에 이르렀다.",
            position: flashbackPos,
            controls: pinnedControls,
            report: &flashbackReport
        )
        XCTAssertTrue(block.contains("비가 내리는 같은 장면 요약."))
        let jumpLocations = flashbackReport
            .filter { $0.kind == .sceneSummary }
            .compactMap(\.jumpUTF16)
        XCTAssertEqual(
            jumpLocations,
            [outline.scenes[0].utf16Range.lowerBound, outline.scenes[1].utf16Range.lowerBound]
        )
    }

    // MARK: - F09: Cursor-bounded context assembly excludes future knowledge

    func testF09_workSummaryExcludedWhenFutureScenesExistUnlessPinned() {
        let body = """
            # 1장
            서연은 아침 일찍 도서관을 찾았다.

            # 2장
            민준이 서연에게 오래된 편지를 건넸다.

            # 3장
            반전: 편지를 쓴 진범은 집사였다.
            """
        let outline = DocumentOutline.parse(body)
        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash
        let h3 = outline.scenes[2].contentHash
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: [
                h1: "서연이 도서관을 찾았다.",
                h2: "민준이 편지를 건넸다.",
                h3: "진범이 집사임이 밝혀졌다.",
            ],
            workSummary: "전체 줄거리: 반전으로 진범이 집사임이 밝혀진다."
        )
        let document = DocumentContext(title: "추리 소설", kind: .novel)

        // Cursor in Scene 2 (Scene 3 is in the future) -> workSummary must be excluded.
        let midNovelStart = outline.scenes[1].utf16Range.lowerBound
        let prefix = "민준이 서연에게 "
        let unpinned = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: midNovelStart,
            style: .continuation
        )
        guard case .continuation(let unpinnedText) = unpinned.prompt else {
            return XCTFail("Expected continuation prompt")
        }
        XCTAssertFalse(unpinnedText.contains("진범이 집사"))
        XCTAssertFalse(unpinned.report.items.contains { $0.kind == .workSummary })

        // Explicit User Canon pin on "work" -> allowed even before end of work.
        let pinnedSnapshot = KnowledgeSnapshot(
            entryID: snapshot.entryID,
            outline: outline,
            summariesByHash: snapshot.summariesByHash,
            workSummary: snapshot.workSummary,
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .contextPin, key: "work", value: "고정")
            ])
        )
        let pinned = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: pinnedSnapshot,
            prefixStartUTF16: midNovelStart,
            style: .continuation
        )
        guard case .continuation(let pinnedText) = pinned.prompt else {
            return XCTFail("Expected continuation prompt")
        }
        XCTAssertTrue(pinnedText.contains("지난 줄거리: 전체 줄거리"))

        // Cursor at the very end of the manuscript -> workSummary is allowed.
        let endScene = outline.scenes[2]
        let endPrefix = "반전: 편지를 쓴 진범은 집사였다.\n"
        let endStart = endScene.utf16Range.upperBound - endPrefix.utf16.count
        let atEnd = ContextAssembler.assembleWithReport(
            prefix: endPrefix,
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: endStart,
            style: .continuation
        )
        XCTAssertTrue(atEnd.report.items.contains { $0.kind == .workSummary })
    }

    func testF09_flowEventsFromFutureScenesAreExcluded() {
        let body = """
            # 1장
            남편이 어린 시절의 골목을 떠올렸다.

            # 2장
            남편이 옛집 우물가를 회상했다.

            # 3장
            미래의 폭로: 남편이 비밀 금고를 열었다.
            """
        let outline = DocumentOutline.parse(body)
        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash
        let h3 = outline.scenes[2].contentHash
        let husband = CharacterCard(name: "남편")

        let e1 = StoryEvent(
            sceneHash: h1, participants: [husband.id],
            summary: "어린 시절 골목을 걸었다", importance: 3,
            quote: "어린 시절의 골목을 떠올렸다")
        let e2 = StoryEvent(
            sceneHash: h2, participants: [husband.id],
            summary: "우물가에서 물을 길었다", importance: 3,
            quote: "옛집 우물가를 회상했다")
        let futureEvent = StoryEvent(
            sceneHash: h3, participants: [husband.id],
            summary: "미래 폭로: 비밀 금고를 열었다", importance: 5,
            quote: "비밀 금고를 열었다")

        let segments: [String: SceneSegmentation] = [
            h2: SceneSegmentation(segments: [
                NarrativeSegment(
                    sceneHash: h2, localStart: 0, localEnd: 200,
                    startQuote: "남편이 옛집 우물가를 회상했다",
                    layer: .flashback, depth: 1, subjectCharacter: "남편")
            ])
        ]
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: [h1: "1장 요약"],
            events: [h1: [e1], h2: [e2], h3: [futureEvent]],
            segments: segments,
            characters: [husband],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .sceneType, key: h1, value: "회상"),
                NarrativeOverride(kind: .sceneType, key: h2, value: "회상"),
            ])
        )
        let document = DocumentContext(
            title: "회상 소설", kind: .novel, characters: [husband])

        let scene2Start = outline.scenes[1].utf16Range.lowerBound
        let prefix = "남편이 옛집 우물가를 회상했다."
        let result = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: scene2Start,
            style: .continuation
        )
        guard case .continuation(let text) = result.prompt else {
            return XCTFail("Expected continuation prompt")
        }
        XCTAssertTrue(text.contains("어린 시절 골목을 걸었다"))
        XCTAssertFalse(
            text.contains("비밀 금고를 열었다"),
            "Future scene flowEvent must not leak before cursor"
        )
    }

    func testF09_sceneCohabitantsAndCurrentSceneExcludeUnanchoredMidSceneItems() {
        let body = """
            # 1장
            서연은 조용한 거실에서 차를 마셨다.
            한참 뒤 다락방에서 도윤이 갑자기 나타났다.
            """
        let outline = DocumentOutline.parse(body)
        let h1 = outline.scenes[0].contentHash
        let seoyeon = CharacterCard(name: "서연")
        let doyoon = CharacterCard(name: "도윤")

        let lateEvent = StoryEvent(
            sceneHash: h1,
            participants: [doyoon.id],
            summary: "도윤이 다락방에서 나타났다",
            importance: 4,
            quote: "다락방에서 도윤이 갑자기 나타났다"
        )
        let sceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [
            h1: .init(
                contentHash: h1,
                headingPath: ["1장"],
                summary: "서연이 차를 마신 뒤 다락방에서 도윤이 나타난다.",
                title: "다락방의 기습",
                narrativeType: "회상",
                pov: "도윤",
                location: "다락방"
            )
        ]
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: [h1: "1장 요약"],
            events: [h1: [lateEvent]],
            sceneSummaries: sceneSummaries,
            characters: [seoyeon, doyoon]
        )
        let document = DocumentContext(
            title: "밀실 소설", kind: .novel, characters: [seoyeon, doyoon])

        // Mid-scene cursor right after the first sentence: Doyoon and the attic twist have not appeared yet.
        let prefix = "# 1장\n서연은 조용한 거실에서 차를 마셨다."
        let midCursor = prefix.utf16.count
        XCTAssertLessThan(midCursor, outline.scenes[0].utf16Range.upperBound)

        XCTAssertEqual(
            snapshot.sceneCohabitants(at: midCursor),
            [],
            "Mid-scene cursor must not leak characters whose event quote is after the cursor"
        )
        XCTAssertEqual(
            snapshot.sceneCohabitants(at: outline.scenes[0].utf16Range.upperBound),
            [doyoon.id],
            "At the end of the scene, the character from the scene event is included"
        )

        let assembledMid = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: 0,
            style: .continuation
        )
        guard case .continuation(let midText) = assembledMid.prompt else {
            return XCTFail("Expected continuation prompt")
        }
        XCTAssertFalse(midText.contains("이 장면의 사람들: 도윤"))
        XCTAssertFalse(midText.contains("다락방"))
    }

    // MARK: - F26: Unicode / Emoji safe wordBoundaryTrimmed and rawSuffixTrimmed

    func testF26_wordBoundaryAndRawSuffixTrimmingPreserveEmojiAndHangulBoundaries() {
        let counterexample = "😀😀 a b"
        let trimmedCounterexample = ContextAssembler.wordBoundaryTrimmed(
            counterexample, keepingFraction: 0.8)
        XCTAssertEqual(trimmedCounterexample, "a b")
        XCTAssertFalse(trimmedCounterexample.contains("\u{FFFD}"))

        let richText = "첫째😀🎉🚀 둘째👩🏽‍💻 셋째🇰🇷 넷째한글 다섯째🌟 여섯째끝"
        for fraction in [0.8, 0.6, 0.4, 0.2] {
            let trimmed = ContextAssembler.wordBoundaryTrimmed(richText, keepingFraction: fraction)
            XCTAssertFalse(trimmed.contains("\u{FFFD}"), "Broken surrogate at fraction \(fraction)")
            XCTAssertTrue(richText.hasSuffix(trimmed))
            XCTAssertTrue(trimmed.hasSuffix("여섯째끝"))
        }

        let unbrokenEmoji = String(repeating: "😀🎉🚀👩🏽‍💻가나다", count: 20)
        let rawTrimmed = ContextAssembler.rawSuffixTrimmed(unbrokenEmoji)
        XCTAssertFalse(rawTrimmed.contains("\u{FFFD}"))
        XCTAssertTrue(unbrokenEmoji.hasSuffix(rawTrimmed))
        XCTAssertLessThan(rawTrimmed.count, unbrokenEmoji.count)
    }

    // MARK: - F27: prefixStartUTF16 advances forward when front-trimming window

    func testF27_frontTrimmingWindowAdvancesPrefixStartUTF16KeepingCursorInvariant() {
        let scene1 = "# 1장\n" + String(repeating: "앞장면 문장입니다. ", count: 30) + "\n"
        let scene2 = "# 2장\n" + String(repeating: "😀🎉현재장면 어절입니다. ", count: 30)
        let body = scene1 + scene2
        let outline = DocumentOutline.parse(body)
        XCTAssertEqual(outline.scenes.count, 2)

        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash
        let seoyeon = CharacterCard(name: "서연")
        let utteranceInScene2 = Utterance(
            speakerID: seoyeon.id,
            text: "여기야.",
            utf16Start: outline.scenes[1].utf16Range.lowerBound + 4,
            listenerID: nil,
            politeness: .plain
        )
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(),
            outline: outline,
            summariesByHash: [h1: "1장 요약입니다.", h2: "2장 요약입니다."],
            utterances: [utteranceInScene2],
            characters: [seoyeon]
        )
        let document = DocumentContext(
            title: "위치 불변 시험", kind: .novel, characters: [seoyeon])

        let prefixStart = 100
        let nsBody = body as NSString
        let prefix = nsBody.substring(from: prefixStart)
        let expectedCursor = prefixStart + prefix.utf16.count
        XCTAssertEqual(expectedCursor, nsBody.length)

        let counter = TokenCounter { $0.utf16.count }
        let budget = 220
        let outcome = ContextAssembler.assembleWithReport(
            prefix: prefix,
            document: document,
            knowledge: snapshot,
            prefixStartUTF16: prefixStart,
            style: .continuation,
            tokenCounter: counter,
            tokenBudget: budget
        )

        let retainedRange = try! XCTUnwrap(outcome.report.rawUTF16Range)
        XCTAssertEqual(
            retainedRange.upperBound,
            expectedCursor,
            "Cursor UTF-16 position must remain invariant across front-trimming steps"
        )
        XCTAssertGreaterThan(
            retainedRange.lowerBound,
            prefixStart,
            "Trimming from the front of prefix must advance prefixStartUTF16 forward"
        )
    }

    // MARK: - F30: BackgroundIndexer.runPass reports blocked state on initial gate check

    @MainActor
    func testF30_manualPassBlockedAtEntryReportsBlockedInsteadOfCompletedNoChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-f30-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EntryStore(directory: root, autosaveDelay: .seconds(3600))
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        defer { indexer.prepareForProjectTransition() }
        indexer.attachLegacy(store: store)

        _ = store.newEntry(kind: .novel)
        store.updateActiveBody("# 1장\n충분히 긴 소설 본문입니다. 열이나 저전력 상태에서 수동 읽기가 처음부터 차단될 때를 검증합니다.")

        // Inject low-power mode gate block for deep manual pass
        indexer._testGateStateProvider = { (.nominal, true) }

        let blockedExpectation = expectation(description: "Manual pass transitions to .blocked")
        var didFulfillBlocked = false
        var observedPhases: [BackgroundIndexer.PassPhase] = []
        let cancellable = indexer.manualPhaseChanges.sink { phase in
            observedPhases.append(phase)
            if case .blocked = phase, !didFulfillBlocked {
                didFulfillBlocked = true
                blockedExpectation.fulfill()
            }
        }
        defer { cancellable.cancel() }

        indexer.requestPass()
        await fulfillment(of: [blockedExpectation], timeout: 2.0)
        while indexer.isIndexing {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .blocked(let reason) = indexer.manualPhase else {
            return XCTFail("Expected .blocked phase, got \(indexer.manualPhase)")
        }
        XCTAssertTrue(reason.contains("저전력"), "Unexpected block reason: \(reason)")
        XCTAssertFalse(observedPhases.contains(.completedNoChange))
    }

    // MARK: - F33: .instruct mode token budget enforcement

    func testF33_instructModeEnforcesTokenBudgetAndTrimsUnbrokenStrings() async throws {
        let counter = TokenCounter(
            { $0.utf16.count },
            promptCost: { prompt in
                switch prompt {
                case .continuation(let text):
                    return text.utf16.count
                case .instruct(let system, let user):
                    return system.utf16.count + user.utf16.count + 40
                }
            }
        )

        let unbrokenPrefix = String(repeating: "공백없는긴한국어문자열", count: 80)
        let document = DocumentContext(
            title: "지시형 예산 시험",
            kind: .novel,
            characters: [CharacterCard(name: "서연", note: "차분한 성격")]
        )
        let budget = 350

        let coreOutcome = ContextAssembler.assembleCore(
            prefix: unbrokenPrefix,
            document: document,
            knowledge: nil,
            prefixStartUTF16: 0,
            style: .instruct,
            knobs: .defaults,
            counter: counter,
            tokenBudget: budget
        )
        XCTAssertNotNil(
            coreOutcome.totalTokens,
            "assembleCore must report totalTokens in .instruct mode too"
        )
        XCTAssertGreaterThan(coreOutcome.totalTokens ?? 0, budget)

        let assembled = ContextAssembler.assembleWithReport(
            prefix: unbrokenPrefix,
            document: document,
            knowledge: nil,
            prefixStartUTF16: 0,
            style: .instruct,
            tokenCounter: counter,
            tokenBudget: budget
        )
        guard case .instruct(let system, let user) = assembled.prompt else {
            return XCTFail("Expected .instruct prompt")
        }
        XCTAssertTrue(system.contains(ContextAssembler.instructSystem))
        XCTAssertLessThanOrEqual(
            counter.count(assembled.prompt),
            budget,
            "assembleWithReport must trim .instruct prompt (including unbroken input) within budget"
        )
        XCTAssertFalse(user.contains("\u{FFFD}"))

        // CompletionEngine in .instruct mode must return .empty without invoking backend when over maxPromptTokens.
        let engine = CompletionEngine(tokenCounter: counter)
        let overBudgetPrompt = AssembledPrompt.instruct(
            system: ContextAssembler.instructSystem,
            user: ContextAssembler.instructUser(prefix: unbrokenPrefix)
        )
        let parameters = CompletionParameters(
            modelID: "unregistered/model",
            promptStyle: .instruct,
            maxPromptTokens: 50
        )
        let completion = try await engine.complete(
            prompt: overBudgetPrompt,
            parameters: parameters
        )
        XCTAssertEqual(completion.text, "")
        XCTAssertEqual(completion.promptTokenCount, 0)
    }
}
