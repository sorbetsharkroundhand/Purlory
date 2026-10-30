@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ConsistencyEvidenceTests: XCTestCase {
    private let minjun = CharacterCard(name: "민준")
    private let seoyeon = CharacterCard(name: "서연")
    private var cards: [CharacterCard] { [minjun, seoyeon] }
    private let death = "민준은 사망했다."
    private var body: String { "# 사건\n\(death)\n# 현재\n민준이 말했다. \"돌아왔어요.\"\n서연이 말했다. \"왔구나.\"" }

    private func snapshot(_ source: String, events: [(Int, String, String?)] = [],
                          types: [Int: String] = [:], segments: [String: SceneSegmentation] = [:]) -> KnowledgeSnapshot {
        let outline = DocumentOutline.parse(source)
        var records: [String: [StoryEvent]] = [:]
        for (scene, value, quote) in events {
            let hash = outline.scenes[scene].contentHash
            records[hash, default: []].append(.init(sceneHash: hash, participants: [minjun.id],
                summary: "상태", importance: 5, deltas: [.init(characterID: minjun.id, field: .vitality, value: value, sceneHash: hash)], quote: quote))
        }
        var summaries: [String: KnowledgeSidecar.SceneSummary] = [:]
        for (index, type) in types {
            summaries[outline.scenes[index].contentHash] = .init(contentHash: outline.scenes[index].contentHash, headingPath: [], summary: "장면", narrativeType: type)
        }
        return .init(entryID: UUID(), outline: outline, summariesByHash: [:], events: records,
            utterances: DialogueAttribution.utterances(in: source, cards: cards), sceneSummaries: summaries, segments: segments)
    }
    private func check(_ value: KnowledgeSnapshot, _ source: String, characters: [CharacterCard]? = nil) -> [ConsistencyWarning] {
        ConsistencyChecker.check(snapshot: value, characters: characters ?? cards, source: source)
    }

    func testDeadSpeakerCarriesBothLiteralOriginalsAndOneStableNavigationTarget() throws {
        let value = snapshot(body, events: [(0, "사망", death)])
        let warnings = check(value, body)
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warning.kind, .deadSpeaker)
        XCTAssertEqual(warning.evidence.map(\.quote), [death, "돌아왔어요."])
        let documentID = WritingDocumentID(rawValue: value.entryID)
        XCTAssertTrue(warning.evidence.allSatisfy { $0.documentID == documentID && $0.utf16Hint != nil })
        XCTAssertEqual(warning.sourcePosition(in: body, documentID: documentID), warning.utf16Position)
        XCTAssertNil(warning.sourcePosition(in: body, documentID: .init(rawValue: UUID())))
        XCTAssertNil(warning.sourcePosition(in: body.replacingOccurrences(of: death, with: "민준은 살아 있었다."), documentID: documentID))
        XCTAssertEqual(check(value, body).map(\.id), warnings.map(\.id))
    }

    func testNoOriginalOrAmbiguousOrChangedSourceCannotGrantWarnings() {
        XCTAssertTrue(check(snapshot(body, events: [(0, "사망", nil)]), body).isEmpty)
        XCTAssertTrue(check(snapshot(body, events: [(0, "사망", "없는 인용")]), body).isEmpty)
        let duplicate = body.replacingOccurrences(of: death, with: "\(death) \(death)")
        XCTAssertTrue(check(snapshot(duplicate, events: [(0, "사망", death)]), duplicate).isEmpty)
        XCTAssertTrue(check(snapshot(body, events: [(0, "사망", death)]), body + "추가").isEmpty)
        XCTAssertTrue(check(snapshot(body, events: [(0, "사망", death)]), body, characters: cards + [minjun]).isEmpty)
        let nfd = "가".decomposedStringWithCanonicalMapping
        let unicode = body.replacingOccurrences(of: death, with: nfd)
        XCTAssertTrue(check(snapshot(unicode, events: [(0, "사망", "가")]), unicode).isEmpty)
    }

    func testUnverifiedNewerOrCompetingLatestVitalityDoesNotResurrectOldDeath() {
        let source = "# 사건\n\(death)\n# 다음\n민준은 살아 있었다.\n# 현재\n민준이 말했다. \"돌아왔어요.\""
        XCTAssertTrue(check(snapshot(source, events: [(0, "사망", death), (1, "생존", nil)]), source).isEmpty)
        XCTAssertTrue(check(snapshot(source, events: [(0, "사망", death), (1, "사망", nil)]), source).isEmpty)
        XCTAssertTrue(check(snapshot(source, events: [(0, "사망", death), (1, "사망", "민준은 살아 있었다."), (1, "생존", "민준은 살아 있었다.")]), source).isEmpty)
    }

    func testFlashbackDoesNotConsumeDeduplicationAndShiftedDeathCannotAffectPresent() {
        let source = "# 사건\n\(death)\n# 회상\n민준이 말했다. \"예전이에요.\"\n# 현재\n민준이 말했다. \"지금이에요.\""
        let value = snapshot(source, events: [(0, "사망", death)], types: [1: "회상"])
        XCTAssertEqual(check(value, source).first?.evidence.last?.quote, "지금이에요.")
        XCTAssertTrue(check(snapshot(source, events: [(0, "사망", death)], types: [0: "회상"]), source).isEmpty)
        XCTAssertTrue(check(snapshot(body, events: [(0, "사망", death)], types: [1: "꿈"]), body).isEmpty)
    }

    func testHonorficsRequireFourOriginalAnchorsAndResetAcrossShiftedSample() throws {
        let source = """
        # 현재
        민준이 말했다. "하나요."
        서연이 말했다. "응."
        민준이 말했다. "둘요."
        서연이 말했다. "응."
        민준이 말했다. "셋요."
        서연이 말했다. "응."
        민준이 말했다. "넷이야."
        """
        let warnings = check(snapshot(source), source)
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warning.kind, .honorificBreak)
        XCTAssertEqual(warning.evidence.map(\.quote), ["하나요.", "둘요.", "셋요.", "넷이야."])
        let outline = DocumentOutline.parse(source), scene = outline.scenes[0]
        let match = (source as NSString).range(of: "둘요.")
        let shifted = NarrativeSegment(sceneHash: scene.contentHash,
            localStart: match.location - scene.utf16Range.lowerBound, localEnd: NSMaxRange(match) - scene.utf16Range.lowerBound,
            startQuote: "둘요.", layer: .uncertain)
        let segmentation = SceneSegmentation(segments: [shifted])
        XCTAssertTrue(check(snapshot(source, segments: [scene.contentHash: segmentation]), source).isEmpty)
    }

    func testAffirmativeDeathVocabularyRefusesNegationAndUncertainty() {
        for value in ["사망하지 않음", "사망 미확인", "사망 추정", "죽었을지도 모름", "죽었다고 알려짐", "비사망"] {
            XCTAssertFalse(ConsistencyChecker.isDead(value), value)
            XCTAssertTrue(check(snapshot(body, events: [(0, value, death)]), body).isEmpty, value)
        }
        for value in ["사망", "사고로 사망", "죽음", "죽었다", "죽었음"] { XCTAssertTrue(ConsistencyChecker.isDead(value)) }
    }
    func testSourceMustActuallySayThisCharacterDiedAndDuplicateSpeechCannotEstablishUsage() {
        let wrong = body.replacingOccurrences(of: death, with: "서연은 사망했다.")
        XCTAssertTrue(check(snapshot(wrong, events: [(0, "사망", "서연은 사망했다.")]), wrong).isEmpty)
        let alive = body.replacingOccurrences(of: death, with: "민준은 살아 있었다.")
        XCTAssertTrue(check(snapshot(alive, events: [(0, "사망", "민준은 살아 있었다.")]), alive).isEmpty)
        let source = "# 현재\n민준이 말했다. \"하나요.\"\n서연이 말했다. \"응.\"\n민준이 말했다. \"넷이야.\""
        let utterances = DialogueAttribution.utterances(in: source, cards: cards)
        let value = KnowledgeSnapshot(entryID: UUID(), outline: DocumentOutline.parse(source), summariesByHash: [:],
            utterances: [utterances[0], utterances[0], utterances[0]] + utterances.dropFirst())
        XCTAssertTrue(check(value, source).isEmpty)
    }

    func testUnrelatedShiftInsidePriorSceneDoesNotHideAnOriginalPresentDeath() {
        let source = body.replacingOccurrences(of: death, with: death + " 기억 속 과거였다.")
        let outline = DocumentOutline.parse(source), scene = outline.scenes[0]
        let match = (source as NSString).range(of: "기억 속 과거였다.")
        let segment = NarrativeSegment(sceneHash: scene.contentHash,
            localStart: match.location - scene.utf16Range.lowerBound, localEnd: NSMaxRange(match) - scene.utf16Range.lowerBound,
            startQuote: "기억 속 과거였다.", layer: .flashback)
        XCTAssertEqual(check(snapshot(source, events: [(0, "사망", death)],
            segments: [scene.contentHash: .init(segments: [segment])]), source).count, 1)
    }

    func testCancelledCheckReturnsNoPartialCandidates() async {
        let source = body, value = snapshot(body, events: [(0, "사망", death)]), characters = cards
        let task = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            return ConsistencyChecker.check(snapshot: value, characters: characters, source: source)
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
    }

    @MainActor
    func testEditingRetiresWarningsImmediatelyEvenWhileBackgroundWorkIsPaused() {
        let source = body, value = snapshot(body, events: [(0, "사망", death)])
        let warnings = check(value, source)
        XCTAssertEqual(warnings.count, 1)
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let reader = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        defer { reader.shutdown() }
        for paused in [false, true] {
            reader.setMemoryPressurePaused(paused)
            reader._testApplyPassOutputs(snapshot: value, warnings: warnings, metrics: nil)
            reader.noteChange(entryID: value.entryID)
            XCTAssertTrue(reader.warnings.isEmpty, "Old source actions must retire synchronously, paused=\(paused)")
        }
    }

}
