import SwiftUI

/// 서사 (Narrative Graph, v6) — 소설의 **서사 구조 자체**를 git graph의 시각
/// 언어로 표현하는 통합 서사 탐색 화면 (PLAN §6.6).
///
/// 핵심 원칙:
/// - **Branch = PlotThread.** 인물·POV·씬·장·회상이 아니라 "하나의 지속적인
///   문제·목표·갈등"이 레인 하나다. 그래프의 topology가 곧 작품의 서사 지문 —
///   직선 소설은 직선으로, 군상극은 병렬 레인으로 나온다.
/// - **레이아웃은 시각화만 한다.** 분석(PlotThread 추론·멤버십)이 topology를
///   만들고, 레이아웃은 그것을 결정적으로 배치한다 (요구사항 §11).
/// - **회상은 branch가 아니다.** 회상·꿈·삽입 서사는 Narrative Traversal —
///   레인이 아니라 bracket 표시로 구분한다 (요구사항 §8).
/// - **흐름/시간순은 같은 그래프의 두 Projection.** 같은 정본 사건·같은
///   PlotThread identity를 담화 순서/작중 시간순으로 다르게 배열할 뿐이다.
/// - **Progressive Disclosure.** 기본은 사건 제목 + topology. 상세(관점·인과·
///   델타·신뢰)는 선택 시 패널에서. 경고·충돌·복선은 "검토 필요" 접이 영역에.
///
/// 왜 필요한가: CLAUDE.md §1-5 "기억은 사용자의 것" — 씬 제목·유형, 구간,
/// 사건 중요도, 플롯 제목·상태·멤버십, 충돌 판정, 복선, 시간 관계를 모두
/// 여기서 보고 고칠 수 있다.
struct NarrativeView: View {
    @ObservedObject var indexer: BackgroundIndexer
    @ObservedObject var store: EntryStore
    let theme: PurloryTheme
    /// 사이드바 섹션에 임베드됐는가 — 고정 폭·높이 상한을 풀고 공간을 채운다.
    var embedded = false

    @Environment(\.colorScheme) private var colorScheme

    /// Projection — 같은 정본 사건·플롯을 담화 순서/작중 시간순으로 투영한다.
    enum Projection: String, CaseIterable {
        case flow = "흐름"
        case chrono = "시간순"
    }
    @State private var projection: Projection = .flow

    /// 선택된 정본 사건 — 상세 패널 (Progressive Disclosure의 축).
    @State private var selectedEventKey: String?
    /// 선택된 플롯 스레드 — 그 레인·사건 강조, 나머지 약화.
    ///
    /// **선택은 클릭으로만 바뀐다** — 다른 플롯을 누르면 곧바로 그리로 옮겨가고,
    /// 같은 플롯을 다시 누르면 풀린다 (`toggleThread`). 강조 범위가 포인터를
    /// 따라 흔들리면 읽던 맥락을 잃지만, 비교하려고 옆 플롯을 누르는 것은
    /// 명백한 의도다 — 먼저 해제하라고 요구할 이유가 없다.
    ///
    /// hover는 여기에 **관여하지 않는다.** 예전에는 hover가 강조 스레드를
    /// 정해서, 스크롤로 포인터 아래를 지나가는 것만으로 최상위 body가 무효화되고
    /// 행·레이아웃이 통째로 다시 계산됐다 (프레임당 3.7ms@200씬).
    @State private var selectedThreadID: String?
    /// 인물 필터 — 그 인물이 참여한 사건만 강조.
    @State private var selectedCharacterID: UUID?
    /// 검토 필요 영역 펼침 — 기본 접힘 (메인 사건 흐름을 방해하지 않는다).
    @State private var reviewExpanded = false
    /// 펼쳐진 사소 사건 묶음.
    @State private var expandedMinors: Set<String> = []

    /// 제목 수정 중인 씬 해시 (인라인 편집).
    @State private var editingSceneHash: String?
    @State private var draftTitle = ""
    /// 구간 경계 수정 (요구사항 §15) — (구간 ID, 시작 경계인가).
    @State private var editingBoundary: (id: String, isStart: Bool)?
    @State private var draftBoundary = ""
    /// 플롯 이름 수정 중인 스레드 ID.
    @State private var editingThreadID: String?
    @State private var draftThreadTitle = ""

    /// 그래프 행·레이아웃 캐시 (#48) — 키 입력마다 store가 objectWillChange를
    /// 울려도 스냅샷(세대)·projection·사소 펼침이 그대로면 행 재구축 O(사건)과
    /// 레인 배치를 다시 하지 않는다. 세대는 BackgroundIndexer.snapshotGeneration —
    /// 스냅샷 전체 동등 비교 대신 정수 비교로 무효화를 판정한다.
    private struct GraphCacheKey: Equatable {
        var generation: Int
        var projection: Projection
        var expandedMinors: Set<String>
    }
    private struct GraphCache {
        var key: GraphCacheKey
        var rows: [GraphRow]
        var layout: ThreadGraphLayout
    }
    @State private var graphCache: GraphCache?

