import SwiftUI

enum WorkspaceMotion {
    static let navigator = Animation.spring(response: 0.3, dampingFraction: 0.9)
}

/// The shell owns presentation only; document lifetime, storage and indexing belong to the session.
struct WorkspaceShellView<Navigator: View, Editor: View, Context: View, Rail: View>: View {
    @Binding var navigatorWidth: Double
    let presentation: WorkspacePresentationState
    let onNavigatorCollapse: () -> Void
    let railWidth: CGFloat
    let theme: PurloryTheme
    @ViewBuilder var navigator: () -> Navigator
    @ViewBuilder var editor: () -> Editor
    @ViewBuilder var context: () -> Context
    @ViewBuilder var rail: () -> Rail
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.purloryWorkspaceAccessibilityOptions) private var accessibilityOptions
    @State private var navigatorDragProjectedWidth: CGFloat?
    private var reduceMotion: Bool { accessibilityOptions.resolvedReduceMotion(system: systemReduceMotion) }

    var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayoutPolicy.resolve(availableWidth: geometry.size.width,
                presentation: presentation, railWidth: railWidth,
                projectedNavigatorWidth: navigatorDragProjectedWidth)
            let contextVisible = presentation.contextVisible
            let effectiveDock = layout.toolDock
            let height = max(0, geometry.size.height - 2 * WorkspaceLayoutPolicy.outerInset)
            let railReservation = railWidth > 0 ? railWidth + WorkspaceLayoutPolicy.surfaceGap : 0
            let navigatorLeading = WorkspaceLayoutPolicy.outerInset + railReservation
                + (layout.navigatorPlacement == .overlay && contextVisible && effectiveDock == .left
                    ? WorkspaceLayoutState.toolWidth + WorkspaceLayoutPolicy.toolSeparatorWidth : 0)

            HStack(spacing: 0) {
                if railWidth > 0 {
                    rail().frame(width: railWidth)
                    Color.clear.frame(width: WorkspaceLayoutPolicy.surfaceGap)
                }
                // This allocation changes width; the actual navigator keeps one overlay slot.
                Color.clear.frame(width: layout.navigatorReservation)
                HStack(spacing: 0) {
                    if contextVisible && effectiveDock == .left {
                        context().frame(width: WorkspaceLayoutState.toolWidth)
                            .background(WorkspaceToolSurface(theme: theme, floating: false))
                            .clipShape(RoundedRectangle(cornerRadius: PurloryRadius.lg, style: .continuous))
                        Color.clear.frame(width: WorkspaceLayoutPolicy.toolSeparatorWidth)
                    }
                    VStack(spacing: 0) {
                        WorkspaceFrame(theme: theme) {
                            editor().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if contextVisible && effectiveDock == .bottom {
                            Color.clear.frame(height: WorkspaceLayoutPolicy.surfaceGap)
                            context().frame(height: min(WorkspaceLayoutState.bottomToolMaxHeight, height * 0.4))
                                .background(WorkspaceToolSurface(theme: theme, floating: false))
                                .clipShape(RoundedRectangle(cornerRadius: PurloryRadius.lg, style: .continuous))
                        }
                    }
                    .frame(width: layout.manuscriptWidth, height: height)
                    if contextVisible && effectiveDock == .right {
                        Color.clear.frame(width: WorkspaceLayoutPolicy.toolSeparatorWidth)
                        context().frame(width: WorkspaceLayoutState.toolWidth)
                            .background(WorkspaceToolSurface(theme: theme, floating: false))
                            .clipShape(RoundedRectangle(cornerRadius: PurloryRadius.lg, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(WorkspaceLayoutPolicy.outerInset)
            .overlay(alignment: .topLeading) {
                if presentation.navigatorVisible {
                    navigator()
                        .frame(width: layout.navigatorWidth, height: height)
                        .opacity(navigatorDragOpacity)
                        .background(theme.cardSurfaceC)
                        .clipShape(RoundedRectangle(cornerRadius: PurloryRadius.lg, style: .continuous))
                        .offset(x: navigatorLeading, y: WorkspaceLayoutPolicy.outerInset)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topLeading) {
                if presentation.navigatorVisible {
                    SidebarResizeDivider(
                        width: Binding(get: { layout.navigatorWidth }, set: { navigatorWidth = Double($0) }),
                        minWidth: WorkspaceLayoutState.navigatorMinWidth,
                        maxWidth: max(WorkspaceLayoutState.navigatorMinWidth, layout.navigatorMaximumWidth),
                        collapseThreshold: WorkspaceLayoutState.navigatorCollapseThreshold,
                        collapseReleaseThreshold: WorkspaceLayoutState.navigatorCollapseReleaseThreshold,
                        onCollapse: { settleNavigatorDrag(collapse: true) },
                        onDragPreview: { navigatorDragProjectedWidth = $0 },
                        onDragSettled: { settleNavigatorDrag(collapse: false) }, theme: theme)
                        .frame(width: 24, height: height)
                        .offset(x: navigatorLeading + layout.navigatorWidth - 12,
                                y: WorkspaceLayoutPolicy.outerInset)
                }
            }
            .overlay(alignment: .topTrailing) {
                if contextVisible && effectiveDock == .floating {
                    context()
                        .frame(width: WorkspaceLayoutState.toolWidth,
                            height: min(WorkspaceLayoutState.floatingToolMaxHeight, max(240, geometry.size.height - 36)))
                        .background(WorkspaceToolSurface(theme: theme, floating: true))
                        .clipShape(RoundedRectangle(cornerRadius: PurloryRadius.lg, style: .continuous))
                        .shadow(color: .black.opacity(PurloryElevation.floating.opacity),
                            radius: PurloryElevation.floating.radius, y: PurloryElevation.floating.y)
                        .padding(18)
                }
            }
        }
        .background(theme.workspaceSurfaceC)
    }

    private var navigatorDragOpacity: Double {
        guard let projectedWidth = navigatorDragProjectedWidth else { return 1 }
        let collapseRange =
            WorkspaceLayoutState.navigatorMinWidth
            - WorkspaceLayoutState.navigatorCollapseThreshold
        let progress = min(
            1,
            max(
                0,
                (WorkspaceLayoutState.navigatorMinWidth - projectedWidth) / collapseRange))
        return 1 - Double(progress) * 0.2
    }

    private func settleNavigatorDrag(collapse: Bool) {
        withAnimation(reduceMotion ? nil : WorkspaceMotion.navigator) {
            navigatorDragProjectedWidth = nil
            if collapse {
                onNavigatorCollapse()
            }
        }
    }
}

struct WorkspaceChromeSurface: View {
    let theme: PurloryTheme
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.purloryWorkspaceAccessibilityOptions) private var accessibilityOptions

    var body: some View {
        if systemReduceTransparency || accessibilityOptions.reduceTransparency {
            theme.workspaceSurfaceC
        } else {
            Rectangle().fill(.thinMaterial).overlay(theme.toolbarC)
        }
    }
}

struct WorkspaceToolSurface: View {
    let theme: PurloryTheme
    let floating: Bool
    var body: some View {
        WorkspacePaperSurface(theme: theme, identifier: "purlory.workspace.tool",
            surface: floating ? theme.pill.withAlphaComponent(1) : theme.cardSurface)
    }
}

/// Connects the workspace directly to the sole mutable project owner.
struct WorkspaceSurface: View {
    @ObservedObject var projectSession: ProjectSession
    @ObservedObject var editorRequests: ProjectEditorRequests
    @ObservedObject var completion: CompletionController
    @ObservedObject var livingMargin: LivingMarginModel
    let indexer: BackgroundIndexer
    var editorBridge: ProjectEditorBridge? = nil
    var positionStore: WritingPositionStore = .shared
    var writingDiagnostics: WritingDiagnosticsRuntime? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @StateObject private var palette = PaletteSettings.shared
    @StateObject private var outline = DocumentOutlineController()
    @StateObject private var spatial = SpatialWorkspaceController()
    @State private var seededSpatialProject: WritingProjectID?
    @State private var assistance: WorkspaceAssistance?
    @State private var entities: WorkspaceEntityController?
    @State private var diagnosticsVisible = false
    @State private var writerSection: SidebarSection?
    @AppStorage("purlory.appearance") private var appearance = ""
    @AppStorage("purlory.sidebarVisible") private var sidebarVisible = true
    @AppStorage("purlory.sidebarSection") private var section = SidebarSection.files.rawValue

    var body: some View {
        let theme = palette.theme(for: colorScheme)
        VStack(spacing: 0) {
            WorkspaceSpatialChrome(session: projectSession, model: spatial, theme: theme)
            spatialWorkspace(theme: theme)
        }
        .background {
            if spatial.layout.isSingleManuscript { theme.editorSurfaceC }
            else { WorkspaceLiquidGlass(theme: theme) }
        }
        .overlay { WorkspacePaperGrain().allowsHitTesting(false).accessibilityHidden(true) }
        .overlay(alignment: .bottom) {
            if let toast = spatial.toast {
                HStack(spacing: 8) {
                    Circle().fill(theme.ink2C).frame(width: 6, height: 6)
                    Text(toast).purloryUIFont(11, .medium)
                }.foregroundStyle(theme.inkC).padding(.horizontal, 14).padding(.vertical, 6)
                    .background(theme.pillC, in: Capsule()).overlay(Capsule().strokeBorder(theme.pillBorderC))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.bottom, 32).allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .accessibilityIdentifier("purlory.workspace.toast")
            }
        }
        .animation(WorkspaceHTMLStyle.animation(0.22), value: spatial.toast)
        .tint(theme.blueC)
        .ignoresSafeArea(.container, edges: .top)
        .background(pouchBridge(theme: theme).frame(width: 0, height: 0))
        .task(id: projectSession.runtimeIdentity) {
            outline.update(activeWritingMode == .general ? projectSession.selectedDocumentSnapshot : nil)
        }
        .onAppear {
            configureSpatial()
            completion.observeForegroundCompletion(owner: outline) { [weak outline] busy in
                outline?.setForegroundBusy(busy)
            }
        }
        .onDisappear { outline.stop() }
        .onChange(of: spatial.pouchSection) { _, destination in
            if destination == .ai { showAssistance(.coauthor, theme: theme) }
            if destination == .object {
                writerSection = spatial.selectedTile == .characters ? .bible : (spatial.selectedTile == .narrative ? .narrative : .context)
                editorRequests.pouch?.dismissTools()
            }
        }
        .sheet(isPresented: Binding(get: { writerSection != nil }, set: { if !$0 { writerSection = nil } })) {
            if let writerSection {
                VStack(spacing: 0) {
                    HStack {
                        Text(writerSection == .bible ? "인물·작품 정보" : (writerSection == .narrative ? "작가 수정과 기록" : "AI 문맥"))
                            .purloryUIFont(13, .semibold)
                        Spacer()
                        Button("닫기") { self.writerSection = nil }.keyboardShortcut(.cancelAction)
                    }.padding(16)
                    ProjectWriterToolsView(session: projectSession, completion: completion, editorRequests: editorRequests,
                        section: writerSection, theme: theme, spatial: spatial, indexer: indexer)
                }.frame(width: 460, height: 540).background(theme.editorSurfaceC)
            }
        }
        .onChange(of: projectSession.selectedDocumentID) { _, _ in configureSpatial() }
        .onChange(of: projectSession.activeProject?.id) { _, _ in configureSpatial() }
        .onChange(of: projectSession.activeProject?.trashedDocumentIDs) { _, _ in configureSpatial() }
        .onChange(of: section) { _, value in
            let tile: WorkspaceTileID?
            switch value {
            case SidebarSection.bible.rawValue: tile = .characters
            case SidebarSection.narrative.rawValue: tile = .narrative
            case SidebarSection.context.rawValue: tile = .context
            case SidebarSection.margin.rawValue: tile = .margin
            default: tile = nil
            }
            if let tile, !spatial.layout.contains(tile) { spatial.toggle(tile) }
        }
        .onChange(of: sidebarVisible) { _, value in
            if spatial.layout.contains(.navigator) != value { spatial.toggle(.navigator) }
        }
        .onChange(of: projectSession.workspaceMode) { _, mode in
            if mode == .write {
                if spatial.layout.contains(.map) { _ = spatial.close(.map) }
                if spatial.layout.contains(.outline) { _ = spatial.close(.outline) }
            }
            if mode == .map && !spatial.layout.contains(.map) { spatial.toggle(.map) }
            if mode == .outline && !spatial.layout.contains(.outline) { spatial.toggle(.outline) }
        }
        .onChange(of: outline.prepared) { _, prepared in
            updateOutlinePosition(identity: prepared?.identity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard let editor = notification.object as? BlockTextView, editor === editorRequests.nativeEditor else { return }
            updateOutlinePosition(identity: projectSession.runtimeIdentity)
        }
        .onChange(of: section) { _, _ in
            if outlineVisible || mapVisible { projectSession.selectWorkspaceMode(.write) }
        }
    }

    private func configureSpatial() {
        guard let project = projectSession.activeProject else { return }
        spatial.configure(project: project, selected: projectSession.selectedDocumentID,
            defaults: projectSession.presentationPreferences)
        editorRequests.spatialWorkspace = spatial
        if assistance == nil { assistance = completion.makeWorkspaceAssistance(session: projectSession, requests: editorRequests, margin: livingMargin) }
        if entities == nil { entities = WorkspaceEntityController(session: projectSession, requests: editorRequests) }
        editorRequests.workspaceHover = { [weak entities] editor, key, offset in entities?.hover(editor: editor, key: key, nativeOffset: offset) }
        editorRequests.workspaceHoverEnd = { [weak entities] in
            if NSEvent.modifierFlags.contains(.option) { entities?.scheduleHide() }
            else { entities?.hide() }
        }
        editorRequests.workspacePolish = { [weak assistance] editor in
            guard let assistance else { return }
            Task { await assistance.runInline(.polish, editor: editor) }
        }
        for (key, editor) in editorRequests.registeredEditors {
            editorRequests.installSpatialInteraction(editor, key: key, session: projectSession)
        }
        spatial.onActivate = { [weak projectSession, weak editorRequests] id in
            projectSession?.selectDocument(id); editorRequests?.focusEditor()
        }
        spatial.onClose = { [weak projectSession] tile in
            if tile == .map || tile == .outline { projectSession?.selectWorkspaceMode(.write) }
        }
        spatial.onTileReorder = { [weak projectSession] layout in
            guard let project = projectSession?.activeProject else { return }
            projectSession?.reorderDocuments(layout.reorderedDocuments(project.documents.map(\.id)), projectID: project.id)
        }
        spatial.onCommit = { [weak projectSession] layout in
            if let selected = projectSession?.selectedDocumentID, !layout.openDocuments.contains(selected),
               let next = layout.openDocuments.first { projectSession?.selectDocument(next) }
        }
        spatial.onNavigationOrder = { [weak projectSession] order in
            guard let project = projectSession?.activeProject else { return }
            var next = order.makeIterator()
            let ids = project.documents.map { document in
                project.trashedDocumentIDs.contains(document.id) ? document.id : (next.next() ?? document.id)
            }
            projectSession?.reorderDocuments(ids, projectID: project.id)
        }
        let stored: WorkspaceTileID?
        switch section {
        case SidebarSection.bible.rawValue: stored = .characters
        case SidebarSection.narrative.rawValue: stored = .narrative
        case SidebarSection.context.rawValue: stored = .context
        default: stored = nil
        }
        if seededSpatialProject != project.id {
            seededSpatialProject = project.id
            if !spatial.restoredPreference, let stored, !spatial.layout.contains(stored) { spatial.toggle(stored) }
        }
    }

    private func spatialWorkspace(theme: PurloryTheme) -> some View {
        SpatialWorkspaceCanvas(model: spatial, theme: theme) { tile in
            switch tile {
            case .document(let id):
                return AnyView(SpatialDocumentTile(session: projectSession, requests: editorRequests,
                    completion: completion, model: spatial, documentID: id, theme: theme,
                    editorBridge: editorBridge, positionStore: positionStore))
            case .navigator:
                return AnyView(SpatialNavigatorPane(session: projectSession, requests: editorRequests, model: spatial,
                    completion: completion, theme: theme, onClose: { spatial.toggle(.navigator); sidebarVisible = false; editorRequests.focusEditor() }))
            default:
                return AnyView(spatialTool(tile, theme: theme))
            }
        }
    }

    private func pouchBridge(theme: PurloryTheme) -> some View {
        WorkspacePouchBridge(model: spatial, requests: editorRequests, defaults: projectSession.presentationPreferences,
            theme: theme, tools: AnyView(WorkspacePouchTools(session: projectSession, requests: editorRequests,
                model: spatial, completion: completion, settings: completion.settings, theme: theme,
                openCoauthor: { showAssistance(.coauthor, theme: theme) },
                openSettings: { editorRequests.pouch?.dismissTools(); openSettings() })
                .defaultAppStorage(projectSession.presentationPreferences)), targetTitle: "집필 도구", actions: [
                pouchTool(.navigator, id: "purlory.workspace.navigator-toggle", label: "문서 목록", symbol: "folder"),
                pouchTool(.characters, id: "purlory.workspace.characters", label: "인물·작품 정보", symbol: "person.2"),
                pouchTool(.narrative, id: "purlory.workspace.narrative", label: "서사 흐름", symbol: "point.topleft.down.curvedto.point.bottomright.up"),
                pouchTool(.margin, id: "purlory.workspace.margin", label: "마진 노트", symbol: "sparkles"),
                WorkspacePouchAction(id: "purlory.source-search.show", label: "검색 · 문서, 원문, 도구 찾기", symbol: "magnifyingglass", selected: { spatial.layout.contains(.search) }, enabled: { projectSession.isEditorEditable }) {
                    spatial.openSearch()
                },
                WorkspacePouchAction(id: "purlory.workspace.object-settings", label: "집필 도구 열기", symbol: "slider.horizontal.3", selected: { spatial.pouchSection != nil }) {
                    spatial.openPouchTools()
                }
            ], extraActions: [
                WorkspacePouchAction(id: "purlory.workspace.pouch.collapse", label: "창을 주머니로 접기", symbol: "arrow.down.right.and.arrow.up.left") {
                    editorRequests.pouch?.collapse()
                },
                WorkspacePouchAction(id: "purlory.workspace.new-document", label: "새 원고", symbol: "plus") {
                    ProjectCommandActions(session: projectSession).newDocument(.manuscript); editorRequests.focusEditor()
                },
                WorkspacePouchAction(id: "purlory.workspace.pouch.coauthor", label: "공동 집필", symbol: "sparkles") {
                    showAssistance(.coauthor, theme: theme)
                },
                WorkspacePouchAction(id: "purlory.workspace.pouch.open-all", label: "문서 나란히 펼치기", symbol: "rectangle.split.3x1") { spatial.openAll() },
                WorkspacePouchAction(id: "purlory.workspace.theme", label: "테마 전환", symbol: "circle.lefthalf.filled") {
                    appearance = colorScheme == .dark ? "light" : "dark"
                },
                WorkspacePouchAction(id: "purlory.workspace.more.characters", label: "인물과 작품 정보", symbol: "person.2") {
                    if !spatial.layout.contains(.characters) { spatial.toggle(.characters) }
                    spatial.selectTile(.characters); spatial.pouchSection = .object
                },
                WorkspacePouchAction(id: "purlory.workspace.more.narrative", label: "작가 수정과 기록", symbol: "text.book.closed") {
                    if !spatial.layout.contains(.narrative) { spatial.toggle(.narrative) }
                    spatial.selectTile(.narrative); spatial.pouchSection = .object
                },
                pouchTool(.review, id: "purlory.workspace.review", label: "연속성·설정 검토", symbol: "checkmark.seal"),
                WorkspacePouchAction(id: "purlory.workspace.quick-command", label: "빠른 명령 팔레트", symbol: "command") {
                    _ = WorkspaceQuickCommandPanel.present(session: projectSession, requests: editorRequests, theme: theme, toggleTheme: {
                        appearance = colorScheme == .dark ? "light" : "dark"
                    })
                },
                WorkspacePouchAction(id: "purlory.workspace.autocomplete", label: completion.settings.autocompleteEnabled ? "자동완성 켜짐" : "자동완성 꺼짐", symbol: "sparkles", selected: { completion.settings.autocompleteEnabled }, enabled: { !completion.isManagingModel }) {
                    completion.setAutocompleteEnabled(!completion.settings.autocompleteEnabled)
                },
                WorkspacePouchAction(id: "purlory.workspace.diagnostics", label: "문장 진단 상태", symbol: "text.magnifyingglass") { diagnosticsVisible = true },
                WorkspacePouchAction(id: "purlory.workspace.settings", label: "설정", symbol: "gearshape") { openSettings() },
                pouchTool(.context, id: "purlory.workspace.context", label: "제안에 쓰인 내용", symbol: "text.alignleft"),
                WorkspacePouchAction(id: "purlory.workspace.source-search", label: "원문 검색", symbol: "doc.text.magnifyingglass") {
                    spatial.openSearch()
                },
                WorkspacePouchAction(id: "purlory.workspace.source-inspection", label: "원문 확인·질문", symbol: "text.bubble") {
                    SourceSearchPanel.present(session: projectSession, requests: editorRequests)
                }
            ] + WorkspaceModePresentation.options(for: activeWritingMode).map { option in
                WorkspacePouchAction(id: "purlory.workspace.mode.\(option.mode.rawValue)", label: option.label, symbol: option.mode == .write ? "pencil" : "map",
                    selected: { projectSession.workspaceMode == option.mode }) {
                    WorkspaceModeSelection.select(option.mode, session: projectSession) { editorRequests.focusEditor() }
                }
            })
            .sheet(isPresented: $diagnosticsVisible) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("문장 진단 상태").purloryUIFont(12, .semibold); Spacer(); Button("닫기") { diagnosticsVisible = false }.keyboardShortcut(.cancelAction) }
                    if let writingDiagnostics { WritingDiagnosticsStatusView(runtime: writingDiagnostics) }
                }.padding(20).frame(width: 420).background(theme.editorSurfaceC)
            }
    }

    private func pouchTool(_ tile: WorkspaceTileID, id: String, label: String, symbol: String) -> WorkspacePouchAction {
        WorkspacePouchAction(id: id, label: tile == .navigator ? (spatial.layout.contains(.navigator) ? "파일 목록 숨기기" : "파일 목록 보이기") : label, symbol: symbol, selected: { spatial.layout.contains(tile) }) {
            spatial.toggle(tile)
            if tile == .navigator { sidebarVisible = spatial.layout.contains(.navigator) }
            editorRequests.focusEditor()
        }
    }

    private func spatialTool(_ tile: WorkspaceTileID, theme: PurloryTheme) -> some View {
        VStack(spacing: 0) {
            SpatialTileHeader(tile: tile, title: spatialToolTitle(tile), theme: theme, actions: [])
                .frame(height: 32)
            Group {
                switch tile {
                case .search:
                    WorkspaceSearchPane(session: projectSession, requests: editorRequests, spatial: spatial, theme: theme) {
                        appearance = colorScheme == .dark ? "light" : "dark"
                    }
                case .margin:
                    livingMarginPanel(theme: theme)
                case .characters:
                    WorkspaceCharacterCards(session: projectSession, requests: editorRequests, completion: completion, model: spatial, indexer: indexer, theme: theme)
                case .map:
                    StoryMapWorkspacePanel(session: projectSession, indexer: indexer, completion: completion,
                        requests: editorRequests, theme: theme)
                case .outline:
                    DocumentOutlineView(controller: outline, requests: editorRequests, session: projectSession, theme: theme)
                case .narrative:
                    WorkspaceNarrativeCards(session: projectSession, requests: editorRequests, indexer: indexer, completion: completion, model: spatial, theme: theme)
                case .review:
                    WorkspaceReviewPane(session: projectSession, requests: editorRequests, indexer: indexer, theme: theme)
                default:
                    ProjectWriterToolsView(session: projectSession, completion: completion, editorRequests: editorRequests,
                        section: tile == .characters ? .bible : (tile == .narrative ? .narrative : .context), theme: theme, spatial: spatial, indexer: indexer)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(theme.cardSurfaceC)
            .clipShape(RoundedRectangle(cornerRadius: PurloryRadius.lg))
    }

    private func spatialToolTitle(_ tile: WorkspaceTileID) -> String {
        switch tile {
        case .characters: "인물"
        case .narrative: "서사 흐름"
        case .margin: "마진 노트"
        case .map: "이야기 지도"
        case .outline: "문서 개요"
        case .review: "검토"
        case .search: "검색"
        default: "참고 기록"
        }
    }

    private func showAssistance(_ mode: WorkspaceAssistance.Mode, theme: PurloryTheme) {
        guard let assistance else { return }
        if mode == .coauthor {
            editorRequests.pouch?.dismissTools()
            WorkspaceAssistancePanel.present(.coauthor, model: assistance, requests: editorRequests, theme: theme)
        } else if let editor = editorRequests.nativeEditor {
            Task { await assistance.runInline(mode, editor: editor) }
        }
    }

    private var outlineVisible: Bool {
        activeWritingMode == .general && projectSession.workspaceMode == .outline
    }
    private var mapVisible: Bool { activeWritingMode == .fiction && projectSession.workspaceMode == .map }
    private func updateOutlinePosition(identity: ProjectRuntimeIdentity?) {
        let offset = identity.flatMap { editorRequests.nativeEditor?.outlineSourcePosition(identity: $0) }
        outline.notePosition(offset, identity: identity)
    }

    private func livingMarginPanel(theme: PurloryTheme) -> some View {
        VStack(spacing: 0) {
            if let writingDiagnostics {
                WritingDiagnosticsStatusView(runtime: writingDiagnostics)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            LivingMarginView(model: livingMargin, mode: activeWritingMode, theme: theme,
                onJumpToEvidence: navigateMarginEvidence,
                onAction: writingQualityAction, supportsAction: { $0.kind == .writingQuality }, spatial: spatial)
            if let error = editorRequests.sourceNavigationError {
                Text(error).purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(12)
            }
            if editorRequests.sourceReturnPoint?.key.projectID == projectSession.activeProject?.id {
                Button("집필 위치로 돌아가기") { editorRequests.returnToWriting(in: projectSession) }
                    .purloryUIFont(11).padding(12)
                    .accessibilityIdentifier("purlory.living-margin.return")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePaperSurface(theme: theme, identifier: "purlory.living-margin"))
    }

    private func navigateMarginEvidence(_ insight: MarginInsight, _ anchor: EvidenceAnchor) {
        if insight.kind == .writingQuality {
            guard let writingDiagnostics else {
                editorRequests.sourceNavigationError = "원문 위치를 확인할 수 없어요. 새 제안을 확인해 주세요."
                return
            }
            _ = writingDiagnostics.navigateMarginEvidence(insightID: insight.id, evidence: anchor, requests: editorRequests)
        } else {
            guard let project = projectSession.activeProject, let reference = OriginalSourceReference.exact(anchor, in: project) else { return }
            let inspection = ProjectSourceInspection(session: projectSession)
            if let token = inspection.capture() { editorRequests.jump(to: reference, inspection: inspection, token: token, in: projectSession) }
        }
    }

    private var writingQualityAction: ((MarginInsight, MarginAction) -> Void)? {
        guard let writingDiagnostics else { return nil }
        return { insight, action in
            guard insight.kind == .writingQuality else { return }
            do { try writingDiagnostics.performMarginAction(insightID: insight.id, action: action) }
            catch { } // The runtime publishes a safe, localized action status.
        }
    }

    private var activeWritingMode: WritingMode {
        projectSession.activeProject?.mode ?? .general
    }
}

private struct ProjectToolUnavailableView: View {
    let theme: PurloryTheme

    var body: some View {
        VStack(alignment: .leading) {
            Text("이 프로젝트 도구는 아직 사용할 수 없어요.")
                .purloryUIFont(11)
                .foregroundStyle(theme.workspaceMutedC)
                .padding(14)
            Spacer(minLength: 0)
        }
    }
}

struct WorkspaceToolDescriptor: Equatable {
    let title: String
    let subtitle: String
    let systemImage: String
}

enum WorkspaceToolPresentation {
    static func isVisible(_ rawSection: String) -> Bool {
        switch SidebarSection(rawValue: rawSection) {
        case .bible, .narrative, .context: true
        case .files, .margin, .none: false
        }
    }

    static func descriptor(for rawSection: String) -> WorkspaceToolDescriptor {
        switch SidebarSection(rawValue: rawSection) {
        case .margin:
            WorkspaceToolDescriptor(
                title: "리빙 마진",
                subtitle: "원고 옆에서 확인할 제안",
                systemImage: "sparkles")
        case .bible:
            WorkspaceToolDescriptor(
                title: "인물과 작품 정보",
                subtitle: "저장된 장르와 인물 설정",
                systemImage: "book.closed")
        case .narrative:
            WorkspaceToolDescriptor(
                title: "작가 수정과 기록",
                subtitle: "저장된 판정과 대화 기록",
                systemImage: "arrow.triangle.branch")
        case .context:
            WorkspaceToolDescriptor(
                title: "제안에 쓰인 내용",
                subtitle: "참조한 원문과 저장된 선택",
                systemImage: "text.magnifyingglass")
        case .files, .none:
            WorkspaceToolDescriptor(
                title: "글 도구",
                subtitle: "원고를 돕는 보조 도구",
                systemImage: "sidebar.right")
        }
    }
}

/// Selection helpers mutate presentation state only. The close button itself restores
/// editor focus so callers that merely update stored presentation state stay side-effect free.
enum WorkspaceToolSelection {
    static func showLivingMargin(currentSection: inout String) {
        currentSection = SidebarSection.margin.rawValue
    }

    static func hide(currentSection: inout String) {
        currentSection = SidebarSection.files.rawValue
    }
}

/// Resolves project evidence without projecting the manuscript into a legacy entry.
@MainActor
enum LivingMarginWorkspaceBridge {
    @discardableResult
    static func jump(
        to anchor: EvidenceAnchor,
        in session: ProjectSession,
        sequence: Int
    ) -> EditorSearchJump? {
        guard let project = session.activeProject,
            !project.trashedDocumentIDs.contains(anchor.documentID),
            let document = project.documents.first(where: { $0.id == anchor.documentID }),
            let query = anchor.resolvedQuery(in: document.body)
        else { return nil }

        session.selectDocument(document.id)
        return EditorSearchJump(
            documentID: document.id,
            query: query,
            sequence: sequence)
    }
}
