import AppKit
import SwiftUI

enum ContentViewRoute: Equatable {
    case progress
    case firstRun
    case workspace
    case error

    static func resolve(_ phase: ProjectSessionPhase) -> ContentViewRoute {
        switch phase {
        case .loading, .suspended: .progress
        case .needsProject: .firstRun
        case .ready: .workspace
        case .failed: .error
        }
    }
}

/// Project writing workspace with one authoritative session and editor bridge.
public struct ContentView: View {
    @ObservedObject private var projectSession: ProjectSession
    private let startup: ProjectStartupCoordinator
    @ObservedObject private var editorRequests: ProjectEditorRequests
    @ObservedObject private var completion: CompletionController
    private let indexer: BackgroundIndexer
    @ObservedObject private var livingMargin: LivingMarginModel
    private let firstRunFlow: FirstRunFlow
    private let positionStore: WritingPositionStore
    private let writingDiagnostics: WritingDiagnosticsRuntime?
    @State private var projectEditorBridge = ProjectEditorBridge()
    /// ""=시스템 따름 / "light" / "dark" — 설정에서 전환.
    @AppStorage("purlory.appearance") private var appearance = ""
    public init(
        projectSession: ProjectSession,
        startup: ProjectStartupCoordinator,
        editorRequests: ProjectEditorRequests,
        completion: CompletionController,
        indexer: BackgroundIndexer,
        livingMargin: LivingMarginModel,
        firstRunFlow: FirstRunFlow,
        positionStore: WritingPositionStore = .shared,
        writingDiagnostics: WritingDiagnosticsRuntime? = nil
    ) {
        self.projectSession = projectSession
        self.startup = startup
        self.editorRequests = editorRequests
        self.completion = completion
        self.indexer = indexer
        self.livingMargin = livingMargin
        self.firstRunFlow = firstRunFlow
        self.positionStore = positionStore; self.writingDiagnostics = writingDiagnostics
    }

