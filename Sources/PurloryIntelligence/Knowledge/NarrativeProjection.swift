import Foundation

/// Pure snapshot-to-row/lane projection; colors and gestures belong to NarrativeView.
/// The view caches results by snapshot generation, projection and minor-group expansion.
/// Projection cannot mutate manuscript or runtime ownership.

// MARK: - 행 모델 (두 Projection 공용)

/// 그래프의 한 행 — 사건이 1급이고, 씬은 section marker, 회상·꿈은 bracket이다
/// (요구사항 §7 시각 우선순위: 사건 > topology > 씬 > 특수 서술 > 메타데이터).
package enum GraphRow: Identifiable {
    package struct SceneInfo {
        package var hash: String
        package var title: String?
        package var titleUserEdited: Bool
        /// 헤딩 경로 라벨 ("1부 › 3장 (2/5)").
        package var path: String
        /// 요약 — 목록에는 넣지 않고 tooltip으로만 (메타데이터 최소화).
        package var summary: String?
        package var type: SceneNarrativeType
        package var typeUserEdited: Bool
        package var start: Int
    }

    /// 씬 경계 — 가는 구분선 수준 (클릭 = 본문 이동, 메뉴 = 제목·유형 편집).
    case sceneMarker(SceneInfo)
    /// Narrative Traversal bracket — 회상·꿈·삽입 서사의 시작/복귀. **플롯
    /// branch가 아니다** (요구사항 §8) — 레인과 다른 시각 문법(bracket).
    case branchOpen(branch: NarrativeBranch)
    case branchClose(branch: NarrativeBranch)
    /// 씬 내부 서사 구간 bracket (요구사항 §8·§15) — 편집 메뉴 보존.
    case segmentBracket(segment: NarrativeSegment, sceneStart: Int, userEdited: Bool)
    /// 정본 사건 — 그래프 노드가 붙는 1급 행.
    case event(id: String, event: CanonicalEvent, start: Int)
    /// 같은 정본 사건의 재서술이 이 씬에 있다 — 관점 참조 (클릭 = 정본 선택).
    case perspectiveRef(id: String, canonicalKey: String, perspective: EventPerspective)
    /// 사소한 사건 묶음 (본줄기 소속 중요도 ≤2) — 접힌 채 시작.
    case minorGroup(id: String, events: [CanonicalEvent], start: Int, expanded: Bool)
    /// 씬 원문이 이해 상한을 넘어 잘린 구간.
    case truncated(id: String, total: Int, read: Int)
    /// 씬은 있는데 아직 사건·요약이 없는 상태.
    case pending(id: String)

    package var id: String {
        switch self {
        case .sceneMarker(let scene): "s-\(scene.hash)"
        case .branchOpen(let branch): "bo-\(branch.anchorHash)"
        case .branchClose(let branch): "bc-\(branch.anchorHash)"
        case .segmentBracket(let segment, _, _): "g-\(segment.persistentID)"
        case .event(let id, _, _): "e-\(id)"
        case .perspectiveRef(let id, _, _): "r-\(id)"
        case .minorGroup(let id, _, _, _): "m-\(id)"
        case .truncated(let id, _, _): "t-\(id)"
        case .pending(let id): "p-\(id)"
        }
    }

    /// 행 높이 — 사건이 크고 메타는 작다 (시각 우선순위).
    package var height: CGFloat {
        switch self {
        case .event: 26
        case .sceneMarker: 24
        case .minorGroup: 18
        case .branchOpen, .branchClose, .segmentBracket, .perspectiveRef,
            .truncated, .pending:
            16
        }
    }

    /// 그래프 노드가 붙는 사건 키 (event 행만).
    package var eventKey: String? {
        if case .event(_, let event, _) = self { return event.canonicalKey }
        return nil
    }

    /// 사소 판정 경계 — 이하이고 본줄기 소속이면 접힘 대상.
    package static let minorImportanceCap = 2

    // MARK: 흐름 Projection (담화 순서 — 씬 marker·traversal bracket 포함)

    package static func flowRows(
        from snapshot: KnowledgeSnapshot, expandedMinors: Set<String>
    ) -> [GraphRow] {
        // 정본 사건 → 첫 등장 씬, 재서술 관점 → 그 씬의 참조 행.
        var canonicalByScene: [String: [CanonicalEvent]] = [:]
        var refsByScene: [String: [(canonical: CanonicalEvent, perspective: EventPerspective)]] =
            [:]
        for event in snapshot.canonicalEvents {
            canonicalByScene[event.sceneHash, default: []].append(event)
            for perspective in event.perspectives where perspective.sceneHash != event.sceneHash {
                refsByScene[perspective.sceneHash, default: []].append((event, perspective))
            }
        }

        // 세그먼트 수 — 같은 헤딩 경로가 몇 조각으로 쪼개졌는지 ("1장 (3/14)").
        var segmentCounts: [[String]: Int] = [:]
        for scene in snapshot.outline.scenes {
            segmentCounts[scene.headingPath, default: 0] += 1
        }

        // 씬 인덱스 → 그 씬이 여는/닫는 traversal(브랜치).
        var branchOpenAt: [Int: NarrativeBranch] = [:]
        var branchCloseAt: [Int: NarrativeBranch] = [:]
        for branch in snapshot.branches {
            branchOpenAt[branch.sceneRange.lowerBound] = branch
            branchCloseAt[branch.sceneRange.upperBound - 1] = branch
        }

        var rows: [GraphRow] = []
        for (index, scene) in snapshot.outline.scenes.enumerated() {
            if let branch = branchOpenAt[index] {
                rows.append(.branchOpen(branch: branch))
            }

            var path = scene.headingPath.filter { !$0.isEmpty }.joined(separator: " › ")
            if path.isEmpty { path = "서두" }
            if let count = segmentCounts[scene.headingPath], count > 1 {
                path += " (\(scene.segmentIndex + 1)/\(count))"
            }
            let meta = snapshot.sceneMetaByHash[scene.contentHash]
            let events = canonicalByScene[scene.contentHash] ?? []
            let refs = refsByScene[scene.contentHash] ?? []
            rows.append(
                .sceneMarker(
                    SceneInfo(
                        hash: scene.contentHash,
                        title: meta?.title,
                        titleUserEdited: meta?.titleUserEdited ?? false,
                        path: path,
                        summary: snapshot.summariesByHash[scene.contentHash],
                        type: meta?.type ?? .present,
                        typeUserEdited: meta?.typeUserEdited ?? false,
                        start: scene.utf16Range.lowerBound)))

            // 씬 내부 traversal 구간 — bracket (플롯 branch가 아니다).
            for segment in snapshot.segmentsByScene[scene.contentHash] ?? [] {
                let edited = [
                    NarrativeOverride.Kind.segmentLayer, .segmentPOV, .segmentNarrator,
                    .segmentFocal, .segmentChrono, .segmentReliability, .segmentSubject,
                    .segmentStart, .segmentEnd,
                ].contains { snapshot.overrides.value($0, key: segment.persistentID) != nil }
                rows.append(
                    .segmentBracket(
                        segment: segment,
                        sceneStart: scene.utf16Range.lowerBound,
                        userEdited: edited))
            }
            if scene.utf16Range.count > DocumentOutline.maxSegmentUTF16 {
                rows.append(
                    .truncated(
                        id: scene.contentHash, total: scene.utf16Range.count,
                        read: DocumentOutline.maxSegmentUTF16))
            }

            // 사건 — 사소(중요도 ≤2)라도 본줄기 밖 플롯에 속하면 접지 않는다
            // (topology에 구멍이 나면 안 된다).
            let start = scene.utf16Range.lowerBound
            var charted: [CanonicalEvent] = []
            var minor: [CanonicalEvent] = []
            for event in events {
                let threadIDs = snapshot.threadIDsByEvent[event.canonicalKey] ?? []
                let mainOnly = threadIDs.allSatisfy { $0 == PlotThread.mainID }
                if event.importance <= minorImportanceCap, mainOnly {
                    minor.append(event)
                } else {
                    charted.append(event)
                }
            }
            if minor.count == 1 {
                charted.append(minor[0])
                minor = []
            }
            for (offset, event) in charted.enumerated() {
                rows.append(
                    .event(id: "\(scene.contentHash)-\(offset)", event: event, start: start))
            }
            if !minor.isEmpty {
                let groupID = "\(scene.contentHash)-minor"
                let expanded = expandedMinors.contains(groupID)
                rows.append(
                    .minorGroup(id: groupID, events: minor, start: start, expanded: expanded))
                if expanded {
                    for (offset, event) in minor.enumerated() {
                        rows.append(
                            .event(
                                id: "\(scene.contentHash)-minor\(offset)", event: event,
                                start: start))
                    }
                }
            }
            for (offset, ref) in refs.enumerated() {
                rows.append(
                    .perspectiveRef(
                        id: "\(scene.contentHash)-ref\(offset)",
                        canonicalKey: ref.canonical.canonicalKey,
                        perspective: ref.perspective))
            }
            if events.isEmpty, refs.isEmpty,
                snapshot.summariesByHash[scene.contentHash] == nil
            {
                rows.append(.pending(id: "\(scene.contentHash)-\(index)"))
            }

            if let branch = branchCloseAt[index] {
                rows.append(.branchClose(branch: branch))
            }
        }
        return rows
    }

    // MARK: 시간순 Projection (ChronoOrder 해석 — traversal 제거)

    /// 사건만 작중 발생 순서로 — 회상 진입·복귀는 실제 사건이 아니므로 없다.
    /// 같은 정본 사건·같은 스레드 identity를 순서만 바꿔 투영한다 (요구사항 §6).
    package static func chronoRows(from snapshot: KnowledgeSnapshot) -> [GraphRow] {
        let byKey = Dictionary(
            uniqueKeysWithValues: snapshot.canonicalEvents.map { ($0.canonicalKey, $0) })
        let startByScene = snapshot.outline.unambiguousSceneIndicesByHash.mapValues {
            snapshot.outline.scenes[$0].utf16Range.lowerBound
        }
        return snapshot.eventChronoOrder.enumerated().compactMap { offset, key in
            guard let event = byKey[key], let start = startByScene[event.sceneHash] else { return nil }
            return .event(
                id: "c-\(offset)", event: event,
                start: start)
        }
    }
}