    /// 캐시된 행·레이아웃 — 키가 같으면 전 패스의 결과를 재사용한다.
    private func cachedGraph(
        _ snapshot: KnowledgeSnapshot
    ) -> (rows: [GraphRow], layout: ThreadGraphLayout) {
        let key = GraphCacheKey(
            generation: indexer.snapshotGeneration,
            projection: projection,
            expandedMinors: expandedMinors)
        if let cache = graphCache, cache.key == key { return (cache.rows, cache.layout) }
        let rows =
            projection == .flow
            ? GraphRow.flowRows(from: snapshot, expandedMinors: expandedMinors)
            : GraphRow.chronoRows(from: snapshot)
        let layout = ThreadGraphLayout.compute(rows: rows, threads: snapshot.plotThreads)
        graphCache = GraphCache(key: key, rows: rows, layout: layout)
        return (rows, layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let snapshot = liveSnapshot {
                threadLegend(snapshot)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        reviewSection(snapshot)
                        graphArea(snapshot)
                        metricsFooter
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: embedded ? .infinity : 380)
                if let key = selectedEventKey,
                    let event = snapshot.canonicalEvents.first(where: { $0.canonicalKey == key })
                {
                    Divider()
                    NarrativeEventDetail(
                        event: event, snapshot: snapshot, theme: theme,
                        characterNames: characterNames,
                        dark: colorScheme == .dark,
                        onJump: { jump(quote: $0) },
                        onJumpOffset: { jump(toUTF16: $0) },
                        onSelect: { selectedEventKey = $0 },
                        onSetImportance: { value in
                            store.setNarrativeOverride(
                                NarrativeOverride(
                                    kind: .eventImportance, key: event.canonicalKey,
                                    value: String(value)),
                                in: store.activeID)
                        },
                        onSetChrono: { otherKey, relation in
                            setChronoEdge(a: event.canonicalKey, b: otherKey, relation: relation)
                        },
                        onSetMembership: { threadID, value in
                            store.setNarrativeOverride(
                                NarrativeOverride(
                                    kind: .threadMembership,
                                    key: "\(threadID)|\(event.canonicalKey)",
                                    value: value),
                                in: store.activeID)
                        },
                        onClose: { selectedEventKey = nil })
                }
            } else {
                placeholder
                if embedded { Spacer(minLength: 0) }
            }
        }
        .padding(14)
        // 적응형 폭 (#30) — 그래프 좌표는 컨테이너 폭을 따라가므로 고정 폭이
        // 아니라 범위로 둔다 (레인 x좌표 계산은 slot 기반, 폭 무관).
        .frame(
            minWidth: embedded ? nil : 380,
            idealWidth: embedded ? nil : 480,
            maxWidth: embedded ? nil : 600)
        .alert(
            editingBoundary?.isStart == true ? "구간 시작 경계 수정" : "구간 끝(복귀) 경계 수정",
            isPresented: Binding(
                get: { editingBoundary != nil },
                set: { if !$0 { editingBoundary = nil } }
            )
        ) {
            TextField("경계 문장을 원문 그대로", text: $draftBoundary)
            Button("적용") {
                if let editing = editingBoundary {
                    let trimmed = draftBoundary.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        store.setNarrativeOverride(
                            NarrativeOverride(
                                kind: editing.isStart ? .segmentStart : .segmentEnd,
                                key: editing.id, value: trimmed),
                            in: store.activeID)
                    }
                }
                editingBoundary = nil
            }
            Button("취소", role: .cancel) { editingBoundary = nil }
        } message: {
            Text("본문에서 경계가 될 문장을 복사해 붙여 넣으세요. 원문에 있는 문장만 경계가 돼요.")
        }
        .alert(
            "플롯 이름 수정",
            isPresented: Binding(
                get: { editingThreadID != nil },
                set: { if !$0 { editingThreadID = nil } }
            )
        ) {
            TextField("플롯 이름", text: $draftThreadTitle)
            Button("적용") {
                if let id = editingThreadID {
                    let trimmed = draftThreadTitle.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        store.setNarrativeOverride(
                            NarrativeOverride(kind: .threadTitle, key: id, value: trimmed),
                            in: store.activeID)
                    }
                }
                editingThreadID = nil
            }
            Button("취소", role: .cancel) { editingThreadID = nil }
        }
    }

    /// 델타·메뉴용 인물 id → 이름.
    /// 패스마다 사전을 다시 만들지 않게 카드·문서 키로 캐시한다 (#48/#50) —
    /// 타이핑은 store를 무효화하지만 카드 배열은 그대로다.
    @State private var namesCache: (
        entryID: UUID?, cards: [CharacterCard], names: [UUID: String]
    )?
    private var characterNames: [UUID: String] {
        let entry = store.activeEntry
        if let cache = namesCache,
            cache.entryID == entry?.id, cache.cards == (entry?.characters ?? [])
        {
            return cache.names
        }
        let cards = entry?.characters ?? []
        let names = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.name) })
        namesCache = (entry?.id, cards, names)
        return names
    }

    /// 활성 문서의 스냅샷만 — 문서를 막 바꾸면 인덱서 스냅샷이 이전 문서 것일
    /// 수 있다. 남의 작품 그래프를 보여주느니 비워 둔다.
    private var liveSnapshot: KnowledgeSnapshot? {
        guard let snapshot = indexer.snapshot,
            snapshot.entryID == store.activeEntry?.id
        else { return nil }
        return snapshot
    }

    // MARK: - 헤더

    /// 헤더 두 줄 — 1행: 제목·수치 + 액션(지금 읽기), 2행: 보기 컨트롤
    /// (인물 필터·Projection). 좁은 사이드바에서 컨트롤 넷이 한 줄에 몰려
    /// 압축·잘림이 생기던 것을 의미 단위로 나눈다 — 액션과 보기 방식은 다른
    /// 종류의 컨트롤이다. 헤더 폭은 그래프 좌표 계산과 무관하다 (독립 레이아웃).
    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.novelC)
                Text("서사")
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                if let snapshot = liveSnapshot {
                    Text("사건 \(snapshot.canonicalEvents.count) · 플롯 \(snapshot.plotThreads.count)")
                        .font(PurloryFonts.monoUI(10))
                        .foregroundStyle(theme.ink3C)
                }
                Spacer()
                // 수동 이해 트리거 — 증분 + 전체 다시 읽기.
                ManualIndexButton(indexer: indexer, theme: theme)
            }
            if liveSnapshot != nil {
                HStack(spacing: 10) {
                    characterFilterMenu
                    Picker("", selection: $projection) {
                        ForEach(Projection.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 110)
                    .help("흐름 = 본문에 등장하는 순서 · 시간순 = 작중 실제 발생 순서 (확실한 시간 간선만 반영)")
                    Spacer()
                }
            }
        }
    }

    private var placeholder: some View {
        Text(
            store.activeEntry?.resolvedKind == .novel
                ? "아직 이해한 내용이 없어요. 타이핑을 멈추면 백그라운드가 장면을 읽기 시작해요."
                : "소설 종류의 문서에서만 서사를 만들어요."
        )
        .purloryUIFont(11)
        .foregroundStyle(theme.ink3C)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    /// 인물 필터 — 칩 대신 콤팩트 메뉴 (레인은 플롯의 것, 인물은 필터).
    @ViewBuilder private var characterFilterMenu: some View {
        if let snapshot = liveSnapshot {
            let participating = snapshot.characters.filter { card in
                snapshot.canonicalEvents.contains { $0.participants.contains(card.id) }
            }
            if !participating.isEmpty {
                Menu {
                    Button("전체") { selectedCharacterID = nil }
                    Divider()
                    ForEach(participating) { card in
                        Button {
                            selectedCharacterID =
                                selectedCharacterID == card.id ? nil : card.id
                        } label: {
                            if selectedCharacterID == card.id {
                                Label(card.name, systemImage: "checkmark")
                            } else {
                                Text(card.name)
                            }
                        }
                    }
                } label: {
                    let name = participating.first { $0.id == selectedCharacterID }?.name
                    Label(name ?? "인물", systemImage: "person")
                        .purloryUIFont(10.5)
                        .foregroundStyle(name == nil ? theme.ink3C : theme.novelC)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("인물 필터 — 그 인물이 참여한 사건만 강조")
            }
        }
    }

    // MARK: - 플롯 범례 (스레드 칩 — 선택·이름·상태 편집)

    @ViewBuilder private func threadLegend(_ snapshot: KnowledgeSnapshot) -> some View {
        // 본줄기 하나뿐이면 범례가 소음이다 — 직선 소설은 범례 없이 직선만.
        let threads = snapshot.plotThreads
        if threads.count >= 2 || threads.contains(where: { !$0.isMain }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(threads) { thread in
                        threadChip(thread)
                    }
                }
            }
        }
    }

    @ViewBuilder private func threadChip(_ thread: ResolvedPlotThread) -> some View {
        let color = threadColor(thread)
        let selected = selectedThreadID == thread.id
        Button {
            toggleThread(thread.id)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(thread.title)
                    .purloryUIFont(10, .medium)
                    .foregroundStyle(selected ? theme.inkC : theme.ink2C)
                    .lineLimit(1)
                Text(thread.status.rawValue)
                    .purloryUIFont(8.5)
                    .foregroundStyle(
                        thread.status == .resolved ? theme.ink3C : color)
                if thread.userEdited { UserEditedMark(theme: theme) }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? color.opacity(0.18) : theme.chipC))
            // 색 비의존 선택 표시 — 테두리 링 + ✓ 마크 (색 약화만이 아닌 형태 신호, #21).
            .overlay(
                Capsule().strokeBorder(
                    selected ? theme.inkC : .clear,
                    style: StrokeStyle(lineWidth: selected ? 1.5 : 0))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(
            thread.summary.isEmpty
                ? (selected ? "다시 클릭: 강조 해제" : "클릭: 이 플롯의 경로만 강조")
                : thread.summary)
        .accessibilityLabel(Text("플롯 \(thread.title)"))
        .accessibilityValue(Text([thread.status.rawValue, selected ? "강조 중" : nil]
            .compactMap { $0 }.joined(separator: " · ")))
        .accessibilityHint(Text(thread.summary.isEmpty ? "클릭으로 이 플롯만 강조" : thread.summary))
        .contextMenu {
            Button("이름 바꾸기…") {
                draftThreadTitle = thread.title
                editingThreadID = thread.id
            }
            if !thread.isMain {
                Menu("상태") {
                    ForEach(ThreadStatus.allCases, id: \.rawValue) { status in
                        Button {
                            store.setNarrativeOverride(
                                NarrativeOverride(
                                    kind: .threadStatus, key: thread.id,
                                    value: status.rawValue),
                                in: store.activeID)
                        } label: {
                            if thread.status == status {
                                Label(status.rawValue, systemImage: "checkmark")
                            } else {
                                Text(status.rawValue)
                            }
                        }
                    }
                }
            }
            if thread.userEdited {
                Divider()
                Button("AI 추론으로 되돌리기") {
                    store.removeNarrativeOverride(
                        kind: .threadTitle, key: thread.id, in: store.activeID)
                    store.removeNarrativeOverride(
                        kind: .threadStatus, key: thread.id, in: store.activeID)
                }
            }
        }
    }

    /// 스레드의 안정 색 — 본줄기는 액센트, 나머지는 stableID 시드.
    private func threadColor(_ thread: ResolvedPlotThread) -> Color {
        thread.isMain
            ? theme.novelC
            : FlowPalette.color(
                seed: thread.colorSeed, theme: theme, dark: colorScheme == .dark)
    }

    // MARK: - 그래프 영역 (두 Projection 공용)

    @ViewBuilder private func graphArea(_ snapshot: KnowledgeSnapshot) -> some View {
        let (rows, layout) = cachedGraph(snapshot)
        if rows.isEmpty {
            Text("사건이 아직 없어요. 「지금 읽기」를 누르면 사건이 추출돼요.")
                .purloryUIFont(11)
                .foregroundStyle(theme.ink3C)
                .padding(.vertical, 8)
        } else {
            // 시간순 안내문은 상시 노출 대신 Projection 피커의 help로 —
            // 보조 설명이 사건 목록보다 먼저 시선을 끌지 않는다.
            ThreadGraphArea(
                rows: rows,
                layout: layout,
                snapshot: snapshot,
                theme: theme,
                dark: colorScheme == .dark,
                selectedEventKey: selectedEventKey,
                selectedThreadID: selectedThreadID,
                emphasizedThreadIDs: emphasizedThreadIDs,
                dimmedKeys: dimmedKeys(snapshot),
                isEditingTitle: { editingSceneHash == $0 },
                draftTitle: $draftTitle,
                characterNames: characterNames,
                onSelectEvent: { key in
                    selectedEventKey = selectedEventKey == key ? nil : key
                },
                // 노드·레인 클릭 = 그 레인의 플롯으로 강조를 옮긴다.
                onSelectThread: { toggleThread($0) },
                onToggleMinor: { id in
                    if expandedMinors.contains(id) {
                        expandedMinors.remove(id)
                    } else {
                        expandedMinors.insert(id)
                    }
                },
                onJump: { jump(toUTF16: $0) },
                onJumpQuote: { jump(quote: $0) },
                onJumpEvidence: { event, start in
                    jumpToEvidence(of: event, sceneStart: start)
                },
                onEditTitle: { hash, current in
                    draftTitle = current
                    editingSceneHash = hash
                },
                onCommitTitle: { hash, start in
                    let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
                    // 빈 제목은 조용히 버리지 않는다 — 편집기를 열어 둬 원인이
                    // 보이게 한다 (이슈 #37: silent guard 실패 금지).
                    guard !trimmed.isEmpty else { return }
                    editingSceneHash = nil
                    setSceneOverride(.sceneTitle, sceneHash: hash, start: start, value: trimmed)
                },
                onSetSceneType: { hash, start, type in
                    setSceneOverride(
                        .sceneType, sceneHash: hash, start: start, value: type.rawValue)
                },
                onResetScene: { hash in
                    store.removeNarrativeOverride(
                        kind: .sceneTitle, key: hash, in: store.activeID)
                    store.removeNarrativeOverride(
                        kind: .sceneType, key: hash, in: store.activeID)
                },
                onSetImportance: { key, value in
                    store.setNarrativeOverride(
                        NarrativeOverride(
                            kind: .eventImportance, key: key, value: String(value)),
                        in: store.activeID)
                },
                onRenameBranch: { branch, name in
                    setSceneOverride(
                        .branchName, sceneHash: branch.anchorHash,
                        start: branchStart(branch, snapshot), value: name)
                },
                onSetBranchChrono: { branch, chrono in
                    setSceneOverride(
                        .branchChrono, sceneHash: branch.anchorHash,
                        start: branchStart(branch, snapshot), value: chrono.rawValue)
                },
                onMergeBranch: { branch in
                    // 브랜치 해제 = 구간 씬 전부를 '현재'로.
                    for index in branch.sceneRange {
                        let scene = snapshot.outline.scenes[index]
                        setSceneOverride(
                            .sceneType, sceneHash: scene.contentHash,
                            start: scene.utf16Range.lowerBound,
                            value: SceneNarrativeType.present.rawValue)
                    }
                },
                onSegmentOverride: { id, kind, value in
                    store.setNarrativeOverride(
                        NarrativeOverride(kind: kind, key: id, value: value),
                        in: store.activeID)
                },
                onEditSegmentBoundary: { id, isStart, current in
                    draftBoundary = current
                    editingBoundary = (id, isStart)
                })
        }
    }

    /// 강조할 스레드 — **선택된 플롯 하나뿐**이다 (nil = 전부 보통).
    /// hover는 보지 않는다: 가시성·필터링·연결선 표시는 선택에만 반응한다.
    private var emphasizedThreadIDs: Set<String>? {
        selectedThreadID.map { [$0] }
    }

    /// 플롯 선택 토글 — 다른 플롯을 누르면 그리로 전환, 같은 것이면 해제.
    private func toggleThread(_ id: String) {
        selectedThreadID = Self.nextSelection(current: selectedThreadID, tapped: id)
    }

    /// 선택 전환 규칙 (순수 함수 — 검증 가능하게 분리).
    ///
    /// 누른 것이 이미 선택돼 있으면 해제하고, 아니면 누른 것으로 **바로
    /// 옮겨간다**. 전환하려고 이전 선택을 먼저 풀게 하면, 플롯을 갈아 보며
    /// 읽는 흐름이 클릭마다 두 번씩 끊긴다.
    nonisolated static func nextSelection(current: String?, tapped: String) -> String? {
        current == tapped ? nil : tapped
    }

    /// 인물 필터로 흐려질 정본 사건 키 집합 — 필터 없으면 nil.
    /// 선택·세대가 같으면 전 패스 결과를 재사용한다 (#48).
    private func dimmedKeys(_ snapshot: KnowledgeSnapshot) -> Set<String>? {
        guard let characterID = selectedCharacterID else { return nil }
        if let cached = dimmedCache, cached.generation == indexer.snapshotGeneration,
            cached.characterID == characterID
        {
            return cached.keys
        }
        let keys = Set(
            snapshot.canonicalEvents
                .filter { !$0.participants.contains(characterID) }
                .map(\.canonicalKey))
        dimmedCache = (
            generation: indexer.snapshotGeneration, characterID: characterID, keys: keys)
        return keys
    }

    @State private var dimmedCache: (
        generation: Int, characterID: UUID, keys: Set<String>
    )?

    private func branchStart(_ branch: NarrativeBranch, _ snapshot: KnowledgeSnapshot) -> Int {
        snapshot.outline.scenes[branch.sceneRange.lowerBound].utf16Range.lowerBound
    }

    // MARK: - 본문 이동 (M7 점프 + 근거 점프)

    /// 본문 위치 클릭 → 에디터 이동. 위치를 직접 넘기지 않고 **그 자리의 본문
    /// 스니펫을 검색어로** 넘긴다 — 지식의 오프셋은 마크다운 좌표, 에디터
    /// 스토리지는 렌더된 텍스트라 좌표가 어긋날 수 있다 (requestSearchJump 통로).
    private func jump(toUTF16 offset: Int) {
        guard let body = store.activeEntry?.body,
            let snippet = Self.jumpSnippet(in: body, atUTF16: offset)
        else { return }
        store.requestSearchJump(store.activeID, query: snippet)
    }

    /// 근거 인용으로 이동 — exact가 사라졌으면 재앵커 사다리 (요구사항 §28).
    private func jump(quote: String) {
        let query = store.activeEntry.flatMap {
            SourceAnchor.resilientQuery(for: quote, in: $0.body)
        } ?? quote
        store.requestSearchJump(store.activeID, query: query)
    }

    /// 사건의 근거로 이동 — 인용이 있으면 인용(직접 근거), 없으면 씬 시작(추론).
    private func jumpToEvidence(of event: CanonicalEvent, sceneStart: Int) {
        if let quote = event.quote {
            jump(quote: quote)
        } else {
            jump(toUTF16: sceneStart)
        }
    }

    /// 오프셋 자리에서 검색 가능한 스니펫을 뽑는다 — 마크다운 마커·공백을
    /// 건너뛰고 산문 한 토막(≤40 UTF-16)을 취한다.
    /// 본체는 SourceAnchor로 통합 (#61 PR1) — 기존 호출부·테스트 호환용 위임.
    nonisolated static func jumpSnippet(in body: String, atUTF16 offset: Int) -> String? {
        SourceAnchor.jumpSnippet(in: body, atUTF16: offset)
    }

    // MARK: - 오버라이드 저장 (사용자 수정 → entries.json)

    /// 씬 키 오버라이드 저장 — 재앵커용 스니펫(씬 첫머리 산문)을 함께 담는다.
    private func setSceneOverride(
        _ kind: NarrativeOverride.Kind, sceneHash: String, start: Int, value: String
    ) {
        let anchor: String?
        if let body = store.activeEntry?.body, !body.isEmpty {
            anchor = Self.jumpSnippet(in: body, atUTF16: start)
        } else {
            anchor = nil
        }
        store.setNarrativeOverride(
            NarrativeOverride(kind: kind, key: sceneHash, value: value, anchor: anchor),
            in: store.activeID)
    }

    /// 시간 간선 오버라이드 — "a가 b보다 relation" (요구사항 §29).
    private func setChronoEdge(a: String, b: String, relation: ChronoRelation) {
        store.setNarrativeOverride(
            NarrativeOverride(kind: .chronoEdge, key: "\(a)|\(b)", value: relation.rawValue),
            in: store.activeID)
    }

    // MARK: - 검토 필요 영역 (경고·시간 모순 — 접이)

    /// 메인 사건 흐름을 방해하지 않도록 검토 항목을 한 영역에 접어 둔다.
    /// 배지 수 = 아직 사용자 답을 기다리는 항목 수.
    @ViewBuilder private func reviewSection(_ snapshot: KnowledgeSnapshot) -> some View {
        let warnings = indexer.snapshot?.entryID == store.activeID ? indexer.warnings : []
        let hasContent = !warnings.isEmpty
            || !snapshot.chronoConflicts.isEmpty || !snapshot.staleOverrides.isEmpty
        if hasContent {
            let attention = warnings.count + snapshot.chronoConflicts.count
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    reviewExpanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: reviewExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.ink3C)
                        Text("검토 필요")
                            .purloryUIFont(11, .semibold)
                            .foregroundStyle(theme.inkC)
                        if attention > 0 {
                            Text("\(attention)")
                                .font(PurloryFonts.monoUI(9))
                                .foregroundStyle(theme.novelC)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.novelBgC))
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("일관성 경고 · 시간 관계 모순")

                if reviewExpanded {
                    warningsList(warnings)
                    staleNotice(snapshot)
                    chronoConflictList(snapshot)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: 일관성 경고 (M7 — 결정적 검사)

    @ViewBuilder private func warningsList(_ warnings: [ConsistencyWarning]) -> some View {
        ForEach(warnings) { warning in
            Button {
                guard let body = store.activeEntry?.body,
                    warning.sourcePosition(in: body, documentID: .init(rawValue: store.activeID)) != nil,
                    let quote = warning.evidence.last?.quote else { return }
                store.requestSearchJump(store.activeID, query: quote)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.novelC)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(warning.kind.rawValue)
                            .purloryUIFont(10.5, .semibold)
                            .foregroundStyle(theme.inkC)
                        Text(warning.message)
                            .purloryUIFont(10.5)
                            .foregroundStyle(theme.ink2C)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PurloryRadius.sm, style: .continuous)
                        .fill(theme.novelBgC))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("본문의 해당 위치로 이동")
        }
    }

    /// 근거를 잃은 사용자 수정 알림 — 조용히 지우지 않는다 (요구사항 §9).
    @ViewBuilder private func staleNotice(_ snapshot: KnowledgeSnapshot) -> some View {
        if !snapshot.staleOverrides.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.ink3C)
                Text("직접 수정한 항목 \(snapshot.staleOverrides.count)개의 원문 근거가 사라졌어요 — 원문이 돌아오면 다시 적용돼요.")
                    .purloryUIFont(10)
                    .foregroundStyle(theme.ink3C)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 시간 관계 모순 (요구사항 §29)

    /// 모순 간선 나열 + 그 자리에서 관계 수정 — 임의 확정 대신 사용자 판정.
    @ViewBuilder private func chronoConflictList(_ snapshot: KnowledgeSnapshot) -> some View {
        ForEach(snapshot.chronoConflicts) { edge in
            if let a = snapshot.canonicalEvent(for: edge.aKey),
                let b = snapshot.canonicalEvent(for: edge.bKey)
            {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.novelC)
                        Text("시간 관계 모순")
                            .purloryUIFont(10.5, .semibold)
                            .foregroundStyle(theme.inkC)
                        Menu("고치기") {
                            ForEach(ChronoRelation.allCases, id: \.rawValue) { relation in
                                Button("‘\(a.summary.prefix(12))’이(가) \(relation.rawValue)") {
                                    setChronoEdge(a: edge.aKey, b: edge.bKey, relation: relation)
                                }
                            }
                        }
                        .purloryUIFont(9.5)
                        .fixedSize()
                    }
                    Text("\(a.summary) ↔ \(b.summary)")
                        .purloryUIFont(10)
                        .foregroundStyle(theme.ink2C)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PurloryRadius.sm, style: .continuous)
                        .fill(theme.novelBgC))
            }
        }
    }

    // MARK: - 성능 지표 (요구사항 §33 — 로컬 전용 개발 지표)

    @ViewBuilder private var metricsFooter: some View {
        if let metrics = indexer.metrics {
            Text(
                String(
                    format: "지식 %.1fKB · 씬 %d (씬당 %.1fKB) · 로드 %.0fms · 저장 %.0fms · 조립 %.0fms",
                    Double(metrics.sidecarBytes) / 1024, metrics.sceneCount,
                    Double(metrics.bytesPerScene) / 1024,
                    metrics.loadMs, metrics.saveMs, metrics.deriveMs)
            )
            .font(PurloryFonts.monoUI(8.5))
            .foregroundStyle(theme.ink3C)
            .padding(.top, 6)
            .help("지식 저장소 성능 — 기기 밖으로 나가지 않는 로컬 지표예요")
        }
    }
}