    public var body: some View {
        Group {
            switch ContentViewRoute.resolve(projectSession.phase) {
            case .progress:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(projectSession.phase == .suspended
                        ? "프로젝트 전환을 마무리하는 중…"
                        : "프로젝트 여는 중…")
                        .purloryUIFont(12)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .firstRun:
                FirstRunView(flow: firstRunFlow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .workspace:
                WorkspaceSurface(
                    projectSession: projectSession,
                    editorRequests: editorRequests,
                    completion: completion,
                    livingMargin: livingMargin,
                    indexer: indexer,
                    editorBridge: projectEditorBridge,
                    positionStore: positionStore, writingDiagnostics: writingDiagnostics)
            case .error:
                VStack(spacing: 12) {
                    Text("프로젝트를 열지 못했습니다")
                        .purloryUIFont(15, .semibold)
                    if let message = projectSession.lastErrorMessage {
                        Text(message)
                            .purloryUIFont(12)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("다시 시도") {
                        Task { try? await startup.bootstrap() }
                    }
                    Button("이전 원고 파일 선택…") {
                        guard let selection = ProjectImportPanel.selectLegacyArchive() else { return }
                        Task {
                            do { try await firstRunFlow.importFolder(selection: selection) }
                            catch { projectSession.reportError(error) }
                        }
                    }
                    .disabled(projectSession.isTransitioning)
                    Button("이전 저장본 확인…") {
                        Task {
                            if await ProjectRecoveryPanel.present(session: projectSession) { editorRequests.focusEditor() }
                        }
                    }
                    .disabled(projectSession.isTransitioning)
                    .accessibilityIdentifier("purlory.recovery.preview")
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
            .frame(minWidth: 860, minHeight: 540)
            .preferredColorScheme(preferredScheme)
            .onAppear {
                // The controller itself enforces explicit completion authorization.
                editorRequests.askSupport = completion.makeAskPurlorySupport()
                editorRequests.judgeSupport = completion.makeContinuityJudgeSupport()
                completion.preloadEngine()
                Self.connectProjectConsumers(session: projectSession, completion: completion, indexer: indexer,
                    writingDiagnostics: writingDiagnostics, editorBridge: projectEditorBridge, livingMargin: livingMargin)
                indexer.caretProvider = { [weak completion] in completion?.lastCaretLocation }
                projectSession.willTransition = { [weak projectEditorBridge, weak completion, weak indexer, weak writingDiagnostics] in
                    if let textView = projectEditorBridge?.editor {
                        if textView.hasMarkedText() {
                            textView.unmarkText()
                            // Publish accepted composition before the session closes its mutation gate.
                            textView.didChangeText()
                        }
                        textView.isEditable = false
                    }
                    writingDiagnostics?.prepareForProjectTransition()
                    completion?.prepareForProjectTransition()
                    indexer?.prepareForProjectTransition()
                }
                projectSession.documentDidChange = { [weak completion, weak indexer, weak projectEditorBridge] snapshot in
                    projectEditorBridge?.noteSnapshot(snapshot)
                    completion?.noteDocumentChange(snapshot)
                    indexer?.noteDocumentChange(snapshot)
                }
                if let snapshot = projectSession.selectedDocumentSnapshot {
                    projectSession.documentDidChange?(snapshot)
                }
            }
            .task {
                guard !projectSession.hasLoadedActiveProject else { return }
                try? await startup.bootstrap()
            }
    }

    static func connectProjectConsumers(
        session: ProjectSession, completion: CompletionController, indexer: BackgroundIndexer,
        writingDiagnostics: WritingDiagnosticsRuntime? = nil, editorBridge: ProjectEditorBridge? = nil,
        livingMargin: LivingMarginModel? = nil
    ) {
        if let writingDiagnostics, let editorBridge, let livingMargin {
            writingDiagnostics.connect(session: session, editorBridge: editorBridge, livingMargin: livingMargin)
        }
        writingDiagnostics?.configure(currentSnapshot: { [weak session] in session?.selectedDocumentSnapshot })
        completion.documentContextProvider = nil
        completion.projectDocumentProvider = { [weak session] in session?.selectedDocumentSnapshot }
        indexer.attach(documentProvider: { [weak session] in session?.selectedDocumentSnapshot })
        connectGhostContext(completion: completion, indexer: indexer, writingDiagnostics: writingDiagnostics)
        completion.knowledgeProvider = { [weak session, weak indexer] in
            guard let identity = session?.runtimeIdentity,
                indexer?.snapshotRuntimeIdentity == identity else { return nil }
            return indexer?.snapshot
        }
        completion.onRecordConversation = { [weak session] record in
            guard let session, let identity = session.runtimeIdentity else { return }
            try? ProjectWriterEditing.perform(.record(record), in: session, identity: identity)
        }
        var writerReader = WriterDocumentReader()
        completion.recordedConversationHashesProvider = { [weak session] in
            guard let snapshot = session?.selectedDocumentSnapshot,
                let writer = try? writerReader.read(snapshot) else { return [] }
            return Set(writer.recordedConversations.map(\.contentHash))
        }
    }

    static func connectGhostContext(completion: CompletionController, indexer: BackgroundIndexer,
                                    writingDiagnostics: WritingDiagnosticsRuntime? = nil) {
        completion.originalNameAnchorsProvider = { [weak indexer] in indexer?.originalNameAnchors }
        completion.observeForegroundCompletion(owner: indexer) { [weak indexer] busy in
            indexer?.setForegroundCompletionBusy(busy)
        }
        if let writingDiagnostics {
            completion.observeForegroundCompletion(owner: writingDiagnostics) { [weak writingDiagnostics] busy in
                writingDiagnostics?.setForegroundBusy(busy)
            }
        }
        completion.contextConfigurationDidChange = { [weak completion, weak indexer] in
            indexer?.originalNameAnchorsEnabled = completion?.usesOriginalNameAnchors ?? false
        }
        completion.contextConfigurationDidChange?()
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

}

// MARK: - 에디터 컬럼

/// View-scoped, weak native handle: transitions also work while this window is not key.
@MainActor
final class ProjectEditorBridge {
    weak var editor: BlockTextView?
    private var currentSnapshot: (() -> ProjectDocumentSnapshot?)?
    private(set) var pendingSnapshot: ProjectDocumentSnapshot?
    private var acceptedIdentity: ProjectRuntimeIdentity?
    private var acceptedRevision: UInt64?
    var snapshotDidChange: ((ProjectDocumentSnapshot) -> Void)?
    var commitDidChange: ((WritingEditorCommit, ProjectDocumentSnapshot) -> Void)?
    var compositionDidChange: ((WritingDiagnosticRange?) -> Void)?
    var editorDidChange: ((BlockTextView?) -> Void)?
    var nativeLoadDidChange: ((ProjectDocumentSnapshot) -> Void)?

    func connect(_ editor: BlockTextView, currentSnapshot: @escaping () -> ProjectDocumentSnapshot?) {
        let changed = self.editor !== editor
        if let previous = self.editor, changed { disconnect(previous) }
        self.editor = editor; self.currentSnapshot = currentSnapshot
        if changed { acceptedIdentity = nil; acceptedRevision = nil; editorDidChange?(editor) }
        editor.writingProjectionCapture.sourceDidLoad = { [weak self] in self?.didLoadSource() }
        editor.writingCommitDidChange = { [weak self] in self?.receive($0) }
        editor.writingCompositionDidChange = { [weak self] in self?.compositionDidChange?($0) }
        editor.writingRuntimeIdentityProvider = { [weak self] in self?.currentSnapshot?()?.identity }
        if let snapshot = currentSnapshot() { noteSnapshot(snapshot) }
    }
    func disconnect(_ editor: BlockTextView) {
        guard self.editor === editor else { return }
        editor.writingProjectionCapture.sourceDidLoad = nil
        editor.writingRuntimeIdentityProvider = nil
        editor.writingCommitDidChange = nil; editor.writingCompositionDidChange = nil
        self.editor = nil; currentSnapshot = nil; pendingSnapshot = nil
        acceptedIdentity = nil; acceptedRevision = nil; editorDidChange?(nil)
    }
    func replayPreparedAuthority(baseIdentity: ProjectRuntimeIdentity?) {
        acceptedIdentity = baseIdentity; acceptedRevision = nil
        if let snapshot = currentSnapshot?() { noteSnapshot(snapshot) }
    }
    private func didLoadSource() {
        guard let snapshot = currentSnapshot?() else { return }
        acceptedIdentity = nil; acceptedRevision = nil
        pendingSnapshot = snapshot; snapshotDidChange?(snapshot)
        nativeLoadDidChange?(snapshot)
        // A queued native load can outlive its binding. Identical bodies do not prove ownership.
        guard let editor, editor.writingDocumentIdentity == .project(snapshot.identity.key) else {
            if editor?.writingDocumentIdentity != nil { editor?.writingProjectionCapture.rejectUnownedLoad() }
            return
        }
        // Prove bytes only at load, outside ordinary edit handling.
        guard let source = editor.writingProjectionCapture.loadedSource,
              source.utf16.elementsEqual(snapshot.body.utf16) else {
            editor.writingProjectionCapture.rejectUnownedLoad()
            return
        }
        noteSnapshot(snapshot)
    }
    func noteSnapshot(_ snapshot: ProjectDocumentSnapshot) {
        guard currentSnapshot?()?.identity == snapshot.identity else { return }
        pendingSnapshot = snapshot
        snapshotDidChange?(snapshot)
        editor?.writingProjectionCapture.noteSnapshot(snapshot)
        adoptPreparedMap(snapshot)
    }
    private func adoptPreparedMap(_ snapshot: ProjectDocumentSnapshot) {
        guard let editor, editor.writingDocumentIdentity == .project(snapshot.identity.key),
              !editor.hasMarkedText(), editor.writingProjectionCapture.compositionDepth == 0,
              editor.writingProjectionCapture.mappedIdentity == snapshot.identity,
              editor.writingProjectionCapture.mappedRevision == editor.writingNativeRevision,
              editor.writingProjectionCapture.nativeLookup != nil,
              acceptedIdentity != snapshot.identity || acceptedRevision != editor.writingNativeRevision else { return }
        let base = acceptedIdentity?.key == snapshot.identity.key ? acceptedIdentity! : snapshot.identity
        let commit = WritingEditorCommit(baseIdentity: base, nativeRevision: editor.writingNativeRevision,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil)
        receive(commit)
    }
    func receive(_ commit: WritingEditorCommit) {
        guard let editor, let snapshot = currentSnapshot?(), snapshot.identity == pendingSnapshot?.identity,
              editor.writingDocumentIdentity == .project(snapshot.identity.key),
              snapshot.identity.key == commit.baseIdentity.key,
              editor.writingProjectionCapture.mappedIdentity == snapshot.identity,
              editor.writingProjectionCapture.mappedRevision == commit.nativeRevision,
              editor.writingNativeRevision == commit.nativeRevision, !editor.hasMarkedText() else { return }
        acceptedIdentity = snapshot.identity; acceptedRevision = commit.nativeRevision
        commitDidChange?(commit, snapshot)
    }
}

struct EditorPane: View {
    @ObservedObject var projectSession: ProjectSession
    @ObservedObject var editorRequests: ProjectEditorRequests
    @ObservedObject var completion: CompletionController
    @ObservedObject var settings: CompletionSettings
    let theme: PurloryTheme
    var editorBridge: ProjectEditorBridge? = nil
    var positionStore: WritingPositionStore = .shared
    var documentID: WritingDocumentID? = nil
    var showsChrome = true
    /// 집중 모드 — 툴바·상태 바를 숨겨 글에만 집중 (L10). 본문 상단 inset(44pt)이
    /// 신호등 아래에서 시작하므로 타이틀바 없이도 첫 줄이 신호등과 겹치지 않는다.
    @AppStorage("purlory.chromeHidden") private var chromeHidden = false

    var body: some View {
        VStack(spacing: 0) {
            if showsChrome && !chromeHidden {
                EditorToolbar(
                    projectSession: projectSession,
                    editorRequests: editorRequests,
                    completion: completion,
                    settings: settings,
                    theme: theme)
            }
            editor
            if showsChrome && !chromeHidden {
                EditorStatusBar(
                    projectSession: projectSession,
                    completion: completion,
                    settings: settings,
                    theme: theme)
            }
        }
    }

    private var editor: some View {
        Group {
            if let identity = editorIdentity {
                PurloryBlockEditor(
                    source: sourceBinding,
                    controller: completion,
                    theme: theme,
                    lineSpacing: CGFloat(settings.lineSpacing),
                    baseFontSize: CGFloat(settings.editorFontSize),
                    proseLayout: projectSession.activeProject?.mode == .fiction
                        && displayedDocument?.kind == .manuscript ? .continuous : .spaced,
                    documentIdentity: identity,
                    positionStore: positionStore,
                    isEditable: projectSession.phase == .ready && !projectSession.isTransitioning,
                    focusRequest: editorRequests.editorFocusRequest,
                    searchJump: editorRequests.spatialWorkspace != nil ? nil : editorRequests.searchJump,
                    assetCatalog: projectSession.assetCatalog,
                    assetImporter: { [key = editorIdentity, epoch = projectSession.activationEpoch] data, reference in
                        guard case .project(let documentKey) = key,
                              projectSession.activationEpoch == epoch,
                              let runtime = projectSession.runtimeIdentity, runtime.key == documentKey else { throw ProjectSessionError.staleRuntime }
                        _ = try await projectSession.importAsset(data: data, reference: reference, for: runtime)
                        guard let catalog = projectSession.assetCatalog else { throw ProjectSessionError.staleRuntime }
                        return catalog
                    },
                    onEditorWindowChange: { [weak projectSession, weak editorBridge, weak editorRequests] view in
                        guard let editor = view as? BlockTextView else { return }
                        if view.window != nil {
                            if case .project(let key) = editor.writingDocumentIdentity {
                                if let projectSession { editorRequests?.register(editor, for: key, session: projectSession) }
                            }
                            guard editor.writingDocumentIdentity?.documentID == projectSession?.selectedDocumentID else { return }
                            editorBridge?.connect(editor, currentSnapshot: { [weak projectSession] in
                                projectSession?.selectedDocumentSnapshot
                            })
                            editorRequests?.nativeEditor = editor
                            editorRequests?.nativeEditorKey = projectSession?.runtimeIdentity?.key
                            // Read the live gate even if this representable update was queued earlier.
                            editor.isEditable = projectSession?.isEditorEditable == true
                        } else if editorBridge?.editor === editor {
                            editorBridge?.disconnect(editor)
                            if editorRequests?.nativeEditor === editor { editorRequests?.nativeEditor = nil }
                        }
                    },
                    onSourceNavigation: { [weak editorRequests] succeeded, jump in
                        editorRequests?.didNavigateSource(succeeded, jump: jump)
                    }, isActiveEditor: displayedDocument?.id == projectSession.selectedDocumentID,
                    onEditorActivation: { [weak projectSession, weak editorBridge, weak editorRequests] view in
                        guard let editor = view as? BlockTextView,
                              case .project(let key) = editor.writingDocumentIdentity,
                              key.projectID == projectSession?.activeProject?.id else { return }
                        projectSession?.selectDocument(key.documentID)
                        editorBridge?.connect(editor, currentSnapshot: { [weak projectSession] in projectSession?.selectedDocumentSnapshot })
                        editorRequests?.nativeEditor = editor; editorRequests?.nativeEditorKey = key
                        editor.isEditable = projectSession?.isEditorEditable == true
                        editorRequests?.scheduleSpatialNavigation()
                    })
            } else {
                Text("프로젝트에서 문서를 선택하세요")
                    .purloryUIFont(13)
                    .foregroundStyle(theme.ink3C)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
            .overlay(alignment: .bottomLeading) {
                if let message = editorRequests.sourceNavigationError {
                    HStack {
                        Text(message).purloryUIFont(11)
                        Button("닫기") { editorRequests.sourceNavigationError = nil }
                    }
                    .padding(8).background(theme.editorSurfaceC)
                    .accessibilityIdentifier("purlory.source-navigation.status")
                }
            }
    }

    private var sourceBinding: Binding<DocumentSource> {
        let id = displayedDocument?.id
        let projectID = projectSession.activeProject?.id
        let epoch = projectSession.activationEpoch
        return Binding(get: { id.flatMap { projectSession.document($0)?.source } ?? DocumentSource("") }, set: { source in
            guard let id, let projectID else { return }
            projectSession.updateDocumentSource(source, for: .init(projectID: projectID, documentID: id), activationEpoch: epoch)
        })
    }

    private var displayedDocument: WritingDocument? {
        (documentID ?? projectSession.selectedDocumentID).flatMap { projectSession.document($0) }
    }

    private var editorIdentity: EditorDocumentIdentity? {
        guard let projectID = projectSession.activeProject?.id,
            let documentID = displayedDocument?.id
        else { return nil }
        return .project(ProjectDocumentKey(projectID: projectID, documentID: documentID))
    }
}

// MARK: - Writing toolbar

/// Document-local title, modes, model status and writing notices stay beside the editor.
struct EditorToolbar: View {
    @ObservedObject var projectSession: ProjectSession
    @ObservedObject var editorRequests: ProjectEditorRequests
    @ObservedObject var completion: CompletionController
    @ObservedObject var settings: CompletionSettings
    let theme: PurloryTheme
    @State private var longParagraphOpen = false

    var body: some View {
        GeometryReader { geometry in
            toolbar(density: WorkspaceLayoutState.toolbarDensity(forEditorWidth: geometry.size.width))
        }
        .frame(height: 36)
    }

    private func toolbar(density: WorkspaceToolbarDensity) -> some View {
        HStack(spacing: density == .compact ? 6 : 10) {
            Circle().fill(theme.novelC).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(projectSession.selectedDocument?.title ?? "문서")
                .purloryUIFont(11.5, .medium)
                .foregroundStyle(theme.ink2C)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: density == .compact ? 150 : 260, alignment: .leading)
            if let projectMode = projectSession.activeProject?.mode {
                let options = WorkspaceModePresentation.options(for: projectMode)
                if options.count > 1 {
                    Picker("작업 공간", selection: workspaceModeBinding) {
                        ForEach(options) { option in
                            Text(option.label).tag(option.mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("purlory.workspace-mode")
                    .accessibilityLabel("작업 공간")
                }
            }
            // 긴 문단 표시 (docs/editor-paragraph-split.md) — 대상이 있을 때만
            // 조용히 나타난다. 누르면 설명·확인. 원문 수정은 사용자 확인이 필수.
            if completion.longParagraph.count > 0 {
                Button {
                    longParagraphOpen.toggle()
                } label: {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.novelC)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(Capsule().fill(theme.novelBgC))
                        // 알림 점 — 눈에 띄게 (조용한 아이콘만으론 놓치기 쉬움).
                        // 툴바색 링으로 배경 알약과 분리한다.
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(theme.novelC)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(theme.toolbarC, lineWidth: 1.5))
                                .offset(x: 3, y: -3)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("긴 문단이 있어 입력이 느려질 수 있어요")
                .popover(isPresented: $longParagraphOpen, arrowEdge: .bottom) {
                    LongParagraphNotice(
                        completion: completion, theme: theme,
                        onDismiss: { longParagraphOpen = false })
                }
            }
            Spacer(minLength: 8)
            ModelChip(completion: completion, settings: settings, theme: theme, compact: density == .compact)
        }
        .padding(.horizontal, WindowChromeGeometry.toolbarHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var workspaceModeBinding: Binding<WorkspaceMode> {
        Binding(
            get: {
                let options = WorkspaceModePresentation.options(for: projectSession.activeProject?.mode ?? .general)
                return options.contains(where: { $0.mode == projectSession.workspaceMode }) ? projectSession.workspaceMode : .write
            },
            set: { mode in
                WorkspaceModeSelection.select(
                    mode,
                    session: projectSession,
                    requestEditorFocus: editorRequests.focusEditor)
            })
    }
}

/// 리퀴드 글래스 토글 스위치 (42×25) — 창 유리 톤과 통일된 디테일.
///
/// 트랙은 ultraThinMaterial 위에 유리 틴트 + 헤어라인 보더, 노브는 흰 원.
/// 다크 모드 스위치·자동완성 스위치 등 모든 토글이 이 컴포넌트를 공유한다.
struct GlassSwitch: View {
    let isOn: Bool
    let theme: PurloryTheme

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? theme.blueC.opacity(0.85) : theme.chipC)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.chipBorderC))
                .shadow(color: .black.opacity(PurloryElevation.flat.opacity), radius: PurloryElevation.flat.radius, y: PurloryElevation.flat.y)
            Circle()
                .fill(theme.knobC)
                .frame(width: 21, height: 21)
                .shadow(color: .black.opacity(PurloryElevation.raised.opacity), radius: PurloryElevation.raised.radius, y: PurloryElevation.raised.y)
                .offset(x: isOn ? 19 : 2)
        }
        .frame(width: 42, height: 25)
        // Reduce Motion에선 즉시 전환 — 상태 변화 자체가 피드백이다 (#27).
        .modifier(ReduceMotionAnimation(animation: .spring(duration: 0.25), value: isOn))
    }
}

/// Reduce Motion을 존중하는 animation 수정자 헬퍼 (#27) — 설정이 켜져 있으면
/// 값 변화를 애니메이션 없이 즉시 반영한다. SwiftUI 크롬 전역에서 재사용.
struct ReduceMotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// "예측 중" 점 세 개 애니메이션 (디자인 purlory-dot).
///
/// 모션 정책 (#27 감사): 무한 반복 모션이라 Reduce Motion에서는 **정적** 0.65로
/// 만든다 — 진행 표시의 의미는 밝기 하나로도 성립한다. 일반 모드도 450ms →
/// 250ms·점 간 80ms로 줄여 프레임 예산 밖으로 나가지 않게 했다.
struct PulsingDots: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .opacity(pulsing ? 1 : (reduceMotion ? 0.65 : 0.25))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.25)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.08),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}

// MARK: - 마크다운 치트시트

/// 마크다운 단축 문법 안내 — 줄 맨 앞/인라인 문법을 한눈에.
/// 상단바 도움말 버튼이 사라진 뒤로는 설정(⌘,)의 "사용 방법"에서 보여준다.
struct MarkdownCheatSheet: View {
    let theme: PurloryTheme

    private struct Item: Identifiable {
        let id = UUID()
        let syntax: String
        let label: String
    }

    private static let blocks: [Item] = [
        Item(syntax: "# ~ ###### ", label: "제목 1 ~ 6"),
        Item(syntax: "- ", label: "글머리 목록 (Tab 들여쓰기)"),
        Item(syntax: "1. ", label: "번호 목록 (Tab 들여쓰기)"),
        Item(syntax: "[ ] ", label: "체크리스트"),
        Item(syntax: "> ", label: "인용 (Tab 중첩 인용)"),
        Item(syntax: "```언어", label: "코드 블록"),
        Item(syntax: "$$ ", label: "수식 (LaTeX)"),
        Item(syntax: "---", label: "구분선"),
    ]

    private static let inlines: [Item] = [
        Item(syntax: "**굵게**", label: "굵게"),
        Item(syntax: "*기울임*", label: "기울임"),
        Item(syntax: "~~취소선~~", label: "취소선"),
        Item(syntax: "==형광펜==", label: "하이라이트"),
        Item(syntax: "`코드`", label: "인라인 코드"),
        Item(syntax: "[말](주소)", label: "링크 (⌘클릭 이동)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("줄 맨 앞에서 입력")
            ForEach(Self.blocks) { row($0) }
            theme.sepC.frame(height: 1).padding(.vertical, 7)
            sectionTitle("인라인")
            ForEach(Self.inlines) { row($0) }
            theme.sepC.frame(height: 1).padding(.vertical, 7)
            Text("서식 메뉴(⌘⌥1~6, ⌘B/⌘I/⌘L, ⌘/ 소스 보기 등)로도 적용할 수 있어요.")
                .purloryUIFont(11)
                .foregroundStyle(theme.ink3C)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 264)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(PurloryFonts.monoUI(10))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(theme.ink3C)
            .padding(.bottom, 6)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Text(item.syntax)
                .font(PurloryFonts.monoUI(11.5, .semibold))
                .foregroundStyle(theme.inkC)
                .padding(.vertical, 2)
                .padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: PurloryRadius.xs).fill(theme.chipC))
            Spacer(minLength: 8)
            Text(item.label)
                .purloryUIFont(12)
                .foregroundStyle(theme.ink2C)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 상태 바

/// 단어 수 · 글자 수 · 읽는 시간 · Markdown (상용 v1.0 — 글쓰기 지표 중심).
///
/// 예전엔 모델명·지연·토큰 같은 개발용 텔레메트리를 늘어놨는데, 글쓰기 앱에선
/// 개발 콘솔처럼 보여 몰입을 깼다. 작가가 흘끗 보고 싶은 값(단어·글자·읽는 시간)만
/// 남기고, 모델 상태는 툴바의 ModelChip이 담당한다.
///
/// ⚠️ 통계는 **디바운스 + 백그라운드**로 센다 — 렌더마다 세면 키 입력마다
/// 문서 전체를 3번 훑어 88k자에서 ~18ms·300k에서 ~62ms가 매 타에 든다
/// (릴리즈 실측 — 대형 문서 타이핑 랙의 주범이었다, docs/editor-perf.md).
/// 값이 최대 ~0.3s 낡을 수 있지만 단어 수는 그래도 된다. 랙은 안 된다.
struct EditorStatusBar: View {
    @ObservedObject var projectSession: ProjectSession
    @ObservedObject var completion: CompletionController
    @ObservedObject var settings: CompletionSettings
    let theme: PurloryTheme
    @State private var stats = TextStats.empty

    var body: some View {
        HStack(spacing: 16) {
            if let notice = projectSession.lastErrorMessage {
                Text(notice)
                    .purloryUIFont(11)
                    .foregroundStyle(theme.blueC)
                    .lineLimit(1)
                separator
            }
            Text("\(stats.words) 단어")
            separator
            Text("\(stats.characters) 자")
            if !stats.readingLabel.isEmpty {
                separator
                Text("읽기 \(stats.readingLabel)")
            }
            if case .failed = completion.engineState {
                separator
                Text("자동완성 로드 실패")
                    .foregroundStyle(theme.dangerC)
                    .lineLimit(1)
                Button("다시 시도") { completion.retryEngineLoad() }
                    .buttonStyle(.link)
                    .font(PurloryFonts.monoUI(11))
            }
            Spacer()
            // 저장 상태 — 실패를 "저장됨"으로 위장하지 않는다 (이슈 #10).
            if projectSession.savePhase == .failed {
                Text("저장 실패")
                    .foregroundStyle(theme.dangerC)
                    .help(projectSession.lastErrorMessage ?? "프로젝트를 저장하지 못했습니다.")
                Button("다시 시도") {
                    Task { try? await projectSession.flush() }
                }
                    .buttonStyle(.link)
                    .font(PurloryFonts.monoUI(11))
            } else if projectSession.savePhase == .saving {
                Text("저장 중…")
            } else if projectSession.savePhase == .saved {
                Text("저장됨")
            } else {
                Text("저장 대기 중")
            }
            separator
            Text("Markdown")
        }
        .font(PurloryFonts.monoUI(10))
        .foregroundStyle(theme.ink3C)
        .padding(.horizontal, 16)
        .frame(height: 26)
        // 통계 재계산 — 키가 바뀌고(편집·문서 전환) 0.25s 조용해진 뒤에만.
        // 그 사이 새 키 입력이 오면 이 task가 취소되고 새로 걸린다(디바운스).
        // 계산은 detached — 88k자 한 패스가 메인 프레임을 막지 않는다.
        .task(id: statsKey) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let text = projectSession.selectedDocument?.body ?? ""
            stats = await Task.detached(priority: .utility) {
                TextStats.compute(text)
            }.value
            guard !Task.isCancelled else { return }  // stale 결과 할당 금지 (#60)
        }
    }

    /// 디바운스 키 — 본문 변경 카운터 + 활성 문서. 문자열 비교(O(n))가 아니라
    /// 카운터 비교(O(1))로 변경을 감지한다.
    private var statsKey: String {
        let key = projectSession.runtimeIdentity?.key
        return "\(key?.projectID.rawValue.uuidString ?? "none")-\(key?.documentID.rawValue.uuidString ?? "none")-\(projectSession.runtimeIdentity?.generation ?? 0)"
    }

    private var separator: some View {
        theme.sepC.frame(width: 1, height: 12)
    }
}

/// 긴 문단 안내·확인 팝오버 (docs/editor-paragraph-split.md).
///
/// 원문을 수정하는 기능이라 **설명이 핵심**이다 — 왜 원고에 손을 대는지, 무엇이
/// 바뀌는지(글자 불변, 개행만), 되돌릴 수 있는지를 알려 사용자가 동의하게 한다.
/// 숫자는 감지 결과의 실제 수치라 막연한 안내가 아니다.
struct LongParagraphNotice: View {
    @ObservedObject var completion: CompletionController
    let theme: PurloryTheme
    let onDismiss: () -> Void
    @State private var detailShown = false
    @State private var splitResult: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.novelC)
                Text("아주 긴 문단이 있어요")
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                Spacer()
            }