// MARK: - 레이아웃 엔진 (요구사항 §11 — 분석 결과의 결정적 시각화)

/// PlotThread → 레인 배치. **레이아웃이 branch를 만들지 않는다** — 스레드
/// 데이터(멤버십·해결)를 그대로 배치할 뿐이다.
///
/// 배치 원칙 (요구사항 §11):
/// - 스레드 순서는 스냅샷 순서(본줄기 → 첫 멤버 담화 위치) — 본줄기는 항상
///   슬롯 0, 장기 스레드는 문서가 자라도 슬롯이 유지된다 (결정적·안정적).
/// - 스레드는 첫 멤버 행에서 열리고, **해결 행에서만** 닫힌다. DORMANT는
///   닫히지 않는다 — 몇 장 뒤에 돌아와도 같은 레인이다 (요구사항 §3).
/// - 해결된 스레드의 슬롯은 회수돼 뒤 스레드가 재사용한다 (겹침 없는 최저 슬롯).
/// - 여러 스레드가 공유하는 사건 = junction — 참여 레인이 노드로 모인다.
package struct ThreadGraphLayout {
    package struct Lane {
        package var thread: ResolvedPlotThread
        package var slot: Int
        /// 첫 멤버 행 (레인 열림).
        package var openRow: Int
        /// 해결 사건 행 — 여기서 레인이 끝난다 (merge). nil = 열린 채 계속.
        package var resolveRow: Int?
        /// 멤버 사건 행들 (오름차순) — 마지막 멤버 뒤 구간은 dormant 꼬리.
        package var memberRows: [Int]
    }

    package struct Node {
        package var key: String
        package var row: Int
        /// 노드가 놓이는 슬롯 — 참여 레인 중 최소 슬롯 (본줄기 우선).
        package var slot: Int
        /// 참여 레인 슬롯 전부 (오름차순).
        package var laneSlots: [Int]
        /// 이 사건에서 **열리는** 레인 슬롯 (branch-out 곡선의 근거).
        package var opensSlots: [Int]
        /// 이 사건에서 **해결되는** 레인 슬롯 (merge-in 곡선의 근거).
        package var resolvesSlots: [Int]
        package var isJunction: Bool { laneSlots.count >= 2 }
    }

    package var lanes: [Lane]
    /// 사건 키 → 노드.
    package var nodes: [String: Node]
    package var slotCount: Int

    package static func compute(rows: [GraphRow], threads: [ResolvedPlotThread]) -> ThreadGraphLayout {
        // 사건 키 → 행 (첫 등장 행 — 같은 키가 두 번 나올 일은 없지만 방어).
        var rowByKey: [String: Int] = [:]
        for (row, graphRow) in rows.enumerated() {
            if let key = graphRow.eventKey, rowByKey[key] == nil {
                rowByKey[key] = row
            }
        }
        let lastRow = max(rows.count - 1, 0)

        // 레인 배치 — 스냅샷 스레드 순서대로 겹침 없는 최저 슬롯.
        var lanes: [Lane] = []
        var spans: [(slot: Int, open: Int, close: Int)] = []
        for thread in threads {
            let memberRows = thread.memberKeys.compactMap { rowByKey[$0] }.sorted()
            guard let open = memberRows.first else { continue }
            let resolveRow = thread.resolvedAtKey.flatMap { rowByKey[$0] }
            let close = resolveRow ?? lastRow
            var slot = 0
            while spans.contains(where: {
                $0.slot == slot && $0.open <= close && open <= $0.close
            }) {
                slot += 1
            }
            spans.append((slot, open, close))
            lanes.append(
                Lane(
                    thread: thread, slot: slot, openRow: open,
                    resolveRow: resolveRow, memberRows: memberRows))
        }

        // Index actual memberships once instead of scanning every lane for each node.
        // Sets retain the previous single participation for duplicate member keys.
        var laneIndicesByEvent: [String: [Int]] = [:]
        for (index, lane) in lanes.enumerated() {
            for key in Set(lane.thread.memberKeys) where rowByKey[key] != nil {
                laneIndicesByEvent[key, default: []].append(index)
            }
        }

        // Preserve lane order for open/resolve curves and the minimum participating slot.
        var nodes: [String: Node] = [:]
        for (key, row) in rowByKey {
            var laneSlots: [Int] = []
            var opens: [Int] = []
            var resolves: [Int] = []
            for index in laneIndicesByEvent[key] ?? [] {
                let lane = lanes[index]
                laneSlots.append(lane.slot)
                if lane.openRow == row { opens.append(lane.slot) }
                if lane.resolveRow == row { resolves.append(lane.slot) }
            }
            laneSlots.sort()
            let slot = laneSlots.first ?? 0
            nodes[key] = Node(
                key: key, row: row, slot: slot, laneSlots: laneSlots,
                opensSlots: opens.filter { $0 != slot },
                resolvesSlots: resolves.filter { $0 != slot })
        }

        return ThreadGraphLayout(
            lanes: lanes, nodes: nodes,
            slotCount: (lanes.map(\.slot).max() ?? 0) + 1)
    }
}

// MARK: - 행 기하 (중심 y · 전체 높이)

/// 행 높이의 누적을 **한 번에** 접은 값.
///
/// 예전엔 `rowCenters`·`totalHeight`가 각각 O(행) computed property라 한 번의
/// body 패스에서 네 번(캔버스 프레임·바깥 프레임·drawLanes·본문) 다시 계산됐다.
/// 행 높이는 데이터에서 정해지므로(`GraphRow.height`) 한 번 접으면 그만이다.
package struct GraphRowGeometry {
    package var centers: [CGFloat]
    package var totalHeight: CGFloat

    package init(rows: [GraphRow]) {
        var centers: [CGFloat] = []
        centers.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for row in rows {
            centers.append(y + row.height / 2)
            y += row.height
        }
        self.centers = centers
        self.totalHeight = y
    }
}
