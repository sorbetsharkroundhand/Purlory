@testable import PurloryIntelligence
@testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 컨텍스트 리포트 소속 격리 회귀 (이슈 #8, Gate 2).
///
/// 리포트가 어느 문서 것인지 모르면 A 작품에서 본 항목을 B 화면에서
/// 고정/제외하며 B 오버라이드가 A의 stable key로 오염된다. 이 테스트는
/// 다음을 고정한다:
///  1. 조립 스냅샷(DocumentContext)은 소속 entryID를 담는다.
///  2. 문서 전환 알림이 이전 문서 리포트·진행 예측을 즉시 무효화한다.
///  3. 같은 문서로의 전환(재선택)은 무해하다.
final class ContextReportIsolationTests: XCTestCase {

    @MainActor
    func testProjectSnapshotUpdatePreservesPartiallyAcceptedGhost() {
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let completion = CompletionController()
        completion.noteDocumentSwitch(to: ProjectRuntimeIdentity(key: key, generation: 1))
        completion.publishCompletion(
            .init(
                text: " first second", timeToFirstChunk: nil, totalTime: 0,
                promptTokensPerSecond: nil, generationTokensPerSecond: nil,
                stoppedAtSentenceBoundary: false, promptTokenCount: 0, reusedPromptTokens: 0),
            caretLocation: 5, mode: "fast")

        XCTAssertEqual(completion.acceptWord(insertionLocation: 5), " first")
        // The editor writes its binding before forwarding noteEdit; that binding
        // synchronously publishes a new session snapshot for the accepted word.
        completion.noteDocumentChange(ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: key, generation: 2),
            title: "Draft", body: "Draft first", kind: .manuscript, mode: .general))
        completion.noteEdit(
            prefix: "Draft first", caretLocation: 11,
            isComposing: false, caretAtParagraphEnd: true)

        XCTAssertEqual(completion.suggestion, " second")
        XCTAssertEqual(completion.acceptSuggestion(), " second")
    }

    @MainActor
    func testABAReturnRejectsOriginalContext() {
        let documentID = WritingDocumentID()
        let aKey = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        let bKey = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        let identities = [
            ProjectRuntimeIdentity(key: aKey, generation: 1),
            ProjectRuntimeIdentity(key: bKey, generation: 2),
            ProjectRuntimeIdentity(key: aKey, generation: 3),
        ]
        let completion = CompletionController()
        completion.noteDocumentSwitch(to: identities[0])
        completion.lastContextReport = ContextReport(
            items: [.init(kind: .meta, text: "Original A", stableKey: "a")],
            entryID: documentID.rawValue, generation: 1, runtimeIdentity: identities[0])

        completion.noteDocumentSwitch(to: identities[1])
        completion.noteDocumentSwitch(to: identities[2])

        XCTAssertNil(completion.lastContextReport,
            "A generation 1 context must not survive the return to A generation 3")
        XCTAssertFalse(completion.isPredicting)
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    private func makeStore() -> EntryStore {
        EntryStore(directory: dir, autosaveDelay: .seconds(3600))
    }

    @MainActor
    func test문서스냅샷은소속entryID를담는다() throws {
        let store = makeStore()
        let novelID = store.newEntry(kind: .novel)

        let context = store.activeDocumentContext
        XCTAssertEqual(context?.entryID, novelID, "조립 스냅샷이 어느 작품 것인지 알아야 한다")

        // 전환하면 스냅샷도 새 활성 문서를 가리킨다.
        let otherID = store.newEntry()
        store.select(otherID)
        XCTAssertEqual(store.activeDocumentContext?.entryID, otherID)
    }

    @MainActor
    func test문서전환이이전문서리포트와진행예측을무효화한다() {
        let completion = CompletionController()
        let store = makeStore()
        let aID = store.activeID
        let bID = store.newEntry()

        // A에서 만들어진 리포트라고 친다 (세대 7).
        let reportA = ContextReport(
            items: [.init(kind: .meta, text: "A 메타", stableKey: "a-key")],
            entryID: aID, generation: 7)
        completion.lastContextReport = reportA

        completion.noteDocumentSwitch(to: bID)

        XCTAssertNil(
            completion.lastContextReport,
            "B로 전환했는데 A 리포트가 남으면 인스펙터가 오염된다")
        XCTAssertFalse(completion.isPredicting, "전환 즉시 진행 표시도 정리돼야 한다")
    }

    @MainActor
    func test같은문서재선택은리포트를살려둔다() {
        let completion = CompletionController()
        let store = makeStore()
        let id = store.newEntry(kind: .novel)

        let report = ContextReport(
            items: [.init(kind: .card, text: "인물 카드", stableKey: "k")],
            entryID: id, generation: 3)
        completion.lastContextReport = report

        // 같은 문서 재선택(사이드바 탭 등) — 지울 이유가 없다.
        completion.noteDocumentSwitch(to: id)

        XCTAssertEqual(completion.lastContextReport, report)
    }

    @MainActor
    func test늦게도착한A리포트는B오버라이드를기록하지못한다() throws {
        // 인스펙터 액션이 기록하는 대상은 리포트 소속 문서여야 한다 — 화면의
        // activeID가 아니라. (View의 targetID 전달 계약을 값 수준에서 고정.)
        let store = makeStore()
        let aID = store.newEntry(kind: .novel)
        _ = store.newEntry()  // B
        store.select(aID)

        // A 소속 리포트 항목을 "A"에 기록 — B가 active여도 A에 남는다.
        let item = ContextReport.Item(kind: .sceneSummary, text: "A 장면", stableKey: "scene-1")
        store.setNarrativeOverride(
            NarrativeOverride(kind: .contextExclude, key: item.stableKey, value: "제외"),
            in: aID)

        let overridesOfA = store.entries.first { $0.id == aID }?.narrativeOverrides ?? []
        XCTAssertTrue(overridesOfA.contains { $0.key == "scene-1" })
        for entry in store.entries where entry.id != aID {
            XCTAssertFalse(
                (entry.narrativeOverrides ?? []).contains { $0.key == "scene-1" },
                "다른 문서의 오버라이드가 오염됐다")
        }
    }
}
