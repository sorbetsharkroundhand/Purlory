@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 백그라운드 이해 파이프라인의 결정적 유닛 회귀 테스트 (PLAN §9).
/// LLM 호출부는 벤치(PurloryBench)가 담당하므로, 여기서는 **같은 입력 재처리
/// 금지**(CLAUDE.md §4)와 저장 규격을 지탱하는 순수 로직만 고정한다:
/// 분석 출력 파싱·사건 중복 제거·임계 미달 정리·메모이제이션 지표.
final class BackgroundIndexerTests: XCTestCase {

    // MARK: - 씬 분석 출력 파싱

    func test다섯줄_형식을_모두_읽는다() {
        let output = """
        제목: 닫힌 문
        요약: 서연은 문을 두드렸다. 아무도 대답하지 않았다.
        유형: 회상
        시점: 서연
        장소: 옥상
        """
        let analysis = try! XCTUnwrap(BackgroundIndexer.parseSceneAnalysis(output))

        XCTAssertEqual(analysis.title, "닫힌 문")
        XCTAssertEqual(analysis.summary, "서연은 문을 두드렸다. 아무도 대답하지 않았다.")
        XCTAssertEqual(analysis.narrativeType, "회상")
        XCTAssertEqual(analysis.pov, "서연")
        XCTAssertEqual(analysis.location, "옥상")
    }

    func test키별칭도_읽는다() {
        // 소형 모델이 "종류"·"시점인물"로 답하는 경우 — 같은 의미로 흡수.
        let analysis = try! XCTUnwrap(BackgroundIndexer.parseSceneAnalysis(
            "제목: 창가\n요약: 비가 왔다.\n종류: 현재\n시점인물: 민준"))

        XCTAssertEqual(analysis.narrativeType, "현재")
        XCTAssertEqual(analysis.pov, "민준")
    }

    func test요약이_없으면_지식이_아니라() {
        // 제목만으로는 지식이 아니다 — B 블록에 넣을 것이 없다면 nil.
        XCTAssertNil(BackgroundIndexer.parseSceneAnalysis("제목: 뭐\n유형: 현재"))
        XCTAssertNil(BackgroundIndexer.parseSceneAnalysis(""))
    }

    func test키없는_산문줄은_구형응답_폴백으로_요약이_된다() {
        let prose = "서연은 문을 두드리고 아무 대답도 듣지 못한 채 조용히 내려왔다."
        let analysis = try! XCTUnwrap(BackgroundIndexer.parseSceneAnalysis(prose))

        XCTAssertNil(analysis.title)
        XCTAssertEqual(analysis.summary, prose)
    }

    func test빈값_줄과_불릿마커는_무시하거나_벗긴다() {
        // 모델이 목록 기호를 붙여도 키 파싱은 살아 있어야 한다.
        let analysis = try! XCTUnwrap(BackgroundIndexer.parseSceneAnalysis(
            "- 제목:\n- 요약: 서연이 웃었다."))

        XCTAssertNil(analysis.title)   // 빈값 줄 스킵
        XCTAssertEqual(analysis.summary, "서연이 웃었다.")
    }

    func test긴_제목과_요약은_문장경계에서_클램프된다() {
        // 40자 제목 → 상한 24. 종결부호 위치가 정확히 경계에 오는 입력이라
        // 절단 결과를 글자 수까지 확정할 수 있다 ("짧다." ×8 = 24자).
        let longTitle = String(repeating: "짧다.", count: 10)
        let longSummary = String(repeating: "첫문장이다.", count: 30) + "끝."
        let analysis = try! XCTUnwrap(BackgroundIndexer.parseSceneAnalysis(
            "제목: \(longTitle)\n요약: \(longSummary)"))

        XCTAssertEqual(analysis.title, String(repeating: "짧다.", count: 8))
        XCTAssertLessThanOrEqual(analysis.summary.count, BackgroundIndexer.maxSummaryCharacters)
        XCTAssertTrue(analysis.summary.hasSuffix("."), "문장 중간 잘림은 저장 규격 위반")
    }

    // MARK: - 사건 분석 대상 중복 제거 (PLAN §6.6)

    private func event(_ summary: String, scene: String = "h1") -> StoryEvent {
        StoryEvent(sceneHash: scene, participants: [], summary: summary, importance: 3)
    }

    func test재서술된_사건은_첫등장만_남긴다() {
        // stableKey = 요약문 해시 — 같은 사건의 재서술은 씬이 달라도 겹친다.
        let events = [
            event("서연이 문을 닫았다", scene: "h1"),
            event("서연이 문을 닫았다", scene: "h2"),
            event("민준이 편지를 태웠다", scene: "h2"),
        ]

        let unique = BackgroundIndexer.uniqueEventsForAnalysis(events)

        XCTAssertEqual(unique.map(\.sceneHash), ["h1", "h2"])
    }

    func test분석_상한은_앞에서부터_적용한다() {
        let many = (0..<45).map { event("사건 번호 \($0)번") }
        XCTAssertEqual(BackgroundIndexer.uniqueEventsForAnalysis(many).count, 40)
        XCTAssertEqual(BackgroundIndexer.uniqueEventsForAnalysis(many, limit: 3).count, 3)
        XCTAssertTrue(BackgroundIndexer.uniqueEventsForAnalysis([], limit: 5).isEmpty)
    }

    // MARK: - 임계 미달 정리 (죽은 그래프 방지, PLAN §6.6)

