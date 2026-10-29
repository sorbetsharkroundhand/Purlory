@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// Plot Thread (v6, Narrative Graph) — 파서·stable identity·상태 파생·레이아웃의
/// 결정적 로직 검증 (LLM 호출 없음). 최종 성공 기준(요구사항 §14):
/// 직선 소설은 직선, 서브플롯은 시작점에서 branch, 만나는 사건에서 merge,
/// 휴면 플롯은 레인 유지, 재분석에도 identity 유지.
final class PlotThreadTests: XCTestCase {

    /// 사건 키 k1…kN (요약 해시 기반 stableKey와 같은 규격의 임의 키).
    private func keys(_ count: Int) -> [String] {
        (1...count).map { "key-\($0)" }
    }

    /// 사건 행만으로 구성된 rows — 레이아웃 단위 테스트용.
    private func eventRows(_ keys: [String]) -> [GraphRow] {
        keys.enumerated().map { offset, key in
            .event(
                id: "r\(offset)",
                event: CanonicalEvent(
                    canonicalKey: key, sceneHash: "scene", summary: key,
                    importance: 3, participants: [], perspectives: [], quote: nil),
                start: 0)
        }
    }

    private func thread(
        id: String, members: [String], resolvedAt: String? = nil, main: Bool = false
    ) -> ResolvedPlotThread {
        ResolvedPlotThread(
            id: id, title: id, summary: "", status: resolvedAt == nil ? .active : .resolved,
            memberKeys: members, roleByKey: [:], resolvedAtKey: resolvedAt,
            isMain: main, userEdited: false, confidence: 0.6)
    }

    // MARK: - 파서

