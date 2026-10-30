import SwiftUI

/// Attaches the prepared read-only map to the actual project and background reader.
struct StoryMapWorkspacePanel: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var indexer: BackgroundIndexer
    @ObservedObject var completion: CompletionController
    @ObservedObject var requests: ProjectEditorRequests
    let theme: PurloryTheme
    @StateObject private var controller: StoryMapController
    private struct RefreshID: Equatable { let identity: ProjectRuntimeIdentity?; let generation: Int }
    init(session: ProjectSession, indexer: BackgroundIndexer, completion: CompletionController,
         requests: ProjectEditorRequests, theme: PurloryTheme) {
        self.session = session; self.indexer = indexer; self.completion = completion; self.requests = requests; self.theme = theme
        _controller = StateObject(wrappedValue: StoryMapController(session: session))
    }
    var body: some View {
        StoryMapView(controller: controller, session: session, requests: requests, theme: theme)
            .task(id: RefreshID(identity: session.runtimeIdentity, generation: indexer.snapshotGeneration)) {
                controller.update(knowledge: indexer.snapshot, knowledgeOrigin: indexer.snapshotRuntimeIdentity,
                    generation: indexer.snapshotGeneration)
            }
            .onAppear {
                completion.observeForegroundCompletion(owner: controller) { [weak controller] busy in controller?.setForegroundBusy(busy) }
            }
            .onReceive(completion.$isMemoryPressurePaused) { controller.setPolicyPaused($0) }
            .onChange(of: controller.prepared) { _, _ in notePosition() }
            .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { value in
                guard let editor = value.object as? BlockTextView, editor === requests.nativeEditor else { return }
                notePosition()
            }
            .onDisappear { controller.stop() }
    }
    private func notePosition() {
        let identity = session.runtimeIdentity
        let offset = identity.flatMap { requests.nativeEditor?.storyMapSourcePosition(identity: $0) }
        controller.notePosition(offset, identity: identity)
    }
}

struct StoryMapView: View {
    @ObservedObject var controller: StoryMapController
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    let theme: PurloryTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("정렬", selection: Binding(get: { controller.order }, set: { controller.setOrder($0) })) {
                Text("원고순").tag(StoryMapProjection.Order.manuscript)
                Text("시간순").tag(StoryMapProjection.Order.chronology)
            }
            .pickerStyle(.segmented).accessibilityIdentifier("purlory.story-map.order")
            if let prepared = controller.prepared, prepared.identity == session.runtimeIdentity {
                filters(prepared.projection)
                if controller.visibleRows.isEmpty {
                    notice(prepared.projection.rows.isEmpty ? "원고의 장면이 여기에 보여요." : "조건에 맞는 사건이 없어요.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(controller.visibleRows) { row in sourceRow(row, prepared: prepared) }
                        }
                    }
                }
            } else { notice(statusText) }
            if let error = requests.sourceNavigationError { notice(error) }
            Spacer(minLength: 0)
            if requests.sourceReturnPoint?.key.projectID == session.activeProject?.id {
                StoryMapActionButton(identifier: "purlory.story-map.return", title: "집필 위치로 돌아가기", theme: theme) {
                    requests.returnToWriting(in: session)
                }.frame(height: 30)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspacePaperSurface(theme: theme, identifier: "purlory.story-map"))
        .accessibilityElement(children: .contain).accessibilityIdentifier("purlory.story-map")
        .accessibilityLabel("이야기 지도")
    }
    private func filters(_ projection: StoryMapProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    Button("모든 플롯") { controller.filter(threadID: nil, characterID: controller.selectedCharacterID) }
                    ForEach(projection.threads) { item in
                        Button(item.title) { controller.filter(threadID: item.id, characterID: controller.selectedCharacterID) }
                    }
                } label: {
                    Label(projection.threads.first { $0.id == controller.selectedThreadID }?.title
                        ?? (controller.selectedThreadID == nil ? "모든 플롯" : "선택한 플롯"), systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier("purlory.story-map.plot")
                Menu {
                    Button("모든 인물") { controller.filter(threadID: controller.selectedThreadID, characterID: nil) }
                    ForEach(projection.characters) { item in
                        Button(item.title) { controller.filter(threadID: controller.selectedThreadID, characterID: item.id) }
                    }
                } label: {
                    Label(projection.characters.first { $0.id == controller.selectedCharacterID }?.title
                        ?? (controller.selectedCharacterID == nil ? "모든 인물" : "선택한 인물"), systemImage: "person")
                }
                .accessibilityIdentifier("purlory.story-map.character")
            }
            .purloryUIFont(11).lineLimit(1)
            if controller.selectedThreadID != nil || controller.selectedCharacterID != nil {
                Button("필터 지우기") { controller.filter(threadID: nil, characterID: nil) }
                    .purloryUIFont(10).accessibilityIdentifier("purlory.story-map.clear-filters")
            }
            if controller.order == .chronology { notice("확인된 시간 관계를 따르며, 불확실한 순서는 원고순으로 보여요.") }
        }
    }
    private func sourceRow(_ row: StoryMapProjection.Row, prepared: PreparedStoryMap) -> some View {
        StoryMapActionButton(identifier: "purlory.story-map.row.\(row.id)", title: row.title, theme: theme,
            detail: row.kind == .event ? row.evidence.quote : nil, help: "원문: " + row.evidence.quote,
            label: "\(row.kind == .scene ? "장면" : "사건"), \(row.title)",
            marker: row.kind == .event ? String(repeating: "● ", count: max(1, min(3, row.laneSlots.count))) : "",
            current: controller.currentSceneID == row.sceneID && row.kind == .scene) {
                requests.jump(to: row, prepared: prepared, in: session)
            }
            .frame(maxWidth: .infinity).frame(height: row.kind == .scene ? 38 : 64)
    }
    private var statusText: String {
        switch controller.status {
        case .idle: "원고의 장면이 여기에 보여요."
        case .preparing: "지도를 준비하고 있어요."
        case .paused: "집필을 위해 지도 갱신을 잠시 쉬고 있어요."
        case .unavailable: "지도를 준비하지 못했어요. 원고를 편집하면 다시 확인해요."
        }
    }
    private func notice(_ text: String) -> some View { Text(text).purloryUIFont(11).foregroundStyle(theme.ink3C) }
}
