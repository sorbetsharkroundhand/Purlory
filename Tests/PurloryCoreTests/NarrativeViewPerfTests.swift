@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// Cold narrative projection cost. NarrativeView caches this result until the snapshot
/// generation, projection or minor-group expansion changes; ordinary hover/typing reuses it.
/// The existing frame-budget gate protects the rebuild without measuring actual app paint.
final class NarrativeViewPerfTests: XCTestCase {

    /// 장편 규모 픽스처 — 씬 200개, 씬당 사건 3개(=600), 플롯 6개.
    /// 30만 자 장편에서 실제로 나올 수 있는 규모.
    private func makeLargeSnapshot(
        sceneCount: Int = 200, eventsPerScene: Int = 3, threadCount: Int = 6
    ) -> KnowledgeSnapshot {
        var body = ""
        for index in 0..<sceneCount {
            body += "# \(index + 1)장\n"
            body += "인물이 무언가를 했다. 그리고 또 다른 일이 벌어졌다. 장면이 이어졌다.\n\n"
        }
        let outline = DocumentOutline.parse(body)

        var events: [String: [StoryEvent]] = [:]
        var allKeys: [String] = []
        for (index, scene) in outline.scenes.enumerated() {
            var sceneEvents: [StoryEvent] = []
            for offset in 0..<eventsPerScene {
                let summary = "사건 \(index)-\(offset) 무언가가 일어났다"
                let event = StoryEvent(
                    sceneHash: scene.contentHash, participants: [],
                    summary: summary,
                    // 중요도 3 이상 — 사소 묶음으로 접히지 않게 (최악 경우 측정).
                    importance: 3 + (offset % 3))
                sceneEvents.append(event)
                allKeys.append(event.stableKey)
            }
            events[scene.contentHash] = sceneEvents
        }

        // 플롯 스레드 — 사건을 라운드로빈으로 나눠 여러 레인이 겹치게.
        var threads: [PlotThread] = []
        for threadIndex in 0..<threadCount {
            let members = allKeys.enumerated()
                .filter { $0.offset % threadCount == threadIndex }
                .map { EventThreadMembership(eventKey: $0.element) }
            guard members.count >= 2 else { continue }
            threads.append(
                PlotThread(
                    title: "플롯 \(threadIndex)", summary: "",
                    memberships: members))
        }

        return KnowledgeSnapshot(
            entryID: UUID(), outline: outline, summariesByHash: [:],
            events: events,
            plotThreadAnalysis: PlotThreadAnalysis(threads: threads, memoHash: "m"),
            characters: [],
            overrides: NarrativeOverrides([]))
    }

    /// Rebuild the cold projection at each synthetic scale, without using the view cache.
    func test_그래프_행_레이아웃_비용() {
        print("\n=== Cold narrative projection (frame budget 16.7ms) ===")
        var worst: Double = 0
        for sceneCount in [50, 100, 200, 400] {
            let snapshot = makeLargeSnapshot(sceneCount: sceneCount)
            var rows: [GraphRow] = []
            let rowsStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 {
                rows = GraphRow.flowRows(from: snapshot, expandedMinors: [])
            }
            let rowsMs = (CFAbsoluteTimeGetCurrent() - rowsStart) / 20 * 1000

            let layoutStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 {
                _ = ThreadGraphLayout.compute(rows: rows, threads: snapshot.plotThreads)
            }
            let layoutMs = (CFAbsoluteTimeGetCurrent() - layoutStart) / 20 * 1000
            worst = max(worst, rowsMs + layoutMs)

            print(
                String(
                    format:
                        "  씬 %4d · 사건 %4d · 행 %4d │ flowRows %6.3fms + layout %6.3fms = %6.3fms (%3.0f%%)",
                    sceneCount, snapshot.canonicalEvents.count, rows.count,
                    rowsMs, layoutMs, rowsMs + layoutMs, (rowsMs + layoutMs) / 16.7 * 100))
        }
        print("")

        // Keep the existing frame-budget gate unchanged.
        XCTAssertLessThan(worst, 16.7)
    }

    /// 행 기하는 한 번만 접힌다 — 중심 y는 높이 누적, 전체 높이는 그 합.
    func test_행_기하_한번에_접힌다() {
        let snapshot = makeLargeSnapshot(sceneCount: 10)
        let rows = GraphRow.flowRows(from: snapshot, expandedMinors: [])
        let geometry = GraphRowGeometry(rows: rows)

        XCTAssertEqual(geometry.centers.count, rows.count)
        XCTAssertEqual(geometry.totalHeight, rows.reduce(0) { $0 + $1.height })
        // 첫 행 중심 = 제 높이의 절반, 이후는 누적.
        XCTAssertEqual(geometry.centers[0], rows[0].height / 2)
        XCTAssertEqual(
            geometry.centers[1], rows[0].height + rows[1].height / 2, accuracy: 0.001)
    }

    // MARK: - 플롯 선택 전환 규칙

    /// A 선택 → B로 전환 → C로 전환 → C 재클릭으로 해제. 요구사항 시나리오.
    func test_다른것을_누르면_바로_전환되고_같은것_재클릭으로_풀린다() {
        var selection: String?

        selection = NarrativeView.nextSelection(current: selection, tapped: "A")
        XCTAssertEqual(selection, "A", "선택이 없으면 누른 것이 선택된다")

        selection = NarrativeView.nextSelection(current: selection, tapped: "B")
        XCTAssertEqual(selection, "B", "A 선택 중 B를 누르면 먼저 풀지 않아도 전환된다")

        selection = NarrativeView.nextSelection(current: selection, tapped: "C")
        XCTAssertEqual(selection, "C", "연달아 눌러도 매번 누른 것으로 옮겨간다")

        selection = NarrativeView.nextSelection(current: selection, tapped: "C")
        XCTAssertNil(selection, "같은 것을 다시 누르면 풀린다")

        selection = NarrativeView.nextSelection(current: selection, tapped: "B")
        XCTAssertEqual(selection, "B", "풀린 뒤에는 새로 선택할 수 있다")
    }
}