    func test_파서_플롯_제목_해결_역할() {
        let ks = keys(8)
        let output = """
            플롯: 1,3,5,8 | 제목: 살인사건의 진실 | 요약: 남편의 죽음을 파헤친다 | 해결: 8
            플롯: 2,4 | 제목: 연애 관계 | 요약: 두 사람의 거리
            플롯: 6 | 제목: 사건하나 | 요약: 멤버 부족 — 버려져야 한다
            잡담: 무시될 줄
            """
        let threads = PlotThreadParser.parse(output, keys: ks)
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[0].title, "살인사건의 진실")
        XCTAssertEqual(threads[0].memberships.map(\.eventKey), ["key-1", "key-3", "key-5", "key-8"])
        // 역할 — 첫 멤버 = 제시, 해결 번호 = 해결, 나머지 = 진행.
        XCTAssertEqual(threads[0].memberships[0].role, .opens)
        XCTAssertEqual(threads[0].memberships[3].role, .resolves)
        XCTAssertEqual(threads[0].resolvedAtKey, "key-8")
        XCTAssertNil(threads[1].resolvedAtKey)
        // stableID는 여는 사건 키에서 파생 — 같은 입력이면 같은 ID.
        XCTAssertEqual(threads[0].stableID, PlotThread.makeStableID(openingKey: "key-1"))
    }

    func test_파서_멤버아닌_해결번호는_버린다() {
        let output = "플롯: 1,3 | 제목: 갈등 | 해결: 7"
        let threads = PlotThreadParser.parse(output, keys: keys(8))
        XCTAssertEqual(threads.count, 1)
        XCTAssertNil(threads[0].resolvedAtKey)
    }

    func test_그래프분석입력은_동일stableKey의_첫사건만_보존한다() {
        let first = StoryEvent(
            sceneHash: "scene-1", participants: [],
            summary: "문이 열린다", importance: 3)
        let repeated = StoryEvent(
            sceneHash: "scene-2", participants: [],
            summary: "문이 열린다", importance: 5)
        let next = StoryEvent(
            sceneHash: "scene-3", participants: [],
            summary: "서연이 들어온다", importance: 4)

        let result = BackgroundIndexer.uniqueEventsForAnalysis(
            [first, repeated, next])

        XCTAssertEqual(result.map(\.sceneHash), ["scene-1", "scene-3"])
        XCTAssertEqual(Set(result.map(\.stableKey)).count, result.count)
    }

    func test_고유사건이_임계값아래로줄면_이전그래프와플롯을_비운다() {
        var sidecar = KnowledgeSidecar(entryID: UUID())
        sidecar.eventGraph = EventGraphAnalysis(memoHash: "old-graph")
        sidecar.plotThreads = PlotThreadAnalysis(threads: [], memoHash: "old-plot")

        let changed = BackgroundIndexer.clearAnalysesBelowThreshold(
            sidecar: &sidecar, uniqueEventCount: 1)

        XCTAssertTrue(changed)
        XCTAssertNil(sidecar.eventGraph)
        XCTAssertNil(sidecar.plotThreads)
    }

    // MARK: - Stable identity (요구사항 §10 — 재분석에도 유지)

    func test_reconcile_멤버겹침이면_이전ID_유지() {
        let old = PlotThread(
            stableID: "thr-OLD", title: "복수",
            memberships: [.init(eventKey: "key-1"), .init(eventKey: "key-2"), .init(eventKey: "key-3")])
        // 재분석 — 앞에 새 사건이 붙어 여는 사건이 바뀌었지만 과반이 겹친다.
        let renewed = PlotThread(
            title: "복수의 준비",
            memberships: [.init(eventKey: "key-0"), .init(eventKey: "key-2"), .init(eventKey: "key-3")])
        let result = PlotThreadParser.reconcile(new: [renewed], previous: [old])
        XCTAssertEqual(result[0].stableID, "thr-OLD")
        // 겹침 없는 새 플롯은 새 ID.
        let fresh = PlotThread(
            title: "새 갈등",
            memberships: [.init(eventKey: "key-8"), .init(eventKey: "key-9")])
        let mixed = PlotThreadParser.reconcile(new: [renewed, fresh], previous: [old])
        XCTAssertEqual(mixed[0].stableID, "thr-OLD")
        XCTAssertNotEqual(mixed[1].stableID, "thr-OLD")
    }

    func test_reconcile_이전ID는_한_플롯에만() {
        let old = PlotThread(
            stableID: "thr-OLD", title: "미스터리",
            memberships: [.init(eventKey: "key-1"), .init(eventKey: "key-2")])
        // 두 새 플롯이 같은 이전 플롯과 겹친다 — 겹침 큰 쪽만 물려받는다.
        let bigger = PlotThread(
            title: "미스터리A",
            memberships: [.init(eventKey: "key-1"), .init(eventKey: "key-2"), .init(eventKey: "key-3")])
        let smaller = PlotThread(
            title: "미스터리B",
            memberships: [.init(eventKey: "key-2"), .init(eventKey: "key-9")])
        let result = PlotThreadParser.reconcile(new: [smaller, bigger], previous: [old])
        XCTAssertEqual(result[1].stableID, "thr-OLD")
        XCTAssertNotEqual(result[0].stableID, "thr-OLD")
    }

    // MARK: - 파생 (derive — 정본 정규화·상태·본줄기 폴백)

    func test_분석없으면_전사건이_본줄기_하나() {
        // 직선 소설 — 플롯 분석이 없으면(또는 못 묶으면) 본줄기 하나 = 직선.
        let order = keys(4)
        let threads = ResolvedPlotThread.derive(
            analysis: nil, canonicalOrder: order, memberMap: [:], overrides: .empty)
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(threads[0].isMain)
        XCTAssertEqual(threads[0].memberKeys, order)
    }

    func test_상태파생_생명주기() {
        let order = keys(10)
        let analysis = PlotThreadAnalysis(threads: [
            // 해결됨.
            PlotThread(
                stableID: "thr-A", title: "해결플롯",
                memberships: [.init(eventKey: "key-1"), .init(eventKey: "key-3", role: .resolves)],
                resolvedAtKey: "key-3"),
            // 마지막 멤버(key-2) 뒤로 사건 8개 — 휴면. 레인은 유지된다.
            PlotThread(
                stableID: "thr-B", title: "휴면플롯",
                memberships: [.init(eventKey: "key-1"), .init(eventKey: "key-2")]),
            // 끝까지 진행 중.
            PlotThread(
                stableID: "thr-C", title: "진행플롯",
                memberships: [.init(eventKey: "key-5"), .init(eventKey: "key-10")]),
        ])
        let threads = ResolvedPlotThread.derive(
            analysis: analysis, canonicalOrder: order, memberMap: [:], overrides: .empty)
        func status(_ id: String) -> ThreadStatus? {
            threads.first { $0.id == id }?.status
        }
        XCTAssertEqual(status("thr-A"), .resolved)
        XCTAssertEqual(status("thr-B"), .dormant)
        XCTAssertEqual(status("thr-C"), .active)
        // 어느 플롯에도 안 속한 사건은 본줄기로.
        let main = threads.first { $0.isMain }
        XCTAssertEqual(main?.memberKeys.contains("key-4"), true)
        // 사용자 상태 오버라이드가 파생을 이긴다.
        let overridden = ResolvedPlotThread.derive(
            analysis: analysis, canonicalOrder: order, memberMap: [:],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .threadStatus, key: "thr-B", value: "해결")
            ]))
        XCTAssertEqual(overridden.first { $0.id == "thr-B" }?.status, .resolved)
    }

    func test_멤버십_오버라이드_추가_제외() {
        let order = keys(5)
        let analysis = PlotThreadAnalysis(threads: [
            PlotThread(
                stableID: "thr-A", title: "갈등",
                memberships: [.init(eventKey: "key-1"), .init(eventKey: "key-2")])
        ])
        let threads = ResolvedPlotThread.derive(
            analysis: analysis, canonicalOrder: order, memberMap: [:],
            overrides: NarrativeOverrides([
                NarrativeOverride(kind: .threadMembership, key: "thr-A|key-4", value: "진행"),
                NarrativeOverride(kind: .threadMembership, key: "thr-A|key-2", value: "제외"),
            ]))
        let a = threads.first { $0.id == "thr-A" }
        XCTAssertEqual(a?.memberKeys, ["key-1", "key-4"])
        XCTAssertTrue(a?.userEdited == true)
        // 제외된 사건은 본줄기로 돌아간다.
        XCTAssertEqual(threads.first { $0.isMain }?.memberKeys.contains("key-2"), true)
    }

    func test_정본정규화_동일사건은_한_멤버로() {
        // key-2가 key-1의 재서술로 접혔다 — 스레드 멤버도 정본 하나로.
        let order = ["key-1", "key-3"]
        let analysis = PlotThreadAnalysis(threads: [
            PlotThread(
                stableID: "thr-A", title: "미스터리",
                memberships: [
                    .init(eventKey: "key-1"), .init(eventKey: "key-2"),
                    .init(eventKey: "key-3"),
                ])
        ])
        let threads = ResolvedPlotThread.derive(
            analysis: analysis, canonicalOrder: order,
            memberMap: ["key-2": "key-1"], overrides: .empty)
        XCTAssertEqual(threads.first { $0.id == "thr-A" }?.memberKeys, ["key-1", "key-3"])
    }

    // MARK: - 레이아웃 (요구사항 §11·§14 — topology는 데이터, 배치는 결정적)

    func test_직선소설은_레인_하나() {
        let order = keys(4)
        let threads = ResolvedPlotThread.derive(
            analysis: nil, canonicalOrder: order, memberMap: [:], overrides: .empty)
        let layout = ThreadGraphLayout.compute(rows: eventRows(order), threads: threads)
        XCTAssertEqual(layout.slotCount, 1)
        XCTAssertEqual(layout.lanes.count, 1)
        // 모든 노드가 중심선 위 — junction 없음.
        XCTAssertTrue(layout.nodes.values.allSatisfy { $0.slot == 0 && !$0.isJunction })
    }

    func test_서브플롯_branch와_merge() {
        // A B C D E — 서브플롯 S = {B, D} (D에서 해결), 본줄기 = {A, C, E}.
        let order = ["A", "B", "C", "D", "E"]
        let main = thread(id: PlotThread.mainID, members: ["A", "C", "E"], main: true)
        let sub = thread(id: "thr-S", members: ["B", "D"], resolvedAt: "D")
        let layout = ThreadGraphLayout.compute(
            rows: eventRows(order), threads: [main, sub])
        // 본줄기 슬롯 0 고정, 서브플롯은 슬롯 1.
        XCTAssertEqual(layout.lanes.first { $0.thread.isMain }?.slot, 0)
        let subLane = layout.lanes.first { $0.thread.id == "thr-S" }
        XCTAssertEqual(subLane?.slot, 1)
        // 서브플롯은 실제 시작 사건(B, 행 1)에서 열리고 해결 사건(D, 행 3)에서 닫힌다.
        XCTAssertEqual(subLane?.openRow, 1)
        XCTAssertEqual(subLane?.resolveRow, 3)
        // 해결된 슬롯은 회수된다 — 그 뒤에 여는 플롯이 슬롯 1을 재사용.
        let late = thread(id: "thr-L", members: ["E"])
        let reuse = ThreadGraphLayout.compute(
            rows: eventRows(order), threads: [main, sub, late])
        XCTAssertEqual(reuse.lanes.first { $0.thread.id == "thr-L" }?.slot, 1)
    }

    func test_두_플롯이_만나는_사건은_junction() {
        // C가 본줄기와 서브플롯 모두에 속한다 — 두 이야기가 만나는 지점.
        let order = ["A", "B", "C", "D"]
        let main = thread(id: PlotThread.mainID, members: ["A", "C", "D"], main: true)
        let sub = thread(id: "thr-S", members: ["B", "C"], resolvedAt: "C")
        let layout = ThreadGraphLayout.compute(
            rows: eventRows(order), threads: [main, sub])
        let junction = layout.nodes["C"]
        XCTAssertEqual(junction?.isJunction, true)
        XCTAssertEqual(junction?.laneSlots, [0, 1])
        // junction 노드는 본줄기 슬롯에 놓이고, 서브플롯이 거기로 merge된다.
        XCTAssertEqual(junction?.slot, 0)
        XCTAssertEqual(junction?.resolvesSlots, [1])
    }

    func test_휴면플롯은_레인을_유지한다() {
        // U = {B, C} 미해결 — 뒤로 한참 안 나와도 레인이 끝나지 않는다
        // (사라졌다 새 branch로 재생성되면 실패, 요구사항 §14).
        let order = keys(10)
        let main = thread(id: PlotThread.mainID, members: order.filter { $0 != "key-2" }, main: true)
        let dormant = thread(id: "thr-U", members: ["key-2", "key-3"])
        let layout = ThreadGraphLayout.compute(
            rows: eventRows(order), threads: [main, dormant])
        let lane = layout.lanes.first { $0.thread.id == "thr-U" }
        XCTAssertNotNil(lane)
        XCTAssertNil(lane?.resolveRow)  // 닫히지 않는다
        // 휴면 레인의 슬롯은 미해결인 동안 회수되지 않는다 — 뒤에 여는 플롯은 다음 슬롯.
        let late = thread(id: "thr-L", members: ["key-8", "key-9"])
        let both = ThreadGraphLayout.compute(
            rows: eventRows(order), threads: [main, dormant, late])
        XCTAssertEqual(both.lanes.first { $0.thread.id == "thr-L" }?.slot, 2)
    }

    func test_레이아웃_결정성() {
        let order = keys(6)
        let main = thread(id: PlotThread.mainID, members: ["key-1", "key-4", "key-6"], main: true)
        let s1 = thread(id: "thr-1", members: ["key-2", "key-5"])
        let s2 = thread(id: "thr-2", members: ["key-3", "key-6"])
        let a = ThreadGraphLayout.compute(rows: eventRows(order), threads: [main, s1, s2])
        let b = ThreadGraphLayout.compute(rows: eventRows(order), threads: [main, s1, s2])
        XCTAssertEqual(a.lanes.map(\.slot), b.lanes.map(\.slot))
        XCTAssertEqual(a.slotCount, b.slotCount)
        XCTAssertEqual(
            a.nodes.mapValues(\.slot), b.nodes.mapValues(\.slot))
    }

    func testLayoutPreservesFirstRowsAndUniqueMembershipsAcrossSlotReuse() throws {
        let rows = eventRows(["A", "B", "A", "C", "unclaimed"])
        let layout = ThreadGraphLayout.compute(rows: rows, threads: [
            thread(id: PlotThread.mainID, members: ["A", "C"], resolvedAt: "C", main: true),
            thread(id: "side", members: ["A", "A", "B", "hidden"], resolvedAt: "B"),
            thread(id: "late", members: ["C"]),
            thread(id: "hidden-only", members: ["hidden"]),
        ])

        XCTAssertEqual(layout.lanes.map(\.thread.id), [PlotThread.mainID, "side", "late"])
        XCTAssertEqual(layout.lanes.map(\.slot), [0, 1, 1])
        XCTAssertEqual(layout.lanes.map(\.openRow), [0, 0, 3])
        XCTAssertEqual(layout.lanes.map(\.resolveRow), [3, 1, nil])
        XCTAssertEqual(layout.lanes.map(\.memberRows), [[0, 3], [0, 0, 1], [3]])
        XCTAssertEqual(layout.slotCount, 2)

        // Duplicate rows use the first occurrence; duplicate memberships join a lane once.
        // Hidden keys create no phantom nodes, and an unclaimed event still has a node.
        let expected: [(key: String, row: Int, slot: Int, lanes: [Int], opens: [Int], resolves: [Int])] = [
            ("A", 0, 0, [0, 1], [1], []),
            ("B", 1, 1, [1], [], []),
            ("C", 3, 0, [0, 1], [1], []),
            ("unclaimed", 4, 0, [], [], []),
        ]
        XCTAssertEqual(Set(layout.nodes.keys), Set(["A", "B", "C", "unclaimed"]))
        for want in expected {
            let node = try XCTUnwrap(layout.nodes[want.key])
            XCTAssertEqual(node.key, want.key)
            XCTAssertEqual(node.row, want.row, want.key)
            XCTAssertEqual(node.slot, want.slot, want.key)
            XCTAssertEqual(node.laneSlots, want.lanes, want.key)
            XCTAssertEqual(node.opensSlots, want.opens, want.key)
            XCTAssertEqual(node.resolvesSlots, want.resolves, want.key)
        }
    }

    func test_projection이_바뀌어도_thread_identity_유지() {
        // 흐름(담화)과 시간순은 행 순서만 다르다 — 레인의 스레드 ID 집합은 같다.
        let discourse = ["A", "B", "C", "D"]
        let chrono = ["C", "A", "B", "D"]  // 회상 속 사건 C가 시간상 먼저
        let main = thread(id: PlotThread.mainID, members: ["A", "B", "D"], main: true)
        let sub = thread(id: "thr-S", members: ["C", "D"])
        let flow = ThreadGraphLayout.compute(rows: eventRows(discourse), threads: [main, sub])
        let time = ThreadGraphLayout.compute(rows: eventRows(chrono), threads: [main, sub])
        XCTAssertEqual(
            Set(flow.lanes.map(\.thread.id)), Set(time.lanes.map(\.thread.id)))
        // 시간순에서는 서브플롯이 행 0(C)에서 열린다 — 순서는 달라도 identity는 같다.
        XCTAssertEqual(time.lanes.first { $0.thread.id == "thr-S" }?.openRow, 0)
    }

    // MARK: - 스냅샷 통합 (threadIDsByEvent·threads(of:))

    func test_스냅샷이_플롯을_싣는다() {
        let body = """
            # 1장
            사건이 있었다.

            # 2장
            더 있었다.
            """
        let outline = DocumentOutline.parse(body)
        let h1 = outline.scenes[0].contentHash
        let h2 = outline.scenes[1].contentHash
        let e1 = StoryEvent(sceneHash: h1, participants: [], summary: "발단", importance: 3)
        let e2 = StoryEvent(sceneHash: h2, participants: [], summary: "전개", importance: 3)
        let analysis = PlotThreadAnalysis(threads: [
            PlotThread(
                stableID: "thr-X", title: "갈등",
                memberships: [.init(eventKey: e1.stableKey), .init(eventKey: e2.stableKey)])
        ])
        let snapshot = KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            events: [h1: [e1], h2: [e2]],
            plotThreadAnalysis: analysis,
            overrides: .empty)
        XCTAssertEqual(snapshot.plotThreads.count, 1)  // 전 사건이 스레드 소속 → 본줄기 없음
        XCTAssertEqual(snapshot.threads(of: e1.stableKey).first?.id, "thr-X")
        XCTAssertEqual(snapshot.threadIDsByEvent[e2.stableKey], ["thr-X"])
    }
}