            if let result = splitResult {
                // 실행 후 조용한 확인.
                Text(result > 0
                    ? "긴 문단 \(result)개를 문장 경계에서 나눴어요. ⌘Z로 되돌릴 수 있어요."
                    : "나눌 문단을 찾지 못했어요.")
                    .purloryUIFont(11.5)
                    .foregroundStyle(theme.ink2C)
                    .fixedSize(horizontal: false, vertical: true)
                Button("닫기") { onDismiss() }
                    .purloryUIFont(12, .medium)
            } else {
                Text("빠르게 입력하면 끊길 수 있어요.")
                    .purloryUIFont(11.5)
                    .foregroundStyle(theme.ink2C)

                if detailShown {
                    Text(detailText)
                        .purloryUIFont(11)
                        .foregroundStyle(theme.ink2C)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                HStack(spacing: 8) {
                    Button {
                        // 감지 count는 실행 후 0으로 갱신되므로 먼저 확보한다.
                        let before = completion.longParagraph.count
                        completion.performLongParagraphSplit()
                        splitResult = before
                    } label: {
                        Text("문단 나누기")
                            .purloryUIFont(12, .semibold)
                            .foregroundStyle(theme.novelC.accessibleForegroundC)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 12)
                            .background(Capsule().fill(theme.novelC))
                    }
                    .buttonStyle(.plain)

                    Button(detailShown ? "접기" : "자세히") { detailShown.toggle() }
                        .purloryUIFont(12, .medium)
                    Spacer()
                    Button("그대로 두기") { onDismiss() }
                        .purloryUIFont(12)
                        .foregroundStyle(theme.ink3C)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var detailText: String {
        let info = completion.longParagraph
        let ratio = info.ratio
        let ratioText = ratio > 1 ? "보통 문단의 \(ratio)배가 넘어요" : "아주 길어요"
        return """
            에디터는 문단 하나를 통째로 다시 배치하기 때문에, 문단이 길수록 글자 하나 \
            입력에 드는 비용이 커져요. 이 문서에서 가장 긴 문단은 약 \
            \(info.maxLength.formatted())자로, \(ratioText).

            문장 경계에서 이 문단을 몇 개로 나누면 입력이 다시 매끄러워져요. 글자는 \
            하나도 바뀌지 않고, 문단 사이에 빈 줄만 들어가요. 마음에 안 들면 ⌘Z 한 \
            번으로 되돌릴 수 있어요.

            나눌 문단: \(info.count)개 · 문장 중간은 자르지 않아요.
            """
    }
}

#if canImport(PreviewsMacros)
#Preview {
    let store = ProjectStore(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-Preview-Projects", isDirectory: true))
    let session = ProjectSession(store: store)
    let editorRequests = ProjectEditorRequests()
    ContentView(
        projectSession: session,
        startup: ProjectStartupCoordinator(session: session, store: store,
            storageLocation: .init(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Preview"))),
        editorRequests: editorRequests,
        completion: CompletionController(),
        indexer: BackgroundIndexer(engine: CompletionEngine()),
        livingMargin: LivingMarginModel(),
        firstRunFlow: FirstRunFlow(
            session: session,
            store: store,
            editorRequests: editorRequests))
        .frame(width: 1180, height: 760)
}
#endif
