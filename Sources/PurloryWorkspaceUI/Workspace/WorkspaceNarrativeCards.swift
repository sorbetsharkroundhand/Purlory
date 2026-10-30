import SwiftUI

/// Compact projections reuse the map's scoped, source-verified preparation and cancellation.
struct WorkspaceNarrativeCards: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var indexer: BackgroundIndexer
    @ObservedObject var completion: CompletionController
    @ObservedObject var model: SpatialWorkspaceController
    let theme: PurloryTheme
    @StateObject private var controller: StoryMapController
    @State private var editingThreadID: String?
    @State private var draftThreadTitle = ""
    @State private var editingSceneHash: String?
    @State private var editingSceneAnchor: String?
    @State private var draftSceneTitle = ""
    private struct RefreshID: Equatable { let identity: ProjectRuntimeIdentity?; let generation: Int }
    init(session: ProjectSession, requests: ProjectEditorRequests, indexer: BackgroundIndexer, completion: CompletionController, model: SpatialWorkspaceController, theme: PurloryTheme) {
        self.session = session; self.requests = requests; self.indexer = indexer; self.completion = completion; self.model = model; self.theme = theme
        _controller = StateObject(wrappedValue: StoryMapController(session: session, requiresMapMode: false))
    }

    private func verifiedSnapshot(for identity: ProjectRuntimeIdentity) -> KnowledgeSnapshot? {
        guard indexer.snapshotRuntimeIdentity == identity,
              let snapshot = indexer.snapshot,
              snapshot.entryID == identity.key.documentID.rawValue else { return nil }
        return snapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            if let prepared = controller.prepared {
                let snapshot = verifiedSnapshot(for: prepared.identity)
                topControls(prepared: prepared, snapshot: snapshot)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let prepared = controller.prepared {
                        let snapshot = verifiedSnapshot(for: prepared.identity)
                        let names = Dictionary(uniqueKeysWithValues: (snapshot?.characters ?? []).map { ($0.id, $0.name) })
                        let rows = controller.visibleRows
                        if rows.isEmpty {
                            Text(prepared.projection.rows.isEmpty ? "원고의 장면과 사건이 여기에 보여요." : "조건에 맞는 사건이 없어요.")
                                .purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(4)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { order, row in
                            narrativeCard(order: order, row: row, prepared: prepared, snapshot: snapshot, names: names)
                        }
                    } else {
                        Text(controller.status == .preparing ? "서사 흐름을 준비하고 있어요…" : "소설 원고를 열면 장면과 사건 흐름이 여기에 표시됩니다.")
                            .purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(4)
                    }
                }.padding(8)
            }
            Divider()
            bottomBar
        }
        .contextMenu {
            Button("연속성·설정 검토 열기") { model.toggle(.review) }
            Button("작가 수정과 기록…") { model.selectTile(.narrative); model.pouchSection = .object }
        }
        .alert("플롯 이름 수정", isPresented: Binding(get: { editingThreadID != nil }, set: { if !$0 { editingThreadID = nil } })) {
            TextField("플롯 이름", text: $draftThreadTitle)
            Button("적용") {
                if let id = editingThreadID, let identity = session.runtimeIdentity {
                    let trimmed = draftThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        applyOverride(NarrativeOverride(kind: .threadTitle, key: id, value: trimmed), identity: identity)
                    }
                }
                editingThreadID = nil
            }
            Button("취소", role: .cancel) { editingThreadID = nil }
        }
        .alert("장면 제목 수정", isPresented: Binding(get: { editingSceneHash != nil }, set: { if !$0 { editingSceneHash = nil } })) {
            TextField("장면 제목", text: $draftSceneTitle)
            Button("적용") {
                if let hash = editingSceneHash, let identity = session.runtimeIdentity {
                    let trimmed = draftSceneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        applyOverride(NarrativeOverride(kind: .sceneTitle, key: hash, value: trimmed, anchor: editingSceneAnchor), identity: identity)
                    }
                }
                editingSceneHash = nil
            }
            Button("취소", role: .cancel) { editingSceneHash = nil }
        }
        .task(id: RefreshID(identity: session.runtimeIdentity, generation: indexer.snapshotGeneration)) {
            controller.update(knowledge: indexer.snapshot, knowledgeOrigin: indexer.snapshotRuntimeIdentity, generation: indexer.snapshotGeneration)
        }
        .onChange(of: controller.prepared) { _, prepared in
            model.entityEvents = prepared.map { prepared in
                prepared.projection.rows.filter { $0.kind == .event }.map { row in
                    WorkspaceEntityEvent(name: row.title, note: row.evidence.quote,
                        reference: .init(key: prepared.identity.key, revision: prepared.projection.revision, evidence: row.evidence, selection: .passage))
                }
            } ?? []
        }
        .onAppear { completion.observeForegroundCompletion(owner: controller) { [weak controller] busy in controller?.setForegroundBusy(busy) } }
        .onReceive(completion.$isMemoryPressurePaused) { controller.setPolicyPaused($0) }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private func topControls(prepared: PreparedStoryMap, snapshot: KnowledgeSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("정렬", selection: Binding(get: { controller.order }, set: { controller.setOrder($0) })) {
                    Text("원고순").tag(StoryMapProjection.Order.manuscript)
                    Text("시간순").tag(StoryMapProjection.Order.chronology)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 130)
                .accessibilityIdentifier("purlory.narrative.order")

                Spacer(minLength: 4)

                if !prepared.projection.characters.isEmpty {
                    Menu {
                        Button("모든 인물") { controller.filter(threadID: controller.selectedThreadID, characterID: nil) }
                        ForEach(prepared.projection.characters) { item in
                            Button(item.title) { controller.filter(threadID: controller.selectedThreadID, characterID: item.id) }
                        }
                    } label: {
                        Label(
                            prepared.projection.characters.first { $0.id == controller.selectedCharacterID }?.title ?? "인물",
                            systemImage: "person"
                        ).purloryUIFont(10)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if controller.selectedThreadID != nil || controller.selectedCharacterID != nil {
                    Button("초기화") { controller.filter(threadID: nil, characterID: nil) }
                        .buttonStyle(.borderless)
                        .purloryUIFont(10)
                }
            }

            if let snapshot, snapshot.plotThreads.count >= 2 || snapshot.plotThreads.contains(where: { !$0.isMain }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(snapshot.plotThreads) { thread in
                            threadChip(thread, identity: prepared.identity)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func threadChip(_ thread: ResolvedPlotThread, identity: ProjectRuntimeIdentity) -> some View {
        let selected = controller.selectedThreadID == thread.id
        return Button {
            controller.filter(
                threadID: selected ? nil : thread.id,
                characterID: controller.selectedCharacterID
            )
        } label: {
            HStack(spacing: 4) {
                Circle().fill(thread.isMain ? theme.novelC : theme.blueC).frame(width: 6, height: 6)
                Text(thread.title).purloryUIFont(10, .medium).foregroundStyle(selected ? theme.inkC : theme.ink2C).lineLimit(1)
                Text(thread.status.rawValue).purloryUIFont(8.5).foregroundStyle(thread.status == .resolved ? theme.ink3C : theme.novelC)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? theme.activeBgC : theme.chipC))
            .overlay(Capsule().strokeBorder(selected ? theme.novelC : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("플롯 이름 바꾸기…") {
                draftThreadTitle = thread.title
                editingThreadID = thread.id
            }
            if !thread.isMain {
                Menu("플롯 상태") {
                    ForEach(ThreadStatus.allCases, id: \.rawValue) { status in
                        Button {
                            applyOverride(NarrativeOverride(kind: .threadStatus, key: thread.id, value: status.rawValue), identity: identity)
                        } label: {
                            if thread.status == status { Label(status.rawValue, systemImage: "checkmark") }
                            else { Text(status.rawValue) }
                        }
                    }
                }
            }
            if thread.userEdited {
                Divider()
                Button("AI 추론으로 되돌리기") {
                    removeOverride(.threadTitle, key: thread.id, identity: identity)
                    removeOverride(.threadStatus, key: thread.id, identity: identity)
                }
            }
        }
    }

    @ViewBuilder
    private func narrativeCard(
        order: Int,
        row: StoryMapProjection.Row,
        prepared: PreparedStoryMap,
        snapshot: KnowledgeSnapshot?,
        names: [UUID: String]
    ) -> some View {
        let eventKey: String? = row.id.hasPrefix("event:") ? String(row.id.dropFirst("event:".count)) : nil
        let canonical = eventKey.flatMap { key in snapshot?.canonicalEvents.first(where: { $0.canonicalKey == key }) }
        let scene = snapshot?.outline.scenes.first(where: { $0.utf16Range.lowerBound == row.sourceRange.lowerBound })
        let sceneMeta = scene.flatMap { snapshot?.sceneMetaByHash[$0.contentHash] }

        WorkspaceCompactCard(
            model: model,
            id: "narrative.\(row.id)",
            title: row.title,
            detail: row.evidence.quote,
            term: row.evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines),
            theme: theme,
            role: row.kind == .scene ? (sceneMeta?.type.rawValue ?? "장면") : (canonical.map { "중요도 \($0.importance)" } ?? ""),
            order: String(format: "%02d", order + 1),
            sourceDocumentID: prepared.identity.key.documentID
        ) {
            Text(row.evidence.quote).purloryUIFont(11).foregroundStyle(theme.ink2C).textSelection(.enabled)
            if let canonical, let snapshot {
                let participants = canonical.participants.compactMap { names[$0] }
                if !participants.isEmpty {
                    Text("인물: " + participants.joined(separator: " · "))
                        .purloryUIFont(10).foregroundStyle(theme.ink3C)
                }
                if let member = snapshot.storyEvent(forMember: canonical.canonicalKey) {
                    let deltas = member.deltas.compactMap { delta -> String? in
                        guard let name = names[delta.characterID] else { return nil }
                        return "\(name) \(delta.field.rawValue)=\(delta.value)"
                    }
                    if !deltas.isEmpty {
                        Text("상태 변화: " + deltas.joined(separator: " · "))
                            .purloryUIFont(10).foregroundStyle(theme.ink2C)
                    }
                }
                let causes = snapshot.causes(of: canonical.canonicalKey)
                let effects = snapshot.effects(of: canonical.canonicalKey)
                if !causes.isEmpty || !effects.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(causes) { link in
                            if let other = snapshot.canonicalEvent(for: link.fromKey) {
                                Text("← \(link.kind.rawValue): \(other.summary)").purloryUIFont(9.5).foregroundStyle(theme.ink3C)
                            }
                        }
                        ForEach(effects) { link in
                            if let other = snapshot.canonicalEvent(for: link.toKey) {
                                Text("→ \(link.kind.rawValue): \(other.summary)").purloryUIFont(9.5).foregroundStyle(theme.ink3C)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("본문 이동 →") {
                    let inspection = ProjectSourceInspection(session: session)
                    let reference = OriginalSourceReference(key: prepared.identity.key, revision: prepared.projection.revision, evidence: row.evidence, selection: .passage)
                    if let token = inspection.capture() { requests.jump(to: reference, inspection: inspection, token: token, in: session) }
                }.buttonStyle(.plain).purloryUIFont(10, .medium).foregroundStyle(theme.blueC)
                Spacer(minLength: 4)
                if let canonical {
                    Menu("중요도 \(canonical.importance)") {
                        ForEach(1...5, id: \.self) { level in
                            Button("중요도 \(level)") {
                                applyOverride(NarrativeOverride(kind: .eventImportance, key: canonical.canonicalKey, value: String(level), anchor: canonical.quote), identity: prepared.identity)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .purloryUIFont(10)
                    .fixedSize()
                }
            }
        }
        .contextMenu {
            Button("본문 이동") {
                let inspection = ProjectSourceInspection(session: session)
                let reference = OriginalSourceReference(key: prepared.identity.key, revision: prepared.projection.revision, evidence: row.evidence, selection: .passage)
                if let token = inspection.capture() { requests.jump(to: reference, inspection: inspection, token: token, in: session) }
            }
            if let scene {
                Divider()
                Button("장면 제목 바꾸기…") {
                    draftSceneTitle = row.title
                    editingSceneAnchor = row.evidence.quote
                    editingSceneHash = scene.contentHash
                }
                Menu("장면 유형") {
                    ForEach(SceneNarrativeType.allCases, id: \.rawValue) { kind in
                        Button(kind.rawValue) {
                            applyOverride(NarrativeOverride(kind: .sceneType, key: scene.contentHash, value: kind.rawValue, anchor: row.evidence.quote), identity: prepared.identity)
                        }
                    }
                }
                if sceneMeta?.titleUserEdited == true || sceneMeta?.typeUserEdited == true {
                    Button("장면 수정 초기화") {
                        removeOverride(.sceneTitle, key: scene.contentHash, identity: prepared.identity)
                        removeOverride(.sceneType, key: scene.contentHash, identity: prepared.identity)
                    }
                }
            }
            if let canonical, let snapshot {
                Divider()
                Menu("중요도") {
                    ForEach(1...5, id: \.self) { level in
                        Button {
                            applyOverride(NarrativeOverride(kind: .eventImportance, key: canonical.canonicalKey, value: String(level), anchor: canonical.quote), identity: prepared.identity)
                        } label: {
                            if canonical.importance == level { Label("\(level)", systemImage: "checkmark") }
                            else { Text("\(level)") }
                        }
                    }
                }
                let nonMainThreads = snapshot.plotThreads.filter { !$0.isMain }
                if !nonMainThreads.isEmpty {
                    Menu("플롯 배정") {
                        ForEach(nonMainThreads) { thread in
                            Menu(thread.title) {
                                ForEach(ThreadRole.allCases, id: \.rawValue) { role in
                                    Button(role.rawValue) {
                                        applyOverride(NarrativeOverride(kind: .threadMembership, key: "\(thread.id)|\(canonical.canonicalKey)", value: role.rawValue, anchor: canonical.quote), identity: prepared.identity)
                                    }
                                }
                                Button("이 플롯에서 제외") {
                                    applyOverride(NarrativeOverride(kind: .threadMembership, key: "\(thread.id)|\(canonical.canonicalKey)", value: "제외", anchor: canonical.quote), identity: prepared.identity)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("작가 수정과 기록…") { model.selectTile(.narrative); model.pouchSection = .object }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                model.toggle(.review)
            } label: {
                Label("검토", systemImage: "checkmark.seal").purloryUIFont(10.5, .medium)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.layout.contains(.review) ? theme.novelC : theme.ink2C)
            .help("연속성·설정·시간선 검토 타일 열기")
            .accessibilityIdentifier("purlory.narrative.open-review")

            Button {
                model.selectTile(.narrative); model.pouchSection = .object
            } label: {
                Label("수정·기록", systemImage: "text.book.closed").purloryUIFont(10.5, .medium)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(theme.ink2C)
            .accessibilityIdentifier("purlory.narrative.open-records")

            if requests.sourceReturnPoint?.key.projectID == session.activeProject?.id {
                Button("복귀") { requests.returnToWriting(in: session) }
                    .buttonStyle(.borderless)
                    .purloryUIFont(10.5, .medium)
                    .foregroundStyle(theme.blueC)
                    .accessibilityIdentifier("purlory.narrative.return")
            }

            Spacer(minLength: 4)

            if session.activeProject?.mode == .fiction {
                ManualIndexButton(indexer: indexer, theme: theme)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func applyOverride(_ overrideValue: NarrativeOverride, identity: ProjectRuntimeIdentity) {
        try? ProjectWriterEditing.perform(.override(overrideValue), in: session, identity: identity)
        indexer.rehydrate(entryID: identity.key.documentID.rawValue)
    }

    private func removeOverride(_ kind: NarrativeOverride.Kind, key: String, identity: ProjectRuntimeIdentity) {
        try? ProjectWriterEditing.perform(.removeOverride(kind, key), in: session, identity: identity)
        indexer.rehydrate(entryID: identity.key.documentID.rawValue)
    }
}

/// Continuity, character, timeline, dialogue, open-thread, and structure review tile.
struct WorkspaceReviewPane: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var indexer: BackgroundIndexer
    let theme: PurloryTheme
    @State private var projection: FictionReviewProjection?
    @State private var selectedCategory: ReviewIssue.Category?
    @State private var judgeControllers: [String: ContinuityJudgeController] = [:]
    @State private var errorMessage: String?

    private struct ReviewRefreshKey: Equatable {
        let identity: ProjectRuntimeIdentity?
        let snapshotGen: Int
        let candidateCount: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = session.selectedDocumentSnapshot, snapshot.mode == .fiction {
                let disposition = (try? ReviewDispositionIndex.load(snapshot)) ?? ReviewDispositionIndex(origin: snapshot.identity.key, records: [])
                let allIssues = projection?.issues ?? []
                let activeIssues = allIssues.filter {
                    disposition.state(for: $0) == .active && (selectedCategory == nil || $0.category == selectedCategory)
                }
                categoryBar(allIssues: allIssues, disposition: disposition)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if activeIssues.isEmpty {
                            Text(allIssues.isEmpty ? "현재 확인이 필요한 연속성·설정 항목이 없어요." : "선택한 분류에 해당하는 미확인 항목이 없어요.")
                                .purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(6)
                        }
                        ForEach(activeIssues) { issue in
                            issueCard(issue, snapshot: snapshot)
                        }
                        if !disposition.records.isEmpty {
                            DisclosureGroup("처리한 항목 (\(disposition.records.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(disposition.records) { record in
                                        HStack(alignment: .top, spacing: 6) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(record.kind == .intentional ? "의도한 설정" : "확인 완료")
                                                    .purloryUIFont(9.5, .semibold).foregroundStyle(theme.novelC)
                                                Text(record.statement).purloryUIFont(10.5).foregroundStyle(theme.ink2C)
                                            }
                                            Spacer(minLength: 4)
                                            Button("복원") {
                                                do {
                                                    try ReviewDispositionService.restore(
                                                        decisionID: record.id,
                                                        targetID: record.targetID,
                                                        in: session,
                                                        identity: snapshot.identity
                                                    )
                                                } catch { errorMessage = error.localizedDescription }
                                            }
                                            .buttonStyle(.borderless)
                                            .purloryUIFont(10, .medium)
                                        }
                                        .padding(6)
                                        .background(theme.chipC, in: RoundedRectangle(cornerRadius: 7))
                                    }
                                }.padding(.top, 4)
                            }
                            .purloryUIFont(11, .medium)
                            .foregroundStyle(theme.ink2C)
                            .padding(.top, 4)
                        }
                    }.padding(10)
                }
                Divider()
                HStack {
                    if requests.sourceReturnPoint?.key.projectID == session.activeProject?.id {
                        Button("집필 위치로 돌아가기") { requests.returnToWriting(in: session) }
                            .buttonStyle(.borderless)
                            .purloryUIFont(10.5, .medium)
                            .foregroundStyle(theme.blueC)
                    }
                    Spacer()
                    ManualIndexButton(indexer: indexer, theme: theme)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                Text("소설 원고를 선택하면 설정·시간선·인물 연속성을 검토할 수 있어요.")
                    .purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(14)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purlory.workspace.review-pane")
        .task(id: ReviewRefreshKey(
            identity: session.runtimeIdentity,
            snapshotGen: indexer.snapshotGeneration,
            candidateCount: indexer.continuityCandidates.count
        )) {
            guard let document = session.selectedDocumentSnapshot else { projection = nil; return }
            let snap = indexer.snapshot
            let origin = indexer.snapshotRuntimeIdentity
            let candidates = indexer.continuityCandidates
            let prepared = try? await FictionReviewProjection.prepare(
                document, snapshot: snap, snapshotOrigin: origin, candidates: candidates
            )
            if !Task.isCancelled { projection = prepared }
        }
        .onDisappear {
            for controller in judgeControllers.values { controller.dismiss() }
            judgeControllers.removeAll()
        }
        .alert("검토 판정을 저장할 수 없어요", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func categoryBar(allIssues: [ReviewIssue], disposition: ReviewDispositionIndex) -> some View {
        let active = allIssues.filter { disposition.state(for: $0) == .active }
        let counts = Dictionary(grouping: active, by: \.category).mapValues(\.count)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                categoryChip(nil, title: "전체", count: active.count)
                ForEach(ReviewIssue.Category.allCases, id: \.rawValue) { category in
                    if let count = counts[category], count > 0 {
                        categoryChip(category, title: categoryLabel(category), count: count)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func categoryChip(_ category: ReviewIssue.Category?, title: String, count: Int) -> some View {
        let selected = selectedCategory == category
        return Button {
            selectedCategory = selected ? nil : category
        } label: {
            HStack(spacing: 4) {
                Text(title).purloryUIFont(10, .medium)
                Text("\(count)").purloryUIFont(9.5)
                    .foregroundStyle(selected ? theme.novelC : theme.workspaceMutedC)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? theme.activeBgC : theme.chipC))
        }
        .buttonStyle(.plain)
    }

    private func issueCard(_ issue: ReviewIssue, snapshot: ProjectDocumentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(issue.title)
                    .purloryUIFont(10, .semibold)
                    .foregroundStyle(issue.severity == .review ? theme.novelC : theme.blueC)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.novelBgC))
                Spacer()
                Button("의도한 설정") {
                    record(.intentional, issue: issue, identity: snapshot.identity)
                }
                .buttonStyle(.borderless)
                .purloryUIFont(10, .medium)
                Button("확인 완료") {
                    record(.resolved, issue: issue, identity: snapshot.identity)
                }
                .buttonStyle(.borderless)
                .purloryUIFont(10)
            }
            Text(issue.message)
                .purloryUIFont(11)
                .foregroundStyle(theme.inkC)
                .fixedSize(horizontal: false, vertical: true)

            if let candidate = issue.candidate, issue.requiresJudging {
                judgeSection(for: issue.id, candidate: candidate, snapshot: snapshot)
            }

            ForEach(Array(issue.evidence.enumerated()), id: \.offset) { _, anchor in
                HStack(alignment: .top, spacing: 6) {
                    Text("“\(anchor.quote)”")
                        .purloryUIFont(10)
                        .foregroundStyle(theme.ink2C)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let project = session.activeProject,
                       let reference = OriginalSourceReference.exact(anchor, in: project) {
                        Button("원문 이동 →") {
                            let inspection = ProjectSourceInspection(session: session)
                            if let token = inspection.capture() {
                                requests.jump(to: reference, inspection: inspection, token: token, in: session)
                            }
                        }
                        .buttonStyle(.plain)
                        .purloryUIFont(10, .medium)
                        .foregroundStyle(theme.blueC)
                    }
                }
            }
        }
        .padding(9)
        .background(theme.hoverC, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func judgeSection(for issueID: String, candidate: ContinuityCandidate, snapshot: ProjectDocumentSnapshot) -> some View {
        if let controller = judgeControllers[issueID] {
            ContinuityJudgeInlineView(controller: controller, candidate: candidate, theme: theme)
        } else if let support = requests.judgeSupport, support.available {
            Button {
                let controller = support.makeController(session: session, origin: snapshot.identity)
                judgeControllers[issueID] = controller
                controller.judge(candidate: candidate)
            } label: {
                Label("로컬 AI 판정 요청", systemImage: "sparkles")
                    .purloryUIFont(10, .medium)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func record(_ choice: ReviewDispositionService.Choice, issue: ReviewIssue, identity: ProjectRuntimeIdentity) {
        do {
            try ReviewDispositionService.record(choice, issue: issue, in: session, identity: identity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func categoryLabel(_ category: ReviewIssue.Category) -> String {
        switch category {
        case .continuity: "설정"
        case .characters: "인물"
        case .timeline: "시간선"
        case .dialogue: "말투"
        case .openThreads: "열린 플롯"
        case .structure: "서술 구간"
        }
    }
}

private struct ContinuityJudgeInlineView: View {
    @ObservedObject var controller: ContinuityJudgeController
    let candidate: ContinuityCandidate
    let theme: PurloryTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch controller.status {
                case .preparing, .judging:
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text("로컬 모델이 문맥을 대조하는 중…").purloryUIFont(10).foregroundStyle(theme.ink2C)
                    Button("취소") { controller.cancel() }.buttonStyle(.borderless).purloryUIFont(10)
                case .needsReview:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(theme.novelC)
                    Text(controller.decision?.explanation ?? "검토가 필요한 충돌로 판정됐어요.").purloryUIFont(10, .medium).foregroundStyle(theme.inkC)
                case .quiet:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(theme.blueC)
                    Text("문맥상 자연스러운 서술로 보입니다.").purloryUIFont(10).foregroundStyle(theme.ink2C)
                default:
                    Button("다시 판정") { controller.judge(candidate: candidate) }
                        .buttonStyle(.bordered).controlSize(.mini).purloryUIFont(10)
                }
            }
        }
    }
}