    func test임계미달이면_과거_분석을_버린다() {
        var sidecar = KnowledgeSidecar(entryID: UUID())
        sidecar.eventGraph = EventGraphAnalysis()
        sidecar.plotThreads = PlotThreadAnalysis()

        XCTAssertTrue(BackgroundIndexer.clearAnalysesBelowThreshold(
            sidecar: &sidecar, uniqueEventCount: 1))
        XCTAssertNil(sidecar.eventGraph)
        XCTAssertNil(sidecar.plotThreads)
    }

    func test임계는_각각_따로_적용된다() {
        var sidecar = KnowledgeSidecar(entryID: UUID())
        sidecar.eventGraph = EventGraphAnalysis()
        sidecar.plotThreads = PlotThreadAnalysis()

        XCTAssertTrue(BackgroundIndexer.clearAnalysesBelowThreshold(
            sidecar: &sidecar, uniqueEventCount: 2))
        XCTAssertNotNil(sidecar.eventGraph)  // 그래프 하한 2 — 유지
        XCTAssertNil(sidecar.plotThreads)    // 스레드 하한 3 — 폐기
    }

    func test충분하면_아무것도_건드리지_않는다() {
        var sidecar = KnowledgeSidecar(entryID: UUID())
        sidecar.eventGraph = EventGraphAnalysis()
        sidecar.plotThreads = PlotThreadAnalysis()

        XCTAssertFalse(BackgroundIndexer.clearAnalysesBelowThreshold(
            sidecar: &sidecar, uniqueEventCount: 5))
        XCTAssertNotNil(sidecar.eventGraph)
        XCTAssertNotNil(sidecar.plotThreads)
    }

    // MARK: - 메모이제이션 지표 (요구사항 §33)

    func test지표는_사이드카_크기를_씬수로_나눈다() {
        let sidecar = KnowledgeSidecar(entryID: UUID())
        let metrics = BackgroundIndexer.measure(
            sidecar: sidecar, sceneCount: 4, loadMs: 1.5, deriveMs: 2.5, saveMs: 3.5)

        XCTAssertEqual(metrics.sceneCount, 4)
        XCTAssertGreaterThan(metrics.sidecarBytes, 0) // 빈 사이드카도 골격은 직렬화된다
        XCTAssertEqual(metrics.bytesPerScene, metrics.sidecarBytes / 4)
        XCTAssertEqual(metrics.loadMs, 1.5)
        XCTAssertEqual(metrics.saveMs, 3.5)
        XCTAssertEqual(metrics.deriveMs, 2.5)
    }

    func test씬수_영이면_나누지_않는다() {
        let metrics = BackgroundIndexer.measure(
            sidecar: KnowledgeSidecar(entryID: UUID()), sceneCount: 0,
            loadMs: 0, deriveMs: 0)
        XCTAssertEqual(metrics.bytesPerScene, 0)
    }

    // MARK: - 열·전력 게이트 (백그라운드 3요건, PLAN §9)

    func test정상_상태에서는_모든_패스를_허용한다() {
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            XCTAssertTrue(BackgroundIndexer.gateAllows(
                deep: true, thermalState: state, lowPowerModeEnabled: false))
            XCTAssertTrue(BackgroundIndexer.gateAllows(
                deep: false, thermalState: state, lowPowerModeEnabled: false))
        }
    }

    func test발열_serious_이상은_빠른패스도_보류한다() {
        // 시민의식은 전부 아니오만 있다 — 발기 중엔 요약도 예측도 양보.
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            XCTAssertFalse(BackgroundIndexer.gateAllows(
                deep: true, thermalState: state, lowPowerModeEnabled: false))
            XCTAssertFalse(BackgroundIndexer.gateAllows(
                deep: false, thermalState: state, lowPowerModeEnabled: false))
        }
    }

    func test저전력은_깊은패스만_보류한다() {
        // 빠른 패스는 타이핑 직후의 이해라 저전력에도 돈다 — 깊은 패스(전체
        // 재분석·전파)만 배터리를 아끼려 미룬다.
        XCTAssertTrue(BackgroundIndexer.gateAllows(
            deep: false, thermalState: .nominal, lowPowerModeEnabled: true))
        XCTAssertFalse(BackgroundIndexer.gateAllows(
            deep: true, thermalState: .nominal, lowPowerModeEnabled: true))
    }

    // MARK: - 커서 거리순 순회 (docs/m6-scene-split.md §5)

    private let scenes = DocumentOutline.parse(
        "# A\n가.\n# B\n나.\n# C\n다.\n").scenes

    private func assertDistance(
        _ expected: Int, scene index: Int, caret: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            BackgroundIndexer.distance(from: scenes[index], to: caret), expected,
            file: file, line: line)
    }

    func test커서가_씬안이면_거리는_영이다() {
        assertDistance(0, scene: 1, caret: 8)   // "# B" 시작
        assertDistance(0, scene: 1, caret: 10)  // B 본문 안
    }

    func test커서에서_먼_방향으로_거리가_자란다() {
        assertDistance(0, scene: 0, caret: 7)   // A 끝 경계(=B 시작) — 사실상 인접
        assertDistance(7, scene: 0, caret: 14)  // A ← C 시작 지점
        assertDistance(7, scene: 2, caret: 7)   // C ← B 시작 지점 (뒤쪽)
        assertDistance(14, scene: 2, caret: 0)  // 문서 맨 앞에서 C까지
    }
}