/// 수동 이해 트리거 — 기본 클릭은 **증분** 읽기(바뀐 씬만), 메뉴에서 **처음부터
/// 다시 읽기**(파생 캐시 폐기 후 전체 재분석)를 고른다. 사용자 수정은
/// entries.json에 있어 안전하다.
/// "지금 읽기" 버튼 — 패스의 단계를 구분해 보여준다 (#35).
///
/// 진행 중엔 결정적 진행률(처리 씬/더티 씬)과 **취소**를, 차단(열·저전력)·정지에
/// 는 이유와 재시도를, 완료/무변경/취소는 일시 표시 후 조용히 돌아간다.
/// 상태 의미는 색이 아니라 문장으로 전달한다 (#38 계열).
struct ManualIndexButton: View {
    @ObservedObject var indexer: BackgroundIndexer
    let theme: PurloryTheme

    var body: some View {
        switch indexer.manualPhase {
        case .idle:
            menu
        case .queued:
            phaseText("준비 중…", color: theme.ink3C)
        case .reading(let done, let total):
            HStack(spacing: 6) {
                Text("읽는 중 \(done)/\(total)")
                    .font(PurloryFonts.monoUI(10))
                    .foregroundStyle(theme.ink2C)
                Button {
                    indexer.cancelManualPass()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.ink3C)
                }
                .buttonStyle(.plain)
                .help("읽기 중단 — 여기까지 읽은 것은 저장돼 있어요")
                .accessibilityLabel(Text("읽기 중단"))
            }
            .accessibilityElement(children: .combine)
        case .blocked(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(reason)
                    .purloryUIFont(9.5)
                    .foregroundStyle(theme.warningC)
                    .fixedSize(horizontal: false, vertical: true)
                retryButton(label: "다시 시도")
            }
        case .stalled(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .purloryUIFont(9.5)
                    .foregroundStyle(theme.dangerC)
                    .fixedSize(horizontal: false, vertical: true)
                retryButton(label: "다시 시도")
            }
        case .completedNew:
            phaseText("새로 읽었어요", color: theme.ink3C)
        case .completedNoChange:
            phaseText("변한 게 없어요 — 이미 최신이에요", color: theme.ink3C)
        case .cancelled:
            phaseText("중단했어요 — 여기까지는 저장됐어요", color: theme.ink3C)
        }
    }

    private var menu: some View {
        Menu {
            Button {
                indexer.requestPass()
            } label: {
                Label("지금 읽기 — 바뀐 부분만", systemImage: "sparkles")
            }
            Button {
                indexer.requestFullPass()
            } label: {
                Label("처음부터 다시 읽기", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label("지금 읽기", systemImage: "sparkles")
                .purloryUIFont(10.5, .medium)
                .foregroundStyle(theme.novelC)
        } primaryAction: {
            indexer.requestPass()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("클릭: 바뀐 씬만 읽기 · 메뉴: 전체 다시 읽기 (직접 수정한 내용은 보존돼요)")
        .accessibilityLabel(Text("지금 읽기"))
    }

    private func retryButton(label: String) -> some View {
        Button(label) { indexer.requestPass() }
            .purloryUIFont(10, .semibold)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel(Text("다시 시도"))
    }

    private func phaseText(_ text: String, color: Color) -> some View {
        Text(text)
            .purloryUIFont(10)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(text)
    }
}

// MARK: - 레인 색 (요구사항 §24)

/// persistent ID 기반 안정 색 — 재분석·재실행 후에도 같은 플롯·인물은 같은 색.
/// 선명한 8색 (형광 금지, 라이트/다크 두 벌).
/// ⚠️ Theme 토큰 규칙의 **문서화된 예외** (이슈 #56) — 데이터 시각화 고정 팔레트.
/// 레인·브랜치 구분색은 의미 매핑(플롯 정체성)이라 라이트/다크 크롬 팔레트를
/// 따르지 않는다. 다크 대비는 `color(seed:theme:dark:)`에서 스스로 조정한다.
enum FlowPalette {
    static let hues: [(light: UInt32, dark: UInt32)] = [
        (0x2F80D0, 0x5AA7F0),  // 청
        (0xD9930D, 0xF0B429),  // 호박
        (0xC2255C, 0xEC5F94),  // 자홍
        (0x6741D9, 0x9775FA),  // 보라
        (0x099268, 0x2FCB9B),  // 청록
        (0xD9480F, 0xFF8B4D),  // 주황
        (0x3B5BDB, 0x7B95FF),  // 남
        (0x5C940D, 0x94D82D),  // 연두
    ]

    /// seed nil = 본줄기/서술 — 앱 액센트색.
    static func color(seed: Int?, theme: PurloryTheme, dark: Bool) -> Color {
        guard let seed else { return theme.novelC }
        let pair = hues[seed % hues.count]
        return Color(nsColor: NSColor(hex: dark ? pair.dark : pair.light))
    }
}

// MARK: - 그래프 렌더 (Canvas 레인 + 행 콘텐츠 + 노드)

private struct ThreadGraphArea: View {
    let rows: [GraphRow]
    let layout: ThreadGraphLayout
    let snapshot: KnowledgeSnapshot
    let theme: PurloryTheme
    let dark: Bool
    let selectedEventKey: String?
    /// 선택된 플롯 — 노드의 선택 링 표시에 쓴다.
    let selectedThreadID: String?
    /// 강조 스레드 (플롯 선택에서만 온다) — nil이면 전부 보통.
    let emphasizedThreadIDs: Set<String>?
    /// 인물 필터로 흐려질 사건 키.
    let dimmedKeys: Set<String>?
    let isEditingTitle: (String) -> Bool
    @Binding var draftTitle: String
    let characterNames: [UUID: String]

    var onSelectEvent: (String) -> Void
    var onSelectThread: (String) -> Void
    var onToggleMinor: (String) -> Void
    var onJump: (Int) -> Void
    var onJumpQuote: (String) -> Void
    var onJumpEvidence: (CanonicalEvent, Int) -> Void
    var onEditTitle: (String, String) -> Void
    var onCommitTitle: (String, Int) -> Void
    var onSetSceneType: (String, Int, SceneNarrativeType) -> Void
    var onResetScene: (String) -> Void
    var onSetImportance: (String, Int) -> Void
    var onRenameBranch: (NarrativeBranch, String) -> Void
    var onSetBranchChrono: (NarrativeBranch, ChronoRelation) -> Void
    var onMergeBranch: (NarrativeBranch) -> Void
    var onSegmentOverride: (String, NarrativeOverride.Kind, String) -> Void
    var onEditSegmentBoundary: (String, Bool, String) -> Void

    private let laneWidth: CGFloat = 14
    private let leftInset: CGFloat = 8

    /// 그래프 열 폭 — 레인 수에 비례 (직선 소설 = 좁게).
    private var graphWidth: CGFloat {
        leftInset + CGFloat(max(layout.slotCount, 1)) * laneWidth + 6
    }

    var body: some View {
        let geometry = GraphRowGeometry(rows: rows)
        ZStack(alignment: .topLeading) {
            // 캔버스 폭 = graphWidth 정확히 — 레인·곡선·헤일로는 전부 이 안에
            // 그려진다. 고정 여유 폭을 더하면 좁은 사이드바에서 ZStack이
            // 뷰포트보다 넓어지고, 세로 ScrollView가 넓은 콘텐츠를 **가운데
            // 정렬**해 왼쪽 레인이 leading 밖으로 잘린다 (clipping의 원인).
            Canvas { context, _ in
                drawLanes(context: &context, geometry: geometry)
            }
            .frame(width: graphWidth, height: geometry.totalHeight)
            .allowsHitTesting(false)

            // 행 하나 = [그래프 거터(노드) | 콘텐츠] 한 단위.
            //
            // 왜 합쳤나: 예전엔 행 배열을 **세 번** 순회했다 — 콘텐츠 VStack,
            // 노드 오버레이 ForEach, 그리고 캔버스의 헤일로 루프. 노드가 별도
            // 패스로 절대 배치되면 행을 Lazy로 만들어도 노드 1200개는 그대로
            // 만들어져 laziness가 무의미하다. 행 높이는 데이터로 고정이라
            // (`GraphRow.height`) 거터 안 배치가 예전 절대 좌표와 정확히 같다.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 0) {
                        graphGutter(row: row, index: index)
                        rowContent(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: row.height)
                }
            }
        }
        .frame(height: geometry.totalHeight, alignment: .topLeading)
        // leading 고정 — 부모가 얼마나 넓든 그래프 원점은 항상 leading에서
        // 시작한다 (사이드바 리사이즈·전체화면에서 inset 유지).
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 행의 그래프 거터 — 레인 히트 스트립 위에 사건 노드를 놓는다.
    /// 좌표는 예전 절대 배치와 동일 (x = 레인 중심, y = 행 중심).
    @ViewBuilder private func graphGutter(row: GraphRow, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            // 레인 선 자체도 클릭 대상이다 — 노드가 드문 구간에서는 선이
            // 그 플롯의 유일한 표식이라, 선을 눌러도 반응하지 않으면 화면이
            // 죽은 것처럼 보인다. Canvas는 그리기 전용이라 히트가 안 되므로
            // 행마다 투명 스트립을 깔아 대신 받는다 (레인 수는 보통 ≤8).
            ForEach(lanesCrossing(index), id: \.thread.id) { lane in
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: laneWidth, height: row.height)
                    .position(x: x(of: lane.slot), y: row.height / 2)
                    .onTapGesture { onSelectThread(lane.thread.id) }
            }
            if case .event(_, let event, _) = row,
                let node = layout.nodes[event.canonicalKey],
                node.row == index
            {
                // 노드는 스트립보다 **위**에 — 같은 x를 공유하므로 아래 깔리면
                // 사건 선택(상세 패널)이 레인 선택에 먹힌다.
                nodeView(node, event: event)
                    .position(x: x(of: node.slot), y: row.height / 2)
            }
        }
        .frame(width: graphWidth, height: row.height)
    }

    /// 이 행에 걸쳐 있는 레인들 — 열린 행부터 해결 행까지(미해결이면 끝까지).
    private func lanesCrossing(_ index: Int) -> [ThreadGraphLayout.Lane] {
        let lastRow = rows.count - 1
        return layout.lanes.filter { lane in
            lane.openRow <= index && index <= (lane.resolveRow ?? lastRow)
        }
    }

    private func x(of slot: Int) -> CGFloat {
        leftInset + CGFloat(slot) * laneWidth + laneWidth / 2
    }

    private func laneColor(_ lane: ThreadGraphLayout.Lane) -> Color {
        lane.thread.isMain
            ? theme.novelC
            : FlowPalette.color(seed: lane.thread.colorSeed, theme: theme, dark: dark)
    }

    @FocusState private var titleFieldFocused: Bool

    // MARK: 레인 그리기

    private func drawLanes(context: inout GraphicsContext, geometry: GraphRowGeometry) {
        let centers = geometry.centers
        guard !centers.isEmpty else { return }
        let bottom = geometry.totalHeight

        for lane in layout.lanes {
            let color = laneColor(lane)
            let isEmphasized = emphasizedThreadIDs?.contains(lane.thread.id) ?? false
            let dimmedLane = emphasizedThreadIDs != nil && !isEmphasized
            let baseOpacity: Double = dimmedLane ? 0.15 : (isEmphasized ? 1 : 0.8)
            let width: CGFloat = isEmphasized ? 2.6 : 2
            let laneX = x(of: lane.slot)

            // ① 몸통 — 멤버 구간은 실선, 마지막 멤버 뒤(미해결 꼬리)는 점선.
            //    해결 스레드는 해결 행에서 끝난다 (의미 있는 종료).
            guard let firstRow = lane.memberRows.first else { continue }
            let startY = centers[firstRow]
            let solidEndRow = lane.resolveRow ?? lane.memberRows.last ?? firstRow
            let solidEndY = centers[min(solidEndRow, centers.count - 1)]

            var solid = Path()
            solid.move(to: CGPoint(x: laneX, y: startY))
            solid.addLine(to: CGPoint(x: laneX, y: solidEndY))
            context.stroke(
                solid, with: .color(color.opacity(baseOpacity)),
                style: StrokeStyle(lineWidth: width, lineCap: .round))

            // 미해결 스레드의 꼬리 — 아직 열려 있음을 점선으로 (DORMANT 포함).
            if lane.resolveRow == nil, solidEndY < bottom - 2 {
                var tail = Path()
                tail.move(to: CGPoint(x: laneX, y: solidEndY))
                tail.addLine(to: CGPoint(x: laneX, y: bottom))
                context.stroke(
                    tail, with: .color(color.opacity(baseOpacity * 0.45)),
                    style: StrokeStyle(lineWidth: width * 0.8, dash: [3, 4]))
            }

            // ② 열림 곡선 — 여는 사건 노드에서 이 레인으로 갈라져 나온다.
            if let openNode = layout.nodes[
                lane.thread.memberKeys.first ?? ""],
                openNode.slot != lane.slot
            {
                let from = CGPoint(x: x(of: openNode.slot), y: centers[openNode.row])
                let to = CGPoint(x: laneX, y: min(centers[openNode.row] + 18, bottom))
                context.stroke(
                    curve(from: from, to: to),
                    with: .color(color.opacity(baseOpacity)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            // ③ 해결 곡선 — 레인이 해결 사건 노드로 합류하며 끝난다 (merge).
            if let resolveRow = lane.resolveRow,
                let resolveKey = lane.thread.resolvedAtKey,
                let node = layout.nodes[resolveKey],
                node.slot != lane.slot
            {
                let from = CGPoint(x: laneX, y: max(centers[resolveRow] - 18, 0))
                let to = CGPoint(x: x(of: node.slot), y: centers[resolveRow])
                context.stroke(
                    curve(from: from, to: to),
                    with: .color(color.opacity(baseOpacity)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            // ④ 교차 곡선 — 중간 멤버 사건이 다른 슬롯의 노드에 놓이면 레인이
            //    그 노드에 닿았다 돌아온다 (두 이야기가 만나는 지점).
            for memberRow in lane.memberRows {
                guard memberRow != lane.openRow, memberRow != lane.resolveRow,
                    let key = rowKey(at: memberRow),
                    let node = layout.nodes[key], node.slot != lane.slot
                else { continue }
                let nodePoint = CGPoint(x: x(of: node.slot), y: centers[memberRow])
                let inFrom = CGPoint(x: laneX, y: max(centers[memberRow] - 16, 0))
                let outTo = CGPoint(x: laneX, y: min(centers[memberRow] + 16, bottom))
                context.stroke(
                    curve(from: inFrom, to: nodePoint),
                    with: .color(color.opacity(baseOpacity)),
                    style: StrokeStyle(lineWidth: width * 0.9, lineCap: .round))
                context.stroke(
                    curve(from: nodePoint, to: outTo),
                    with: .color(color.opacity(baseOpacity)),
                    style: StrokeStyle(lineWidth: width * 0.9, lineCap: .round))
            }
        }

        // 노드 자리의 헤일로 — 선을 지워 노드가 읽히는 틈을 만든다.
        context.blendMode = .destinationOut
        for (row, graphRow) in rows.enumerated() {
            guard case .event(_, let event, _) = graphRow,
                let node = layout.nodes[event.canonicalKey], node.row == row
            else { continue }
            let radius = nodeSize(event) / 2 + 1.5
            let center = CGPoint(x: x(of: node.slot), y: centers[row])
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2)),
                with: .color(.black))
        }
        context.blendMode = .normal
    }

    /// 행 → 그 행의 사건 키.
    private func rowKey(at row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        return rows[row].eventKey
    }

    /// 완만한 S-곡선 — 분기·합류·교차의 공용 획.
    private func curve(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        let midY = (from.y + to.y) / 2
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x, y: midY),
            control2: CGPoint(x: to.x, y: midY))
        return path
    }

    // MARK: 노드

    private func nodeSize(_ event: CanonicalEvent) -> CGFloat {
        switch event.importance {
        case 5: 11
        case 4: 9.5
        case 3: 7.5
        default: 5.5
        }
    }

    @ViewBuilder private func nodeView(
        _ node: ThreadGraphLayout.Node, event: CanonicalEvent
    ) -> some View {
        let lane = layout.lanes.first { $0.slot == node.slot }
        let color = lane.map(laneColor) ?? theme.novelC
        let threadIDs = Set(snapshot.threadIDsByEvent[event.canonicalKey] ?? [])
        let dimmed =
            (emphasizedThreadIDs.map { $0.isDisjoint(with: threadIDs) } ?? false)
            || (dimmedKeys?.contains(event.canonicalKey) ?? false)
        let opacity: Double = dimmed ? 0.25 : 1
        let size = nodeSize(event)

        // 노드가 그려진 레인의 플롯 — 클릭하면 강조가 이 플롯으로 옮겨온다.
        let laneThreadID = lane?.thread.id
        Button {
            onSelectEvent(event.canonicalKey)
            if let laneThreadID { onSelectThread(laneThreadID) }
        } label: {
            ZStack {
                if node.isJunction {
                    // 여러 플롯이 만나는 사건 — 링 + 중심점 (merge 문법).
                    Circle()
                        .strokeBorder(color.opacity(opacity), lineWidth: 2)
                        .frame(width: size + 5, height: size + 5)
                    Circle()
                        .fill(color.opacity(opacity))
                        .frame(width: size * 0.4, height: size * 0.4)
                } else if event.importance >= 4 {
                    Circle()
                        .fill(color.opacity(opacity))
                        .frame(width: size, height: size)
                } else {
                    Circle()
                        .strokeBorder(color.opacity(opacity), lineWidth: 1.5)
                        .frame(width: size, height: size)
                }
                if selectedEventKey == event.canonicalKey {
                    Circle()
                        .strokeBorder(theme.inkC.opacity(0.6), lineWidth: 1.3)
                        .frame(width: size + 10, height: size + 10)
                }
            }
            .contentShape(Circle().scale(2.2))
        }
        .buttonStyle(.plain)
        // hover 상태를 두지 않는다 — 강조·가시성은 선택에만 반응한다.
        // 클릭 가능하다는 신호는 tooltip이 대신한다 (상태 변화 0).
        .help(
            laneThreadID != nil && laneThreadID == selectedThreadID
                ? "\(event.summary)\n다시 클릭: 플롯 강조 해제"
                : laneThreadID != nil
                    ? "\(event.summary)\n클릭: 이 플롯의 경로만 강조"
                : event.summary)
    }

    // MARK: 행 콘텐츠 (그래프 오른쪽 열)

    @ViewBuilder private func rowContent(_ row: GraphRow) -> some View {
        switch row {
        case .sceneMarker(let scene):
            sceneMarkerContent(scene)
        case .branchOpen(let branch):
            bracketContent(
                icon: "chevron.down.2", text: "\(branch.name) · \(branch.chrono.rawValue)",
                userEdited: branch.userEdited
            )
            .contextMenu { branchMenu(branch) }
        case .branchClose:
            bracketContent(icon: "chevron.up.2", text: "복귀", userEdited: false)
        case .segmentBracket(let segment, let sceneStart, let userEdited):
            segmentBracketContent(segment, sceneStart: sceneStart, userEdited: userEdited)
        case .event(_, let event, let start):
            eventContent(event, start: start)
        case .perspectiveRef(_, let canonicalKey, let perspective):
            perspectiveRefContent(perspective, canonicalKey: canonicalKey)
        case .minorGroup(let id, let events, _, let expanded):
            Button {
                onToggleMinor(id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                    Text("사소한 사건 \(events.count)개")
                        .purloryUIFont(10)
                }
                .foregroundStyle(theme.ink3C)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .truncated(_, let total, let read):
            // ⚠️ 헤딩 없는 장편이 씬 하나가 되면 여기서 대부분이 잘린다 (PLAN §8).
            Text("앞 \(read.formatted())자만 이해됨 — \((total - read).formatted())자는 지식에 없어요")
                .purloryUIFont(9.5)
                .foregroundStyle(theme.ink3C)
                .lineLimit(1)
        case .pending:
            Text("아직 안 읽음")
                .purloryUIFont(9.5)
                .foregroundStyle(theme.ink3C)
        }
    }

    // MARK: 씬 marker — section 구분선 수준 (요구사항 §7)

    @ViewBuilder private func sceneMarkerContent(_ scene: GraphRow.SceneInfo) -> some View {
        HStack(spacing: 6) {
            if isEditingTitle(scene.hash) {
                // onCommit 폐기 대체 (이슈 #58) — Enter(onSubmit)와 포커스 상실
                // 모두에서 커밋한다. SidebarView 이름 변경과 같은 패턴.
                TextField("씬 제목", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .purloryUIFont(10.5)
                    .focused($titleFieldFocused)
                    .onSubmit { onCommitTitle(scene.hash, scene.start) }
                    .onChange(of: titleFieldFocused) { _, focused in
                        if !focused, isEditingTitle(scene.hash) {
                            onCommitTitle(scene.hash, scene.start)
                        }
                    }
                    .frame(width: 180)
            } else {
                Text(scene.title ?? scene.path)
                    .purloryUIFont(10, .semibold)
                    .foregroundStyle(theme.ink2C)
                    .lineLimit(1)
                if scene.titleUserEdited || scene.typeUserEdited {
                    UserEditedMark(theme: theme)
                }
                if scene.type != .present {
                    Text(scene.type.rawValue)
                        .purloryUIFont(8.5)
                        .foregroundStyle(theme.blueC)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.blueC.opacity(0.12)))
                }
                Rectangle()
                    .fill(theme.sepC)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture { onJump(scene.start) }
        .help(scene.summary ?? "본문의 이 장면으로 이동")
        .contextMenu {
            Button("제목 수정") { onEditTitle(scene.hash, scene.title ?? "") }
            Menu("장면 유형") {
                ForEach(SceneNarrativeType.allCases, id: \.rawValue) { type in
                    Button {
                        onSetSceneType(scene.hash, scene.start, type)
                    } label: {
                        if scene.type == type {
                            Label(type.rawValue, systemImage: "checkmark")
                        } else {
                            Text(type.rawValue)
                        }
                    }
                }
            }
            if scene.titleUserEdited || scene.typeUserEdited {
                Divider()
                Button("AI 분석으로 되돌리기") { onResetScene(scene.hash) }
            }
        }
    }

    // MARK: traversal bracket (회상·꿈 — 플롯 branch와 다른 시각 문법)

    @ViewBuilder private func bracketContent(
        icon: String, text: String, userEdited: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 7))
                .foregroundStyle(theme.blueC.opacity(0.8))
            Text(text)
                .purloryUIFont(9)
                .foregroundStyle(theme.blueC.opacity(0.9))
                .lineLimit(1)
            if userEdited { UserEditedMark(theme: theme) }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    theme.blueC.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
    }

    @ViewBuilder private func branchMenu(_ branch: NarrativeBranch) -> some View {
        Menu("시간 관계") {
            ForEach(ChronoRelation.allCases, id: \.rawValue) { relation in
                Button {
                    onSetBranchChrono(branch, relation)
                } label: {
                    if branch.chrono == relation {
                        Label(relation.rawValue, systemImage: "checkmark")
                    } else {
                        Text(relation.rawValue)
                    }
                }
            }
        }
        Button("회상 아님 — 본줄기로 합치기") { onMergeBranch(branch) }
    }

    @ViewBuilder private func segmentBracketContent(
        _ segment: NarrativeSegment, sceneStart: Int, userEdited: Bool
    ) -> some View {
        HStack(spacing: 4) {
            bracketContent(
                icon: "arrow.uturn.down",
                text: segment.subjectCharacter.map { "\(segment.layer.rawValue) · \($0)" }
                    ?? segment.layer.rawValue,
                userEdited: userEdited)
            if segment.returnState == .uncertain {
                Text("복귀 불확실")
                    .purloryUIFont(8)
                    .foregroundStyle(theme.novelC)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onJump(sceneStart + segment.localStart) }
        .help("“\(segment.startQuote)” \(segment.endQuote.map { "→ “\($0)”" } ?? "→ 씬 끝")")
        .contextMenu {
            let id = segment.persistentID
            Menu("층 — 이 구간의 성격") {
                ForEach(NarrativeSegment.Layer.allCases, id: \.rawValue) { layer in
                    Button {
                        onSegmentOverride(id, .segmentLayer, layer.rawValue)
                    } label: {
                        if segment.layer == layer {
                            Label(layer.rawValue, systemImage: "checkmark")
                        } else {
                            Text(layer.rawValue)
                        }
                    }
                }
            }
            Button("회상 아님 — 현재로") {
                onSegmentOverride(id, .segmentLayer, NarrativeSegment.Layer.present.rawValue)
            }
            Menu("시점 인물") {
                ForEach(characterNames.values.sorted(), id: \.self) { name in
                    Button(name) { onSegmentOverride(id, .segmentPOV, name) }
                }
            }
            Menu("이 과거의 주인") {
                ForEach(characterNames.values.sorted(), id: \.self) { name in
                    Button(name) { onSegmentOverride(id, .segmentSubject, name) }
                }
            }
            Menu("신뢰 상태") {
                ForEach(SourceReliability.allCases, id: \.rawValue) { reliability in
                    Button {
                        onSegmentOverride(id, .segmentReliability, reliability.rawValue)
                    } label: {
                        if segment.reliability == reliability {
                            Label(reliability.rawValue, systemImage: "checkmark")
                        } else {
                            Text(reliability.rawValue)
                        }
                    }
                }
            }
            Menu("시간 관계") {
                ForEach(ChronoRelation.allCases, id: \.rawValue) { relation in
                    Button {
                        onSegmentOverride(id, .segmentChrono, relation.rawValue)
                    } label: {
                        if segment.chrono == relation {
                            Label(relation.rawValue, systemImage: "checkmark")
                        } else {
                            Text(relation.rawValue)
                        }
                    }
                }
            }
            Divider()
            Button("시작 경계 수정…") {
                onEditSegmentBoundary(segment.persistentID, true, segment.startQuote)
            }
            Button("끝(복귀) 경계 수정…") {
                onEditSegmentBoundary(segment.persistentID, false, segment.endQuote ?? "")
            }
        }
    }

    // MARK: 사건 행 — 제목이 1급 (요구사항 §7)

    @ViewBuilder private func eventContent(_ event: CanonicalEvent, start: Int) -> some View {
        let threadIDs = Set(snapshot.threadIDsByEvent[event.canonicalKey] ?? [])
        let dimmed =
            (emphasizedThreadIDs.map { $0.isDisjoint(with: threadIDs) } ?? false)
            || (dimmedKeys?.contains(event.canonicalKey) ?? false)
        HStack(alignment: .center, spacing: 6) {
            Text(event.summary)
                .purloryUIFont(11, event.importance >= 4 ? .semibold : .regular)
                .foregroundStyle(theme.inkC)
                .lineLimit(1)
            // 그래프 노드의 VoiceOver 대응 (#55) — 노드 원은 Canvas라 개별 요소가
            // 못 되므로 행 콘텐츠에 사건 요약을 레이블로 단다.
            .accessibilityLabel(Text(event.summary))
            .accessibilityHint(Text("사건 상세 보기"))
            if event.perspectives.count >= 2 {
                Text("관점 \(event.perspectives.count)")
                    .purloryUIFont(8.5)
                    .foregroundStyle(theme.novelC)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.novelBgC))
            }
            if let quote = event.quote {
                Button {
                    onJumpQuote(quote)
                } label: {
                    Image(systemName: "text.quote")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.blueC.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("근거 원문 보기: “\(quote)”")
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onSelectEvent(event.canonicalKey) }
        // hover 없음 — 포인터가 지나가는 것만으로 강조가 바뀌면 안 되고,
        // 스크롤 중 그 상태 변화가 곧 프레임 드롭이었다.
        .help("클릭: 사건 상세 보기")
        // 캔버스 조작의 키보드·VO 축 (#21): 행 = 버튼(선택), 흐림 상태도 값으로.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(dimmed ? "필터로 흐려짐" : ""))
        .accessibilityAction(named: Text("사건 상세 보기")) {
            onSelectEvent(event.canonicalKey)
        }
        .contextMenu {
            Menu("중요도") {
                ForEach(1...5, id: \.self) { level in
                    Button {
                        onSetImportance(event.canonicalKey, level)
                    } label: {
                        if event.importance == level {
                            Label("\(level)", systemImage: "checkmark")
                        } else {
                            Text("\(level)")
                        }
                    }
                }
            }
            Button("근거 원문 보기") { onJumpEvidence(event, start) }
        }
    }

    // MARK: 관점 참조 행 (같은 사건의 재서술)

    @ViewBuilder private func perspectiveRefContent(
        _ perspective: EventPerspective, canonicalKey: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 7))
                .foregroundStyle(theme.ink3C)
            Text("같은 사건 — \(perspective.summary)")
                .purloryUIFont(9.5)
                .foregroundStyle(theme.ink3C)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelectEvent(canonicalKey) }
        .help("\(perspective.source.rawValue)·\(perspective.reliability.rawValue) — 클릭: 정본 사건 상세")
    }
}

// MARK: - 사건 상세 패널 (통합 — 인물·시간·플롯·씬/구간·관점·인과·근거)

private struct NarrativeEventDetail: View {
    let event: CanonicalEvent
    let snapshot: KnowledgeSnapshot
    let theme: PurloryTheme
    let characterNames: [UUID: String]
    let dark: Bool
    var onJump: (String) -> Void
    var onJumpOffset: (Int) -> Void
    /// 관련 사건 클릭 — 그 정본 사건으로 선택을 옮긴다.
    var onSelect: (String) -> Void
    var onSetImportance: (Int) -> Void
    /// (상대 정본 키, 관계) — "이 사건이 상대보다 relation" 시간 간선.
    var onSetChrono: (String, ChronoRelation) -> Void
    /// (스레드 ID, 값 = 역할 rawValue 또는 "제외") — 플롯 멤버십 편집.
    var onSetMembership: (String, String) -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.summary)
                        .purloryUIFont(11.5, .semibold)
                        .foregroundStyle(theme.inkC)
                        .fixedSize(horizontal: false, vertical: true)
                    Menu {
                        ForEach(1...5, id: \.self) { level in
                            Button {
                                onSetImportance(level)
                            } label: {
                                if event.importance == level {
                                    Label("\(level)", systemImage: "checkmark")
                                } else {
                                    Text("\(level)")
                                }
                            }
                        }
                    } label: {
                        ImportanceDots(importance: event.importance, theme: theme)
                    }
                    .menuStyle(.button)
                .menuIndicator(.hidden)
                    .fixedSize()
                    .help("중요도 수정")
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.ink3C)
                    }
                    .buttonStyle(.plain)
                }

                // 플롯 멤버십 — 이 사건이 어느 이야기(들)를 진전시키는가.
                threadLines

                // 참여 인물·흐름.
                let names = Dictionary(
                    uniqueKeysWithValues: snapshot.characters.map { ($0.id, $0.name) })
                let who = event.participants.compactMap { names[$0] }
                if !who.isEmpty {
                    detailLine("인물", who.joined(separator: " · "))
                }
                timeLine
                sceneLine

                // 상태 델타 — 원본 StoryEvent 역추적.
                if let member = snapshot.storyEvent(forMember: event.canonicalKey),
                    let rendered = deltaLine(member.deltas)
                {
                    detailLine("상태", rendered)
                }

                // 관점들 (요구사항 §12·§13) — 서로 모순될 수 있는 서술을 나란히.
                if event.perspectives.count >= 2 {
                    Text("관점")
                        .purloryUIFont(10, .semibold)
                        .foregroundStyle(theme.ink2C)
                    ForEach(event.perspectives) { perspective in
                        perspectiveRow(perspective)
                    }
                }

                // 관련 사건 (인과) — 클릭해 따라간다.
                let causes = snapshot.causes(of: event.canonicalKey)
                let effects = snapshot.effects(of: event.canonicalKey)
                ForEach(causes) { link in
                    causalRow(link, label: "← \(link.kind.rawValue)", otherKey: link.fromKey)
                }
                ForEach(effects) { link in
                    causalRow(link, label: "→ \(link.kind.rawValue)", otherKey: link.toKey)
                }

                // 근거 원문 (Source Evidence).
                if let quote = event.quote {
                    Button {
                        onJump(quote)
                    } label: {
                        Label("근거 원문 보기 — “\(quote)”", systemImage: "text.quote")
                            .purloryUIFont(10)
                            .foregroundStyle(theme.blueC)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    /// 플롯 줄 — 속한 스레드 + 역할, 멤버십 편집 메뉴.
    @ViewBuilder private var threadLines: some View {
        let mine = snapshot.threads(of: event.canonicalKey)
        let others = snapshot.plotThreads.filter { thread in
            !mine.contains { $0.id == thread.id }
        }
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("플롯")
                .purloryUIFont(9.5, .semibold)
                .foregroundStyle(theme.ink3C)
            ForEach(mine) { thread in
                let color = thread.isMain
                    ? theme.novelC
                    : FlowPalette.color(seed: thread.colorSeed, theme: theme, dark: dark)
                HStack(spacing: 3) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(thread.title)
                        .purloryUIFont(10)
                        .foregroundStyle(theme.ink2C)
                    if let role = thread.role(of: event.canonicalKey) {
                        Text(role.rawValue)
                            .purloryUIFont(8.5)
                            .foregroundStyle(color)
                    }
                }
                .contextMenu {
                    if !thread.isMain {
                        Menu("역할") {
                            ForEach(ThreadRole.allCases, id: \.rawValue) { role in
                                Button(role.rawValue) {
                                    onSetMembership(thread.id, role.rawValue)
                                }
                            }
                        }
                        Button("이 플롯에서 제외") { onSetMembership(thread.id, "제외") }
                    }
                }
            }
            if !others.filter({ !$0.isMain }).isEmpty {
                Menu {
                    ForEach(others.filter { !$0.isMain }) { thread in
                        Button(thread.title) {
                            onSetMembership(thread.id, ThreadRole.advances.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.ink3C)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("이 사건을 다른 플롯에 추가")
            }
        }
    }

    /// 시간 정보 한 줄 — 담화 순번·시간 순위 + 모순 여부.
    @ViewBuilder private var timeLine: some View {
        let discourse = snapshot.canonicalEvents.firstIndex {
            $0.canonicalKey == event.canonicalKey
        }
        let rank = snapshot.chronoRank(of: event.canonicalKey)
        let inConflict = snapshot.chronoConflicts.contains {
            $0.aKey == event.canonicalKey || $0.bKey == event.canonicalKey
        }
        if discourse != nil || rank != nil {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("시간")
                    .purloryUIFont(9.5, .semibold)
                    .foregroundStyle(theme.ink3C)
                Text(
                    [
                        discourse.map { "본문 \($0 + 1)번째" },
                        rank.map { "시간순 \($0 + 1)번째" },
                    ]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .purloryUIFont(10)
                .foregroundStyle(theme.ink2C)
                if inConflict {
                    Text("모순 있음 — 검토 필요에서 고칠 수 있어요")
                        .purloryUIFont(9)
                        .foregroundStyle(theme.novelC)
                }
            }
        }
    }

    /// 씬/구간 정보 — 씬 라벨(클릭 = 이동) + 관점 맥락 구간의 층.
    @ViewBuilder private var sceneLine: some View {
        if let scene = snapshot.outline.scenes.first(where: {
            $0.contentHash == event.sceneHash
        }) {
            let meta = snapshot.sceneMetaByHash[event.sceneHash]
            let path = scene.headingPath.filter { !$0.isEmpty }.joined(separator: " › ")
            let label = meta?.title ?? (path.isEmpty ? "서두" : path)
            let segment = event.perspectives.first?.segmentID
                .flatMap { snapshot.segment(withID: $0) }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("장면")
                    .purloryUIFont(9.5, .semibold)
                    .foregroundStyle(theme.ink3C)
                Button {
                    onJumpOffset(scene.utf16Range.lowerBound)
                } label: {
                    Text(label)
                        .purloryUIFont(10)
                        .foregroundStyle(theme.blueC)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("이 장면의 시작으로 이동")
                if let segment {
                    Text("구간: \(segment.layer.rawValue)\(segment.depth >= 2 ? " · 깊이 \(segment.depth)" : "")")
                        .purloryUIFont(9)
                        .foregroundStyle(theme.blueC)
                }
            }
        }
    }

    private func deltaLine(_ deltas: [StateDelta]) -> String? {
        let pieces = deltas.compactMap { delta -> String? in
            guard let name = characterNames[delta.characterID] else { return nil }
            return "\(name) \(delta.field.rawValue)=\(delta.value)"
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    @ViewBuilder private func perspectiveRow(_ perspective: EventPerspective) -> some View {
        Button {
            if let quote = perspective.quote { onJump(quote) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(perspective.viewpoint ?? "서술")
                    .purloryUIFont(9, .semibold)
                    .foregroundStyle(theme.novelC)
                Text(perspective.summary)
                    .purloryUIFont(10)
                    .foregroundStyle(theme.ink2C)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(perspective.source.rawValue)·\(perspective.reliability.rawValue)")
                    .purloryUIFont(8.5)
                    .foregroundStyle(theme.ink3C)
                if let segment = perspective.segmentID
                    .flatMap({ snapshot.segment(withID: $0) })
                {
                    Text(segment.layer.rawValue)
                        .purloryUIFont(8.5)
                        .foregroundStyle(theme.blueC)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("이 관점의 원문 보기")
    }

    @ViewBuilder private func causalRow(
        _ link: CausalLink, label: String, otherKey: String
    ) -> some View {
        if let other = snapshot.canonicalEvent(for: otherKey) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Button {
                    onSelect(other.canonicalKey)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(label)
                            .purloryUIFont(9, .semibold)
                            .foregroundStyle(theme.novelC)
                        Text(other.summary)
                            .purloryUIFont(10)
                            .foregroundStyle(theme.ink2C)
                            .lineLimit(2)
                        if !link.reason.isEmpty {
                            Text(link.reason)
                                .purloryUIFont(8.5)
                                .foregroundStyle(theme.ink3C)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("연결된 사건의 상세 보기")
                if let quote = other.quote {
                    Button {
                        onJump(quote)
                    } label: {
                        Image(systemName: "text.quote")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.blueC)
                    }
                    .buttonStyle(.plain)
                    .help("연결된 사건의 원문 보기")
                }
            }
            .contextMenu {
                // 시간 관계 편집 (요구사항 §29) — 이 사건 vs 상대 사건.
                Menu("시간 관계 — 이 사건이 상대보다") {
                    ForEach(ChronoRelation.allCases, id: \.rawValue) { relation in
                        Button(relation.rawValue) {
                            onSetChrono(other.canonicalKey, relation)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(key)
                .purloryUIFont(9.5, .semibold)
                .foregroundStyle(theme.ink3C)
            Text(value)
                .purloryUIFont(10)
                .foregroundStyle(theme.ink2C)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 사용자 수정 표식 — AI 추출과 시각적으로 구분 (요구사항 §18).
struct UserEditedMark: View {
    let theme: PurloryTheme

    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 8))
            .foregroundStyle(theme.novelC)
            .help("직접 수정한 항목 — 재분석해도 덮어쓰지 않아요")
    }
}

/// 중요도 1–5 — 숫자보다 점이 훑기 쉽다 (조용한 UI, CLAUDE.md §3).
private struct ImportanceDots: View {
    let importance: Int
    let theme: PurloryTheme

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1...5, id: \.self) { level in
                Circle()
                    .fill(level <= importance ? theme.novelC.opacity(0.55) : theme.sepC)
                    .frame(width: 3, height: 3)
            }
        }
        .help("중요도 \(importance)/5")
    }
}
