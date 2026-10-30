import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

/// Presentation policy supplied by the workspace; storage stays independent of writing modes.
public enum EditorProseLayout: Sendable {
    case spaced
    case continuous
}

/// Notion식 블록 에디터 (에디터 v3 — 디자인 완전 이식).
///
/// 웹 목업의 세 축을 NSTextView(TextKit 1)로 옮긴 것:
/// - `transformMarkdown` → 마커(`# `, `> `, `- ` …)를 입력 즉시 **소비**하고
///   문단에 블록 속성(`.purloryBlock`)을 부여한다. 화면에 마커는 남지 않는다.
/// - `serialize`/`buildDOM` → 저장은 항상 순수 마크다운. 로드 시 마커를 파싱해
///   블록으로 복원한다. 파일 포맷은 이전과 완전 호환.
/// - 블록 장식(불릿·번호·체크박스·인용 바·코드/수식 배경·구분선·이미지)은
///   `PurloryLayoutManager`가 그린다 — text storage 밖이라 undo·IME에 무해.
/// - 커서 효과(펄스 blink·이동 리플·커서 줄 하이라이트)는 뷰의 `draw`/
///   `drawInsertionPoint`에서 그린다 (에디터 v3.1 — 창 글로우 대체).
///
/// 에디터 본문의 가독 폭 상수 — 창을 넓혀도 한 줄이 끝없이 길어지지 않게
/// 편안한 폭으로 묶고 남는 폭은 좌우 여백으로 돌린다(글이 가운데 컬럼에 놓인다).
/// iA Writer·Ulysses·Bear가 프리미엄으로 느껴지는 핵심 — 긴 줄은 눈이 다음 줄을
/// 찾기 어려워 장시간 읽기를 피로하게 한다.
public enum EditorMetrics {
    /// 본문 최대 폭(pt) — 한글 약 38자·라틴 약 70자 수준의 차분한 measure.
    public static let maxContentWidth: CGFloat = 760
    /// 좁은 창에서의 기본 좌우 여백(pt) — 디자인 padding.
    public static let minSideInset: CGFloat = 56

    /// 뷰 폭에 맞는 좌우 inset — 폭이 넓어지면 여백을 키워 본문을 가운데로 모은다.
    public static func sideInset(forWidth width: CGFloat) -> CGFloat {
        max(minSideInset, ((width - maxContentWidth) / 2).rounded())
    }
    static func workspaceSideInset(forWidth width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        max(windowWidth < 640 ? 28 : 48, ((width - 680) / 2).rounded())
    }
}

/// 고스트 텍스트(M3)는 기존 방식 그대로: storage 밖에서 `draw(_:)`로만 그린다.
public struct PurloryBlockEditor: NSViewRepresentable {
    @Binding var text: String

    private let controller: CompletionController?
    private let theme: PurloryTheme
    /// 본문 줄 간격(pt) — 설정에서 조절. 낮추면 줄이 촘촘해진다.
    private let lineSpacing: CGFloat
    /// 본문 기본 글자 크기(pt) — 설정에서 조절(⌘+/⌘−).
    private let baseFontSize: CGFloat
    private let proseLayout: EditorProseLayout
    /// 현재 편집 중인 안정적인 문서 identity — runtime generation은 포함하지 않는다.
    private let documentIdentity: EditorDocumentIdentity
    private let positionStore: WritingPositionStore
    /// 에디터 포커스 요청 카운터(EntryStore.editorFocusRequests) — 값이 바뀌면
    /// 텍스트 뷰를 first responder로 만든다 (새 저널 → 바로 타이핑).
    private let focusRequest: Int
    /// 전역 검색 결과 클릭 — seq가 바뀌면 본문 매치 위치로 스크롤·선택 표시 (요구 2).
    private let searchJump: EditorSearchJump?
    private let assetCatalog: ProjectAssetCatalog?
    private let assetImporter: (@MainActor (Data, String) async throws -> ProjectAssetCatalog)?
    private let onEditorWindowChange: ((NSTextView) -> Void)?
    private let onSourceNavigation: ((Bool, EditorSearchJump) -> Void)?
    private let isEditable: Bool
    private var isActiveEditor: Bool
    private let onEditorActivation: ((NSTextView) -> Void)?

    public init(
        text: Binding<String>,
        controller: CompletionController? = nil,
        theme: PurloryTheme = .light,
        lineSpacing: CGFloat = CGFloat(CompletionSettings.defaultLineSpacing),
        baseFontSize: CGFloat = CGFloat(CompletionSettings.defaultFontSize),
        proseLayout: EditorProseLayout = .spaced,
        documentIdentity: EditorDocumentIdentity,
        positionStore: WritingPositionStore = .shared,
        isEditable: Bool = true,
        focusRequest: Int = 0,
        searchJump: EditorSearchJump? = nil,
        assetCatalog: ProjectAssetCatalog? = nil,
        assetImporter: (@MainActor (Data, String) async throws -> ProjectAssetCatalog)? = nil,
        onEditorWindowChange: ((NSTextView) -> Void)? = nil,
        onSourceNavigation: ((Bool, EditorSearchJump) -> Void)? = nil,
        isActiveEditor: Bool = true,
        onEditorActivation: ((NSTextView) -> Void)? = nil
    ) {
        self._text = text
        self.controller = controller
        self.theme = theme
        self.lineSpacing = lineSpacing
        self.baseFontSize = baseFontSize
        self.proseLayout = proseLayout
        self.documentIdentity = documentIdentity
        self.positionStore = positionStore
        self.focusRequest = focusRequest
        self.searchJump = searchJump
        self.assetCatalog = assetCatalog
        self.assetImporter = assetImporter
        self.onEditorWindowChange = onEditorWindowChange
        self.onSourceNavigation = onSourceNavigation
        self.isEditable = isEditable
        self.isActiveEditor = isActiveEditor
        self.onEditorActivation = onEditorActivation
    }

    /// Explicit legacy-workspace bridge. Project workspace composition uses the neutral primary
    /// initializer above, while EntryStore remains available only at its compatibility boundary.
    public init(
        text: Binding<String>,
        controller: CompletionController? = nil,
        theme: PurloryTheme = .light,
        lineSpacing: CGFloat = CGFloat(CompletionSettings.defaultLineSpacing),
        baseFontSize: CGFloat = CGFloat(CompletionSettings.defaultFontSize),
        entryID: UUID = UUID(),
        positionStore: WritingPositionStore = .shared,
        isEditable: Bool = true,
        focusRequest: Int = 0,
        searchJump: EntryStore.SearchJump? = nil,
        onEditorWindowChange: ((NSTextView) -> Void)? = nil
    ) {
        self.init(
            text: text,
            controller: controller,
            theme: theme,
            lineSpacing: lineSpacing,
            baseFontSize: baseFontSize,
            documentIdentity: .legacy(entryID),
            positionStore: positionStore,
            isEditable: isEditable,
            focusRequest: focusRequest,
            searchJump: searchJump.map {
                EditorSearchJump(
                    documentID: $0.entryID, query: $0.query, sequence: $0.seq)
            },
            onEditorWindowChange: onEditorWindowChange)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 스택을 직접 조립 — 커스텀 레이아웃 매니저(블록 장식)를 쓰기 위해.
        let storage = NSTextStorage()
        let layoutManager = PurloryLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = BlockTextView(frame: .zero, textContainer: container)
        if case .project = documentIdentity { textView.documentUndoManager = UndoManager(); textView.editorialWorkspaceStyle = true }
        textView.automaticallyFocusOnAttachment = isActiveEditor
        textView.writingDocumentIdentity = documentIdentity
        textView.setAccessibilityIdentifier(isActiveEditor ? "purlory.editor" : "purlory.editor.\(documentIdentity.documentID.rawValue.uuidString)")
        // 편집 범위를 알아야 수식·이미지 마커 검사를 증분으로 할 수 있다
        // (전체 문자열 검색은 30만 자에서 16.9ms — docs/editor-perf.md).
        storage.delegate = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Keep the first sentence clear of window chrome without changing the text origin logic.
        textView.textContainerInset = textView.editorialWorkspaceStyle
            ? NSSize(width: 48, height: 60) : NSSize(width: 56, height: 60)
        // 커서는 잉크색(라이트=검정/다크=하양) — 높이는 커서 위치의 글자 크기를 따른다.
        textView.insertionPointColor = theme.ink
        // 시스템 사각 선택 하이라이트는 끈다 — 선택 영역은 우리가 draw()에서
        // 라운드 사각형(테마 selection 틴트)으로 직접 그린다 (우리식 드래그 표시).
        textView.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        // ⌘F 문서 내 검색 — 스크롤 뷰 상단의 표준 find bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // 이미지 파일 드롭 수락 — NSTextView 기본 타입에 이미지 타입을 더한다.
        textView.registerForDraggedTypes(
            textView.registeredDraggedTypes + [.fileURL, .png, .tiff])

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        textView.palette = theme
        textView.lineSpacing = lineSpacing
        textView.baseFontSize = baseFontSize
        textView.proseLayout = proseLayout
        textView.editorWindowDidChange = onEditorWindowChange
        configureActivation(textView, coordinator: context.coordinator)
        configureAssets(textView)
        textView.load(markdown: text)
        context.coordinator.lastSyncedText = text
        // 최초 값은 소비된 것으로 간주 — 실제 포커스는 뷰가 창에 붙을 때(launch) 준다.
        context.coordinator.lastFocusRequest = focusRequest
        context.coordinator.markSearchJumpConsumed(searchJump, for: documentIdentity)

        let scrollView = WritingScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // 타자기 존을 직접 관리하므로 안전영역 기반 자동 인셋은 끈다 — 이 스크롤 뷰는
        // 타이틀바 밑이 아니라 툴바·상태 바 사이에 있어 자동 상단 인셋은 어차피 0이다.
        scrollView.automaticallyAdjustsContentInsets = false

        if let persisted = context.coordinator.restorePosition(
            for: documentIdentity, body: textView.string, in: positionStore)
        {
            textView.restoreWritingPosition(persisted)
        }
        context.coordinator.loadedDocumentIdentity = documentIdentity
        context.coordinator.attach(to: textView)
        // 스크롤 주도 가시 렌더 (#18 2단계) — 스크롤이 멈출 때 화면 밖을 건너뛴
        // 블록을 채워 그린다 (편집·커서 경로는 여전히 전체 패스).
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView, queue: .main
        ) { [weak textView] _ in
            MainActor.assumeIsolated {
                guard let textView else { return }
                textView.scheduleVisibleRefresh()
            }
        }
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BlockTextView else { return }
        let activationChanged = context.coordinator.parent.isActiveEditor != isActiveEditor
        textView.setAccessibilityIdentifier(isActiveEditor ? "purlory.editor" : "purlory.editor.\(documentIdentity.documentID.rawValue.uuidString)")
        textView.writingDocumentIdentity = documentIdentity
        if !isEditable, textView.hasMarkedText() {
            textView.unmarkText()
            textView.didChangeText()
        }
        textView.isEditable = isEditable
        textView.editorWindowDidChange = onEditorWindowChange
        if textView.window != nil { onEditorWindowChange?(textView) }
        configureAssets(textView)
        let documentChanged = documentIdentity != context.coordinator.loadedDocumentIdentity
        if documentChanged {
            context.coordinator.isDocumentTransitioning = true
        } else {
            context.coordinator.parent = self
        }
        configureActivation(textView, coordinator: context.coordinator)
        if activationChanged {
            if isActiveEditor { context.coordinator.attach(to: textView) }
            else { textView.ghostText = nil; textView.showConversationPrompt(nil) }
        }

        if textView.proseLayout != proseLayout {
            textView.proseLayout = proseLayout
            // A document transition loads its new presentation below.
            if !documentChanged { textView.restyleAll() }
        }

        // 팔레트는 ink를 바꾸지 않을 수 있다 — 테마 **전체** 동등성으로 판정해야
        // 선택색·현재 줄·코드 배경이 이전 팔레트에 남지 않는다 (이슈 #34, #54 Equatable).
        if textView.palette != theme {
            textView.palette = theme
            textView.insertionPointColor = theme.ink
            textView.restyleAll()
        }
        // 줄 간격 설정이 바뀌면 전체 문단 스타일을 다시 적용한다.
        if textView.lineSpacing != lineSpacing {
            textView.lineSpacing = lineSpacing
            textView.restyleAll()
        }
        // 글자 크기 설정이 바뀌면 폰트를 다시 만들고 전체 문단·수식을 다시 그린다.
        if textView.baseFontSize != baseFontSize {
            textView.baseFontSize = baseFontSize
            textView.restyleAll()
        }
        // 저널이 바뀌면(전환) 직전 저널의 커서 위치를 저장해 둔다 — 아직 옛 내용을
        // 보여주는 지금 selectedRange가 옛 커서다 (M6).
        if documentChanged, let previous = context.coordinator.loadedDocumentIdentity {
            if textView.hasMarkedText() { textView.unmarkText() }
            context.coordinator.selectionByDocument[previous] = textView.selectedRange()
            // 재실행 후 복원용 영속 기록 (#36) — IME 조합 중은 스냅샷이 nil을
            // 돌려 저장하지 않는다 (완료 조건 4).
            if let snapshot = textView.writingPositionSnapshot() {
                context.coordinator.recordPosition(
                    snapshot, body: textView.string, for: previous,
                    in: positionStore)
            }
        }
        // 외부(저널 전환·로드)에서 본문이 바뀐 경우에만 다시 파싱한다.
        // serialize() 재비교가 아니라 "마지막 동기화 텍스트"와 비교한다 —
        // 직렬화 왕복의 미세한 비대칭이 렌더 → reload → publish → 렌더의
        // 무한 루프(비치볼)로 번지는 것을 차단 (r1 버그).
        if documentChanged {
            controller?.noteDocumentSwitch(to: documentIdentity.documentID.rawValue)
            controller?.dismissConversationSuggestion(remember: false)
            _ = textView.prepareForDocumentTransition(
                from: context.coordinator.loadedDocumentIdentity,
                to: documentIdentity,
                markdown: text)
            context.coordinator.lastSyncedText = text
            // 다시 찾은 저널이면 마지막으로 있던 위치로 커서·스크롤을 복원한다.
            // (처음 여는 저널은 저장값이 없어 load의 맨 위 규칙을 그대로 둔다.)
            // 세션 메모리에 없으면 **재실행 전 저장값**으로 재안착 복원 (#36) —
            // 장편 원고를 다시 열면 상단이 아니라 마지막 집필 자리에서 시작한다.
            if let saved = context.coordinator.selectionByDocument[documentIdentity] {
                textView.restoreSelection(to: saved)
            } else if let persisted = context.coordinator.restorePosition(
                for: documentIdentity, body: textView.string,
                in: positionStore)
            {
                textView.restoreWritingPosition(persisted)
            }
        } else if !text.utf16.elementsEqual(context.coordinator.lastSyncedText.utf16) {
            // Same stable identity: synchronize external body state without severing native undo.
            context.coordinator.isDocumentTransitioning = true
            textView.load(markdown: text)
            context.coordinator.lastSyncedText = text
            textView.ghostText = nil
            controller?.dismissSuggestion()
            textView.showConversationPrompt(nil)
            controller?.dismissConversationSuggestion(remember: false)
            controller?.refreshLongParagraphDetection()
            context.coordinator.isDocumentTransitioning = false
        }
        if documentChanged {
            context.coordinator.loadedDocumentIdentity = documentIdentity
            context.coordinator.parent = self
            context.coordinator.attach(to: textView)
            context.coordinator.isDocumentTransitioning = false
            // 긴 문단 감지는 문서 로드 때 1회 — 키 입력 경로에 O(문서)를 안 넣는다.
            controller?.refreshLongParagraphDetection()
        }
        // 새 저널 등 포커스 요청 — reload 뒤에 first responder로 만든다.
        if isActiveEditor, focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            let requestedIdentity = documentIdentity
            let requestedEpoch = context.coordinator.callbackEpoch
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard coordinator?.ownsCallback(requestedIdentity, epoch: requestedEpoch) == true,
                    let textView, let window = textView.window
                else { return }
                window.makeFirstResponder(textView)
            }
        }
        // 검색 결과 클릭 — reload·레이아웃이 끝난 다음 틱에 매치 위치로 이동·표시.
        if let jump = context.coordinator.consumeSearchJump(
            searchJump, for: documentIdentity)
        {
            let requestedIdentity = documentIdentity
            let requestedEpoch = context.coordinator.callbackEpoch
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard coordinator?.ownsCallback(requestedIdentity, epoch: requestedEpoch) == true
                else { return }
                if let source = jump.source, let textView {
                    coordinator?.parent.onSourceNavigation?(textView.applySourceNavigation(source), jump)
                } else { textView?.revealMatch(of: jump.query) }
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func configureActivation(_ view: BlockTextView, coordinator: Coordinator) {
        view.automaticallyFocusOnAttachment = isActiveEditor
        view.editorDidActivate = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.parent.onEditorActivation?(view)
            coordinator.parent.isActiveEditor = true
            coordinator.attach(to: view)
        }
    }

    private func configureAssets(_ view: BlockTextView) {
        if case .project = documentIdentity { view.usesProjectAssets = true }
        else { view.usesProjectAssets = false }
        view.projectAssetCatalog = assetCatalog
        view.projectAssetImporter = assetImporter
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PurloryBlockEditor
        /// 스크롤 경계 관찰자 소유 (#18 2단계) — 뷰 수명과 함께 해제.
        var scrollObserver: NSObjectProtocol?

        /// 마지막으로 바인딩과 동기화된 마크다운 — updateNSView의 reload 기준.
        var lastSyncedText = ""
        /// 마지막으로 처리한 포커스 요청 값 — 값이 바뀔 때만 포커스를 옮긴다.
        var lastFocusRequest = 0
        /// Search counters are session-local, so each stable editor identity keeps its own
        /// consumed sequence across A -> B -> A transitions.
        private var lastConsumedSearchJumpByDocument: [EditorDocumentIdentity: Int] = [:]
        /// 저널별 마지막 커서 위치(세션 메모리) — 전환 후 돌아오면 그 자리로 복원 (M6).
        var selectionByDocument: [EditorDocumentIdentity: NSRange] = [:]
        /// 현재 로드된 안정적 문서 identity — 전환 감지·커서 저장/복원 키.
        var loadedDocumentIdentity: EditorDocumentIdentity?
        /// Programmatic TextKit replacement must not publish into either manuscript binding.
        var isDocumentTransitioning = false
        /// Monotonic callback ownership prevents stale A callbacks after an A -> B -> A cycle.
        var callbackEpoch: UInt64 = 0

        init(_ parent: PurloryBlockEditor) {
            self.parent = parent
        }

        func applyWorkspaceSource(_ body: String, to editor: BlockTextView) {
            isDocumentTransitioning = true
            editor.load(markdown: body); lastSyncedText = body
            isDocumentTransitioning = false
        }

        func markSearchJumpConsumed(
            _ jump: EditorSearchJump?, for identity: EditorDocumentIdentity
        ) {
            guard let jump, jump.documentID == identity.documentID else { return }
            lastConsumedSearchJumpByDocument[identity] = jump.sequence
        }

        func consumeSearchJump(
            _ jump: EditorSearchJump?, for identity: EditorDocumentIdentity
        ) -> EditorSearchJump? {
            guard let jump, jump.documentID == identity.documentID else { return nil }
            if let source = jump.source, identity != .project(source.key) { return nil }
            guard lastConsumedSearchJumpByDocument[identity] != jump.sequence else { return nil }
            lastConsumedSearchJumpByDocument[identity] = jump.sequence
            return jump
        }

        func attach(to textView: BlockTextView) {
            textView.writingDocumentIdentity = parent.documentIdentity
            callbackEpoch &+= 1
            guard parent.isActiveEditor else { return }
            let attachedEpoch = callbackEpoch
            let attachedIdentity = parent.documentIdentity
            parent.controller?.suggestionDidChange = { [weak self, weak textView] suggestion in
                guard self?.ownsCallback(attachedIdentity, epoch: attachedEpoch) == true
                else { return }
                textView?.ghostText = suggestion
            }
            // 대화 기록 제안 (요구사항 §20) — 감지가 스토리지 프리픽스에서 돌아
            // 범위가 곧 이 뷰의 좌표다. 은은한 하이라이트 + 끝자락 pill.
            parent.controller?.conversationSuggestionDidChange = { [weak self, weak textView] block in
                guard self?.ownsCallback(attachedIdentity, epoch: attachedEpoch) == true
                else { return }
                textView?.showConversationPrompt(
                    block.map { NSRange(location: $0.utf16Range.lowerBound,
                                        length: $0.utf16Range.count) })
            }
            // 긴 문단 감지·나누기 다리 (docs/editor-paragraph-split.md).
            parent.controller?.detectLongParagraphs = { [weak self, weak textView] in
                guard self?.ownsCallback(attachedIdentity, epoch: attachedEpoch) == true,
                    let textView
                else { return .none }
                let (count, maxLen) = textView.oversizedProseParagraphs()
                return .init(
                    count: count, maxLength: maxLen,
                    typicalLength: textView.typicalProseParagraphLength())
            }
            parent.controller?.splitLongParagraphs = { [weak self, weak textView] in
                guard self?.ownsCallback(attachedIdentity, epoch: attachedEpoch) == true
                else { return 0 }
                return textView?.splitOversizedProseParagraphs() ?? 0
            }
        }

        func ownsCallback(
            _ identity: EditorDocumentIdentity, epoch: UInt64
        ) -> Bool {
            loadedDocumentIdentity == identity && callbackEpoch == epoch && parent.isActiveEditor
        }

        public func textDidChange(_ notification: Notification) {
            guard !isDocumentTransitioning,
                let textView = notification.object as? BlockTextView
            else { return }
            // 입력 지연 계측 (로컬 진단) — 핸들러 구간과, 이 런루프 턴에 쌓인
            // 후속 작업(SwiftUI 갱신·레이아웃)까지의 총 구간을 나눠 잰다.
            // 랙 보고를 숫자로 만들기 위한 장비 — 측정 없이 튜닝 없음 (CLAUDE.md §2-7).
            let start = CFAbsoluteTimeGetCurrent()
            textView.writingProjectionCapture.willBind()
            let serialized = textView.serialize()
            lastSyncedText = serialized
            parent.text = serialized
            if let storage = textView.textStorage {
                textView.writingProjectionCapture.didBind(source: serialized, storage: storage)
            }
            // 집필 위치 영속 기록 (#36) — 메모리 갱신 + 디바운스 디스크. 조합 중은
            // record가 무시한다. 전환 없이 ⌘Q해도 마지막 자리가 남는 이유다.
            if let snapshot = textView.writingPositionSnapshot() {
                recordPosition(
                    snapshot, body: textView.string,
                    for: loadedDocumentIdentity ?? parent.documentIdentity,
                    in: parent.positionStore)
            }
            forwardEditEvent(textView)
            let handlerMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let controller = parent.controller
            DispatchQueue.main.async {
                let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                controller?.noteKeystroke(handlerMs: handlerMs, totalMs: totalMs)
            }
        }

        func recordPosition(
            _ snapshot: (
                location: Int, selectionLength: Int, before: String, after: String, marked: Bool
            ),
            body: String,
            for identity: EditorDocumentIdentity,
            in store: WritingPositionStore
        ) {
            switch identity {
            case .project(let key):
                store.record(
                    location: snapshot.location,
                    selectionLength: snapshot.selectionLength,
                    body: body,
                    for: key,
                    marked: snapshot.marked)
            case .legacy(let id):
                store.record(
                    entryID: id,
                    location: snapshot.location,
                    before: snapshot.before,
                    after: snapshot.after,
                    marked: snapshot.marked)
            }
        }

        func restorePosition(
            for identity: EditorDocumentIdentity,
            body: String,
            in store: WritingPositionStore
        ) -> WritingPositionStore.Position? {
            switch identity {
            case .project(let key):
                return store.restore(in: body, for: key)
            case .legacy(let id):
                guard let position = store.position(for: id),
                    let location = store.resolve(for: id, in: body)
                else { return nil }
                return WritingPositionStore.Position(
                    location: location,
                    selectionLength: position.selectionLength,
                    before: position.before,
                    after: position.after)
            }
        }

        private var selectionRefreshPending = false

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isDocumentTransitioning,
                let textView = notification.object as? BlockTextView
            else { return }
            // AppKit can announce selection from inside layout invalidation (including
            // undo). Collapsing math here would recursively change storage before the
            // layout manager has applied the original character delta.
            if (textView.layoutManager as? PurloryLayoutManager)?.processingStorageEdit == true {
                guard !selectionRefreshPending else { return }
                selectionRefreshPending = true
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self else { return }
                    self.selectionRefreshPending = false
                    guard let textView, textView.window != nil else { return }
                    self.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
                }
                return
            }
            textView.syncTypingAttributes()
            // 커서가 선택된 이미지 밖으로 나가면 객체 선택을 푼다 (렌더 유지 조건 갱신 전에).
            textView.syncImageSelection()
            // 커서가 수식 문단에 들어오면 소스, 나가면 렌더로 전환.
            textView.refreshRenderedBlocks()
            // Selection notifications can arrive inside TextKit undo invalidation.
            // Measure only after its layout ranges have caught up with storage.
            textView.scheduleEditingOverlayRefresh()
            // 드래그 선택 위 서식 툴바 표시/숨김.
            textView.updateSelectionToolbar()
            textView.workspaceInteraction?.selectionDidChange()
            if let identity = loadedDocumentIdentity,
                let snapshot = textView.writingPositionSnapshot(), !snapshot.marked
            {
                recordPosition(
                    snapshot, body: textView.string, for: identity,
                    in: parent.positionStore)
            }
            guard parent.isActiveEditor, let controller = parent.controller,
                  textView.window?.firstResponder === textView else { return }
            let range = textView.selectedRange()
            if range.length > 0 {
                controller.dismissSuggestion()
            } else {
                controller.noteSelectionChange(caretLocation: range.location)
            }
        }

        public func textDidEndEditing(_ notification: Notification) {
            if parent.isActiveEditor { parent.controller?.dismissSuggestion() }
        }

        /// Tab 수락 / → 한 단어 / Esc 거부 (PLAN §5, 에디터 v3) +
        /// Enter 대화 기록 (요구사항 §20 — Interaction Priority):
        /// - Tab·→ 는 고스트 전용 (대화 제안과 무관).
        /// - Enter: 대화 제안이 떠 있으면 **기록하고 개행도 정상 진행** (false
        ///   리턴) — 글쓰기 흐름이 끊기지 않는다.
        /// - Esc: 고스트가 먼저, 다음이 대화 제안 (겹치면 고스트부터 닫는다).
        public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.isActiveEditor, let controller = parent.controller else { return false }

            if commandSelector == #selector(NSStandardKeyBindingResponding.insertTab(_:)) {
                guard let accepted = controller.acceptSuggestion() else { return false }
                textView.breakUndoCoalescing()
                textView.insertText(accepted, replacementRange: textView.selectedRange())
                textView.breakUndoCoalescing()
                (textView as? BlockTextView)?.postGhostAnnouncement("제안을 수락했어요")  // #24
                return true
            }

            if commandSelector == #selector(NSStandardKeyBindingResponding.insertNewline(_:)) {
                // 기록은 부수 효과 — 개행은 평소처럼 진행된다 (요구사항 §20).
                controller.acceptConversationSuggestion()
                return false
            }

            if commandSelector == #selector(NSStandardKeyBindingResponding.moveRight(_:)) {
                let range = textView.selectedRange()
                guard range.length == 0,
                    let word = controller.acceptWord(insertionLocation: range.location)
                else { return false }
                textView.breakUndoCoalescing()
                textView.insertText(word, replacementRange: range)
                textView.breakUndoCoalescing()
                // 부분 수락 상태도 VoiceOver에 안내 (#24 완료 조건 2).
                if let blockView = textView as? BlockTextView {
                    if let remaining = blockView.ghostText, !remaining.isEmpty {
                        blockView.postGhostAnnouncement(
                            "한 단어를 수락했어요 — 남은 제안: \(remaining.prefix(60))")
                    } else {
                        blockView.postGhostAnnouncement("제안 전체를 수락했어요")
                    }
                }
                return true
            }

            if commandSelector == #selector(NSStandardKeyBindingResponding.cancelOperation(_:))
                || commandSelector == #selector(NSStandardKeyBindingResponding.complete(_:)) {
                if controller.hasSuggestion {
                    controller.dismissSuggestion()
                    (textView as? BlockTextView)?.postGhostAnnouncement("제안을 거절했어요")  // #24
                    return true
                }
                if controller.hasConversationSuggestion {
                    controller.dismissConversationSuggestion(remember: true)
                    return true
                }
                return false
            }

            return false
        }

        // MARK: 컨트롤러 이벤트 전달

        func requestExplicitCompletion(_ textView: BlockTextView) {
            guard !textView.hasMarkedText(), parent.isActiveEditor,
                parent.controller?.engineState == .ready else { return }
            forwardEditEvent(textView)
        }

        private func forwardEditEvent(_ textView: BlockTextView) {
            guard parent.isActiveEditor, let controller = parent.controller,
                  textView.window?.firstResponder === textView else { return }
            let storage = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret != NSNotFound, caret <= storage.length else { return }

            // 코드·수식·구분선 블록에서는 제안하지 않는다 (디자인 v3 게이트).
            let paragraph = storage.paragraphRange(for: NSRange(location: caret, length: 0))
            let block = textView.blockInfo(in: paragraph).block
            let allowed = ![.code, .math, .divider, .image].contains(block)

            controller.noteEdit(
                prefix: Self.prefix(
                    of: storage, before: caret, limit: controller.effectiveContextCharacters),
                caretLocation: caret,
                isComposing: textView.hasMarkedText(),
                caretAtParagraphEnd: allowed && Self.isCaretAtParagraphEnd(storage, caret: caret)
            )
        }

        /// 커서 앞 원문 창(C). 시작점을 512(UTF-16) 격자에 내림 스냅해 타이핑
        /// 중 창 시작이 한 글자씩 밀리지 않게 한다 — 창 시작이 고정돼야 직전
        /// 요청과의 공통 접두(LCP)가 살아남아 KV 프리필 재사용이 가능하다
        /// (PLAN §11–§12). 내림 스냅이라 창이 limit보다 최대 한 격자 길 수 있다
        /// (soft 예산 — 하드 상한은 엔진의 토큰 예산이 지킨다).
        private static func prefix(of storage: NSString, before caret: Int, limit: Int) -> String {
            let raw = max(0, caret - limit)
            guard raw > 0 else { return storage.substring(to: caret) }
            var start = (raw / 512) * 512
            // 서러게이트 페어(이모지 등) 중간을 피해 합성 문자 경계로 물러난다.
            start = storage.rangeOfComposedCharacterSequence(at: start).location
            // 근처(≤256자)에 문단 경계가 있으면 그 뒤에서 시작 — 모델이 문단
            // 중간부터 읽지 않게 한다. 줄바꿈 위치도 고정이라 안정성은 유지된다.
            let searchLength = min(256, caret - start)
            if searchLength > 0 {
                let newline = storage.range(
                    of: "\n", options: [],
                    range: NSRange(location: start, length: searchLength))
                if newline.location != NSNotFound, newline.location + 1 < caret {
                    start = newline.location + 1
                }
            }
            return storage.substring(
                with: NSRange(location: start, length: caret - start))
        }

        private static func isCaretAtParagraphEnd(_ storage: NSString, caret: Int) -> Bool {
            let paragraph = storage.paragraphRange(for: NSRange(location: caret, length: 0))
            guard paragraph.upperBound > caret else { return true }
            let tail = storage.substring(
                with: NSRange(location: caret, length: paragraph.upperBound - caret))
            return tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - 타자기 존 스크롤 뷰

/// 마지막으로 쓰는 줄이 창 바닥(상태 바 바로 위)에 붙지 않고, 화면 중하단의
/// 편안한 위치에 머물게 하는 스크롤 뷰.
///
/// 왜: 기본 NSTextView는 타이핑 중 커서가 보이도록 뷰 하단(=textContainerInset
/// 44pt)까지만 스크롤한다. 그래서 글이 한 화면을 넘기면 그 뒤로는 줄곧 커서가
/// **바닥을 긁으며** 써지고, 이는 답답함 → "그만 쓰고 싶다"로 이어진다.
/// 아래쪽에 뷰 높이의 일부만큼 스크롤 여백(contentInsets.bottom)을 두면,
/// `BlockTextView.scrollRangeToVisible`가 이 여백만큼 커서 아래를 함께 드러내
/// 활성 줄이 대략 화면 75% 지점에 park하게 한다 — iA Writer·Ulysses의 차분한
/// 글쓰기 존과 같은 감각. 한 화면 안에 드는 짧은 글엔 스크롤이 없어 영향이 없다.
final class WritingScrollView: NSScrollView {
    var workspacePresentationEnabled = false
    var workspaceTypewriter = false
    func updateWorkspaceInsets() {
        guard workspacePresentationEnabled else { return }
        // Ordinary writing keeps the established 25% bottom breathing room.
        let next = NSEdgeInsets(top: workspaceTypewriter ? bounds.height * 0.26 : 0, left: 0,
            bottom: bounds.height * (workspaceTypewriter ? 0.38 : gutterFraction), right: 0)
        if abs(contentInsets.top - next.top) > 0.5 || abs(contentInsets.bottom - next.bottom) > 0.5 { contentInsets = next }
    }
    /// 활성 줄이 park할 지점을 남기기 위해 뷰 높이에 곱하는 하단 여백 비율.
    /// 0.25 → 커서가 바닥(≈93%)이 아니라 화면 75% 지점에 머문다(약 4~5줄 여유).
    private let gutterFraction: CGFloat = 0.25

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if workspacePresentationEnabled { updateWorkspaceInsets(); return }
        // 높이에 비례해 여백을 갱신 — 작은 창에선 작게, 큰 창에선 크게.
        let gutter = (newSize.height * gutterFraction).rounded()
        guard abs(contentInsets.bottom - gutter) > 0.5 else { return }
        contentInsets = NSEdgeInsets(top: contentInsets.top, left: 0, bottom: gutter, right: 0)
    }
}

// MARK: - 블록 모델

/// 문단 블록 타입 (디자인의 data-md와 1:1).

/// 이미지 소스 한 줄(`![](src){width=NN align=X}`)에서 파싱한 표시 속성.
/// 마크다운 왕복은 소스 문자열 그대로라 별도 저장 없이 `markdown`으로 되돌린다.
struct ImageAttrs: Equatable {
    var src: String
    /// 컬럼 폭 대비 표시 너비(%). 기본 100(=폭에 맞춤).
    var width: Int = 100
    /// 가로 정렬 — "left" / "center"(기본) / "right".
    var align: String = "center"
    /// 원문 alt·title — 속성 재작성 시 손실 없이 되돌리려고 보관 (이슈 #12).
    var alt: String = ""
    var title: String?
    /// `{…}` 앞부분(이미지 구문) 원문 — 있으면 markdown 재합성 대신 스플라이스.
    var optionsPrefix: String?
    /// 인식 못 한 확장 속성 토큰 원문(`custom=x` 등, 원래 순서 유지) —
    /// 정렬·리사이즈를 해도 사라지지 않게 (이슈 #14).
    var extraOptions: [String] = []

    /// 소스 마크다운으로 직렬화. optionsPrefix가 있으면 원문 구문을 그대로 쓰고
    /// `{…}`만 다시 붙인다 — alt·title·destination 표기가 절대 변하지 않는다.
    /// 없으면(새 조립) 구성요소를 CommonMark 규칙으로 **이스케이프해** 합성한다 —
    /// 기본값이면 접미를 생략한다.
    var markdown: String {
        var opts: [String] = []
        if width != 100 { opts.append("width=\(width)") }
        if align != "center" { opts.append("align=\(align)") }
        opts.append(contentsOf: extraOptions)
        let suffix = opts.isEmpty ? "" : "{\(opts.joined(separator: " "))}"
        if let prefix = optionsPrefix {
            return suffix.isEmpty ? prefix : "\(prefix) \(suffix)"
        }
        let titlePart = title.map { " \"" + Self.escapeTitle($0) + "\"" } ?? ""
        // title은 닫는 괄호 **안**이다 — 밖에 두면 파서가 이미지로 인정하지 않는다.
        return "![\(Self.escapeAlt(alt))](\(Self.serializeDestination(src))\(titlePart))\(suffix)"
    }

    // MARK: 신규 합성용 이스케이프 (#14) — 파서의 unescape와 짝을 이룬다.

    /// alt 텍스트 — 이미지 구문을 닫는 `]`와 백슬래시만 막으면 충분하다
    /// (파서 scanAlt가 중첩 괄호 카운트·escape만 존중).
    static func escapeAlt(_ text: String) -> String {
        escapeCharacters(text, in: "\\[]")
    }

    /// title — 여는 따옴표 종류에 따라 닫힘이 갈리므로 세 따옴표를 모두 막는다.
    static func escapeTitle(_ text: String) -> String {
        escapeCharacters(text, in: "\\\"'()")
    }

    /// destination — 공백·괄호가 있으면 angle destination(`<…>`)으로 감싸고,
    /// 내부의 `<` `>`는 이스케이프한다. 일반 destination은 공백에서 끊긴다.
    static func serializeDestination(_ path: String) -> String {
        guard path.contains(where: { " \t()".contains($0) }) else { return path }
        return "<\(escapeCharacters(path, in: "\\<>"))>"
    }

    private static func escapeCharacters(_ text: String, in set: String) -> String {
        var out = ""
        for c in text {
            if set.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

/// 렌더 모드 이미지 문단 하나 — 레이아웃 매니저 드로잉이 읽는 값 스냅샷.
struct ImageRender {
    let range: NSRange
    let image: NSImage
    /// 실제 그려질 크기(폭 % 반영 후).
    let size: NSSize
    let align: String
    /// 객체 선택 상태 — true면 선택 테두리를 그린다.
    let selected: Bool
    /// 로드 실패 플레이스홀더일 때의 원인 — nil이면 정상 렌더 (이슈 #15).
    let failure: ImageLoadFailure?

    init(
        range: NSRange, image: NSImage, size: NSSize, align: String,
        selected: Bool, failure: ImageLoadFailure? = nil
    ) {
        self.range = range
        self.image = image
        self.size = size
        self.align = align
        self.selected = selected
        self.failure = failure
    }
}


// MARK: - 텍스트 뷰

/// 블록 변환·직렬화·고스트 렌더를 담당하는 NSTextView.
final class BlockTextView: NSTextView {
    var workspaceInteraction: (any EditorWorkspaceInteraction)?
    private var workspaceTrackingArea: NSTrackingArea?
    var documentUndoManager: UndoManager?
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }
    @objc func undo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let manager = undoManager, manager.canUndo else { return }
        breakUndoCoalescing(); manager.undo()
    }
    @objc func redo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let manager = undoManager, manager.canRedo else { return }
        breakUndoCoalescing(); manager.redo()
    }
    private func historyCommandEnabled(_ action: Selector?) -> Bool? {
        if action == #selector(undo(_:)) { return isEditable && !hasMarkedText() && undoManager?.canUndo == true }
        if action == #selector(redo(_:)) { return isEditable && !hasMarkedText() && undoManager?.canRedo == true }
        return nil
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        historyCommandEnabled(menuItem.action) ?? super.validateMenuItem(menuItem)
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        historyCommandEnabled(item.action) ?? super.validateUserInterfaceItem(item)
    }
    var automaticallyFocusOnAttachment = true
    var editorDidActivate: (() -> Void)?
    let writingProjectionCapture = WritingEditorProjectionCapture()
    /// Native binding ownership is independent of the session's current runtime generation.
    var writingDocumentIdentity: EditorDocumentIdentity? {
        didSet {
            if oldValue != writingDocumentIdentity { writingProjectionCapture.sourceDidLoad?() }
        }
    }
    let writingDecorations = WritingDiagnosticsDecorationLayer()
    var usesProjectAssets = false
    var projectAssetCatalog: ProjectAssetCatalog? {
        didSet {
            if projectAssetCatalog != nil { usesProjectAssets = true }
            if oldValue != projectAssetCatalog { projectImageCache.removeAll() }
        }
    }
    var projectAssetImporter: (@MainActor (Data, String) async throws -> ProjectAssetCatalog)?
    private var projectImageCache = ImageLRU(budgetBytes: 128 * 1024 * 1024)

    func resolvedImage(for reference: String, maxPixelWidth: CGFloat? = nil) -> NSImage? {
        guard usesProjectAssets else {
            if let maxPixelWidth { return PurloryImageStore.displayImage(for: reference, maxPixelWidth: maxPixelWidth) }
            return PurloryImageStore.image(for: reference)
        }
        guard let bytes = projectAssetCatalog?.data(for: reference) else { return nil }
        let key = "\(reference)|\(maxPixelWidth ?? 0)"
        if let image = projectImageCache.find(key) { return image }
        let image = maxPixelWidth.map { PurloryImageStore.displayImage(data: bytes, maxPixelWidth: $0) }
            ?? NSImage(data: bytes)
        guard let image else { return nil }
        projectImageCache.insert(key: key, image: image,
            bytes: max(1, Int(image.size.width * image.size.height * 4)))
        return image
    }

    private func imageFailure(for reference: String) -> ImageLoadFailure? {
        guard usesProjectAssets else { return ImageFailure.classify(reference) }
        switch ImageReferenceParser.classify(reference) {
        case .remote, .blocked: return nil
        case .managedRelative, .externalFile: break
        }
        let ext = (reference as NSString).pathExtension.lowercased()
        if !ext.isEmpty, !PurloryImageStore.imageExtensions.contains(ext) { return .unsupported }
        guard projectAssetCatalog?.data(for: reference) != nil else { return .missing }
        guard let image = resolvedImage(for: reference), image.size.width > 0 else { return .corrupt }
        return nil
    }

    func insertProjectImage(data: Data, reference: String, object: PurloryImageObject? = nil) async throws {
        try await insertProjectImage(data: data, reference: reference, object: object,
            context: captureProjectImageOperation())
    }

    private struct ProjectImageOperation {
        let importer: @MainActor (Data, String) async throws -> ProjectAssetCatalog
        let body: String
        let selection: NSRange
        let projectID: WritingProjectID
    }

    /// Capture before enqueuing: SwiftUI may reuse this view before the task starts.
    private func captureProjectImageOperation() throws -> ProjectImageOperation {
        guard usesProjectAssets, let importer = projectAssetImporter,
            let projectID = projectAssetCatalog?.projectID, !hasMarkedText()
        else { throw ProjectSessionError.staleRuntime }
        return ProjectImageOperation(importer: importer, body: string,
            selection: selectedRange(), projectID: projectID)
    }

    private func insertProjectImage(
        data: Data, reference: String, object: PurloryImageObject?, context: ProjectImageOperation
    ) async throws {
        try await importProjectAsset(data: data, reference: reference, context: context) { view in
            if var object {
                object.src = reference
                view.insertImageParagraph(markdown: object.markdown)
            } else {
                view.insertImageBlock(relativePath: reference)
            }
        }
    }

    /// Keep a multi-file drop in one runtime generation until every asset is durable.
    func insertProjectImages(_ images: [(data: Data, reference: String)]) async throws {
        try await insertProjectImages(images, context: captureProjectImageOperation())
    }

    private func insertProjectImages(
        _ images: [(data: Data, reference: String)], context: ProjectImageOperation
    ) async throws {
        for image in images {
            try await importProjectAsset(data: image.data, reference: image.reference, context: context) { _ in }
        }
        for image in images { insertImageBlock(relativePath: image.reference) }
    }

    private func importProjectAsset(
        data: Data, reference: String, context: ProjectImageOperation, apply: (BlockTextView) -> Void
    ) async throws {
        try Task.checkCancellation()
        let catalog = try await context.importer(data, reference)
        guard !Task.isCancelled, !hasMarkedText(), string == context.body, selectedRange() == context.selection,
            projectAssetCatalog?.projectID == context.projectID, catalog.projectID == context.projectID
        else { throw ProjectSessionError.staleRuntime }
        projectAssetCatalog = catalog
        apply(self)
    }

    private func saveAndInsertImage(_ data: Data, ext: String, object: PurloryImageObject? = nil) {
        guard usesProjectAssets else {
            guard let relative = PurloryImageStore.save(data, ext: ext) else {
                alertAssetWriteFailure("이미지 파일을 저장하지 못했어요.")
                return
            }
            insertImageBlock(relativePath: relative)
            return
        }
        let suffix = PurloryImageStore.imageExtensions.contains(ext.lowercased()) ? ext.lowercased() : "png"
        let reference = "images/\(UUID().uuidString).\(suffix)"
        guard let context = try? captureProjectImageOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await insertProjectImage(data: data, reference: reference, object: object, context: context) }
            catch ProjectSessionError.staleRuntime {} catch is CancellationError {}
            catch { alertAssetWriteFailure(error.localizedDescription) }
        }
    }

    /// 레이아웃 매니저(nonisolated 드로잉)에서도 읽는다 — 쓰기는 메인 스레드뿐.
    /// nonisolated 드로잉이 읽기 때문에 @MainActor 전환이 불가능하다 — 이 탈출구는
    /// 렌더 경로 재설계(#53·#61)에서 스냅샷 패턴으로 없앨 과제다 (이슈 #45).
    nonisolated(unsafe) var palette: PurloryTheme = .light

    /// 원본 마크다운 소스 직접 편집 모드 여부 (⌘/).
    private(set) var isSourceMode = false

    /// 문서 끝 빈 문단(typingAttributes에만 존재)의 블록 스냅샷 —
    /// 레이아웃 매니저가 nonisolated 드로잉 중에 읽는다.
    nonisolated(unsafe) private(set) var tailBlockInfo:
        (block: String?, checked: Bool, marker: String?, indent: Int, codeLang: String?) = (nil, false, nil, 0, nil)

    /// typingAttributes 변경 후 호출해 스냅샷을 갱신한다.
    private func updateTailSnapshot() {
        tailBlockInfo = (
            typingAttributes[.purloryBlock] as? String,
            typingAttributes[.purloryChecked] as? Bool ?? false,
            typingAttributes[.purloryMarker] as? String,
            typingAttributes[.purloryIndent] as? Int ?? 0,
            typingAttributes[.purloryCodeLang] as? String
        )
    }

    /// 본문 기본 글자 크기(pt) — 설정에서 주입. 모든 블록 크기가 이 값에 비례한다.
    /// 디자인 기준은 20pt. 값이 바뀌면 bodyFont를 다시 만든다.
    var baseFontSize: CGFloat = 20 {
        didSet {
            guard baseFontSize != oldValue else { return }
            bodyFont = PurloryFonts.serif(baseFontSize)
            // 인라인 수식 원자도 본문 크기에 맞춰 다시 렌더한다 (이슈 #20).
            if window != nil { rerenderInlineAtoms() }
        }
    }

    /// 본문 기본 폰트 — 디자인: Noto Serif KR. 크기는 baseFontSize를 따른다.
    private(set) var bodyFont = PurloryFonts.serif(20)

    /// 디자인 기준(20pt) 대비 배율 — 제목·코드·수식 크기를 함께 확대/축소한다.
    private var fontScale: CGFloat { baseFontSize / 20 }
    var editorialWorkspaceStyle = false {
        didSet {
            (layoutManager as? PurloryLayoutManager)?.editorialWorkspaceStyle = editorialWorkspaceStyle
        }
    }

    /// 본문 줄 간격(pt) — 설정에서 주입. `lineHeightMultiple` 대신 `lineSpacing`을
    /// 쓰는 이유: 배수는 여백을 라인 위쪽에 몰아 글자가 커서 아래쪽에 붙지만,
    /// lineSpacing은 자연 줄 높이를 유지해 글자·커서 높이가 일치한다 (요구 1·4).
    var lineSpacing: CGFloat = CGFloat(CompletionSettings.defaultLineSpacing)
    var proseLayout: EditorProseLayout = .spaced

    /// 고스트 페이드 인 진행도(0…1) — 없던 제안이 새로 뜰 때만 0에서 1로 올린다.
    /// AI 제안이 커서 옆에 "쿵" 나타나 시선을 때리지 않고 부드럽게 스며들게 하려는 것.
    /// 한 단어(→) 수락으로 제안이 짧아질 때는 1을 유지해 다시 깜빡이지 않는다.
    private var ghostOpacity: CGFloat = 1
    /// 페이드 인 애니메이션 태스크 — 새 제안·폐기 때 취소하고 다시 건다.
    private var ghostFadeTask: Task<Void, Never>?

    /// 고스트 세대 (#24) — 새 제안이 뜰 때마다 증가한다. 시각 고스트와 접근성
    /// 노출이 같은 원천(`ghostText`)에서 같은 세대로 읽힘을 보장하는 근거다.
    /// 사라짐(→nil)은 세대를 올리지 않는다 — 같은 제안의 생애주기 동안 불변.
    private(set) var ghostGeneration = 0

    /// 접근성 경로가 쓰는 현재 제안 스냅샷 — 시각 드로잉과 **같은 원천**이다 (#24).
    func ghostSnapshotForAccessibility() -> (text: String, generation: Int)? {
        guard let ghost = ghostText, !ghost.isEmpty else { return nil }
        return (ghost, ghostGeneration)
    }

    /// 현재 고스트 텍스트. nil/빈 문자열이면 그리지 않는다.
    var ghostText: String? {
        didSet {
            guard ghostText != oldValue else { return }
            if let ghost = ghostText, !ghost.isEmpty, (oldValue == nil || oldValue?.isEmpty == true) {
                ghostGeneration += 1
                announceGhostAppearance(ghost)
            }
            // 없던 자리에 제안이 새로 뜰 때만 페이드 인 — 짧아짐·사라짐은 즉시 반영.
            if let ghost = ghostText, !ghost.isEmpty, oldValue == nil {
                startGhostFadeIn()
            } else if ghostText == nil {
                ghostFadeTask?.cancel()
                ghostFadeTask = nil
                ghostOpacity = 1
            }
            needsDisplay = true
        }
    }

    /// 마커 소비/스타일 적용 중 재진입 방지.
    private var isTransforming = false
    var mediaParagraphIndex: ParagraphRenderIndex?
    var mediaDirtyRanges: [NSRange] = []
    var mediaIndexBuildCount = 0
    var lastMediaIndexUpdateParagraphs = 0
    var lastMediaRenderParagraphCount = 0
    var mediaLastSelectionRange: NSRange?

    /// 수식 렌더 폰트 크기 — 본문 크기와 맞춘다.
    var mathFontSize: CGFloat { baseFontSize }

    /// 수식 배경 박스가 렌더된 수식보다 사방으로 확보하는 여백(pt) — 항상 글씨보다
    /// 이만큼 크게, 분수처럼 세로로 큰 수식이면 박스도 그만큼 커진다 (요구 5).
    /// 레이아웃 매니저의 nonisolated 드로잉에서도 읽는 불변 상수.
    nonisolated static let mathBoxMargin: CGFloat = 10

    /// 현재 렌더 모드인 수식 문단들 (문단 range + 렌더된 LaTeX 이미지).
    /// `refreshRenderedBlocks()`이 갱신하고 레이아웃 매니저가 그린다.
    /// 다중 행 display 그룹은 그룹 전체 범위가 하나의 항목으로 들어간다 (이슈 #20).
    nonisolated(unsafe) private(set) var mathRenders: [(range: NSRange, image: NSImage)] = []
    /// 무효 수식 문단(location) → 파싱 오류 원인 — 우클릭 메뉴·접근성 안내용 (이슈 #22).
    nonisolated(unsafe) private(set) var mathRenderErrors: [Int: String] = [:]

    /// 직전 패스에서 감지된 다중 행 수식 그룹 범위 — 구조 편집 후 줄 높이 잔상을
    /// 되돌리는 기준 (이슈 #22 valid→invalid→valid 잔상 예방).
    private var previousMathGroups: [NSRange] = []
    /// 이번 패스에서 clear 전경을 심은 범위들 (#18) — 다음 패스에서 **이 범위만**
    /// 제거한다. 과거엔 문서 전체(0..length)를 지웠는데, 이것이 매 키 입력·커서
    /// 이동마다 O(문서) 레이아웃 무효화를 만드는 주범이었다. 편집 범위의 임시
    /// 속성은 TextStorage가 스스로 떨어뜨리므로, 기록된 범위(문단 경계 확장)만
    /// 닦으면 누수가 없다.
    private var previousClearRanges: [NSRange] = []
    /// 스크롤 틱 coalescing (#18 2단계) — 연속 스크롤 중 마지막 위치만 갱신.
    private var visibleRefreshTask: Task<Void, Never>?

    /// 스크롤이 멈춘 뒤 120ms에 1번만 가시 범위 재수집.
    func scheduleVisibleRefresh() {
        visibleRefreshTask?.cancel()
        visibleRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.refreshVisibleBlocks()
        }
    }

    /// 현재 렌더 모드인 이미지 문단들 — 문단 range·이미지·표시 크기·정렬·선택 여부.
    /// 정렬/크기는 소스(`![](src){width=NN align=X}`)에서 파싱해 담고, 레이아웃
    /// 매니저의 `drawImage`가 그대로 쓴다 (요구 3).
    nonisolated(unsafe) private(set) var imageRenders: [ImageRender] = []

    /// 객체로 선택된 이미지 문단의 시작 위치 — 클릭하면 소스(![](…)) 대신 이미지가
    /// 선택 테두리와 함께 남고, 정렬·줄바꿈 툴바가 뜬다 (요구 3).
    var selectedImageLocation: Int?

    /// 드래그 중 미리보기 너비(%) — refreshRenderedBlocks가 소스 대신 이 값을 쓴다.
    private var resizePreview: (loc: Int, width: Int)?
    /// 선택된 이미지를 감싸는 오버레이 박스 (요구: 이미지를 하나의 박스로).
    private var imageBox: ImageBoxOverlay?
    /// 이미지 이동 드래그 중 표시할 드롭 위치 y (뷰 좌표). nil이면 표시 안 함.
    var imageDropIndicatorY: CGFloat?

    // MARK: 커서 효과 (에디터 v3.1 — 글로우 대체)

    /// 직전 선택(길이>0) 하이라이트가 걸친 영역 — 더블클릭으로 잡힌 공백·개행
    /// 선택은 글리프 rect 바깥까지 그려져, 선택 해제 시 AppKit의 무효화가
    /// 다 덮지 못하고 잔상이 남는다. 선택이 바뀔 때 이 rect를 직접 지운다.
    private var lastSelectionRect: NSRect?
    private var nativeTextUpdateDepth = 0
    private var refreshingEditingOverlays = false
    private var editingOverlayRefreshPending = false
    private var pendingCaretBlinkRestart = false

    /// NSTextView can notify selection/insertion changes before an insertion or
    /// IME update has finished. Resolve the final layout once those edits unwind.
    private func finishNativeTextUpdate() {
        nativeTextUpdateDepth -= 1
        guard nativeTextUpdateDepth == 0 else { return }
        scheduleEditingOverlayRefresh(restartBlink: true)
    }

    fileprivate func scheduleEditingOverlayRefresh(restartBlink: Bool = false) {
        pendingCaretBlinkRestart = pendingCaretBlinkRestart || restartBlink
        guard !editingOverlayRefreshPending else { return }
        editingOverlayRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editingOverlayRefreshPending = false
            let restart = self.pendingCaretBlinkRestart
            self.pendingCaretBlinkRestart = false
            guard self.window != nil else { return }
            self.refreshActiveLineHighlight(restartBlink: restart)
        }
    }

    /// Synchronize the paragraph background, selection cleanup and caret after
    /// selection, focus or layout changes. Keep one background view so moving
    /// between paragraphs cannot leave stale bands behind.
    func refreshActiveLineHighlight(restartBlink: Bool = true) {
        guard nativeTextUpdateDepth == 0, !isTransforming else {
            scheduleEditingOverlayRefresh(restartBlink: restartBlink)
            return
        }
        guard !refreshingEditingOverlays else { return }
        refreshingEditingOverlays = true
        defer { refreshingEditingOverlays = false }
        syncActiveLineView()
        // 직전 선택 하이라이트 영역 무효화 — 공백·개행 선택 잔상 방지.
        let selection = selectionHighlightRect()
        if selection != lastSelectionRect, let oldSelection = lastSelectionRect {
            setNeedsDisplay(oldSelection.insetBy(dx: -4, dy: -4))
        }
        lastSelectionRect = selection
        syncCaretView(restartBlink: restartBlink)
    }

    /// 현재 선택 하이라이트가 그려질 수 있는 영역 (뷰 좌표). 선택이 없으면 nil.
    ///
    /// 개행 선택은 마지막 글리프 오른쪽 바깥까지 그려지므로, 세로는 글리프
    /// bounding rect를 따르되 가로는 컨테이너 전체 폭으로 잡는다 — 지우기
    /// 전용이라 넓게 잡아도 다시 그리는 비용만 조금 늘 뿐 안전하다.
    private func selectionHighlightRect() -> NSRect? {
        let range = selectedRange()
        guard range.length > 0, let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // 문서 끝 개행까지 선택되면 여분 라인 프래그먼트에도 하이라이트가 걸친다.
        if range.upperBound >= (string as NSString).length {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { rect = rect.union(extra) }
        }
        rect.origin.x = 0
        rect.size.width = textContainer.size.width
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Highlight the native paragraph, including wraps and U+2028 line breaks.
    /// TextKit's used fragments include first-line indents and author alignment;
    /// a container-wide band starts too far left in indented manuscripts.
    private func activeParagraphRect() -> NSRect? {
        guard let window, window.firstResponder === self,
            selectedRange().length == 0,
            selectedRange().location != NSNotFound,
            selectedImageLocation == nil,
            !isEditingMath,
            let layoutManager, let textContainer
        else { return nil }
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        layoutManager.ensureLayout(forCharacterRange: paragraph)
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        var bounds: NSRect?
        func include(_ fragment: NSRect, used: NSRect) {
            guard fragment.height > 0 else { return }
            let top = max(fragment.minY, used.minY - 2)
            let bottom = min(fragment.maxY, used.maxY + 2)
            let rect = NSRect(x: used.minX, y: top,
                width: max(1, fragment.maxX - padding - used.minX),
                height: max(1, bottom - top))
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        if paragraph.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, _, _ in
                include(fragment, used: used)
            }
        }
        // A terminal soft break has an empty visual line in the SAME paragraph.
        // A terminal Enter instead belongs to the next, empty paragraph.
        let endsWithSoftBreak = paragraph.upperBound == ns.length && ns.length > 0
            && ns.character(at: ns.length - 1) == 0x2028
        if paragraph.length == 0 || endsWithSoftBreak {
            layoutManager.ensureLayout(for: textContainer)
            let extra = layoutManager.extraLineFragmentRect
            if layoutManager.extraLineFragmentTextContainer === textContainer, extra.height > 0 {
                var used = layoutManager.extraLineFragmentUsedRect
                if caret == ns.length, let insertion = caretRectInView() {
                    used.origin.x = insertion.minX - origin.x
                }
                include(extra, used: used)
            }
        }
        return bounds?.offsetBy(dx: origin.x, dy: origin.y)
    }

    private var isEditingMath: Bool {
        guard window?.firstResponder === self else { return false }
        let ns = string as NSString
        let location = min(selectedRange().location, ns.length)
        return blockInfo(in: ns.paragraphRange(for: NSRange(location: location, length: 0))).block == .math
    }

    /// Native editing gestures take precedence over workspace dismissal.
    var ownsEscapeKey: Bool {
        hasMarkedText() || !(ghostText ?? "").isEmpty || selectedImageLocation != nil
            || isEditingMath || workspaceInteraction?.ownsEscapeKey == true
    }

    /// 창에 처음 붙을 때 한 번만 자동 포커스 — 앱을 켜면 곧바로 쓸 수 있게.
    private var didInitialFocus = false
    var editorWindowDidChange: ((NSTextView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { workspaceInteraction?.detach(); hideSelectionToolbar() }
        editorWindowDidChange?(self)
        guard automaticallyFocusOnAttachment, !didInitialFocus, window != nil else { return }
        didInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            editorDidActivate?()
            // AppKit may provide the window undo manager only after editor activation.
            editorWindowDidChange?(self)
            DispatchQueue.main.async { [weak self] in
                // 포커스가 돌아오면 커서 문단의 수식을 소스 모드로 되돌린다.
                self?.refreshRenderedBlocks()
                self?.refreshActiveLineHighlight()
            }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            // 포커스를 잃으면 커서가 수식 문단에 남아 있어도 렌더로 전환하고,
            // 커서 줄 하이라이트도 지운다.
            DispatchQueue.main.async { [weak self] in
                self?.refreshRenderedBlocks()
                self?.refreshActiveLineHighlight()
            }
        }
        return ok
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let workspaceTrackingArea { removeTrackingArea(workspaceTrackingArea); self.workspaceTrackingArea = nil }
        guard workspaceInteraction != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); workspaceTrackingArea = area
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); workspaceInteraction?.mouseMoved(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); workspaceInteraction?.mouseExited() }
    override func mouseDragged(with event: NSEvent) {
        if workspaceInteraction?.mouseDragged(event) == true { return }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if workspaceInteraction?.mouseUp(event) == true { return }
        super.mouseUp(with: event)
    }

    // MARK: 마크다운 ↔ 블록 변환

    /// Replaces the manuscript at a stable document boundary. This is intentionally separate
    /// from ordinary binding synchronization: only a real document identity change may discard
    /// native undo and transient editor state.
    @discardableResult
    func prepareForDocumentTransition(
        from previous: EditorDocumentIdentity?,
        to next: EditorDocumentIdentity,
        markdown: String
    ) -> Bool {
        guard previous != next else { return false }
        prepareForDocumentTransition(markdown: markdown)
        return true
    }

    func prepareForDocumentTransition(markdown: String) {
        if hasMarkedText() {
            // Commit Hangul composition before replacing TextKit storage. Persisting the outgoing
            // position remains the coordinator's responsibility and never records marked state.
            unmarkText()
        }
        ghostText = nil
        showConversationPrompt(nil)
        hideImageToolbar()
        hideSelectionToolbar()
        load(markdown: markdown)
        undoManager?.removeAllActions()
    }

    /// 인용(`> `, `> > `) 접두 파싱 — 중첩 단계(0...6)와 본문을 돌려준다.
    /// 공백 없는 `>literal`은 인용으로 오독하지 않는다.
    nonisolated static func parseQuotePrefix(_ line: String) -> (indent: Int, body: String)? {
        if line == ">" { return (0, "") }
        guard line.hasPrefix("> ") else { return nil }
        var rest = line[...]
        var count = 0
        while count < 7 {
            if rest.hasPrefix("> ") {
                count += 1
                rest = rest.dropFirst(2)
            } else if rest == ">" {
                count += 1
                rest = rest.dropFirst(1)
                break
            } else {
                break
            }
        }
        guard count > 0 else { return nil }
        return (count - 1, String(rest))
    }

    /// 들여쓰기된 목록(`  - `, `  1. `, `  - [ ] `) 접두 파싱 — 2칸 공백 단위로 최대 6단계.
    nonisolated static func parseListPrefix(_ line: String) -> (
        block: PurloryBlock, checked: Bool, marker: String?, indent: Int, body: String
    )? {
        var leadingSpaces = 0
        for ch in line {
            if ch == " " { leadingSpaces += 1 }
            else { break }
        }
        let indent = min(6, leadingSpaces / 2)
        let rest = String(line.dropFirst(indent * 2))
        if rest.hasPrefix("- [ ] ") || rest.hasPrefix("- [x] ") {
            return (.todo, rest.hasPrefix("- [x] "), nil, indent, String(rest.dropFirst(6)))
        } else if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            return (.bullet, false, nil, indent, String(rest.dropFirst(2)))
        } else if let match = rest.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let marker = String(rest[rest.startIndex..<match.upperBound])
                .trimmingCharacters(in: .whitespaces)
            return (.number, false, marker, indent, String(rest[match.upperBound...]))
        }
        return nil
    }

    /// 마크다운을 파싱해 storage를 블록 문서로 채운다 (buildDOM).
    func load(markdown: String, sourceMode: Bool = false) {
        guard let storage = textStorage else { return }
        isSourceMode = sourceMode
        lastTypingKeyTimestamp = nil
        invalidateMediaIndex()
        isTransforming = true
        let result = NSMutableAttributedString()
        var inCode = false
        var currentCodeLang: String?
        // 다중 행 display 수식 그룹 상태 — "$$"만 있는(혹은 $$ 뒤 내용이 이어지는)
        // 줄에 열리고 $$로 닫힌다. 그룹 안에선 다른 블록 파싱(#·-·>)을 전부 건너뛴다:
        // 행렬·cases 내용 줄이 헤딩·목록으로 오독되면 원문 구조가 깨진다 (이슈 #20).
        var inMathGroup = false
        let lines = markdown.components(separatedBy: "\n")
        if sourceMode {
            result.append(NSAttributedString(string: markdown, attributes: styleAttributes(for: .p, checked: false)))
        } else {
            for (index, rawLine) in lines.enumerated() {
                var line = rawLine
                let trimmedFence = line.trimmingCharacters(in: .whitespaces)
                if !inMathGroup {
                    if !inCode, trimmedFence.hasPrefix("```"), !trimmedFence.dropFirst(3).contains("`") {
                        inCode = true
                        let lang = String(trimmedFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        currentCodeLang = lang.isEmpty ? nil : lang
                        continue
                    } else if inCode, trimmedFence == "```" {
                        inCode = false
                        currentCodeLang = nil
                        continue
                    }
                }
                var block = PurloryBlock.p
                var checked = false
                var marker: String?
                var indent = 0
                var codeLang: String?
                // 정렬 래퍼(<p align="…">…</p>)는 블록 판정 전에 벗긴다.
                var align: String?
                if !inCode, !inMathGroup {
                    let full = NSRange(location: 0, length: (line as NSString).length)
                    if let match = Self.alignWrapper.firstMatch(in: line, range: full) {
                        align = (line as NSString).substring(with: match.range(at: 1))
                        line = (line as NSString).substring(with: match.range(at: 2))
                    }
                }
                // 이 줄이 수식 그룹에서 어떤 역할인지 — 속성으로 기록해 serialize가
                // 구분자를 정확히 되돌려준다.
                var mathDelim: String?
                if inCode {
                    block = .code
                    codeLang = currentCodeLang
                } else if inMathGroup {
                    block = .math
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "$$" || trimmed.hasSuffix("$$"), trimmed.count >= 2 {
                        // 닫는 줄. 텍스트는 **원문 그대로** 둔다 — 빈 문단은 storage에서
                        // 존재하지 않아(마지막 줄이면 특히) 속성째 사라진다. 구분자를
                        // 벗기는 일은 렌더·직렬화가 역할 속성으로 처리한다 (이슈 #20).
                        mathDelim = "close"
                        inMathGroup = false
                    } else {
                        // 중간 내용 줄 — 완결 단독 수식과 구별해야 serialize가 $$를
                        // 덧붙이지 않는다.
                        mathDelim = "mid"
                    }
                } else if line.hasPrefix("###### ") {
                    block = .h6; line = String(line.dropFirst(7))
                } else if line.hasPrefix("##### ") {
                    block = .h5; line = String(line.dropFirst(6))
                } else if line.hasPrefix("#### ") {
                    block = .h4; line = String(line.dropFirst(5))
                } else if line.hasPrefix("### ") {
                    block = .h3; line = String(line.dropFirst(4))
                } else if line.hasPrefix("## ") {
                    block = .h2; line = String(line.dropFirst(3))
                } else if line.hasPrefix("# ") {
                    block = .h1; line = String(line.dropFirst(2))
                } else if let quoteMatch = Self.parseQuotePrefix(line) {
                    block = .quote; indent = quoteMatch.indent; line = quoteMatch.body
                } else if let listMatch = Self.parseListPrefix(line) {
                    block = listMatch.block; checked = listMatch.checked
                    marker = listMatch.marker; indent = listMatch.indent; line = listMatch.body
                } else if line.range(of: #"^---+\s*$"#, options: .regularExpression) != nil {
                    block = .divider; line = ""
                } else if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count >= 4 {
                    block = .math; line = String(line.dropFirst(2).dropLast(2))
                } else if line.trimmingCharacters(in: .whitespaces) == "$$"
                    || (line.hasPrefix("$$") && !line.dropFirst(2).hasPrefix("$")) {
                    // "$$" 단독 또는 "$$내용…" — 여러 줄 display의 열기 (이슈 #20).
                    // 텍스트는 원문 그대로 — 벗기는 일은 렌더·직렬화가 한다.
                    block = .math
                    mathDelim = "open"
                    inMathGroup = true
                } else if line.range(
                    of: #"^!\[[^\]]*\]\([^)\s]+\)(?:\{[^}]*\})?$"#,
                    options: .regularExpression) != nil {
                    // 한 줄 전체가 이미지 마크다운 — 원문(![](src){…})을 소스로 보관하고
                    // 커서가 밖이면 렌더 이미지로 덮어 그린다 (수식과 같은 방식).
                    block = .image
                }
                var attrs = styleAttributes(for: block, checked: checked, indent: indent)
                attrs[.purloryBlock] = block.rawValue
                if checked { attrs[.purloryChecked] = true }
                if let marker { attrs[.purloryMarker] = marker }
                if indent > 0 { attrs[.purloryIndent] = indent }
                if let codeLang { attrs[.purloryCodeLang] = codeLang }
                if let mathDelim { attrs[.purloryMathDelim] = mathDelim }
                if let align {
                    attrs[.purloryAlign] = align
                    if let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                        as? NSMutableParagraphStyle {
                        ps.alignment = align == "right" ? .right : .center
                        attrs[.paragraphStyle] = ps
                    }
                }
                let suffix = index < lines.count - 1 ? "\n" : ""
                switch block {
                case .code, .math, .divider, .image:
                    // 코드·수식·이미지엔 인라인 서식이 없다 — 원문 그대로.
                    result.append(NSAttributedString(string: line + suffix, attributes: attrs))
                default:
                    for segment in InlineMarkdown.parse(line) {
                        var merged = attrs
                        for (key, value) in segment.attrs { merged[key] = value }
                        result.append(NSAttributedString(string: segment.text, attributes: merged))
                    }
                    result.append(NSAttributedString(string: suffix, attributes: attrs))
                }
            }
        }
        storage.setAttributedString(result)
        if !sourceMode {
            decorateInline(in: NSRange(location: 0, length: storage.length))
            convertAllInlineMath()
        }
        // 저널을 열면 맨 위·처음에 커서를 둔다 — 예전엔 문서 끝에 놓여, 뷰포트는
        // 위인데 커서는 아래라 첫 키 입력이 바닥으로 순간이동하는 혼란이 있었다.
        setSelectedRange(NSRange(location: 0, length: 0))
        // 뷰포트도 맨 위로 — 긴 저널을 열면 처음부터 보이게.
        scrollToBeginningOfDocument(nil)
        if storage.length == 0 {
            applyBlock(.p, to: NSRange(location: 0, length: 0), registerUndo: false)
        }
        syncTypingAttributes()
        isTransforming = false
        selectedImageLocation = nil
        hideImageToolbar()
        hideSelectionToolbar()
        // 새 문서의 마커 캐시를 실측으로 초기화 — 로드는 드물어 전체 스캔이 싸다.
        // (이전 문서의 플래그를 물려받으면 빠른 경로 판정이 틀린다.)
        syncMarkerFlag()
        // 직렬화 캐시도 새 문서 기준으로 — 다음 serialize()가 전체 재구축한다.
        invalidateSerialCache()
        // 커서가 어느 문단에 있든(수식·이미지 포함) 로드 직후엔 전부 렌더로 강제한다 —
        // 소스가 잠깐 보였다 사라지지 않게. 사용자가 커서를 움직이면 평소 규칙으로 복귀.
        if !sourceMode { refreshRenderedBlocks(forceRender: true) }
        writingDidLoad(markdown)
        needsDisplay = true
    }

    /// 전역 검색 결과 클릭 — 본문에서 질의어의 첫 매치를 선택하고 화면 가운데쯤으로
    /// 스크롤한다 (요구 2). 선택 하이라이트(민트 영역)가 곧 "여기예요" 표시가 된다.
    /// 매치가 없으면(제목만 걸렸거나 마커에 걸친 경우) 그대로 둔다.
    func revealMatch(of query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let ns = string as NSString
        let match = ns.range(of: q, options: .caseInsensitive)
        guard match.location != NSNotFound else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(match)
        // 매치 줄이 화면 가장자리에 걸리지 않게 위아래 여유를 두고 드러낸다.
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: match, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            _ = scrollToVisible(rect.insetBy(dx: 0, dy: -140))
        } else {
            scrollRangeToVisible(match)
        }
        refreshActiveLineHighlight()
    }

    /// 현재 집필 위치 스냅샷 — 문서별 복원 저장용 (#36). `marked`를 함께 반환해
    /// 스토어가 확정되지 않은 IME 조합 위치를 기록하지 않도록 한다.
    func writingPositionSnapshot() -> (
        location: Int, selectionLength: Int, before: String, after: String, marked: Bool
    )? {
        let ns = string as NSString
        let location = max(0, min(selectedRange().location, ns.length))
        let selectionLength = max(0, min(selectedRange().length, ns.length - location))
        let selectionEnd = location + selectionLength
        let beforeStart = max(0, location - 24)
        let afterEnd = min(ns.length, selectionEnd + 24)
        return (
            location,
            selectionLength,
            ns.substring(with: NSRange(location: beforeStart, length: location - beforeStart)),
            ns.substring(with: NSRange(location: selectionEnd, length: afterEnd - selectionEnd)),
            hasMarkedText()
        )
    }

    /// 재안착 사다리를 통과한 위치로 복원(#36) — 앵커가 문맥에 맞으면 true.
    func restoreWritingPosition(_ position: WritingPositionStore.Position, entryID: UUID) -> Bool {
        guard let resolved = WritingPositionStore.shared.resolve(for: entryID, in: string)
        else { return false }
        restoreWritingPosition(
            .init(
                location: resolved,
                selectionLength: position.selectionLength,
                before: position.before,
                after: position.after))
        return true
    }

    func restoreWritingPosition(_ position: WritingPositionStore.Position) {
        let length = (string as NSString).length
        let location = max(0, min(position.location, length))
        let selectionLength = max(0, min(position.selectionLength, length - location))
        setSelectedRange(NSRange(location: location, length: selectionLength))
        syncTypingAttributes()
        scrollRangeToVisible(selectedRange())
    }

    /// 저장해 둔 커서 위치로 되돌리고 그 자리로 스크롤한다 (저널 재방문, M6).
    func restoreCaret(to location: Int) {
        restoreSelection(to: NSRange(location: location, length: 0))
    }

    func restoreSelection(to range: NSRange) {
        let textLength = (string as NSString).length
        let location = max(0, min(range.location, textLength))
        let selectionLength = max(0, min(range.length, textLength - location))
        setSelectedRange(NSRange(location: location, length: selectionLength))
        syncTypingAttributes()
        scrollRangeToVisible(selectedRange())
    }

    /// `<p align="center|right">…</p>` — 정렬 저장 래퍼 (.p 문단 전용).
    private static let alignWrapper = try! NSRegularExpression(
        pattern: #"^<p align="(center|right)">([^\n]*)</p>$"#)

    /// storage를 순수 마크다운으로 되돌린다 (저장 경로).
    ///
    /// **문단별 증분 캐시**로 매 키 입력의 O(문서)를 O(편집)으로 줄인다
    /// (docs/editor-perf.md): 전체 비용의 정체는 NSTextStorage 조각(UTF-16 백업)을
    /// Swift 문자열로 브리지·이어붙이는 것이라(300k에서 17ms), 바뀐 문단만 다시
    /// 브리지하고 나머지는 캐시된 네이티브 줄을 재사용해 join한다(0.14ms).
    ///
    /// **불변조건**: `serialize(증분 상태) == serialize(전체 문서)`. 캐시가 조금이라도
    /// 불확실하면(`serialLinesValid == false`) 전체 재구축으로 떨어진다 — 그 경로는
    /// 예전 코드와 동일한 결과라 정답이 보장된다. 안전 판정은 델리게이트가 한다
    /// (`updateSerialCacheState`). 등식은 `SerializationFuzzTests`가 검증한다.
    func serialize() -> String {
        if isSourceMode { return string }
        writingProjectionCapture.serializationInvocationCount += 1
        writingProjectionCapture.beginSerialization(storage: textStorage)
        if !serialLinesValid {
            rebuildSerialCache()
        } else if serialFastDirty {
            applyFastSerialUpdate()
        }
        return assembleSerialized(serialLines)
    }

    /// Explicit inspection maps the native caret to original Markdown coordinates.
    /// Consumed block markers and code fences contribute only to source coordinates.
    func sourceCursorOffset(at requestedOffset: Int? = nil) -> Int {
        if isSourceMode {
            let ns = string as NSString
            return min(max(0, requestedOffset ?? selectedRange().location), ns.length)
        }
        let ns = string as NSString, caret = min(max(0, requestedOffset ?? selectedRange().location), ns.length)
        var nativeOffset = 0, sourceOffset = 0, inCode = false
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: nativeOffset, length: 0))
            let line = serializedLine(of: para)
            if line.isCode != inCode {
                sourceOffset += line.isCode ? 4 + (line.codeLang?.utf16.count ?? 0) : 4
                inCode = line.isCode
            }
            if caret < NSMaxRange(para) || NSMaxRange(para) == ns.length {
                let info = storageBlockInfo(in: para), plain = paragraphContent(para)
                let length = min(max(0, caret - para.location), plain.utf16.count)
                let indentCount = info.indent * 2
                let blockPrefix: Int
                switch info.block {
                case .h1: blockPrefix = 2
                case .h2: blockPrefix = 3
                case .h3: blockPrefix = 4
                case .h4: blockPrefix = 5
                case .h5: blockPrefix = 6
                case .h6: blockPrefix = 7
                case .quote: blockPrefix = (info.indent + 1) * 2
                case .bullet: blockPrefix = indentCount + 2
                case .number: blockPrefix = indentCount + (info.marker ?? "1.").utf16.count + 1
                case .todo: blockPrefix = indentCount + 6
                case .math:
                    let content = serializedContent(of: para, block: info.block)
                    blockPrefix = line.text == content ? 0 : 2
                default:
                    if let align = alignValue(at: para), info.block == .p {
                        blockPrefix = "<p align=\"\(align)\">".utf16.count
                    } else { blockPrefix = 0 }
                }
                guard let storage = textStorage,
                    ![PurloryBlock.code, .math, .divider, .image].contains(info.block) else {
                    return sourceOffset + blockPrefix + length
                }
                var prefixLength = InlineMarkdown.serialize(storage,
                    in: NSRange(location: para.location, length: length)).utf16.count
                if length > 0 {
                    var run = NSRange()
                    let attrs = storage.attributes(at: para.location + length - 1, effectiveRange: &run)
                    if NSMaxRange(run) > para.location + length,
                        !(attrs[.attachment] is MathAtomAttachment) {
                        if attrs[.purloryCode] as? Bool == true { prefixLength -= 1 }
                        else {
                            prefixLength -= (attrs[.purloryBold] as? Bool == true ? 2 : 0)
                                + (attrs[.purloryItalic] as? Bool == true ? 1 : 0)
                                + (attrs[.purloryStrikethrough] as? Bool == true ? 2 : 0)
                                + (attrs[.purloryHighlight] as? Bool == true ? 2 : 0)
                        }
                        if attrs[.purloryColor] != nil || attrs[.purloryFontSize] != nil { prefixLength -= 7 }
                    }
                }
                return sourceOffset + blockPrefix + max(0, prefixLength)
            }
            sourceOffset += line.text.utf16.count + 1
            nativeOffset = NSMaxRange(para)
        } while nativeOffset < ns.length
        return sourceOffset
    }

    /// Read-only original coverage for complete native paragraphs. Unlike a caret,
    /// a block owns its opening/closing fences and consumed Markdown prefixes.
    /// This also works before an inactive tile has attached a diagnostics runtime.
    func originalParagraphRange(forNative range: NSRange) -> NSRange? {
        let ns = string as NSString
        guard range.location >= 0, range.length > 0, range.location <= ns.length,
              range.length <= ns.length - range.location else { return nil }
        var native = 0, source = 0, inCode = false, start: Int?
        while native < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: native, length: 0))
            let line = serializedLine(of: paragraph), wasCode = inCode, beforeFence = source
            if line.isCode != inCode {
                source += line.isCode ? 4 + (line.codeLang?.utf16.count ?? 0) : 4
                inCode = line.isCode
            }
            if paragraph.location == range.location { start = line.isCode && !wasCode ? beforeFence : source }
            source += line.text.utf16.count + (ns.character(at: paragraph.upperBound - 1) == 10 ? 1 : 0)
            if paragraph.upperBound == range.upperBound, let start {
                if line.isCode {
                    let nextCode: Bool
                    if paragraph.upperBound < ns.length {
                        let next = ns.paragraphRange(for: NSRange(location: paragraph.upperBound, length: 0))
                        nextCode = serializedLine(of: next).isCode
                    } else { nextCode = false }
                    if !nextCode { source += 4 }
                }
                return NSRange(location: start, length: source - start)
            }
            native = paragraph.upperBound
        }
        return nil
    }

    /// 문단 하나가 직렬화에 기여하는 줄과 코드 여부. 전체 재구축·증분 갱신이
    /// **같은 코드**를 쓰므로 두 경로의 출력이 구조적으로 일치한다.
    private func serializedLine(of para: NSRange) -> (text: String, isCode: Bool, codeLang: String?) {
        // Trust stored block attributes, never typing attributes from an empty caret paragraph.
        let info = storageBlockInfo(in: para)
        let native = string as NSString
        let hasFeed = para.length > 0 && para.upperBound <= native.length && native.character(at: para.upperBound - 1) == 0x0A
        writingProjectionCapture.beginLine(para, hasLineFeed: hasFeed)
        let content = serializedContent(of: para, block: info.block)
        func result(prefix: String = "", suffix: String = "", code: Bool = false,
                    codeLang: String? = nil, literal: Bool = false) -> (text: String, isCode: Bool, codeLang: String?) {
            let text = prefix + (literal ? "" : content) + suffix
            writingProjectionCapture.finishLine(text: text, prefix: prefix, suffix: suffix, isCode: code,
                eligible: ![PurloryBlock.code, .math, .divider, .image].contains(info.block), literal: literal)
            return (text, code, codeLang)
        }
        let indentPrefix = info.indent > 0 ? String(repeating: "  ", count: info.indent) : ""
        switch info.block {
        case .code: return result(code: true, codeLang: info.codeLang)
        case .h1: return result(prefix: "# ")
        case .h2: return result(prefix: "## ")
        case .h3: return result(prefix: "### ")
        case .h4: return result(prefix: "#### ")
        case .h5: return result(prefix: "##### ")
        case .h6: return result(prefix: "###### ")
        case .quote: return result(prefix: String(repeating: "> ", count: info.indent + 1))
        case .bullet: return result(prefix: indentPrefix + "- ")
        case .number: return result(prefix: indentPrefix + (info.marker ?? "1.") + " ")
        case .todo: return result(prefix: indentPrefix + "- [" + (info.checked ? "x" : " ") + "] ")
        case .math:
            if let storage = textStorage, para.location < storage.length {
                let attrs = storage.attributes(at: para.location, effectiveRange: nil)
                switch attrs[.purloryMathDelim] as? String {
                case "open", "mid", "close": return result()
                default: break
                }
            }
            return result(prefix: "$$", suffix: "$$")
        case .divider: return result(prefix: "---", literal: true)
        case .image: return result()
        default:
            if let align = alignValue(at: para) {
                return result(prefix: "<p align=\"\(align)\">", suffix: "</p>")
            }
            return result()
        }
    }

    /// 캐시된 문단 줄들 → 최종 마크다운. 코드 펜스 상태 기계와 문서 끝 개행
    /// 규칙은 **문단 간 조립 로직**이라 캐시에 넣지 않고 여기서 매번 계산한다
    /// (네이티브 문자열 join이라 300k에서도 0.1ms).
    private func assembleSerialized(_ lines: [(text: String, isCode: Bool, codeLang: String?)]) -> String {
        var out: [String] = []
        out.reserveCapacity(lines.count + 2)
        var inCode = false
        for line in lines {
            if line.isCode {
                if !inCode {
                    out.append("```" + (line.codeLang ?? ""))
                    inCode = true
                }
                out.append(line.text)
            } else {
                if inCode { out.append("```"); inCode = false }
                out.append(line.text)
            }
        }
        let ns = string as NSString
        // 문서가 개행으로 끝나면 마지막 빈 문단도 한 줄이다.
        if ns.length > 0, ns.character(at: ns.length - 1) == 0x0A {
            if inCode { out.append("```"); inCode = false }
            out.append("")
        }
        if inCode { out.append("```") }
        return out.joined(separator: "\n")
    }

    /// 전체 재구축 — 예전 serialize의 전체 순회. `serialLinesValid`가 false일 때만
    /// 돈다(첫 호출·구조 변화·불확실). 이후 증분 갱신의 기준선이 된다.
    private func rebuildSerialCache() {
        let ns = string as NSString
        var lines: [(text: String, isCode: Bool, codeLang: String?)] = []
        let selLoc = min(selectedRange().location, ns.length)
        var fastIdx: Int?
        var fastStart = 0
        var location = 0
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var line = serializedLine(of: para)
            // 네이티브 UTF-8로 강제 — join에서 문자 단위 재변환을 없앤다(핵심).
            line.text.makeContiguousUTF8()
            lines.append(line)
            // 커서가 든 문단을 빠른 경로의 시작점으로 삼는다(타이핑은 여기서 이어진다).
            if fastIdx == nil, para.lowerBound <= selLoc, selLoc <= para.upperBound {
                fastIdx = lines.count - 1
                fastStart = para.location
            }
            location = para.upperBound
        } while location < ns.length
        serialLines = lines
        serialLinesValid = true
        serialFastDirty = false
        serialFastIndex = fastIdx
        serialFastStart = fastStart
    }

    /// 빠른 경로: 추적 중인 문단 하나만 다시 브리지해 캐시에 splice.
    private func applyFastSerialUpdate() {
        serialFastDirty = false
        guard let idx = serialFastIndex, idx < serialLines.count else {
            rebuildSerialCache()
            return
        }
        let ns = string as NSString
        guard serialFastStart <= ns.length else {
            rebuildSerialCache()
            return
        }
        let anchor = min(serialFastStart, max(0, ns.length - 1))
        let para = ns.paragraphRange(for: NSRange(location: anchor, length: 0))
        // 추적하던 문단의 시작이 어긋났으면(예상 못 한 구조 변화) 전체로 후퇴.
        guard para.location == serialFastStart else {
            rebuildSerialCache()
            return
        }
        var line = serializedLine(of: para)
        line.text.makeContiguousUTF8()
        serialLines[idx] = line
    }

    // MARK: 긴 문단 나누기 (docs/editor-paragraph-split.md)

    /// `trigger`를 넘는 산문(`.p`) 문단의 개수·최대 크기. UI 설명문의 실제 수치.
    /// O(문서)지만 키 입력 경로가 아니다 — 사용자가 표시를 누를 때만 계산한다.
    /// 산문만 대상 — 헤딩·코드·수식·목록·인용은 이 크기가 되지 않고, 나누면
    /// 의미가 깨진다(코드 펜스 등).
    func oversizedProseParagraphs() -> (count: Int, maxLength: Int) {
        let ns = string as NSString
        var count = 0
        var maxLength = 0
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if para.length > ParagraphSplitter.trigger,
                storageBlockInfo(in: para).block == .p
            {
                count += 1
                maxLength = max(maxLength, para.length)
            }
            location = para.upperBound
        }
        return (count, maxLength)
    }

    /// 산문 문단 중 가장 흔한 크기(중앙값 근사) — "보통 문단의 N배" 설명용.
    /// 대략치면 충분하므로 앞쪽 산문 문단들만 표본한다.
    func typicalProseParagraphLength() -> Int {
        let ns = string as NSString
        var lengths: [Int] = []
        var location = 0
        while location < ns.length, lengths.count < 200 {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let len = para.length
            if len > 20, len <= ParagraphSplitter.trigger,
                storageBlockInfo(in: para).block == .p
            {
                lengths.append(len)
            }
            location = para.upperBound
        }
        guard !lengths.isEmpty else { return 0 }
        lengths.sort()
        return lengths[lengths.count / 2]
    }

    /// 긴 산문 문단을 문장 경계에서 `\n\n`으로 나눈다 — **단일 undo 그룹**.
    ///
    /// 글자는 하나도 바꾸지 않고 문단 구분 개행만 삽입한다(ParagraphSplitter가
    /// 오프셋을 계산, 검증은 텍스트 보존 테스트). 뒤 문단부터 처리해 앞 오프셋이
    /// 밀리지 않게 한다. `\n\n` 삽입은 `insertText`로 — 네이티브 undo에 잡히고
    /// typingAttributes(주변 산문 속성)를 물려받아 새 문단도 `.p`가 된다.
    /// 나눈 문단 수를 돌려준다(0이면 대상 없음).
    @discardableResult
    func splitOversizedProseParagraphs() -> Int {
        let ns = string as NSString
        // 대상 문단을 먼저 모은다(문서 순서) — 편집 중 순회하면 오프셋이 흔들린다.
        var targets: [NSRange] = []
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if para.length > ParagraphSplitter.trigger,
                storageBlockInfo(in: para).block == .p
            {
                targets.append(para)
            }
            location = para.upperBound
        }
        guard !targets.isEmpty else { return 0 }

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("긴 문단 나누기")
        var splitCount = 0
        // 뒤 문단부터 → 앞 문단의 절대 오프셋이 보존된다.
        for para in targets.reversed() {
            // 문단 평문(끝 개행 제외)에서 나눌 위치를 구한다.
            let content = paragraphContent(para)
            let offsets = ParagraphSplitter.breakOffsetsUTF16(in: content)
            guard !offsets.isEmpty else { continue }
            splitCount += 1
            // 한 문단 안에서도 뒤 오프셋부터 삽입해 앞 오프셋을 지킨다.
            for offset in offsets.reversed() {
                let at = para.location + offset
                if shouldChangeText(
                    in: NSRange(location: at, length: 0), replacementString: "\n\n")
                {
                    textStorage?.replaceCharacters(
                        in: NSRange(location: at, length: 0), with: "\n\n")
                    didChangeText()
                }
            }
        }
        undoManager?.endUndoGrouping()
        // 구조가 크게 바뀌었으니 직렬화 캐시·렌더를 새로 잡는다.
        invalidateSerialCache()
        refreshRenderedBlocks()
        return splitCount
    }

    /// 편집이 캐시를 어떻게 바꾸는지 판정한다 (델리게이트에서 호출).
    ///
    /// **안전한 빠른 경로**: 문단 경계를 바꾸지 않는 단일 문단 내 편집.
    /// - 개행이 삭제되지 않았다(문단 병합 없음) — `shouldChangeText`가 편집 전에
    ///   삭제될 텍스트의 개행을 세어 알려준다(`serialPendingRemovedNewlines`).
    /// - 개행이 삽입되지 않았다(문단 분할 없음) — 편집된 새 범위를 직접 스캔.
    /// - 편집이 추적 중인 문단 안이다 — 아니면 인덱스가 어긋나므로 전체로 후퇴.
    ///
    /// 위 조건이 하나라도 불확실하면 `serialLinesValid = false`로 전체 재구축을
    /// 예약한다. `shouldChangeText`를 거치지 않는 프로그래matic 편집(마커 변환 등)은
    /// `serialPendingTracked == false`라 자동으로 전체 재구축된다.
    fileprivate func updateSerialCacheState(
        editedMask: NSTextStorageEditActions, editedRange: NSRange, delta: Int
    ) {
        let tracked = serialPendingTracked
        let removedNewlines = serialPendingRemovedNewlines
        serialPendingTracked = false
        serialPendingRemovedNewlines = 0

        guard serialLinesValid else { return }  // 이미 재구축 예약됨

        let ns = string as NSString
        // 안전 조건 ①: 이 편집이 shouldChangeText를 거쳤고, 개행을 지우지 않았다.
        guard editedMask.contains(.editedCharacters), tracked, removedNewlines == 0 else {
            serialLinesValid = false
            return
        }
        // 안전 조건 ②: 삽입된 새 텍스트에 개행이 없다(문단 분할 없음).
        let clamped = NSRange(
            location: min(editedRange.location, ns.length),
            length: min(editedRange.length, max(0, ns.length - editedRange.location)))
        if clamped.length > 0,
            ns.rangeOfCharacter(from: .newlines, options: [], range: clamped).location != NSNotFound
        {
            serialLinesValid = false
            return
        }
        // 안전 조건 ③: 편집이 추적 중인 문단 안이다.
        let para = ns.paragraphRange(
            for: NSRange(location: min(editedRange.location, max(0, ns.length)), length: 0))
        if para.location == serialFastStart {
            serialFastDirty = true
        } else {
            serialLinesValid = false  // 다른 문단 — 재구축이 새 커서 문단으로 재조준
        }
    }

    /// storage 속성만으로 읽는 블록 정보 — 직렬화 전용 (문자 없는 문단은 항상 p).
    private func storageBlockInfo(in paragraph: NSRange)
        -> (block: PurloryBlock, checked: Bool, marker: String?, indent: Int, codeLang: String?)
    {
        guard let storage = textStorage, paragraph.location < storage.length else {
            return (.p, false, nil, 0, nil)
        }
        let attrs = storage.attributes(at: paragraph.location, effectiveRange: nil)
        let block = (attrs[.purloryBlock] as? String).flatMap(PurloryBlock.init(rawValue:)) ?? .p
        return (
            block,
            attrs[.purloryChecked] as? Bool ?? false,
            attrs[.purloryMarker] as? String,
            attrs[.purloryIndent] as? Int ?? 0,
            attrs[.purloryCodeLang] as? String
        )
    }

    /// 문단의 블록 정보. 빈 마지막 문단은 typingAttributes에서 읽는다 (편집 규칙용).
    func blockInfo(in paragraph: NSRange)
        -> (block: PurloryBlock, checked: Bool, marker: String?, indent: Int, codeLang: String?)
    {
        let attrs: [NSAttributedString.Key: Any]
        if let storage = textStorage, paragraph.location < storage.length {
            attrs = storage.attributes(at: paragraph.location, effectiveRange: nil)
        } else {
            attrs = typingAttributes
        }
        let block = (attrs[.purloryBlock] as? String).flatMap(PurloryBlock.init(rawValue:)) ?? .p
        return (
            block,
            attrs[.purloryChecked] as? Bool ?? false,
            attrs[.purloryMarker] as? String,
            attrs[.purloryIndent] as? Int ?? 0,
            attrs[.purloryCodeLang] as? String
        )
    }

    private func paragraphContent(_ paragraph: NSRange) -> String {
        let ns = string as NSString
        var text = ns.substring(with: paragraph)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// 문단 내용 직렬화 — 코드·수식·구분선은 원문 그대로, 나머지는 인라인
    /// 서식을 마크다운 마커로 복원한다.
    private func serializedContent(of paragraph: NSRange, block: PurloryBlock) -> String {
        let plain = paragraphContent(paragraph)
        guard let storage = textStorage,
            ![PurloryBlock.code, .math, .divider, .image].contains(block)
        else {
            writingProjectionCapture.recordRawBody()
            return plain
        }
        let contentRange = NSRange(
            location: paragraph.location, length: (plain as NSString).length)
        return InlineMarkdown.serialize(storage, in: contentRange,
            capture: writingProjectionCapture.capturesCurrentLine ? { [writingProjectionCapture] span in
                writingProjectionCapture.recordSpan(span)
            } : nil)
    }

    /// 문단의 저장된 정렬 값 ("center"/"right") — 직렬화용.
    private func alignValue(at paragraph: NSRange) -> String? {
        guard let storage = textStorage, paragraph.location < storage.length else { return nil }
        return storage.attribute(.purloryAlign, at: paragraph.location, effectiveRange: nil)
            as? String
    }

    /// 커서 문단에 블록을 부여하고 스타일을 다시 입힌다 (undo 등록 포함).
    func applyBlock(
        _ block: PurloryBlock, checked: Bool = false, marker: String? = nil,
        indent: Int = 0, codeLang: String? = nil,
        to paragraph: NSRange, registerUndo: Bool = true
    ) {
        guard let storage = textStorage else { return }
        let wasTransforming = isTransforming
        isTransforming = true
        let clampedIndent = [.bullet, .number, .todo, .quote].contains(block)
            ? min(6, max(0, indent)) : 0
        var attrs = styleAttributes(for: block, checked: checked, indent: clampedIndent)
        attrs[.purloryBlock] = block.rawValue
        if checked { attrs[.purloryChecked] = true }
        if let marker { attrs[.purloryMarker] = marker }
        if clampedIndent > 0 { attrs[.purloryIndent] = clampedIndent }
        if block == .code, let codeLang, !codeLang.isEmpty {
            attrs[.purloryCodeLang] = codeLang
        }
        if paragraph.length > 0 {
            if registerUndo {
                _ = shouldChangeText(in: paragraph, replacementString: nil)
            }
            // setAttributes는 인라인 서식 키까지 지운다 — 코드·수식·구분선·이미지가
            // 아니면 보존했다가 되살린 뒤 폰트·색을 다시 조립한다.
            let keepInline = ![PurloryBlock.code, .math, .divider, .image].contains(block)
            let preserved = keepInline ? inlineSnapshot(in: paragraph) : []
            storage.setAttributes(attrs, range: paragraph)
            for (range, inline) in preserved {
                storage.addAttributes(inline, range: range)
            }
            decorateInline(in: paragraph)
            applyStoredAlignment(base: attrs, in: paragraph)
            applyStoredLineSpacing(in: paragraph)
            if registerUndo { didChangeText() }
        }
        // 커서가 이 문단 안에 있을 때만 typingAttributes를 덮는다.
        let caret = selectedRange().location
        if caret >= paragraph.location, caret <= paragraph.upperBound {
            typingAttributes = attrs
            updateTailSnapshot()
        }
        isTransforming = wasTransforming
        needsDisplay = true
        scheduleEditingOverlayRefresh()
    }

    /// 팔레트/테마 변경 시 문서 전체를 다시 입힌다.
    func restyleAll() {
        let ns = string as NSString
        let caret = min(max(0, selectedRange().location), ns.length)
        let caretParagraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let emptyTail = caretParagraph.length == 0 ? blockInfo(in: caretParagraph) : nil
        let emptyTailInline = typingAttributes.filter { InlineMarkdown.inlineKeys.contains($0.key) }
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let info = blockInfo(in: para)
            applyBlock(
                info.block, checked: info.checked, marker: info.marker,
                indent: info.indent, codeLang: info.codeLang,
                to: para, registerUndo: false)
            location = para.upperBound
        }
        // The final empty paragraph has no storage attributes. Do not inherit the preceding
        // heading/list when a theme or font change restyles the document.
        if let emptyTail {
            applyBlock(
                emptyTail.block, checked: emptyTail.checked, marker: emptyTail.marker,
                indent: emptyTail.indent, codeLang: emptyTail.codeLang,
                to: caretParagraph, registerUndo: false)
            typingAttributes.merge(emptyTailInline) { _, inherited in inherited }
            typingAttributes.merge(inlineDecoration(for: typingAttributes)) { _, decorated in decorated }
            if let ps = typingAttributes[.paragraphStyle] as? NSMutableParagraphStyle {
                if let align = emptyTailInline[.purloryAlign] as? String {
                    ps.alignment = align == "right" ? .right : .center
                }
                if let spacing = emptyTailInline[.purloryLineSpacing] as? Double {
                    ps.minimumLineHeight = 0; ps.maximumLineHeight = 0
                    ps.lineSpacing = CGFloat(spacing)
                }
            }
        }
        syncTypingAttributes()
        // 테마가 바뀌면 잉크 색으로 수식을 다시 렌더한다.
        rerenderInlineAtoms()
        // Rebuild every paragraph without forcing focused math out of source mode.
        invalidateMediaIndex()
        refreshRenderedBlocks()
        needsDisplay = true
        scheduleEditingOverlayRefresh()
    }

    /// 커서 문단의 속성을 typingAttributes로 동기화 — 빈 문단에서도 블록 유지.
    func syncTypingAttributes() {
        // The input method owns attributes while composing the first character.
        guard !hasMarkedText(), let storage = textStorage else { return }
        let caret = selectedRange().location
        guard caret != NSNotFound else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(caret, ns.length), length: 0))
        if para.location < storage.length {
            // 굵게 같은 인라인 서식이 커서 앞 글자에서 이어지도록 caret-1 기준 —
            // 블록 속성은 문단 안에서 균일해 어디를 읽어도 같다.
            let anchor = min(
                max(para.location, min(caret, ns.length) - 1), storage.length - 1)
            typingAttributes = storage.attributes(at: anchor, effectiveRange: nil)
        }
        updateTailSnapshot()
    }

    // MARK: 인라인 서식 (굵게·기울임·취소선·하이라이트·코드·링크·색·정렬)

    /// purlory 인라인 키 런 스냅샷 — setAttributes로 지워지기 전에 보관한다.
    private func inlineSnapshot(
        in range: NSRange
    ) -> [(NSRange, [NSAttributedString.Key: Any])] {
        guard let storage = textStorage, range.length > 0 else { return [] }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range, options: []) { attrs, run, _ in
            let kept = attrs.filter { InlineMarkdown.inlineKeys.contains($0.key) }
            if !kept.isEmpty { runs.append((run, kept)) }
        }
        return runs
    }

    /// purlory 인라인 키를 읽어 폰트·색을 조립한다 — 항상 블록 기본 폰트 위에서
    /// 호출돼야 한다 (setAttributes 직후 / 로드 직후).
    func decorateInline(in range: NSRange) {
        guard let storage = textStorage, range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, run, _ in
            let addition = inlineDecoration(for: attrs)
            if !addition.isEmpty { storage.addAttributes(addition, range: run) }
        }
        decorateInlineLinks(in: range)
    }

    /// 산문 문단 내 `[보이는 말](URL)` 인라인 링크에 시각적 강조(액센트 색·밑줄·툴팁)를 입힌다.
    /// 원문 텍스트는 보존하고 표시 속성만 사용해 `WritingNativeProjectionIndex`와 충돌하지 않는다.
    private func decorateInlineLinks(in range: NSRange) {
        guard !isSourceMode, let storage = textStorage, range.length > 0 else { return }
        let ns = storage.string as NSString
        var loc = range.location
        while loc < min(range.upperBound, ns.length) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = max(para.upperBound, loc + 1) }
            let info = storageBlockInfo(in: para)
            guard ![PurloryBlock.code, .math, .divider, .image].contains(info.block) else { continue }
            let text = paragraphContent(para)
            for link in WritingProseProjection.links(in: text) where !link.image {
                let fullRange = NSRange(location: para.location + link.source.location, length: link.source.length)
                let labelRange = NSRange(location: para.location + link.label.location, length: link.label.length)
                let openBracket = NSRange(location: fullRange.location, length: max(0, labelRange.location - fullRange.location))
                let tailSyntax = NSRange(location: labelRange.upperBound, length: max(0, fullRange.upperBound - labelRange.upperBound))
                if openBracket.length > 0 {
                    storage.addAttribute(.foregroundColor, value: palette.ink3, range: openBracket)
                }
                if tailSyntax.length > 0 {
                    storage.addAttribute(.foregroundColor, value: palette.ink3, range: tailSyntax)
                }
                if labelRange.length > 0 {
                    storage.addAttributes([
                        .foregroundColor: palette.blue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: palette.blue.withAlphaComponent(0.55),
                    ], range: labelRange)
                }
            }
        }
    }

    private func inlineDecoration(for attrs: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any] {
        var addition: [NSAttributedString.Key: Any] = [:]
        var base = attrs[.font] as? NSFont ?? bodyFont
        // 크기 조절은 블록 기본 폰트를 리사이즈한 것 위에 굵게·기울임을 쌓는다.
        if let size = attrs[.purloryFontSize] as? Double,
            abs(base.pointSize - CGFloat(size)) > 0.1 {
            base = NSFontManager.shared.convert(base, toSize: CGFloat(size))
            addition[.font] = base
        }
        if attrs[.purloryCode] as? Bool == true {
            addition[.font] = NSFont.monospacedSystemFont(
                ofSize: base.pointSize * 0.78, weight: .regular)
            addition[.backgroundColor] = palette.codeBg
        } else {
            if attrs[.purloryBold] as? Bool == true {
                // NSFontManager does not select the bundled variable font's weight axis.
                let converted = base.familyName == bodyFont.familyName
                    ? PurloryFonts.serif(base.pointSize, weight: .bold)
                    : NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
                if converted != base { addition[.font] = converted }
                // 시스템 serif(New York) 폴백은 볼드가 한글 글리프에
                // 적용되지 않는다 — 커버하지 못하면 스트로크로 가짜 볼드.
                if !converted.coveredCharacterSet.contains(
                    UnicodeScalar(0xAC00)!) {
                    addition[.strokeWidth] = -2.5
                }
            }
            // 기울임은 항상 obliqueness — 한글엔 이탤릭 페이스가 없어
            // 폰트 변환으론 라틴만 기울어진다.
            if attrs[.purloryItalic] as? Bool == true {
                addition[.obliqueness] = 0.18
            }
            if attrs[.purloryStrikethrough] as? Bool == true {
                addition[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                addition[.strikethroughColor] =
                    (attrs[.purloryColor] as? String).flatMap(NSColor.init(inlineHex:)) ?? palette.ink2
            }
            if attrs[.purloryHighlight] as? Bool == true {
                addition[.backgroundColor] = palette.warning.withAlphaComponent(0.22)
            }
        }
        if let hex = attrs[.purloryColor] as? String, let color = NSColor(inlineHex: hex) {
            addition[.foregroundColor] = color
        }
        return addition
    }

    /// 문단에 저장된 .purloryAlign을 문단 스타일에 반영한다.
    private func applyStoredAlignment(
        base attrs: [NSAttributedString.Key: Any], in paragraph: NSRange
    ) {
        guard let storage = textStorage, paragraph.location < storage.length,
            let align = storage.attribute(
                .purloryAlign, at: paragraph.location, effectiveRange: nil) as? String,
            let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle
        else { return }
        ps.alignment = align == "right" ? .right : .center
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    /// 문단에 저장된 .purloryLineSpacing을 문단 스타일에 반영한다 (선택 줄 줄 간격, 요구 4).
    /// 정렬 반영(applyStoredAlignment) 뒤에 호출해 현재 문단 스타일을 이어받는다.
    private func applyStoredLineSpacing(in paragraph: NSRange) {
        guard let storage = textStorage, paragraph.location < storage.length,
            let spacing = storage.attribute(
                .purloryLineSpacing, at: paragraph.location, effectiveRange: nil) as? Double
        else { return }
        let current =
            storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle ?? .default
        guard let ps = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        // Explicit author formatting keeps its native line-spacing semantics.
        ps.minimumLineHeight = 0; ps.maximumLineHeight = 0
        ps.lineSpacing = CGFloat(spacing)
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    // MARK: 스타일 (디자인 CSS와 1:1)

    func styleAttributes(
        for block: PurloryBlock, checked: Bool, indent: Int = 0
    ) -> [NSAttributedString.Key: Any] {
        let t = palette
        var font = bodyFont
        var color = t.ink
        let ps = NSMutableParagraphStyle()
        // 자연 줄 높이 + 사용자 줄 간격 — 글자가 커서 높이의 중앙에 오도록
        // 라인 박스를 부풀리지 않는다 (요구 1·4, lineHeightMultiple 대체).
        ps.lineSpacing = lineSpacing
        let indentOffset = CGFloat(min(6, max(0, indent))) * 24

        switch block {
        case .p:
            if proseLayout == .continuous {
                ps.firstLineHeadIndent = baseFontSize
                ps.paragraphSpacing = round(baseFontSize * 0.22)
                ps.alignment = .left
                ps.lineBreakMode = .byWordWrapping
                ps.lineBreakStrategy = .hangulWordPriority
            } else {
                ps.paragraphSpacing = round(baseFontSize * 0.65)
            }
        case .h1:
            font = PurloryFonts.serif(editorialWorkspaceStyle ? baseFontSize * 1.52 : 31 * fontScale, weight: .bold)
            ps.paragraphSpacingBefore = editorialWorkspaceStyle ? baseFontSize * 1.52 * 0.2 : 16
            ps.paragraphSpacing = editorialWorkspaceStyle ? baseFontSize * 1.52 * 0.25 : 4
        case .h2:
            font = PurloryFonts.serif(editorialWorkspaceStyle ? baseFontSize * 1.12 : 25 * fontScale, weight: editorialWorkspaceStyle ? .medium : .semibold)
            if editorialWorkspaceStyle { color = t.workspaceMuted }
            ps.paragraphSpacingBefore = editorialWorkspaceStyle ? baseFontSize * 1.12 * 0.1 : 12
            ps.paragraphSpacing = editorialWorkspaceStyle ? baseFontSize * 1.12 : 2
        case .h3:
            font = PurloryFonts.serif(21 * fontScale, weight: .semibold)
            ps.paragraphSpacingBefore = 8
        case .h4:
            font = PurloryFonts.serif(19 * fontScale, weight: .semibold)
            ps.paragraphSpacingBefore = 6
        case .h5:
            font = PurloryFonts.serif(17.5 * fontScale, weight: .semibold)
            ps.paragraphSpacingBefore = 4
        case .h6:
            font = PurloryFonts.serif(16 * fontScale, weight: .medium)
            color = t.ink2
            ps.paragraphSpacingBefore = 4
        case .quote:
            color = t.ink2
            if editorialWorkspaceStyle { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let qIndent = 19 + CGFloat(min(6, max(0, indent))) * 14
            ps.firstLineHeadIndent = qIndent
            ps.headIndent = qIndent
            ps.paragraphSpacingBefore = 6
            ps.paragraphSpacing = 6
        case .bullet:
            ps.firstLineHeadIndent = 26 + indentOffset
            ps.headIndent = 26 + indentOffset
        case .number:
            ps.firstLineHeadIndent = 34 + indentOffset
            ps.headIndent = 34 + indentOffset
        case .todo:
            ps.firstLineHeadIndent = 32 + indentOffset
            ps.headIndent = 32 + indentOffset
            if checked { color = t.ink3 }
        case .code:
            font = NSFont.monospacedSystemFont(ofSize: 14.5 * fontScale, weight: .regular)
            ps.firstLineHeadIndent = 18
            ps.headIndent = 18
            ps.tailIndent = -18
        case .math:
            font = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            ps.alignment = .center
            ps.paragraphSpacingBefore = 10
            ps.paragraphSpacing = 10
            ps.firstLineHeadIndent = 20
            ps.headIndent = 20
            ps.tailIndent = -48
        case .divider:
            ps.minimumLineHeight = 28
            ps.maximumLineHeight = 28
        case .image:
            // 소스(![](…)) 편집 모드에서 가운데 정렬 — 렌더 이미지도 중앙에 온다.
            color = t.ink3
            font = PurloryFonts.ui(13 * fontScale)
            ps.alignment = .center
            ps.paragraphSpacingBefore = 8
            ps.paragraphSpacing = 8
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: ps,
        ]
        if block == .p || block == .quote { attrs[.kern] = CGFloat.zero }
        if editorialWorkspaceStyle, [.h1, .h2].contains(block) {
            attrs[.kern] = -font.pointSize * (block == .h1 ? 0.025 : 0.012)
        }
        if editorialWorkspaceStyle, block == .quote { attrs[.obliqueness] = 0.18 }
        if block == .todo, checked {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = t.ink3
        }
        return attrs
    }

    // MARK: 마커 소비 (transformMarkdown)

    /// 문서에 아직 소비되지 않은 수식·이미지 마커(`$$`·`![`)가 있을 수 있는가.
    ///
    /// `refreshRenderedBlocks`의 빠른 경로가 원래 매 키 입력마다 문서 전체를
    /// `range(of:)`로 두 번 훑었다 — 30만 자에서 **16.9ms**로 프레임 예산을
    /// 혼자 먹었다 (docs/editor-perf.md). 이제 편집 범위만 보고 증분으로 판정한다.
    ///
    /// **보수적으로 틀린다**: 확실하지 않으면 true로 두어 전체 경로를 타게 한다.
    /// 마커를 놓쳐 수식이 영영 렌더되지 않는 쪽이, 가끔 헛도는 쪽보다 나쁘다.
    /// 전체 경로가 한 번 돌면 스스로 정확한 값으로 되돌린다(`syncMarkerFlag`).
    var mayHaveMarkers = true

    /// 전체 경로에서 마커 유무를 실측해 캐시를 되돌린다. 이 경로는 이미 O(문서)라
    /// 스캔 한 번이 복잡도를 바꾸지 않는다 — 마커를 지운 뒤 빠른 경로로 복귀하는 길.
    private func syncMarkerFlag() {
        let ns = string as NSString
        mayHaveMarkers =
            ns.range(of: "$$").location != NSNotFound
            || ns.range(of: "![").location != NSNotFound
    }

    // MARK: 직렬화 증분 캐시 (docs/editor-perf.md)

    /// 문단별 직렬화 줄 캐시 — 네이티브 문자열. `assembleSerialized`가 join한다.
    /// 메모리는 대략 문서 크기의 사본 하나(600k자 ≈ 1.2MB) — 지연을 위한 거래.
    fileprivate var serialLines: [(text: String, isCode: Bool, codeLang: String?)] = []
    /// false면 다음 `serialize()`가 전체 재구축한다 — 정답이 보장되는 폴백.
    fileprivate var serialLinesValid = false
    /// 추적 중인 문단만 다시 브리지하면 되는 상태.
    fileprivate var serialFastDirty = false
    /// 빠른 경로가 갱신할 `serialLines`의 인덱스 (커서 문단).
    fileprivate var serialFastIndex: Int?
    /// 그 문단의 시작 오프셋 — 편집이 같은 문단인지 확인하는 키.
    fileprivate var serialFastStart = 0
    /// `shouldChangeText`가 이 편집을 가로챘는가 — 못 가로챈 편집(프로그래matic)은
    /// 삭제 개행 수를 알 수 없어 안전하게 전체 재구축한다.
    fileprivate var serialPendingTracked = false
    /// `shouldChangeText`가 편집 전에 센 "삭제될 텍스트의 개행 수". 0이 아니면
    /// 문단이 병합되므로 빠른 경로를 쓰지 않는다.
    fileprivate var serialPendingRemovedNewlines = 0

    /// 직렬화 캐시를 강제로 무효화한다 — 문서 로드 등 대량 교체 후.
    func invalidateSerialCache() {
        serialLinesValid = false
        serialFastDirty = false
    }

    /// 편집 **직전**에 삭제될 텍스트의 개행을 센다 — 직렬화 증분 캐시의 안전
    /// 판정에 필요하다(`updateSerialCacheState`). `didProcessEditing`은 이미 바뀐
    /// storage만 보므로 "무엇이 지워졌는지"를 알 수 없다. 이 훅은 타이핑·IME·
    /// 붙여넣기·삭제·undo 등 NSText 경로 전부에서 편집 전에 불린다.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?)
        -> Bool
    {
        let ns = string as NSString
        if affectedCharRange.length > 0, affectedCharRange.upperBound <= ns.length {
            let old = ns.substring(with: affectedCharRange)
            serialPendingRemovedNewlines = old.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        } else {
            serialPendingRemovedNewlines = 0
        }
        serialPendingTracked = true
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        guard !isTransforming else { return }
        if !isSourceMode, !hasMarkedText() {
            transformMarkerIfNeeded()
            transformInlineMarkerIfNeeded()
        }
        // IME 조합 중에도 갱신 — 문단 위치가 밀리면 렌더 range를 다시 잡아야 한다.
        if !isSourceMode {
            refreshRenderedBlocks()
        }
        scheduleEditingOverlayRefresh(restartBlink: true)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        writingProjectionCapture.beginComposition()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        writingProjectionCapture.endComposition(hasMarkedText() ? markedRange() : nil)
    }

    override func unmarkText() {
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        writingProjectionCapture.beginComposition()
        super.unmarkText()
        writingProjectionCapture.endComposition(nil)
    }

    /// 커서 바로 앞에서 완성된 인라인 마커(`***…***` `**…**` `*…*` `~~…~~` `==…==` `` `…` ``)를
    /// 소비해 서식 속성으로 바꾼다 — transformMarkdown의 인라인 판.
    private func transformInlineMarkerIfNeeded() {
        guard !isSourceMode, let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: sel)
        let info = blockInfo(in: para)
        guard ![PurloryBlock.code, .math, .divider, .image].contains(info.block) else { return }
        let text = paragraphContent(para)
        let nsText = text as NSString
        let caretInPara = sel.location - para.location

        // "$…$" 닫기 타이핑 — 인라인 수식 원자로 즉시 전환 (이슈 #20).
        // 코드 스팬에 걸친 쌍은 변환하지 않는다 — 코드는 문자 그대로다.
        if let region = MathScanner.closingInline(in: text, atCaret: caretInPara) {
            let skips = inlineCodeSkips(in: para)
            if !skips.contains(where: { NSIntersectionRange($0, region.range).length > 0 }) {
                convertInlineMath(in: para)
                return
            }
        }

        for rule in InlineMarkdown.typingRules {
            let matches = rule.pattern.matches(
                in: text, range: NSRange(location: 0, length: nsText.length))
            // 방금 타이핑으로 닫힌 마커만 — 커서 위치에서 끝나는 매치.
            guard let match = matches.first(where: { $0.range.upperBound == caretInPara })
            else { continue }
            let inner = nsText.substring(with: match.range(at: 1))
            let markerRange = NSRange(
                location: para.location + match.range.location, length: match.range.length)
            isTransforming = true
            if shouldChangeText(in: markerRange, replacementString: inner) {
                storage.replaceCharacters(in: markerRange, with: inner)
                storage.addAttributes(
                    rule.attrs,
                    range: NSRange(
                        location: markerRange.location, length: (inner as NSString).length))
                didChangeText()
            }
            isTransforming = false
            let newPara = (string as NSString).paragraphRange(
                for: NSRange(location: para.location, length: 0))
            applyBlock(
                info.block, checked: info.checked, marker: info.marker,
                indent: info.indent, codeLang: info.codeLang,
                to: newPara, registerUndo: false)
            // 변환 직후 이어지는 타이핑은 일반 글씨 — 서식이 계속 번지지 않게.
            var typing = styleAttributes(for: info.block, checked: info.checked, indent: info.indent)
            typing[.purloryBlock] = info.block.rawValue
            if info.checked { typing[.purloryChecked] = true }
            if let marker = info.marker { typing[.purloryMarker] = marker }
            if info.indent > 0 { typing[.purloryIndent] = info.indent }
            if let codeLang = info.codeLang { typing[.purloryCodeLang] = codeLang }
            typingAttributes = typing
            updateTailSnapshot()
            return
        }

        // `[텍스트](주소)` 닫는 `)` 타이핑 시 즉시 인라인 링크 장식 갱신.
        if caretInPara > 0, nsText.character(at: caretInPara - 1) == 41 {
            decorateInlineLinks(in: para)
        }
    }

    private func transformMarkerIfNeeded() {
        guard !isSourceMode else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: sel)
        let info = blockInfo(in: para)
        let text = paragraphContent(para)

        if info.block == .bullet {
            // "- [ ] "를 두 단계로 쓰는 경우: bullet 상태에서 "[ ] " → todo.
            if let match = text.range(of: #"^\[\s?\]\s"#, options: .regularExpression) {
                consumeMarker(
                    length: text[text.startIndex..<match.upperBound].utf16.count,
                    in: para, block: .todo, indent: info.indent)
            }
            return
        }
        if info.block == .quote, text.hasPrefix("> "), info.indent < 6 {
            consumeMarker(length: 2, in: para, block: .quote, indent: info.indent + 1)
            return
        }
        guard info.block == .p else { return }

        if text == "```" {
            consumeMarker(length: 3, in: para, block: .code)
        } else if let match = text.range(of: #"^```([A-Za-z0-9_+#.-]+)\s$"#, options: .regularExpression) {
            let lang = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            consumeMarker(
                length: text[text.startIndex..<match.upperBound].utf16.count,
                in: para, block: .code, codeLang: lang.isEmpty ? nil : lang)
        } else if text == "$$ " {
            consumeMarker(length: 3, in: para, block: .math)
        } else if text.hasPrefix("$$"), text.hasSuffix("$$"), text.count >= 5 {
            // "$$H_2$$"처럼 여닫는 마커까지 통째로 타이핑한 경우 — 마커를 벗겨
            // 수식 블록으로 바꾼다 ("$$ " 두 글자+공백 방식과 동일한 결과).
            consumeMathWrapper(in: para)
        } else if text == "---" {
            consumeDivider(in: para)
        } else if text.hasPrefix("###### ") {
            consumeMarker(length: 7, in: para, block: .h6)
        } else if text.hasPrefix("##### ") {
            consumeMarker(length: 6, in: para, block: .h5)
        } else if text.hasPrefix("#### ") {
            consumeMarker(length: 5, in: para, block: .h4)
        } else if text.hasPrefix("### ") {
            consumeMarker(length: 4, in: para, block: .h3)
        } else if text.hasPrefix("## ") {
            consumeMarker(length: 3, in: para, block: .h2)
        } else if text.hasPrefix("# ") {
            consumeMarker(length: 2, in: para, block: .h1)
        } else if let match = text.range(of: #"^\[\s?\]\s"#, options: .regularExpression) {
            consumeMarker(
                length: text[text.startIndex..<match.upperBound].utf16.count,
                in: para, block: .todo)
        } else if text.hasPrefix("> ") {
            consumeMarker(length: 2, in: para, block: .quote)
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
            consumeMarker(length: 2, in: para, block: .bullet)
        } else if let match = text.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let marker = String(text[text.startIndex..<match.upperBound])
                .trimmingCharacters(in: .whitespaces)
            consumeMarker(
                length: text[text.startIndex..<match.upperBound].utf16.count,
                in: para, block: .number, marker: marker)
        }
    }

    private func consumeMarker(
        length: Int, in paragraph: NSRange, block: PurloryBlock,
        marker: String? = nil, indent: Int = 0, codeLang: String? = nil
    ) {
        guard let storage = textStorage else { return }
        isTransforming = true
        let markerRange = NSRange(location: paragraph.location, length: length)
        if shouldChangeText(in: markerRange, replacementString: "") {
            storage.replaceCharacters(in: markerRange, with: "")
            didChangeText()
        }
        isTransforming = false
        let ns = string as NSString
        let newPara = ns.paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        applyBlock(block, marker: marker, indent: indent, codeLang: codeLang, to: newPara)
    }

    /// "$$…$$" 한 줄을 마커 없이 수식 블록으로 — 내용만 남기고 블록을 부여한다.
    private func consumeMathWrapper(in paragraph: NSRange) {
        guard let storage = textStorage else { return }
        let text = paragraphContent(paragraph)
        guard text.count >= 5 else { return }
        let inner = String(text.dropFirst(2).dropLast(2))
        isTransforming = true
        let contentRange = NSRange(
            location: paragraph.location, length: (text as NSString).length)
        if shouldChangeText(in: contentRange, replacementString: inner) {
            storage.replaceCharacters(in: contentRange, with: inner)
            didChangeText()
        }
        isTransforming = false
        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: paragraph.location, length: 0))
        applyBlock(.math, to: newPara)
        refreshRenderedBlocks()
    }

    private func consumeDivider(in paragraph: NSRange) {
        guard let storage = textStorage else { return }
        isTransforming = true
        let markerRange = NSRange(location: paragraph.location, length: 3)
        if shouldChangeText(in: markerRange, replacementString: "") {
            storage.replaceCharacters(in: markerRange, with: "")
            didChangeText()
        }
        isTransforming = false
        let ns = string as NSString
        let dividerPara = ns.paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        applyBlock(.divider, to: dividerPara)
        // 디자인처럼 아래에 새 문단을 만들고 커서를 옮긴다.
        setSelectedRange(NSRange(location: dividerPara.upperBound > dividerPara.location
            ? dividerPara.upperBound - 1 : dividerPara.location, length: 0))
        insertText("\n", replacementRange: selectedRange())
        let caretPara = (string as NSString).paragraphRange(
            for: NSRange(location: selectedRange().location, length: 0))
        applyBlock(.p, to: caretPara)
    }

    // MARK: 키 동작 (Enter/Backspace/Tab 블록 규칙)

    override func insertTab(_ sender: Any?) {
        if !isSourceMode, !hasMarkedText(), indentListOrQuote(delta: 1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if !isSourceMode, !hasMarkedText(), indentListOrQuote(delta: -1) { return }
        super.insertBacktab(sender)
    }

    /// 목록(`.bullet`, `.number`, `.todo`) 및 인용(`.quote`) 문단의 들여쓰기를 증감한다.
    @discardableResult
    func indentListOrQuote(delta: Int) -> Bool {
        let sel = selectedRange()
        let ns = string as NSString
        let firstPara = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let firstInfo = blockInfo(in: firstPara)
        guard [.bullet, .number, .todo, .quote].contains(firstInfo.block) else { return false }
        var changed = false
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
            let info = blockInfo(in: para)
            if [.bullet, .number, .todo, .quote].contains(info.block) {
                let nextIndent = min(6, max(0, info.indent + delta))
                if nextIndent != info.indent {
                    let nextMarker = info.block == .number && delta > 0 ? "1." : info.marker
                    applyBlock(
                        info.block, checked: info.checked, marker: nextMarker,
                        indent: nextIndent, to: para)
                    changed = true
                }
            }
            location = para.upperBound
        } while location < sel.upperBound
        return changed || [.bullet, .number, .todo, .quote].contains(firstInfo.block)
    }

    override func insertLineBreak(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertLineBreak(sender) }
        guard selectedImageLocation == nil else { return insertNewline(sender) }
        // U+2028 is a line separator, not a paragraph separator. Use the normal
        // input path for undo, autosave and inline attributes without resetting
        // the block or advancing a list number as Enter does.
        insertText("\u{2028}", replacementRange: selectedRange())
        refreshActiveLineHighlight()
    }

    override func insertNewline(_ sender: Any?) {
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        if isSourceMode {
            super.insertNewline(sender)
            return
        }
        // 이미지 객체 선택 중 Enter — 이미지 아래에 새 문단을 만들고 커서를 옮긴다
        // (그림 블럭 완성도). insertText가 막혀 있어 기본 경로로는 아무 일도 없다.
        if let loc = selectedImageLocation {
            let para = (string as NSString).paragraphRange(
                for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            imageLineBreak(after: para)
            return
        }
        guard !hasMarkedText() else { return super.insertNewline(sender) }
        defer { breakUndoCoalescing() }
        let sel = selectedRange()
        let ns = string as NSString
        let para = ns.paragraphRange(for: sel)
        let info = blockInfo(in: para)

        // 빈 목록/코드 블록에서 Enter → 들여쓰기가 있으면 한 단계 내리고, 0이면 본문으로 해제.
        if sel.length == 0, paragraphContent(para).isEmpty,
            [.bullet, .number, .todo, .code].contains(info.block) {
            if info.indent > 0 {
                applyBlock(
                    info.block, checked: false, marker: info.marker,
                    indent: info.indent - 1, to: para)
            } else {
                applyBlock(.p, to: para)
            }
            return
        }

        super.insertNewline(sender)

        // 새 문단의 블록 상속 규칙.
        let caretPara = (string as NSString).paragraphRange(
            for: NSRange(location: selectedRange().location, length: 0))
        switch info.block {
        case .h1, .h2, .h3, .h4, .h5, .h6, .quote, .math, .divider, .image:
            applyBlock(.p, to: caretPara)
        case .todo:
            applyBlock(.todo, checked: false, indent: info.indent, to: caretPara)
        case .number:
            let next = (Int((info.marker ?? "1.").dropLast()) ?? 1) + 1
            applyBlock(.number, marker: "\(next).", indent: info.indent, to: caretPara)
        case .bullet:
            applyBlock(.bullet, indent: info.indent, to: caretPara)
        case .code:
            applyBlock(.code, codeLang: info.codeLang, to: caretPara)
        case .p:
            applyBlock(.p, to: caretPara)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if isSourceMode {
            super.deleteBackward(sender)
            return
        }
        // 이미지가 객체 선택된 상태면 백스페이스로 문단째 지운다 (요구 3).
        if let loc = selectedImageLocation {
            let para = (string as NSString).paragraphRange(
                for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            deleteImageParagraph(para)
            return
        }
        let sel = selectedRange()
        if sel.length == 0, !hasMarkedText() {
            let ns = string as NSString
            let para = ns.paragraphRange(for: sel)
            let info = blockInfo(in: para)
            // 블록 문단 맨 앞에서 Backspace → 들여쓰기가 있으면 먼저 내리고, 0이면 블록 해제.
            if sel.location == para.location, info.block != .p {
                if info.indent > 0 {
                    applyBlock(
                        info.block, checked: info.checked, marker: info.marker,
                        indent: info.indent - 1, to: para)
                } else {
                    applyBlock(.p, to: para)
                }
                return
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: 이미지 원자 모델 (이슈 #16)

    /// 캐럿 제안이 이미지 문단 **내부**로 들어오면 문단 앞·뒤 경계로 튕겨 낸다 —
    /// 렌더된 이미지는 원자 객체라 숨은 소스를 문자 단위로 돌아다닐 수 없다.
    /// 화살표 한 번이면 이미지 앞/뒤로 건너뛴다. 범위 선택(Shift 확장)은 그대로 둔다.
    static func atomicCaretRange(
        _ proposedLocation: Int, result: NSRange, in ns: NSString,
        isImage: (NSRange) -> Bool
    ) -> NSRange {
        guard result.length == 0 else { return result }
        let loc = min(max(result.location, 0), ns.length)
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        // 문단 시작·끝 경계는 "이미지 앞/뒤" 자리라 유효하다.
        guard isImage(para), para.location < loc, loc < para.upperBound else { return result }
        return proposedLocation <= para.location
            ? NSRange(location: para.location, length: 0)
            : NSRange(location: para.upperBound, length: 0)
    }

    override func selectionRange(
        forProposedRange proposedRange: NSRange, granularity: NSSelectionGranularity
    ) -> NSRange {
        let base = super.selectionRange(
            forProposedRange: proposedRange, granularity: granularity)
        let ns = string as NSString
        return Self.atomicCaretRange(proposedRange.location, result: base, in: ns) { para in
            self.blockInfo(in: para).block == .image
        }
    }

    /// VoiceOver가 이미지 문단 대신 읽을 문장 — alt 기반 label에 너비·정렬
    /// value를 덧붙인다. alt가 비었으면 파일명으로 대체한다.
    static func spokenDescription(
        attrs: ImageAttrs, failure: ImageLoadFailure?
    ) -> String {
        var parts: [String] = ["이미지"]
        if failure != nil { parts.append("표시 불가") }
        parts.append(attrs.alt.isEmpty ? (attrs.src as NSString).lastPathComponent : attrs.alt)
        parts.append("너비 \(attrs.width)%")
        let alignName =
            ["left": "왼쪽", "center": "가운데", "right": "오른쪽"][attrs.align]
            ?? attrs.align
        parts.append("\(alignName) 정렬")
        return parts.joined(separator: ", ")
    }

    /// 접근성 읽기에서 이미지 소스(`![…](…){…}`)를 말 문장으로 바꾼다 — VO 사용자는
    /// 마크다운 구문 대신 이미지의 의미를 듣는다.
    override func accessibilityString(for range: NSRange) -> String {
        let ns = string as NSString
        guard ns.length > 0 else {
            return super.accessibilityString(for: range) ?? ""
        }
        let upper = min(range.location + range.length, ns.length)
        guard range.location < upper else { return "" }

        var out = ""
        var cursor = range.location
        while cursor < upper {
            let para = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            if blockInfo(in: para).block == .image,
                let attrs = Self.imageAttrs(
                    from: paragraphContent(para).trimmingCharacters(in: .whitespaces)),
                !isTransforming
            {
                out += Self.spokenDescription(
                    attrs: attrs, failure: imageFailure(for: attrs.src))
            } else {
                // 산문 — 인라인 수식 원자(U+FFFC+attachment)를 "수식: …"로 치환해
                // 읽고, 나머지 글자는 그대로 흘려보낸다 (이슈 #22).
                let end = min(para.upperBound, upper)
                var runCursor = cursor
                while runCursor < end {
                    if let atom = textStorage?.attribute(
                            .attachment, at: runCursor, effectiveRange: nil)
                        as? MathAtomAttachment
                    {
                        out += "수식: \(atom.latex)"
                        runCursor += 1
                    } else {
                        out += ns.substring(with: NSRange(location: runCursor, length: 1))
                        runCursor += 1
                    }
                }
            }
            cursor = para.upperBound
        }
        return out
    }

    /// 객체 모드에서 소비할 수 있는 키 동작 (이슈 #16).
    enum ImageObjectKeyAction: Equatable {
        case exitBefore  // 이미지 앞 경계로 나온다
        case exitAfter  // 이미지 뒤 경계로 나온다
        case align(String)
        case adjustWidth(Int)
        case move(Int)
        case revealToolbar
    }

    /// 객체 선택 중 키 → 동작 해석. 순수 함수 — 키보드 이벤트 합성 없이
    /// 회귀 테스트가 가능하다.
    static func objectKeyAction(
        _ raw: String, command: Bool, option: Bool
    ) -> ImageObjectKeyAction? {
        // 특수키는 charactersIgnoringModifiers의 사유 코드로 온다 (F700~F703).
        switch (raw, command, option) {
        case ("\u{F702}", false, false), ("\u{F700}", false, false):
            return .exitBefore
        case ("\u{F703}", false, false), ("\u{F704}", false, false):
            return .exitAfter
        case ("\u{F702}", true, _):
            return .align("left")
        case ("\u{F700}", true, _):
            return .align("center")
        case ("\u{F703}", true, _):
            return .align("right")
        case ("+", false, _), ("=", false, _):
            return .adjustWidth(10)
        case ("-", false, _), ("_", false, _):
            return .adjustWidth(-10)
        case ("\u{F700}", false, true):
            return .move(-1)
        case ("\u{F704}", false, true):
            return .move(1)
        case ("\r", false, false), (" ", false, false):
            return .revealToolbar
        default:
            return nil
        }
    }

    /// 객체 선택 중 키 조작 — Full Keyboard Access로 정렬·크기·이동·삭제·툴바를
    /// 다루는 경로 (이슈 #16). 이 모드에선 텍스트 입력이 차단돼 있으므로
    /// 화살표·부호키를 객체 조작에 쓸 수 있다. 소비한 키만 true.
    @discardableResult
    private func handleObjectKey(_ event: NSEvent) -> Bool {
        guard let loc = selectedImageLocation else { return false }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        guard let action = Self.objectKeyAction(
            event.charactersIgnoringModifiers ?? "",
            command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option))
        else { return false }

        switch action {
        case .exitBefore:
            clearImageSelection()
            setSelectedRange(NSRange(location: para.location, length: 0))
        case .exitAfter:
            clearImageSelection()
            setSelectedRange(NSRange(location: para.upperBound, length: 0))
        case .align(let a):
            rewriteImage(para, setAlign: a)
        case .adjustWidth(let delta):
            rewriteImage(para, setWidth: min(100, max(10, widthOfSelectedImage() + delta)))
        case .move(let offset):
            moveImageParagraph(para, offset: offset)
            // 새 자리에서 선택 UI를 다시 얹는다 — ⌥↑↓ 연속 입력이 이어지도록.
            if let newLoc = selectedImageLocation {
                showImageBox(for: newLoc)
                presentImageToolbar(for: NSRange(location: newLoc, length: 0))
            }
        case .revealToolbar:
            showImageBox(for: para.location)
            presentImageToolbar(for: para)
        }
        return true
    }

    private var lastTypingKeyTimestamp: TimeInterval?
    private var isHandlingSoftReturn = false

    override func keyDown(with event: NSEvent) {
        workspaceInteraction?.keyDown(event)
        if selectedImageLocation != nil, handleObjectKey(event) { return }
        if handleMathEditingKey(event) { return }
        // AppKit coalesces adjacent typing even across idle time and event groups.
        // A new burst must not undo earlier writing; never split a live IME session.
        if !hasMarkedText(), let previous = lastTypingKeyTimestamp,
           event.timestamp - previous >= 2 {
            breakUndoCoalescing()
        }
        lastTypingKeyTimestamp = event.timestamp
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let previousSoftReturn = isHandlingSoftReturn
        isHandlingSoftReturn = modifiers == .shift && (event.keyCode == 36 || event.keyCode == 76)
        defer { isHandlingSoftReturn = previousSoftReturn }
        // Let the input method handle/commit marked text before remapping the
        // resulting newline command. A raw key interception skips Hangul IME.
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if isHandlingSoftReturn, !hasMarkedText(),
           selector == #selector(NSStandardKeyBindingResponding.insertNewline(_:))
            || selector == #selector(NSStandardKeyBindingResponding.insertNewlineIgnoringFieldEditor(_:)) {
            super.doCommand(by: #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)))
        } else {
            super.doCommand(by: selector)
        }
    }

    /// 수식 소스 모드에서의 객체 조작 키 — 이동(⌥↑↓)과 문단 삭제(⌘⌦)만 가로채고
    /// 나머지 입력은 LaTeX 편집으로 그대로 흘려보낸다 (이슈 #22).
    private func handleMathEditingKey(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !isTransforming else { return false }
        let ns = string as NSString
        let sel = selectedRange()
        let para = ns.paragraphRange(
            for: NSRange(location: min(sel.location, ns.length), length: 0))
        guard blockInfo(in: para).block == .math,
              NSIntersectionRange(sel, para).length > 0 || NSLocationInRange(sel.location, para)
        else { return false }
        let raw = event.charactersIgnoringModifiers ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (raw, flags.contains(.option), flags.contains(.command)) {
        case ("\u{F700}", true, false):
            moveMathParagraph(para, offset: -1)
        case ("\u{F704}", true, false):
            moveMathParagraph(para, offset: 1)
        case ("\u{F728}", _, true):
            deleteMathParagraph(para)
        default:
            return false
        }
        return true
    }

    private func widthOfSelectedImage() -> Int {
        guard let loc = selectedImageLocation else { return 100 }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        return Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces))?.width ?? 100
    }

    /// 이미지 문단을 이웃 문단과 맞바꿔 위(offset -1)·아래(+1)로 옮긴다 —
    /// undo 가능 (shouldChangeText). 성공해도 실패해도 원문 손상은 없다.
    /// internal — 키보드 이동 경로의 회귀 테스트용 (이슈 #16). 선택 UI 갱신은
    /// 호출부(키 핸들러)가 이어서 한다.
    func moveImageParagraph(_ para: NSRange, offset: Int) {
        moveBlockParagraph(para, offset: offset, undoName: "이미지 이동")
    }

    /// 수식(단일·그룹) 문단의 키보드 이동 — undo 이름만 다르다 (이슈 #22).
    func moveMathParagraph(_ para: NSRange, offset: Int) {
        moveBlockParagraph(para, offset: offset, undoName: "수식 이동")
    }

    private func moveBlockParagraph(_ para: NSRange, offset: Int, undoName: String) {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let neighbor: NSRange
        if offset < 0 {
            guard para.location > 0 else { return }
            neighbor = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
        } else {
            guard para.upperBound < ns.length else { return }
            neighbor = ns.paragraphRange(for: NSRange(location: para.upperBound, length: 0))
        }
        let lower = min(para.location, neighbor.location)
        let upper = max(para.upperBound, neighbor.upperBound)
        let span = NSRange(location: lower, length: upper - lower)
        let imageText = ns.substring(with: para)
        let otherText = ns.substring(with: neighbor)
        // 문단은 자기 개행을 데리고 다닌다. 위 이동은 그대로 붙여도 줄 구조가
        // 유지되지만, 아래 이동에서 이웃이 **마지막 문단**(개행 없음)이면
        // 개행을 재배치해야 두 줄이 한 줄로 붙지 않는다.
        let newText: String
        if offset < 0 {
            newText = imageText + otherText
        } else if !otherText.hasSuffix("\n"), imageText.hasSuffix("\n") {
            newText = otherText + "\n" + String(imageText.dropLast())
        } else {
            newText = otherText + imageText
        }
        guard shouldChangeText(in: span, replacementString: newText) else { return }
        nameCurrentUndo(undoName)
        isTransforming = true
        storage.replaceCharacters(in: span, with: newText)
        isTransforming = false

        // 새 자리의 이미지를 다시 객체 선택 — 키보드 이동이 연속되도록.
        selectedImageLocation = offset < 0 ? lower : lower + otherText.count
        refreshRenderedBlocks()
    }


    // MARK: 체크박스 클릭

    override func mouseDown(with event: NSEvent) {
        if workspaceInteraction?.mouseDown(event) == true { return }
        let point = convert(event.locationInWindow, from: nil)
        // 인라인 수식 원자 더블클릭 — 소스(`$latex$`)로 펼쳐 편집한다 (이슈 #20).
        if event.clickCount == 2, revealInlineMathSource(at: point) { return }
        if let layoutManager, let textContainer {
            let containerPoint = NSPoint(
                x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let index = layoutManager.characterIndex(
                for: containerPoint, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)
            let ns = string as NSString
            if ns.length > 0, index <= ns.length {
                let para = ns.paragraphRange(
                    for: NSRange(location: min(index, ns.length), length: 0))
                let info = blockInfo(in: para)
                // ⌘+클릭: 인라인 마크다운 링크(`[텍스트](URL)`) 열기.
                if event.modifierFlags.contains(.command),
                   ![PurloryBlock.code, .math, .divider, .image].contains(info.block),
                   openInlineMarkdownLink(at: index, inParagraph: para) {
                    return
                }
                // 체크박스 히트 존: 문단 들여쓰기(32px + indentOffset) 안쪽.
                let checkboxZone = 28 + CGFloat(info.indent) * 24
                if info.block == .todo, containerPoint.x < checkboxZone {
                    applyBlock(.todo, checked: !info.checked, indent: info.indent, to: para)
                    return
                }
                // 렌더된 이미지 클릭 — 항상 객체 선택(소스는 절대 노출하지 않는다).
                let isRendered = imageRenders.contains { $0.range.location == para.location }
                if info.block == .image, isRendered {
                    selectImageObject(at: para)
                    return
                }
                // 렌더된 수식 박스 클릭 — 끌면 블록 이동, 그 자리에서 떼면
                // 기존처럼 소스 편집 모드 (요구 6).
                if info.block == .math,
                    let mathBox = mathDrawnRect(forParagraphAt: para.location)?
                        .insetBy(dx: -Self.mathBoxMargin, dy: -Self.mathBoxMargin),
                    mathBox.contains(point) {
                    clearImageSelection()
                    trackMathDrag(from: event, paragraph: para)
                    return
                }
            }
        }
        // 이미지가 아닌 곳을 누르면 객체 선택을 해제한다.
        clearImageSelection()
        super.mouseDown(with: event)
    }

    /// 문단 내 `characterIndex`가 `[텍스트](URL)` 링크 안에 있으면 URL을 브라우저로 연다.
    private func openInlineMarkdownLink(at characterIndex: Int, inParagraph para: NSRange) -> Bool {
        let text = paragraphContent(para)
        let localOffset = characterIndex - para.location
        guard localOffset >= 0, localOffset <= (text as NSString).length else { return false }
        for link in WritingProseProjection.links(in: text) where !link.image {
            guard NSLocationInRange(localOffset, link.source) else { continue }
            let rawSpan = (text as NSString).substring(with: link.source)
            guard let openParen = rawSpan.range(of: "](") else { continue }
            var dest = String(rawSpan[openParen.upperBound...].dropLast())
                .trimmingCharacters(in: .whitespaces)
            if let spaceIdx = dest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                dest = String(dest[..<spaceIdx])
            }
            if dest.hasPrefix("<"), dest.hasSuffix(">"), dest.count >= 2 {
                dest = String(dest.dropFirst().dropLast())
            }
            if let url = URL(string: dest), url.scheme != nil {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    // MARK: 이미지 삽입 (붙여넣기 · 드롭 · 파일 선택)

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Plain-text NSTextView otherwise disables Paste for bitmap-only clipboards
        // before our managed-image paste handler can run.
        [.purloryImageObject, .png, .tiff, .init(UTType.jpeg.identifier)] + super.readablePasteboardTypes
    }

    /// Native Paste and pasteboard reads share the managed image path. Plain text
    /// still uses NSTextView's normal insertion and undo behavior.
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        if insertImages(from: pasteboard) { return true }
        // 텍스트가 선택된 상태에서 URL을 붙여넣으면 `[선택 텍스트](URL)` 링크로 자동 감싼다.
        if !isSourceMode, selectedRange().length > 0,
           let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           (raw.hasPrefix("https://") || raw.hasPrefix("http://") || raw.hasPrefix("mailto:")),
           !raw.contains(where: \.isWhitespace) {
            let sel = selectedRange()
            let ns = string as NSString
            let para = ns.paragraphRange(for: sel)
            if ![PurloryBlock.code, .math, .divider, .image].contains(blockInfo(in: para).block),
               sel.upperBound <= para.upperBound - (ns.substring(with: para).hasSuffix("\n") ? 1 : 0) {
                let selectedText = ns.substring(with: sel)
                let replacement = "[\(selectedText)](\(raw))"
                insertText(replacement, replacementRange: sel)
                decorateInlineLinks(in: (string as NSString).paragraphRange(for: NSRange(location: sel.location, length: 0)))
                return true
            }
        }
        return super.readSelection(from: pasteboard)
    }

    /// 툴바 버튼용 — 리스폰더 체인(NSApp.sendAction)으로 도달한다.
    @objc func insertImageFromMenu(_ sender: Any?) {
        presentImagePicker()
    }

    /// ⇧⌘I — 파일 선택 패널로 이미지를 고른다.
    func presentImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PurloryImageStore.imageExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return }
        insertImageFiles(panel.urls)
    }

    /// 파일 URL 하나를 읽어 images 폴더에 복사한 뒤 이미지 블록으로 삽입한다.
    /// 저장 실패는 조용히 무시하지 않는다 (이슈 #15).
    private func insertImageFiles(_ urls: [URL]) {
        var images: [(data: Data, reference: String)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                alertAssetWriteFailure("파일을 읽지 못했어요: \(url.lastPathComponent)")
                return
            }
            if usesProjectAssets {
                images.append((data, "images/\(UUID().uuidString).\(url.pathExtension.lowercased())"))
            } else {
                saveAndInsertImage(data, ext: url.pathExtension)
            }
        }
        guard !images.isEmpty else { return }
        guard let context = try? captureProjectImageOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await insertProjectImages(images, context: context) }
            catch ProjectSessionError.staleRuntime {} catch is CancellationError {}
            catch { alertAssetWriteFailure(error.localizedDescription) }
        }
    }

    /// 페이스트보드에서 이미지(파일 URL 또는 비트맵)를 찾아 삽입한다. 하나라도 넣었으면 true.
    @discardableResult
    /// 페이스트보드에서 이미지를 찾아 삽입한다. 하나라도 넣었으면 true.
    /// internal — 객체 붙여넣기 우선순위의 회귀 테스트용 (이슈 #17).
    func insertImages(from pasteboard: NSPasteboard) -> Bool {
        // 0) Purlory 이미지 객체 — 메타데이터 전체를 보존하는 내부 붙여넣기 (#17).
        // 파일 URL 분기보다 먼저 본다: 자체 복사물엔 항상 객체가 함께 담겨 있고,
        // 같은 asset을 새 UUID로 복사하지 않는 것이 수명 정책상 정답이다.
        if pasteImageObject(from: pasteboard) { return true }
        // 1) 이미지 파일 URL — 원본 확장자를 유지해 복사한다.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter {
                PurloryImageStore.imageExtensions.contains($0.pathExtension.lowercased())
            }
            if !images.isEmpty {
                insertImageFiles(images)
                return true
            }
        }
        // 2) 비트맵 데이터(스크린샷·복사한 이미지) — PNG로 정규화해 저장한다.
        // 저장 실패도 조용히 넘기지 않는다 (이슈 #15).
        if let data = pasteboard.data(forType: .png) {
            saveAndInsertImage(data, ext: "png")
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff),
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) {
            saveAndInsertImage(png, ext: "png")
            return true
        }
        return false
    }

    /// 페이스트보드에 삽입 가능한 이미지가 있는지 (드래그 수락 판정용).
    private func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: .purloryImageObject) != nil { return true }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            urls.contains(where: {
                PurloryImageStore.imageExtensions.contains($0.pathExtension.lowercased())
            }) {
            return true
        }
        return pasteboard.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
        ])
    }

    /// `![](상대경로)` 이미지 블록을 커서 위치에 새 문단으로 삽입한다 —
    /// 앞이 비어 있지 않으면 줄을 나누고, 뒤에는 일반 문단을 만들어 커서를 옮긴다
    /// (`consumeDivider`와 같은 흐름).
    func insertImageBlock(relativePath: String) {
        insertImageParagraph(markdown: "![](\(relativePath))")
    }

    /// 완성된 마크다운 한 줄을 이미지 문단으로 삽입하는 공용 코어 — 상대경로
    /// 삽입과 객체 붙여넣기(#17)가 공유한다. undo 이름을 "이미지 삽입"으로 남긴다.
    private func insertImageParagraph(markdown: String) {
        // 스마트 따옴표·대시 치환은 마크다운 구문("title", --)을 망가뜨린다 —
        // 프로그램 삽입은 원문 그대로 들어가야 한다.
        let previousQuotes = isAutomaticQuoteSubstitutionEnabled
        let previousDashes = isAutomaticDashSubstitutionEnabled
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        defer {
            isAutomaticQuoteSubstitutionEnabled = previousQuotes
            isAutomaticDashSubstitutionEnabled = previousDashes
        }
        let ns = string as NSString
        let sel = selectedRange()
        let para = ns.paragraphRange(for: sel)
        let onEmptyLine = paragraphContent(para).isEmpty
        let prefix = onEmptyLine && sel.location == para.location ? "" : "\n"
        insertText(prefix + markdown + "\n", replacementRange: sel)
        nameCurrentUndo("이미지 삽입")

        // 방금 삽입한 이미지 문단(커서 바로 앞 줄)을 찾아 블록을 지정한다.
        let caret = selectedRange().location
        let imagePara = (string as NSString).paragraphRange(
            for: NSRange(location: max(0, caret - 1), length: 0))
        applyBlock(.image, to: imagePara)
        // 커서가 놓인 새 문단은 일반 문단으로.
        let caretPara = (string as NSString).paragraphRange(
            for: NSRange(location: selectedRange().location, length: 0))
        applyBlock(.p, to: caretPara)
        // 커서는 이미지 다음 문단에 있으므로 이미지가 곧바로 렌더된다.
        refreshRenderedBlocks()
    }

    /// 열려 있는 undo 그룹의 이름을 붙인다 — 편집 이력이 "무엇"이었는지 읽게
    /// 한다 (이슈 #17, 이름 있는 원자적 undo).
    fileprivate func nameCurrentUndo(_ name: String) {
        undoManager?.setActionName(name)
    }

    // MARK: 이미지 객체 선택 (정렬·크기·줄바꿈)

    /// 렌더된 이미지를 객체로 선택한다 — 소스를 감춘 채 박스 오버레이와 툴바를 띄운다.
    private func selectImageObject(at para: NSRange) {
        selectedImageLocation = para.location
        // 커서를 문단 시작에 두되(길이 0) 렌더는 유지된다(refresh의 objectSelected 예외).
        setSelectedRange(NSRange(location: para.location, length: 0))
        window?.makeFirstResponder(self)
        refreshRenderedBlocks()
        showImageBox(for: para.location)  // 박스를 먼저 얹고
        presentImageToolbar(for: para)  // 툴바를 그 위에 올린다
    }

    /// 이미지 박스 오버레이를 만들고(또는 갱신) 이미지 위에 얹는다.
    private func showImageBox(for loc: Int) {
        let box: ImageBoxOverlay
        if let existing = imageBox {
            box = existing
            box.theme = palette  // 재사용 시에도 최신 팔레트 — stale 색 방지 (#34)
        } else {
            box = ImageBoxOverlay(textView: self, theme: palette)
            imageBox = box
        }
        box.paraLocation = loc
        if box.superview !== self { addSubview(box) }
        repositionImageBox()
    }

    /// 객체 선택 해제 — 툴바·박스·편집 카드를 감추고 다시 그린다.
    func clearImageSelection() {
        guard selectedImageLocation != nil else { return }
        selectedImageLocation = nil
        hideImageToolbar()
        hideImageAltEditor()
        imageBox?.removeFromSuperview()
        imageBox = nil
        imageDropIndicatorY = nil
        needsDisplay = true
    }

    /// 선택 변화에 맞춰 이미지 상태를 정리한다 (요구 1):
    /// - 객체 선택 이미지를 벗어나면 선택 해제
    /// - 커서가 이미지 안으로 들어오면 자동으로 객체 선택해, 내부를 커서로
    ///   편집하지 못하게 만든다 (이미지는 항상 렌더 — 소스는 절대 노출 안 됨).
    func syncImageSelection() {
        let ns = string as NSString
        let sel = selectedRange()
        let caretPara = ns.paragraphRange(
            for: NSRange(location: min(sel.location, ns.length), length: 0))

        if let loc = selectedImageLocation, sel.length != 0 || caretPara.location != loc {
            clearImageSelection()
        }
        // 이미지 문단에 커서가 놓였는데 객체 선택이 아니면 자동 선택.
        // (로드·프로그램적 변경 중인 isTransforming 때는 건너뛴다.)
        // 로드 실패 플레이스홀더도 선택 대상이다 — 찾기·Finder·제거 액션을
        // 제공하려면 (이슈 #15).
        guard sel.length == 0, !isTransforming, window?.firstResponder === self,
            caretPara.location < ns.length,
            selectedImageLocation != caretPara.location,
            blockInfo(in: caretPara).block == .image,
            let caretAttrs = Self.imageAttrs(
                from: paragraphContent(caretPara).trimmingCharacters(in: .whitespaces)),
            resolvedImage(for: caretAttrs.src) != nil
                || imageFailure(for: caretAttrs.src) != nil
        else { return }
        // 커서는 그대로 두고(어차피 숨김) 객체 선택만 채택 — setSelectedRange
        // 재귀를 피한다. refresh가 뒤이어 렌더를 유지한다.
        // 화살표로 스쳐 지날 때 툴바/박스를 띄우지 않는다 — 편집 조작은 클릭했을 때만
        // 시작하게 해, 이동 중 UI가 불쑥 튀어나오지 않게 한다 (M10). 클릭 경로
        // (selectImageObject)는 그대로 박스·툴바를 보여준다.
        selectedImageLocation = caretPara.location
        refreshRenderedBlocks()
        needsDisplay = true
    }

    /// 이미지가 객체로 선택된 동안엔 텍스트 입력을 막는다 — 내부는 편집 불가 (요구 1).
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard selectedImageLocation == nil else { return }
        // 텍스트가 드래그 선택된 상태에서 괄호·따옴표·서식 마커를 입력하면 선택 영역을 감싼다.
        let effectiveRange = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        if !isSourceMode, !hasMarkedText(), effectiveRange.length > 0,
           let typed = insertString as? String, typed.count == 1,
           wrapSelectionIfNeeded(with: typed, range: effectiveRange) {
            return
        }
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        super.insertText(insertString, replacementRange: replacementRange)
        let committed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        // Keep each word and its trailing whitespace together. Only committed text
        // ends a typing unit, so Hangul marked-text updates remain AppKit-owned.
        if !hasMarkedText(), committed?.last?.isWhitespace == true {
            breakUndoCoalescing()
        }
    }

    /// 선택 영역이 있을 때 마커(`~`, `=`, `` ` ``) 또는 괄호·따옴표(`(`, `[`, `"`, `“`)로 감싼다.
    private func wrapSelectionIfNeeded(with typed: String, range: NSRange) -> Bool {
        let ns = string as NSString
        guard range.upperBound <= ns.length else { return false }
        let selected = ns.substring(with: range)
        guard !selected.contains("\n") else { return false }
        let para = ns.paragraphRange(for: range)
        guard ![PurloryBlock.code, .math, .divider, .image].contains(blockInfo(in: para).block) else {
            return false
        }
        switch typed {
        case "*", "_":
            setSelectedRange(range)
            toggleInlineStyle(.purloryItalic)
            return true
        case "~":
            setSelectedRange(range)
            toggleInlineStyle(.purloryStrikethrough)
            return true
        case "=":
            setSelectedRange(range)
            toggleInlineStyle(.purloryHighlight)
            return true
        case "`":
            setSelectedRange(range)
            toggleInlineStyle(.purloryCode)
            return true
        default:
            break
        }
        let pairs: [String: (String, String)] = [
            "(": ("(", ")"),
            "[": ("[", "]"),
            "\"": ("\"", "\""),
            "“": ("“", "”"),
        ]
        guard let (open, close) = pairs[typed], let storage = textStorage else { return false }
        let wrapped = open + selected + close
        guard shouldChangeText(in: range, replacementString: wrapped) else { return false }
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        let preserved = inlineSnapshot(in: range)
        let baseAttrs = storage.attributes(at: range.location, effectiveRange: nil)
        isTransforming = true
        storage.replaceCharacters(in: range, with: NSAttributedString(string: wrapped, attributes: baseAttrs))
        for (subRange, inlineAttrs) in preserved {
            let shifted = NSRange(location: subRange.location + open.utf16.count, length: subRange.length)
            storage.addAttributes(inlineAttrs, range: shifted)
        }
        redecorateParagraphs(in: NSRange(location: range.location, length: (wrapped as NSString).length))
        isTransforming = false
        setSelectedRange(NSRange(location: range.location + open.utf16.count, length: range.length))
        didChangeText()
        breakUndoCoalescing()
        return true
    }

    /// 이미지 객체 선택 중 Esc — 선택만 해제한다 (그림 블럭 완성도).
    override func cancelOperation(_ sender: Any?) {
        if selectedImageLocation != nil {
            clearImageSelection()
            return
        }
        super.cancelOperation(sender)
    }

    /// 이미지 객체 선택 중 ⌘C/⌘X — 이미지 비트맵을 클립보드로 (그림 블럭 완성도).
    /// 붙여넣기는 기존 insertImages의 TIFF 경로로 다시 이미지 블록이 된다.
    override func copy(_ sender: Any?) {
        if let loc = selectedImageLocation, copyImageObject(atParagraph: loc) { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let loc = selectedImageLocation {
            guard copyImageObject(atParagraph: loc) else { return }
            let para = (string as NSString).paragraphRange(
                for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            deleteImageParagraph(para)
            return
        }
        super.cut(sender)
    }

    /// 선택된 이미지 문단을 클립보드에 기록한다 — Purlory 객체(JSON)·Markdown
    /// 소스·파일 URL·호환 비트맵을 함께 담아, 내부 붙여넣기는 메타데이터를
    /// 온전히 되살리고 외부 앱도 각자 알아볼 형태를 얻는다 (이슈 #17).
    @discardableResult
    func copyImageObject(atParagraph loc: Int) -> Bool {
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        guard let attrs = Self.imageAttrs(
                from: paragraphContent(para).trimmingCharacters(in: .whitespaces)),
            let image = resolvedImage(for: attrs.src)
        else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // 1) Purlory 전용 객체 — 메타데이터 전체.
        let object = PurloryImageObject(attrs: attrs)
        if let payload = object.encoded() {
            pasteboard.setData(payload, forType: .purloryImageObject)
        }
        if usesProjectAssets, let bytes = projectAssetCatalog?.data(for: attrs.src) {
            pasteboard.setData(bytes, forType: Self.projectImageBytesType)
        }
        // 2) Markdown 소스 — 텍스트 편집기로 붙이면 구문째로.
        pasteboard.setString(attrs.markdown, forType: .string)
        // 3) 원본 파일 URL — 파일을 받아들이는 앱용.
        if !usesProjectAssets, let url = PurloryImageStore.url(for: attrs.src) {
            pasteboard.writeObjects([url as NSURL])
        }
        // 4) 호환 비트맵 — 이미지를 받는 모든 앱용 (기존 동작).
        pasteboard.writeObjects([image])
        return true
    }

    /// 클립보드의 Purlory 이미지 객체를 그대로 삽입한다 — src를 새로 만들지 않고
    /// alt/title/width/align까지 보존 (이슈 #17). 넣었으면 true.
    @discardableResult
    func pasteImageObject(from pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: .purloryImageObject),
            let object = PurloryImageObject(data: data)
        else { return false }
        if usesProjectAssets {
            // Project references cannot be reused across owners; import clipboard bytes instead.
            if let bytes = pasteboard.data(forType: Self.projectImageBytesType) {
                saveAndInsertImage(bytes, ext: (object.src as NSString).pathExtension, object: object)
            } else if let png = pasteboard.data(forType: .png) {
                saveAndInsertImage(png, ext: "png", object: object)
            } else if let tiff = pasteboard.data(forType: .tiff),
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
                saveAndInsertImage(png, ext: "png", object: object)
            } else { return false }
            return true
        }
        insertImageParagraph(markdown: object.markdown)
        return true
    }

    private static let projectImageBytesType = NSPasteboard.PasteboardType("app.purlory.project-image-bytes")

    /// 렌더된 이미지 위에서는 포인터 커서 — 클릭(객체 선택) 대상임을 알린다.
    /// 렌더된 수식 위에서는 열린 손 — 끌어 옮길 수 있음을 알린다 (요구 6).
    override func resetCursorRects() {
        super.resetCursorRects()
        for render in imageRenders {
            if let rect = imageDrawnRect(forParagraphAt: render.range.location) {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
        for render in mathRenders {
            if let rect = mathDrawnRect(forParagraphAt: render.range.location) {
                addCursorRect(
                    rect.insetBy(dx: -Self.mathBoxMargin, dy: -Self.mathBoxMargin),
                    cursor: .openHand)
            }
        }
    }

    /// 이미지 툴바 액션 실행 (요구 3).
    func performImage(_ action: ImageObjectAction) {
        guard let loc = selectedImageLocation else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        switch action {
        case .align(let a): rewriteImage(para, setAlign: a)
        case .width(let w): rewriteImage(para, setWidth: w)
        case .editMetadata: presentImageAltEditor(for: para)
        case .locateFile: locateBrokenImage(para)
        case .revealInFinder: revealBrokenImage(para)
        case .metadata(let alt, let title):
            rewriteImage(para, setAlt: alt, setTitle: .some(title))
            hideImageAltEditor()  // 적용 후 카드를 닫는다 — 툴바 갱신은 rewrite가 한다
        case .lineBreak: imageLineBreak(after: para)
        case .delete: deleteImageParagraph(para)
        }
    }

    /// 깨진 이미지(플레이스홀더) 복구 — 새 파일을 골라 원래 참조가 가리키던
    /// 자리를 채운다 (이슈 #15). 관리 asset은 **상대경로 그대로** 심어 문서를
    /// 건드리지 않고, 외부 절대경로는 임의 경로에 쓰는 대신 새 관리 asset으로
    /// 옮겨 참조를 고친다.
    private func locateBrokenImage(_ para: NSRange) {
        guard let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces))
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes =
            PurloryImageStore.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "'\(attrs.alt.isEmpty ? attrs.src : attrs.alt)' 이미지 파일을 찾아 복구"
        guard panel.runModal() == .OK, let url = panel.urls.first,
            let data = try? Data(contentsOf: url)
        else { return }
        if usesProjectAssets {
            let reference = (try? ProjectPaths.validateRelative(attrs.src)) != nil
                ? attrs.src : "images/\(UUID().uuidString).\(url.pathExtension)"
            guard let context = try? captureProjectImageOperation() else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await importProjectAsset(data: data, reference: reference, context: context) { view in
                        if reference != attrs.src { view.rewriteImage(para, setSrc: reference) }
                        view.refreshRenderedBlocks()
                    }
                } catch ProjectSessionError.staleRuntime {} catch is CancellationError {}
                catch { alertAssetWriteFailure(error.localizedDescription) }
            }
            return
        }
        switch ImageReferenceParser.classify(attrs.src) {
        case .managedRelative:
            guard let destination = PurloryImageStore.url(for: attrs.src) else {
                alertAssetWriteFailure("안전하지 않은 이미지 경로예요.")
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                alertAssetWriteFailure(error.localizedDescription)
                return
            }
            refreshRenderedBlocks()  // 플레이스홀더 → 정상 렌더 즉시 전환
        case .externalFile:
            guard let relative = PurloryImageStore.save(data, ext: url.pathExtension) else {
                alertAssetWriteFailure("images 폴더에 복사하지 못했어요.")
                return
            }
            rewriteImage(para, setSrc: relative)
        case .remote, .blocked:
            break
        }
    }

    /// 깨진 이미지가 참조하던 위치를 Finder에서 연다 — 파일이 없으면 그 부모 폴더.
    private func revealBrokenImage(_ para: NSRange) {
        guard !usesProjectAssets else { return }
        guard let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces))
        else { return }
        guard let url = PurloryImageStore.url(for: attrs.src) else { return }
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// asset 저장 실패를 조용히 넘기지 않는다 (이슈 #15).
    private func alertAssetWriteFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "이미지를 저장하지 못했어요"
        alert.informativeText = "\(detail)\n디스크 여유와 Purlory 폴더 권한을 확인해 주세요."
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// 이미지 소스 줄의 `{width align}`·alt/title 속성을 새 값으로 바꿔 다시 쓴다
    /// (undo 포함). `setTitle`: nil=무변화, .some(nil)=해제, .some(문자열)=지정.
    /// internal — 이름 있는 undo·왕복 보존의 회귀 테스트용 (이슈 #14·#17).
    func rewriteImage(
        _ para: NSRange, setAlign: String? = nil, setWidth: Int? = nil,
        setAlt: String? = nil, setTitle: String?? = nil, setSrc: String? = nil
    ) {
        guard let storage = textStorage else { return }
        let content = paragraphContent(para)
        guard var attrs = Self.imageAttrs(
            from: content.trimmingCharacters(in: .whitespaces))
        else { return }
        if let a = setAlign { attrs.align = a }
        if let w = setWidth { attrs.width = w }
        if let alt = setAlt { attrs.alt = alt }
        if let newSrc = setSrc {
            attrs.src = newSrc
            // destination을 다시 쓰는 것이므로 원문 스플라이스를 내린다 —
            // 합성 경로의 escape 규칙(#14)으로 새 src가 안전하게 직렬화된다.
            attrs.optionsPrefix = nil
        }
        if let newTitle = setTitle {
            attrs.title = newTitle
            // optionsPrefix 스플라이스 경로는 원문을 그대로 쓰므로, title이
            // 바뀌면 prefix를 내려 새로 합성해야 반영된다.
            attrs.optionsPrefix = nil
        }
        let newLine = attrs.markdown
        // 어떤 속성을 바꿨는지로 이력 이름을 정한다 — 이력 줄이 동작을 말하게.
        let actionName: String
        if setAlign != nil { actionName = "이미지 정렬" }
        else if setWidth != nil { actionName = "이미지 크기 조절" }
        else if setAlt != nil || setTitle != nil { actionName = "대체 텍스트 편집" }
        else if setSrc != nil { actionName = "이미지 경로 변경" }
        else { actionName = "이미지 서식" }
        let contentRange = NSRange(
            location: para.location, length: (content as NSString).length)
        guard newLine != content,
            shouldChangeText(in: contentRange, replacementString: newLine)
        else { return }
        nameCurrentUndo(actionName)
        isTransforming = true
        storage.replaceCharacters(in: contentRange, with: newLine)
        isTransforming = false
        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: para.location, length: 0))
        applyBlock(.image, to: newPara, registerUndo: false)
        selectedImageLocation = newPara.location
        setSelectedRange(NSRange(location: newPara.location, length: 0))
        didChangeText()
        refreshRenderedBlocks()
        presentImageToolbar(for: newPara)
    }

    /// 이미지 뒤에 빈 문단을 만들고 커서를 옮긴다 — "줄바꿈"(요구 3).
    private func imageLineBreak(after para: NSRange) {
        clearImageSelection()
        let content = paragraphContent(para)
        let end = para.location + (content as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
        window?.makeFirstResponder(self)
        insertText("\n", replacementRange: selectedRange())
        let caret = selectedRange().location
        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: caret, length: 0))
        applyBlock(.p, to: newPara)
        refreshRenderedBlocks()
    }

    /// 이미지 문단을 개행째 지운다 (요구 3 · 백스페이스 공통).
    /// 이미지 문단을 개행째 지운다 (요구 3 · 백스페이스 공통).
    /// internal — 삭제 undo·asset 장부 등록의 회귀 테스트용 (이슈 #17).
    func deleteImageParagraph(_ para: NSRange) {
        deleteBlockParagraph(para, undoName: "이미지 삭제")
    }

    /// 수식 문단 삭제 — asset 장부 등록이 없을 뿐 구조는 이미지 삭제와 같다 (#22).
    func deleteMathParagraph(_ para: NSRange) {
        deleteBlockParagraph(para, undoName: "수식 삭제")
    }

    private func deleteBlockParagraph(_ para: NSRange, undoName: String) {
        guard let storage = textStorage else { return }
        clearImageSelection()
        // 지워지는 asset을 장부에 적어 둔다 — undo/redo가 끝난 뒤 참조가 없으면
        // Janitor가 정리한다. 즉시 지우지 않는 것이 redo의 전제다 (이슈 #17).
        if let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces)),
            case .managedRelative = ImageReferenceParser.classify(attrs.src)
        {
            AssetJanitor.record(attrs.src)
        }
        guard shouldChangeText(in: para, replacementString: "") else { return }
        nameCurrentUndo(undoName)
        isTransforming = true
        storage.replaceCharacters(in: para, with: "")
        isTransforming = false
        let ns = string as NSString
        setSelectedRange(NSRange(location: min(para.location, ns.length), length: 0))
        didChangeText()
        refreshRenderedBlocks()
    }

    /// 선택된 이미지 위에 정렬·크기·줄바꿈 툴바를 띄운다.
    /// `overrideWidth`는 드래그 리사이즈 중 실시간 % 표시용.
    private func presentImageToolbar(for para: NSRange, overrideWidth: Int? = nil) {
        guard imageRenders.contains(where: { $0.range.location == para.location }),
            let attrs = Self.imageAttrs(
                from: paragraphContent(para).trimmingCharacters(in: .whitespaces)),
            let rect = paragraphRectInView(para)
        else { return }

        let view = ImageObjectToolbarView(
            theme: palette, width: overrideWidth ?? attrs.width, align: attrs.align,
            // 로드 실패 플레이스홀더면 찾기·Finder 복구 액션을 노출한다 (이슈 #15).
            isPlaceholder: imageFailure(for: attrs.src) != nil
        ) { [weak self] action in
            self?.performImage(action)
        }
        let host: NSHostingView<ImageObjectToolbarView>
        if let existing = imageToolbarHost {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            imageToolbarHost = host
        }
        let size = host.fittingSize
        // 이미지 위 중앙 — 위가 좁으면 아래로 내린다 (flipped 좌표).
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = rect.maxY + 8 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        host.frame = NSRect(origin: origin, size: size)
        if host.superview !== self { addSubview(host) }
    }

    func hideImageToolbar() {
        imageToolbarHost?.removeFromSuperview()
    }

    /// alt·title 편집 카드를 툴바 아래에 띄운다 — 현재 alt/title로 미리 채운다 (이슈 #14).
    private func presentImageAltEditor(for para: NSRange) {
        guard let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces)),
            let toolbarFrame = imageToolbarHost?.frame
        else { return }
        let view = ImageAltEditorView(
            theme: palette, initialAlt: attrs.alt, initialTitle: attrs.title,
            onApply: { [weak self] alt, title in
                self?.performImage(.metadata(alt: alt, title: title))
            },
            onCancel: { [weak self] in self?.hideImageAltEditor() })
        let host = NSHostingView(rootView: view)
        // 툴바 바로 아래 — 화면 위쪽에 붙으면 이미지 아래로 내린다.
        var origin = NSPoint(
            x: toolbarFrame.minX + 4, y: toolbarFrame.maxY + 6)
        if origin.y + host.fittingSize.height > bounds.height {
            origin = NSPoint(x: toolbarFrame.minX + 4, y: toolbarFrame.minY - host.fittingSize.height - 6)
        }
        origin.x = max(8, min(origin.x, bounds.width - host.fittingSize.width - 8))
        host.frame = NSRect(origin: origin, size: host.fittingSize)
        imageAltEditorHost?.removeFromSuperview()
        imageAltEditorHost = host
        addSubview(host)
    }

    func hideImageAltEditor() {
        imageAltEditorHost?.removeFromSuperview()
        imageAltEditorHost = nil
    }

    /// 문단이 차지하는 **전체 컬럼 폭** rect (뷰 좌표) — 레이아웃 매니저의
    /// `paragraphRect`(이미지를 그리는 기준)와 정확히 같은 규칙으로 만든다.
    /// 이게 어긋나 있어서 핸들 히트 존이 이미지와 따로 놀았다(리사이즈 불가 버그).
    private func paragraphRectInView(_ para: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y
        // x·폭을 컬럼 전체로 맞춘다 (drawImage의 rect와 동일).
        rect.origin.x = textContainerOrigin.x + textContainer.lineFragmentPadding
        rect.size.width = textContainer.size.width - textContainer.lineFragmentPadding * 2
        return rect
    }

    // MARK: 이미지 크기 조절 (모서리 핸들 드래그, 요구 2)

    /// 렌더된 이미지가 실제로 그려지는 뷰 좌표 rect — `drawImage`와 같은 규칙.
    /// 핸들 히트 테스트·그리기의 기준.
    func imageDrawnRect(forParagraphAt loc: Int) -> NSRect? {
        guard let render = imageRenders.first(where: { $0.range.location == loc }),
            let row = paragraphRectInView(
                (string as NSString).paragraphRange(
                    for: NSRange(location: min(loc, (string as NSString).length), length: 0)))
        else { return nil }
        let box = row.insetBy(dx: 8, dy: 6)
        guard render.size.width > 0, render.size.height > 0 else { return nil }
        let scale = min(box.width / render.size.width, box.height / render.size.height, 1)
        let size = NSSize(width: render.size.width * scale, height: render.size.height * scale)
        let x: CGFloat
        switch render.align {
        case "left": x = box.minX
        case "right": x = box.maxX - size.width
        default: x = row.midX - size.width / 2
        }
        return NSRect(
            x: x, y: row.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 100% 표시 너비 — 드래그 델타를 %로 환산할 때의 기준.
    func imageFitWidth(forParagraphAt loc: Int) -> CGFloat? {
        guard let render = imageRenders.first(where: { $0.range.location == loc })
        else { return nil }
        return imageDisplaySize(render.image, widthPercent: 100).width
    }

    /// 이미지 소스에서 현재 너비(%)를 읽는다.
    func imageWidthPercent(at loc: Int) -> Int {
        let para = (string as NSString).paragraphRange(
            for: NSRange(location: min(loc, (string as NSString).length), length: 0))
        return Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces))?.width ?? 100
    }

    // MARK: - 이미지 박스 오버레이 연동 (요구 A·B)

    /// 오버레이(있으면)를 이미지 위치에 맞춰 다시 배치한다.
    func repositionImageBox() {
        guard let box = imageBox, let loc = selectedImageLocation,
            let rect = imageDrawnRect(forParagraphAt: loc)
        else { return }
        box.frame = rect.insetBy(dx: -box.inset, dy: -box.inset)
        box.needsDisplay = true
    }

    /// 크기 조절 미리보기 — 시작 너비%에 드래그 델타(pt)를 더해 %로 환산해 반영한다.
    func previewImageResize(at loc: Int, startWidth: Int, deltaWidth: CGFloat) {
        guard let fitW = imageFitWidth(forParagraphAt: loc), fitW > 0 else { return }
        let startDisplayW = fitW * CGFloat(startWidth) / 100
        let pct = Int(((startDisplayW + deltaWidth) / fitW * 100).rounded())
        let clamped = min(100, max(10, pct))
        resizePreview = (loc, clamped)
        refreshRenderedBlocks()  // 끝에서 repositionImageBox 호출됨
        let para = (string as NSString).paragraphRange(
            for: NSRange(location: min(loc, (string as NSString).length), length: 0))
        presentImageToolbar(for: para, overrideWidth: clamped)
    }

    /// 크기 조절 확정 — 미리보기 너비%를 소스에 기록한다.
    func commitImageResize(at loc: Int) {
        let finalWidth = resizePreview?.width
        resizePreview = nil
        let para = (string as NSString).paragraphRange(
            for: NSRange(location: min(loc, (string as NSString).length), length: 0))
        if let finalWidth, finalWidth != imageWidthPercent(at: loc) {
            rewriteImage(para, setWidth: finalWidth)
        } else {
            refreshRenderedBlocks()
            presentImageToolbar(for: para)
        }
    }

    /// 이동 드래그 중 — 드롭될 문단 위쪽에 표시선을 그린다.
    func updateImageDropIndicator(toViewPoint p: NSPoint) {
        let idx = min(characterIndexForInsertion(at: p), (string as NSString).length)
        let dropPara = (string as NSString).paragraphRange(
            for: NSRange(location: idx, length: 0))
        imageDropIndicatorY = paragraphRectInView(dropPara)?.minY
        needsDisplay = true
    }

    /// 이미지 문단을 드롭 지점의 문단 앞으로 옮긴다 (요구 B).
    func moveImageParagraph(at loc: Int, toViewPoint p: NSPoint) {
        moveParagraph(at: loc, as: .image, toViewPoint: p)
    }

    /// 블록 문단(이미지·수식)을 통째로 드롭 지점의 문단 앞으로 옮긴다 (요구 B·6).
    /// 다중 행 수식 그룹이면 그룹 전체를 옮긴다 (이슈 #20).
    func moveParagraph(at loc: Int, as block: PurloryBlock, toViewPoint p: NSPoint) {
        imageDropIndicatorY = nil
        guard let storage = textStorage else { return }
        let ns = string as NSString
        var para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        // 수식 그룹 소속이면 이동 단위를 그룹 전체로 넓힌다.
        if block == .math, let group = mathGroup(containing: para.location) {
            para = group
        }
        let isMathGroup = block == .math && para.length > 0
            && ns.paragraphRange(for: NSRange(location: para.location, length: 0)).upperBound
                != para.upperBound
        let lineText = ns.substring(with: para).trimmingCharacters(in: CharacterSet(["\n"]))
        let dropIdx = min(characterIndexForInsertion(at: p), ns.length)
        let dropPara = ns.paragraphRange(for: NSRange(location: dropIdx, length: 0))
        guard dropPara.location < para.location || dropPara.location >= para.upperBound else {
            refreshRenderedBlocks(); return
        }
        clearImageSelection()

        // 지울 범위: 블록 문단(개행 포함). 마지막 줄이라 개행이 없으면 앞 개행을 지운다.
        var removeRange = para
        let endsNL =
            para.length > 0
            && ns.substring(
                with: NSRange(location: para.location + para.length - 1, length: 1)) == "\n"
        if !endsNL, para.location > 0 {
            removeRange = NSRange(location: para.location - 1, length: para.length + 1)
        }
        var insertLoc = dropPara.location

        guard shouldChangeText(
            in: NSRange(location: 0, length: ns.length), replacementString: nil)
        else { return }
        nameCurrentUndo("블록 이동")
        isTransforming = true
        storage.replaceCharacters(in: removeRange, with: "")
        // 삭제로 밀린 삽입 위치 보정.
        if insertLoc >= removeRange.location + removeRange.length {
            insertLoc -= removeRange.length
        } else if insertLoc > removeRange.location {
            insertLoc = removeRange.location
        }
        insertLoc = min(max(0, insertLoc), (string as NSString).length)
        storage.replaceCharacters(
            in: NSRange(location: insertLoc, length: 0), with: lineText + "\n")
        isTransforming = false

        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: insertLoc, length: 0))
        if !isMathGroup {
            // 단일 문단만 속성 재부여 — 그룹은 열기/닫기 구분자 속성이 문단마다
            // 다르므로 텍스트와 함께 이동한 속성을 건드리지 않는다 (이슈 #20).
            applyBlock(block, to: newPara, registerUndo: false)
        }
        if block == .image {
            setSelectedRange(NSRange(location: newPara.location, length: 0))
            didChangeText()
            // 옮긴 이미지를 다시 객체 선택해 박스를 이어서 보여준다.
            selectImageObject(at: newPara)
        } else {
            // 커서는 블록 **다음** 문단에 — 수식은 커서가 들어오면 소스로 풀리므로
            // 옮긴 직후에도 렌더 상태를 유지한다.
            setSelectedRange(NSRange(
                location: min(newPara.upperBound, (string as NSString).length), length: 0))
            didChangeText()
            refreshRenderedBlocks()
        }
    }

    // MARK: 수식 블록 드래그 이동 (요구 6)

    /// 렌더된 수식이 실제 그려지는 뷰 좌표 rect — `drawMath`와 같은 축소 규칙.
    /// 히트 판정·커서 rect의 기준. 다중 행 그룹은 그룹 전체 rect 기준 (이슈 #20).
    func mathDrawnRect(forParagraphAt loc: Int) -> NSRect? {
        guard let render = mathRenders.first(where: { NSLocationInRange(loc, $0.range) }),
            let row = paragraphRectInView(render.range)
        else { return nil }
        var size = render.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let maxWidth = max(40, row.width - 32)
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        return NSRect(
            x: row.midX - size.width / 2, y: row.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// 수식 클릭/드래그 판별 루프 — 3pt 이상 끌면 이동 모드(드롭 표시선 + 손 커서),
    /// 그 자리에서 떼면 평소처럼 커서를 넣어 소스 편집 모드로 들어간다.
    private func trackMathDrag(from event: NSEvent, paragraph para: NSRange) {
        guard let window else { return }
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseDragged {
                if abs(next.locationInWindow.x - event.locationInWindow.x) > 3
                    || abs(next.locationInWindow.y - event.locationInWindow.y) > 3 {
                    moved = true
                }
                if moved {
                    NSCursor.closedHand.set()
                    updateImageDropIndicator(
                        toViewPoint: convert(next.locationInWindow, from: nil))
                }
                continue
            }
            // mouseUp — 이동 확정 또는 편집 진입.
            imageDropIndicatorY = nil
            if moved {
                moveParagraph(
                    at: para.location, as: .math,
                    toViewPoint: convert(next.locationInWindow, from: nil))
                NSCursor.arrow.set()
            } else {
                let p = convert(event.locationInWindow, from: nil)
                let idx = min(characterIndexForInsertion(at: p), (string as NSString).length)
                window.makeFirstResponder(self)
                setSelectedRange(NSRange(location: idx, length: 0))
                refreshRenderedBlocks()
            }
            needsDisplay = true
            return
        }
    }

    // MARK: 드래그 드롭 (이미지 파일)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasImage(sender.draggingPasteboard)
            ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasImage(sender.draggingPasteboard)
            ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pasteboardHasImage(sender.draggingPasteboard)
            ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard pasteboardHasImage(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        // 드롭 지점으로 커서를 옮긴 뒤 그 자리에 삽입한다.
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index != NSNotFound {
            setSelectedRange(NSRange(location: min(index, (string as NSString).length), length: 0))
        }
        return insertImages(from: sender.draggingPasteboard)
    }

    // MARK: 인라인 수식 원자 (이슈 #20)

    /// raw `$…$` 스팬이 문서에 남아 있을 가능성 — 빠른 경로 판정용.
    /// `$` 입력·소스 펼치기·로드 시 남은 스팬에서 켜지고, 접기 검사가 실측으로 끈다.
    private(set) var mayHaveInlineMath = true

    /// 회귀 테스트용 — 붙여넣기 등 외부 편집 후의 상태를 흉내 낸다 (이슈 #20).
    var mayHaveInlineMathForTesting: Bool {
        get { mayHaveInlineMath }
        set { mayHaveInlineMath = newValue }
    }
    /// 인라인 수식 원자의 storage 문자 — U+FFFC (attachment 글자 하나).
    static let attachmentCharacter = "\u{FFFC}"


    /// 수식 스캔 제외 범위(문단 상대) — 인라인 코드 스팬과 **이미 존재하는
    /// 수식 원자**. 원자를 끼고 `$`가 재결합하면 이중 변환으로 내용이 삼켜진다.
    private func inlineCodeSkips(in paragraph: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var skips: [NSRange] = []
        storage.enumerateAttribute(.purloryCode, in: paragraph, options: []) { value, range, _ in
            if value as? Bool == true {
                skips.append(
                    NSRange(
                        location: range.location - paragraph.location, length: range.length))
            }
        }
        storage.enumerateAttribute(.purloryMath, in: paragraph, options: []) { value, range, _ in
            if value as? Bool == true {
                skips.append(
                    NSRange(
                        location: range.location - paragraph.location, length: range.length))
            }
        }
        return skips
    }

    /// 산문 문단의 `$…$` 스팬을 렌더 원자(attachment 한 글자)로 바꾼다.
    /// 변환한 스팬 수를 돌려준다. 코드 블록·수식/이미지/구분선 블록은 처음부터 건너뛴다.
    @discardableResult
    func convertInlineMath(in paragraph: NSRange, registersUndo: Bool = true) -> Int {
        guard let storage = textStorage,
            ![PurloryBlock.code, .math, .divider, .image].contains(blockInfo(in: paragraph).block)
        else { return 0 }
        let content = paragraphContent(paragraph)
        // 인라인 원자는 **inlineText**만 대상이다. 산문 한가운데의 `$$…$$`는
        // 단일-$ 복원으로 되돌릴 때 경계가 흔들려(파싱 비대칭) 원문 텍스트로
        // 남긴다 — 블록 렌더는 문단 단위 그룹이 담당한다 (이슈 #20).
        let regions = MathScanner.regions(
            in: content, skipping: inlineCodeSkips(in: paragraph)
        ).filter { $0.kind == .inlineText }
        guard !regions.isEmpty else { return 0 }

        if registersUndo { isTransforming = true }
        defer { if registersUndo { isTransforming = false } }
        for region in regions.reversed() {
            let span = NSRange(
                location: paragraph.location + region.range.location,
                length: region.range.length)
            // 원자 폰트 크기 — 문단에 저장된 인라인 크기 속성을 존중한다.
            let baseAttrs =
                storage.attributes(at: span.location, effectiveRange: nil)
            let size = (baseAttrs[.purloryFontSize] as? Double).map { CGFloat($0) }
                ?? baseFontSize
            let atom = MathAtomAttachment(latex: region.latex)
            atom.render(fontSize: size, color: palette.ink)

            if registersUndo {
                guard shouldChangeText(in: span, replacementString: "") else { continue }
            }
            // 주의: String(unichar)은 십진수 "65532"를 만든다 — 유니코드 스칼라로.
            storage.replaceCharacters(
                in: span, with: Self.attachmentCharacter)
            var atomAttrs = baseAttrs
            atomAttrs[.attachment] = atom
            atomAttrs[.purloryMath] = true
            // VoiceOver 읽기는 accessibilityString(for:)가 attachment를 문장으로
            // 바꿔 담당한다 (이슈 #22).
            storage.setAttributes(
                atomAttrs, range: NSRange(location: span.location, length: 1))
            if registersUndo {
                nameCurrentUndo("수식 원자 전환")
                didChangeText()
            }
        }
        return regions.count
    }

    /// 로드 직후 전 문서 1회 전환 — 로드는 undo 대상이 아니므로 storage를 곧장 고친다.
    func convertAllInlineMath() {
        // 남는 raw 스팬 여부는 syncInlineMathFlag가 실측으로 정리한다.
        let ns = string as NSString
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = para.upperBound
            convertInlineMath(in: para, registersUndo: false)
        }
        syncInlineMathFlag()
    }

    /// 커서가 떠난 문단의 raw `$…$`를 원자로 접는다. 커서 문단은 편집 중일 수 있어
    /// 건드리지 않고 플래그만 유지한다 — 다음 커서 이동 때 접힌다.
    private func collapseRawInlineMath(awayFrom sel: NSRange, in ranges: [NSRange]) {
        guard mayHaveInlineMath else { return }
        let paragraphs = ranges.flatMap { indexedMediaParagraphs(in: $0) }
        var seen = Set<Int>()
        for paragraph in paragraphs.sorted(by: { $0.range.location > $1.range.location }) {
            let para = paragraph.range
            guard seen.insert(para.location).inserted else { continue }
            let caretInside = NSIntersectionRange(sel, para).length > 0
                || (sel.location >= para.location && sel.location <= para.upperBound)
            if !caretInside, convertInlineMath(in: para) > 0 { needsDisplay = true }
        }
        // Keep the flag conservative until load/global restyle. A scoped pass cannot
        // prove that a distant raw span disappeared without scanning the document.
    }

    /// 문단에 지금 접을 수 있는 raw `$…$`가 있는가.
    private func hasConvertibleRawMath(in paragraph: NSRange) -> Bool {
        !MathScanner.regions(
            in: paragraphContent(paragraph), skipping: inlineCodeSkips(in: paragraph)).isEmpty
    }

    /// 실측으로 플래그 정리 — 전체 경로를 한 번 탄 뒤 호출한다 (syncMarkerFlag 짝).
    private func syncInlineMathFlag() {
        guard let storage = textStorage else {
            mayHaveInlineMath = false
            return
        }
        let ns = storage.string as NSString
        var found = false
        var location = 0
        while location < ns.length, !found {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = para.upperBound
            if hasConvertibleRawMath(in: para) { found = true }
        }
        mayHaveInlineMath = found
    }

    /// 테마·글자 크기 변경 — 원자 이미지를 새 잉크색·크기로 다시 렌더한다.
    func rerenderInlineAtoms() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.purloryMath, in: full, options: []) { value, range, _ in
            guard value as? Bool == true, range.length == 1 else { return }
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            guard let atom = attrs[.attachment] as? MathAtomAttachment else { return }
            let size = (attrs[.purloryFontSize] as? Double).map { CGFloat($0) } ?? baseFontSize
            atom.render(fontSize: size, color: palette.ink)
        }
        needsDisplay = true
    }

    /// 더블클릭한 원자를 `$latex$` 소스로 펼쳐 내용을 선택한다 — 편집 후 커서가
    /// 문단을 떠나면 다시 원자로 접힌다(collapseRawInlineMath).
    private func revealInlineMathSource(at point: NSPoint) -> Bool {
        guard let layoutManager, let textContainer, let storage = textStorage else {
            return false
        }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(
            for: containerPoint, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil)
        let ns = string as NSString
        guard index < ns.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        guard attrs[.purloryMath] as? Bool == true,
            let atom = attrs[.attachment] as? MathAtomAttachment
        else { return false }
        // 원자는 한 글자다 — 소스 텍스트로 갈아끼운다.
        let source = "$\(atom.latex)$"
        let span = NSRange(location: index, length: 1)
        // 문단 속성은 교체 전에 채집 — 교체가 위치를 밀기 때문.
        let paraAttrs = storage.attributes(at: span.location, effectiveRange: nil)
        guard shouldChangeText(in: span, replacementString: source) else { return false }
        isTransforming = true
        storage.replaceCharacters(in: span, with: source)
        storage.setAttributes(
            paraAttrs, range: NSRange(location: index, length: (source as NSString).length))
        isTransforming = false
        nameCurrentUndo("수식 편집")
        didChangeText()
        setSelectedRange(
            NSRange(location: index + 1, length: (atom.latex as NSString).length))
        mayHaveInlineMath = true
        return true
    }

    // MARK: 수식·이미지 렌더

    /// 수식·이미지 문단 표시 갱신 — 커서가 밖에 있고 소스가 렌더되면 소스 글자를
    /// 투명 처리(temporary attribute — storage·undo·저장에 무해)하고, 레이아웃
    /// 매니저가 그 자리에 렌더 결과를 그린다. 커서가 들어오면 소스로 돌아온다.
    /// 연속 `.math` 문단에서 다중 행 display 그룹의 범위를 계산한다 (이슈 #20).
    /// 열기(`$$`) 속성 문단에서 시작해 닫기(`$$`) 속성 문단까지 — 닫힘이 없으면
    /// 수식이 끊기는 곳(문서 끝·다른 블록)까지가 그룹이다. 단독 완결 수식은
    /// 그룹이 아니라 결과에 없다 — 기존 단일 렌더 경로가 맡는다.
    static func mathGroupRanges(
        _ paragraphs: [(range: NSRange, block: PurloryBlock, open: Bool, close: Bool)],
        requireContiguousRanges: Bool = false
    ) -> [NSRange] {
        var groups: [NSRange] = []
        var index = 0
        while index < paragraphs.count {
            let para = paragraphs[index]
            if para.block == .math, para.open {
                var last = index
                while last + 1 < paragraphs.count,
                    paragraphs[last + 1].block == .math,
                    (!requireContiguousRanges || paragraphs[last].range.upperBound == paragraphs[last + 1].range.location),
                    !paragraphs[last].close
                { last += 1 }
                groups.append(NSRange(
                    location: para.range.location,
                    length: paragraphs[last].range.upperBound - para.range.location))
                index = last + 1
            } else {
                index += 1
            }
        }
        return groups
    }

    /// Scroll refresh retains persistent line heights and collects only indexed
    /// viewport/dirty/selection scopes. Ordinary edits use the same bounded lookup;
    /// load, recovery and global restyle explicitly own full construction.
    func refreshVisibleBlocks() {
        refreshRenderedBlocks(limitToVisible: true)
    }

    /// 가시 사각형(±버퍼 문단)이 덮는 본문 범위 — 스크롤 한정 렌더의 필터 (#18).
    func visibleTextRange(bufferParagraphs: Int = 4) -> NSRange? {
        guard let layoutManager, let textContainer,
            let scrollView = enclosingScrollView
        else { return nil }
        let visibleRect = scrollView.contentView.bounds
        guard visibleRect.height > 0 else { return nil }
        let origin = textContainerOrigin
        // 위아래로 버퍼 문단 높이만큼 넓힌다 — 스크롤 직후 가장자리 공백 방지.
        let lineHeight = max(12, layoutManager.defaultLineHeight(for: bodyFont))
        let inflated = visibleRect.insetBy(
            dx: 0, dy: -CGFloat(bufferParagraphs) * lineHeight)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: inflated.offsetBy(dx: -origin.x, dy: -origin.y),
            in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return nil }
        return charRange
    }

    /// Paragraph scan window for scroll-driven media refresh.
    ///
    /// The normal visible range is already buffered by a few paragraphs. If an edge lands
    /// inside a multi-line math group, expand only through that contiguous math group so
    /// grouping stays correct without walking unrelated paragraphs in the document.
    func mediaRenderScanRange(for visibleRange: NSRange) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }

        let startAnchor = min(max(0, visibleRange.location), ns.length - 1)
        let endAnchor = min(
            max(startAnchor, max(0, visibleRange.upperBound - 1)),
            ns.length - 1)

        var first = ns.paragraphRange(
            for: NSRange(location: startAnchor, length: 0))
        var last = ns.paragraphRange(
            for: NSRange(location: endAnchor, length: 0))

        func delimiter(_ para: NSRange) -> String {
            guard let storage = textStorage, para.location < storage.length else {
                return ""
            }
            return storage.attribute(
                .purloryMathDelim, at: para.location, effectiveRange: nil) as? String ?? ""
        }

        if blockInfo(in: first).block == .math {
            while first.location > 0, delimiter(first) != "open" {
                let previous = ns.paragraphRange(
                    for: NSRange(location: first.location - 1, length: 0))
                guard previous.location < first.location,
                    blockInfo(in: previous).block == .math
                else { break }
                first = previous
            }
        }

        if blockInfo(in: last).block == .math {
            while last.upperBound < ns.length, delimiter(last) != "close" {
                let next = ns.paragraphRange(
                    for: NSRange(location: last.upperBound, length: 0))
                guard next.location >= last.upperBound,
                    next.location < ns.length,
                    blockInfo(in: next).block == .math
                else { break }
                last = next
            }
        }

        return NSRange(
            location: first.location,
            length: max(0, last.upperBound - first.location))
    }

    /// Rebase published graphics and cleanup scopes before consuming the next edit.
    func rebaseRenderedMedia(replacing edit: NSRange, withLength length: Int) {
        func moved(_ range: NSRange) -> NSRange { rebaseMediaRange(range, replacing: edit, withLength: length) }
        func edited(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, edit).length > 0
                || (edit.length == 0 && edit.location >= range.location && edit.location <= range.upperBound)
        }
        mathRenders = mathRenders.compactMap { edited($0.range) ? nil : (moved($0.range), $0.image) }
        imageRenders = imageRenders.compactMap { item in
            guard !edited(item.range) else { return nil }
            return ImageRender(range: moved(item.range), image: item.image, size: item.size,
                align: item.align, selected: item.selected, failure: item.failure)
        }
        mathRenderErrors = Dictionary(mathRenderErrors.map {
            (moved(NSRange(location: $0.key, length: 0)).location, $0.value)
        }, uniquingKeysWith: { _, latest in latest })
        previousClearRanges = previousClearRanges.map(moved).filter { $0.length > 0 }
        previousMathGroups = previousMathGroups.map(moved).filter { $0.length > 0 }
        mediaLastSelectionRange = mediaLastSelectionRange.map(moved)
        if let location = selectedImageLocation {
            selectedImageLocation = NSLocationInRange(location, edit) ? nil
                : moved(NSRange(location: location, length: 0)).location
        }
    }

    private func mediaRenderWorkRanges(full: Bool) -> [NSRange] {
        let total = textStorage?.length ?? 0
        if full { return [NSRange(location: 0, length: total)] }
        var requests = mediaDirtyRanges + [selectedRange()]
        if let visible = visibleTextRange() { requests.append(visible) }
        if let prior = mediaLastSelectionRange { requests.append(prior) }
        if let image = selectedImageLocation { requests.append(NSRange(location: image, length: 0)) }
        var ranges: [NSRange] = []
        for request in requests {
            let location = min(max(0, request.location), total)
            let length = min(max(0, request.length), total - location)
            let paragraphs = indexedMediaParagraphs(in: NSRange(location: location, length: length))
            guard let first = paragraphs.first, let last = paragraphs.last else { continue }
            var range = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
            for edge in [first.range.location, last.range.location] {
                if let run = mediaParagraphIndex?.mathRun(containing: edge) { range = NSUnionRange(range, run) }
            }
            ranges.append(range)
        }
        // A removed opening/closing delimiter may leave former members outside the
        // current run; include the prior group to restore every persistent line height.
        for old in previousMathGroups where ranges.contains(where: { NSIntersectionRange($0, old).length > 0 }) {
            ranges.append(old)
        }
        return mergedMediaRanges(ranges)
    }

    func refreshRenderedBlocks(
        forceRender: Bool = false, limitToVisible: Bool = false
    ) {
        guard let layoutManager, let storage = textStorage else { return }
        lastMediaRenderParagraphCount = 0
        let fullRefresh = forceRender || mediaParagraphIndex?.utf16Length != storage.length
        _ = indexedMediaParagraphs(in: NSRange(location: 0, length: 0))

        // 빠른 경로: 렌더 중인 블록도, 이미 렌더된 것도, 이미지 선택도 없고 소스에
        // 수식/이미지 마커("$$"·"![")와 raw 인라인 수식("$")조차 없으면 — 즉 대다수의
        // 평문 저널이면 — 문단 순회·임시속성 조작·전체 재그리기를 통째로 건너뛴다
        // (키 입력마다 O(n) 낭비 제거). 마커 검사는 NSString range 검색이라 문단
        // 순회보다 훨씬 싸다.
        // 주의: 수식/이미지 블록은 마커("$$"·"![")가 이미 **소비**돼 storage 텍스트에
        // 남아 있지 않다 — 커서 문단이 수식/이미지면 마커 검사와 무관하게 전체
        // 경로를 타야 한다 (안 그러면 편집 후 렌더로 영영 못 돌아가는 버그).
        if mathRenders.isEmpty, imageRenders.isEmpty, previousMathGroups.isEmpty,
            previousClearRanges.isEmpty, selectedImageLocation == nil, !mayHaveMarkers, !mayHaveInlineMath {
            let source = storage.string as NSString
            let caretPara = source.paragraphRange(
                for: NSRange(location: min(selectedRange().location, source.length), length: 0))
            let caretBlock = blockInfo(in: caretPara).block
            let previousBlock = mediaLastSelectionRange.map {
                blockInfo(in: source.paragraphRange(for: NSRange(
                    location: min($0.location, source.length), length: 0))).block
            }
            // Leaving source mode must render the prior math block even after
            // its consumed markers and temporary graphics have disappeared.
            if caretBlock != .math, caretBlock != .image, previousBlock != .math {
                cancelMathPreview()
                hideMathPreview()
                _ = takeMediaDirtyRanges()
                mediaLastSelectionRange = selectedRange()
                return
            }
        }
        if !limitToVisible {
            collapseRawInlineMath(awayFrom: selectedRange(), in: mediaRenderWorkRanges(full: fullRefresh))
        }
        let scanRanges = mediaRenderWorkRanges(full: fullRefresh)
        _ = takeMediaDirtyRanges()
        func affected(_ range: NSRange) -> Bool {
            fullRefresh || scanRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for old in previousClearRanges where affected(old) || limitToVisible {
            let location = min(old.location, storage.length)
            let length = min(old.length, storage.length - location)
            if length > 0 {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange:
                    (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: length)))
            }
        }
        previousClearRanges = fullRefresh || limitToVisible ? [] : previousClearRanges.filter { !affected($0) }
        var maths = fullRefresh || limitToVisible ? [] : mathRenders.filter { !affected($0.range) }
        var collectedMathErrors = fullRefresh || limitToVisible ? [:] : mathRenderErrors.filter {
            !affected(NSRange(location: $0.key, length: 1))
        }
        var images: [ImageRender] = fullRefresh || limitToVisible ? [] : imageRenders.filter { !affected($0.range) }
        // 편집 모드인 수식 그룹 — 루프 뒤 라이브 미리보기 패널을 붙인다.
        var editingMath: (para: NSRange, source: String)?
        let sel = selectedRange()
        // 포커스가 사이드바 등 밖에 있으면 커서가 문단에 남아 있어도 렌더한다 —
        // 수식·이미지가 문서 마지막 문단일 때 소스가 계속 보이는 문제 방지.
        let focused = window?.firstResponder === self

        var indexed: [Int: ParagraphRenderIndex.Paragraph] = [:]
        for range in scanRanges {
            for paragraph in indexedMediaParagraphs(in: range) { indexed[paragraph.range.location] = paragraph }
        }
        let paras = indexed.values.sorted { $0.range.location < $1.range.location }.map {
            (range: $0.range, block: $0.record.block, open: $0.record.open, close: $0.record.close)
        }
        lastMediaRenderParagraphCount = paras.count
        let groups = Self.mathGroupRanges(paras, requireContiguousRanges: true)
        // Restore old group layout before rendering replacement singles/images.
        // Every scoped group is complete, including on a scroll-driven dirty pass.
        for old in previousMathGroups where affected(old) {
            for member in indexedMediaParagraphs(in: old) {
                if !groups.contains(where: { NSIntersectionRange($0, member.range).length > 0 }) {
                    updateGroupLineHeight(nil, in: member.range)
                }
            }
        }
        previousMathGroups = previousMathGroups.filter { !affected($0) } + groups

        // 2단계 — 다중 행 display 그룹 렌더. 커서가 그룹 어느 줄에든 들어오면
        // 그룹 전체가 소스 편집 모드가 되고, 나가면 하나의 이미지로 합쳐 그린다.
        for group in groups {
            let members = paras.filter {
                $0.block == .math && NSIntersectionRange($0.range, group).length > 0
            }
            guard let lastMember = members.last else {
                continue
            }
            // 그룹 문단은 원문($$ 포함)이 저장돼 있다 — 렌더할 LaTeX만 추출한다.
            let latex = members.map { member -> String in
                var source =
                    paragraphContent(member.range).trimmingCharacters(in: .whitespaces)
                if member.open, source.hasPrefix("$$") {
                    source = String(source.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                if member.close, source.hasSuffix("$$"), source.count >= 2 {
                    source = String(source.dropLast(2)).trimmingCharacters(in: .whitespaces)
                }
                return source
            }
            .joined(separator: "\n")
            let contentEnd = lastMember.range.location
                + (paragraphContent(lastMember.range) as NSString).length
            let editing =
                !forceRender && focused
                && ((sel.length == 0 && sel.location >= group.location
                    && sel.location <= contentEnd)
                    || (sel.length > 0 && NSIntersectionRange(sel, group).length > 0))
            if editing {
                editingMath = (group, latex)
                continue
            }
            guard let image = MathRenderer.image(
                latex: latex, color: palette.ink, fontSize: mathFontSize)
            else { continue }  // 파싱 불가 — 직전 높이 유지 (기존 정책)
            maths.append((group, image))
            previousClearRanges.append(group)
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: NSColor.clear, forCharacterRange: group)
            // 그룹 박스 총높이(렌더±마진+틈)를 문단 수로 나눠 배분한다 — 표시
            // 전용 속성이라 저장·undo에 흔적이 없다.
            let total = displayHeight(of: image) + Self.mathBoxMargin * 2 + 4
            let share = max(28, total / CGFloat(max(members.count, 1)))
            for member in members { updateGroupLineHeight(share, in: member.range) }
        }

        // 3단계 — 단독 완결 수식·이미지.
        // `paras` is already the exact scan window; do not restart at document 0.
        for info in paras {
            let para = info.range
            let block = info.block
            if block == .math,
                groups.contains(where: { NSLocationInRange(para.location, $0) })
            {
                continue  // 그룹 소속은 2단계에서 처리됐다
            }
            guard block == .math || block == .image else { continue }

            let content = paragraphContent(para)
            let contentEnd = para.location + (content as NSString).length
            let objectSelected = block == .image && selectedImageLocation == para.location
            // 이미지는 소스를 **절대** 보여주지 않는다 — 항상 렌더(요구 1).
            // 수식만 커서가 닿으면 편집 모드(소스)로 전환한다.
            let editing =
                block == .math && !forceRender && focused
                && ((sel.length == 0 && sel.location >= para.location
                    && sel.location <= contentEnd)
                    || (sel.length > 0 && NSIntersectionRange(sel, para).length > 0))
            let source = content.trimmingCharacters(in: .whitespaces)

            let rendered: NSImage?
            var attrs: ImageAttrs?
            var mathError: String?
            switch block {
            case .math:
                if source.isEmpty {
                    rendered = nil
                } else {
                    let status = MathRenderer.render(
                        latex: source, color: palette.ink, fontSize: mathFontSize)
                    rendered = status.image
                    mathError = status.error
                }
            case .image:
                attrs = Self.imageAttrs(from: source)
                // 표시용 다운샘플 (#53) — 그리기엔 컬럼 폭×배율이면 충분하다.
                // 전체 해상도 디코딩은 복사·내보내기 경로만 남는다.
                rendered = attrs.flatMap {
                    resolvedImage(
                        for: $0.src,
                        maxPixelWidth: Self.imageDecodePixelWidth(
                            containerWidth: textContainer?.size.width,
                            backingScale: window?.backingScaleFactor ?? 2))
                }
            default:
                rendered = nil
            }

            switch block {
            case .math:
                if editing { editingMath = (para, source) }
                if let image = rendered {
                    // 렌더되는 한 줄 높이(마진)를 **항상** 유지한다 — 커서가 들어와도,
                    // 다른 곳 갔다 와도 풀리지 않게 (요구 2). 편집 모드면 소스만 보인다.
                    updateRenderedLineHeight(displayHeight(of: image), block: .math, in: para)
                    if !editing {
                        maths.append((para, image))
                        previousClearRanges.append(para)
                        layoutManager.addTemporaryAttribute(
                            .foregroundColor, value: NSColor.clear, forCharacterRange: para)
                    }
                } else if let error = mathError {
                    // 유효→무효 전환 — 직전 높이·플로팅 미리보기 잔상을 끊고
                    // 원인 표시 placeholder로 갈아끼운다 (이슈 #22).
                    hideMathPreview()
                    let placeholder = MathRenderer.failurePlaceholder(
                        message: error, latex: source, color: palette.ink)
                    updateRenderedLineHeight(
                        displayHeight(of: placeholder), block: .math, in: para)
                    if !editing {
                        maths.append((para, placeholder))
                        collectedMathErrors[para.location] = error
                        previousClearRanges.append(para)
                        layoutManager.addTemporaryAttribute(
                            .foregroundColor, value: NSColor.clear, forCharacterRange: para)
                    }
                } else if source.isEmpty {
                    updateRenderedLineHeight(nil, block: .math, in: para)  // 빈 수식만 기본
                }
            case .image:
                guard let image = rendered else {
                    // 로드 실패 — 소스로 빠지는 대신 원인·alt·경로를 적은
                    // 플레이스홀더를 렌더한다 (이슈 #15). 소스 노출 금지 불변식 유지.
                    if let a = attrs, let failure = imageFailure(for: a.src) {
                        let placeholder = ImageFailure.placeholder(
                            reason: failure, alt: a.alt, path: a.src, theme: palette)
                        let size = imageDisplaySize(placeholder, widthPercent: a.width)
                        images.append(
                            ImageRender(
                                range: para, image: placeholder, size: size,
                                align: a.align, selected: objectSelected, failure: failure))
                        updateRenderedLineHeight(size.height, block: .image, in: para)
                        previousClearRanges.append(para)
                        layoutManager.addTemporaryAttribute(
                            .foregroundColor, value: NSColor.clear, forCharacterRange: para)
                    } else {
                        // attrs가 없다면 이미지 문단 표식만 남은 빈 줄 — 높이만 복원.
                        updateRenderedLineHeight(nil, block: .image, in: para)
                    }
                    continue
                }
                let a = attrs ?? ImageAttrs(src: "")
                // 드래그 리사이즈 중이면 미리보기 너비를 우선한다.
                let width = resizePreview?.loc == para.location
                    ? resizePreview!.width : a.width
                let size = imageDisplaySize(image, widthPercent: width)
                images.append(
                    ImageRender(
                        range: para, image: image, size: size, align: a.align,
                        selected: objectSelected))
                updateRenderedLineHeight(size.height, block: .image, in: para)
                previousClearRanges.append(para)
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: NSColor.clear, forCharacterRange: para)
            default:
                break
            }
        }
        mathRenders = maths.sorted { $0.range.location < $1.range.location }
        self.mathRenderErrors = collectedMathErrors
        imageRenders = images.sorted { $0.range.location < $1.range.location }
        if fullRefresh { syncMarkerFlag() }
        mediaLastSelectionRange = selectedRange()
        repositionImageBox()  // 렌더/줄 높이 변화에 박스 위치를 맞춘다.
        // Keep live preview beside its source inside the same math block. Retain
        // the existing debounce so typing does not add a render on every key.
        if let (para, source) = editingMath {
            scheduleMathPreview(source: source, in: para)
        } else {
            cancelMathPreview()
            hideMathPreview()
        }
        // 렌더된 이미지 위 포인터 커서 rect를 새 위치로 갱신한다.
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: 수식 라이브 미리보기 (수식 블럭 완성도)

    /// Live preview shares the active source block instead of floating below it.
    private var mathPreviewHost: NSHostingView<MathPreviewView>?
    /// 미리보기 디바운스 (#53) — 글자마다 MTMathList 조판(메인)을 하지 않고
    /// 입력이 150ms 멈췄을 때 마지막 소스만 렌더한다. 대기 중 소스는 계속 갈아끼운다.
    private var mathPreviewTask: Task<Void, Never>?
    private var mathPreviewPending: (source: String, para: NSRange)?

    /// 미리보기 렌더 예약 — 이미 예약이 있으면 소스만 교체한다 (타이머 리셋 없음,
    /// 연속 타이핑에서 최대 한 번의 조판).
    private func scheduleMathPreview(source: String, in para: NSRange) {
        mathPreviewPending = (source, para)
        guard mathPreviewTask == nil else { return }
        mathPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.mathPreviewTask = nil
            guard let pending = self.mathPreviewPending else { return }
            self.mathPreviewPending = nil
            self.presentMathPreview(source: pending.source, in: pending.para)
        }
    }

    private func cancelMathPreview() {
        mathPreviewTask?.cancel()
        mathPreviewTask = nil
        mathPreviewPending = nil
    }

    /// Source and preview occupy one block; preview never covers the next prose row.
    private func presentMathPreview(source: String, in para: NSRange) {
        guard isEditingMath, let rect = paragraphRectInView(para),
            let layoutManager, let textContainer else {
            hideMathPreview()
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let ns = string as NSString
        var sourceRight = rect.midX
        var location = para.location
        while location < min(para.upperBound, ns.length) {
            let member = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let content = NSRange(location: member.location, length: (paragraphContent(member) as NSString).length)
            if content.length > 0 {
                let glyphs = layoutManager.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
                let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                sourceRight = max(sourceRight, bounds.maxX + textContainerOrigin.x)
            }
            location = member.upperBound
        }
        let availableWidth = rect.maxX - sourceRight - 16 - 48
        guard availableWidth >= 64 else { hideMathPreview(); return }
        let image = source.isEmpty
            ? nil
            : MathRenderer.image(latex: source, color: palette.ink, fontSize: mathFontSize)
        let message: String?
        let isError: Bool
        if image != nil {
            message = nil
            isError = false
        } else if source.isEmpty {
            message = "LaTeX 입력 — 예: E = mc^2"
            isError = false
        } else {
            message = "수식을 해석할 수 없어요 — LaTeX 문법을 확인하세요"
            isError = true
        }
        let view = MathPreviewView(
            theme: palette, image: image, message: message, isError: isError,
            maxWidth: availableWidth)
        let host: NSHostingView<MathPreviewView>
        if let existing = mathPreviewHost {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            mathPreviewHost = host
        }
        let size = host.fittingSize
        // SwiftUI rounds intrinsic sizes to whole points. The reserved trailing
        // margin already protects the source; fractional rounding must not hide it.
        guard size.width <= ceil(availableWidth), size.height <= rect.height else {
            hideMathPreview()
            return
        }
        host.frame = NSRect(x: sourceRight + 16, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        if host.superview !== self { addSubview(host) }
    }

    private func hideMathPreview() {
        mathPreviewHost?.removeFromSuperview()
    }

    /// `![alt](src)` 한 줄에서 src(상대경로)만 뽑는다. 형식이 아니면 nil.
    static func imageSource(from line: String) -> String? {
        imageAttrs(from: line)?.src
    }

    /// `![](src){width=NN align=X}` 한 줄에서 소스·너비·정렬을 파싱한다. 형식이 아니면 nil.
    /// 이미지 문단 한 줄 해석 — 공용 파서(ImageReferenceParser, 이슈 #12)의
    /// 결과만 쓴다. 옛 한 줄 정규식은 title·angle·괄호·reference를 놓쳤다.
    /// 원격·차단 소스는 렌더 대상에서 제외한다 (완전 로컬 원칙).
    /// 비격리 순수 파서 — 백그라운드 EPUB 내보내기가 같은 규칙을 쓴다 (#33).
    nonisolated static func imageAttrs(from line: String) -> ImageAttrs? {
        guard let ref = ImageReferenceParser.parse(line) else { return nil }
        switch ref.destinationKind {
        case .managedRelative, .externalFile:
            break
        case .remote, .blocked:
            return nil
        }
        var attrs = ImageAttrs(src: ref.destinationRaw)
        attrs.alt = ref.alt
        attrs.title = ref.title
        // {width align} 확장 적용 — splitOptions가 검증토큰만 남겨 두었다.
        if let trimmed = line.trimmingCharacters(in: .whitespaces) as String?,
           let open = trimmed.lastIndex(of: "{"),
           trimmed.hasSuffix("}") {
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            for token in inner.split(separator: " ") where !token.isEmpty {
                let kv = token.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch String(kv[0]) {
                case "width": if let w = Int(kv[1]) { attrs.width = min(100, max(10, w)) }
                case "align" where ["left", "center", "right"].contains(String(kv[1])):
                    attrs.align = String(kv[1])
                default:
                    // 미지 확장 속성 — 원문 토큰을 순서대로 보관해 재작성 시 되살린다 (이슈 #14).
                    attrs.extraOptions.append(String(token))
                }
            }
            // 재합성 대신 스플라이스 — alt·title을 보존한 채 속성만 바꾼다.
            attrs.optionsPrefix = String(trimmed[..<open])
        } else {
            attrs.optionsPrefix = nil
        }
        return attrs
    }

    /// 표시용 이미지 디코딩 상한 픽셀 — 컬럼 폭 × 배율 × 여유(1.5), 800–2400 클램프.
    /// 이 이상은 화면에서 구분할 수 없다 — 디코딩·메모리만 늘어난다 (#53).
    nonisolated static func imageDecodePixelWidth(
        containerWidth: CGFloat?, backingScale: CGFloat
    ) -> CGFloat {
        let target = (containerWidth ?? 800) * max(1, backingScale) * 1.5
        return min(2400, max(800, target))
    }

    /// drawMath와 같은 규칙(폭 초과 시 축소)으로 실제 그려질 수식 높이를 구한다.
    private func displayHeight(of image: NSImage) -> CGFloat {
        guard let container = textContainer, image.size.width > 0 else {
            return image.size.height
        }
        let rectWidth = container.size.width - container.lineFragmentPadding * 2
        // 컬럼 폭이 아직 안 잡혔으면(레이아웃 전·저널 전환 순간) 축소하지 않는다 —
        // 예전엔 max(40,…) 바닥값이 수식을 40pt로 줄여 줄 높이를 붕괴시켰다.
        guard rectWidth > 120 else { return image.size.height }
        let scale = min(1, (rectWidth - 32) / image.size.width)
        return image.size.height * scale
    }

    /// 이미지가 실제로 그려질 크기 — 컬럼 폭에 맞추고 세로는 480pt로 제한한 뒤,
    /// 사용자 지정 너비 %(요구 3)를 곱한다. (레이아웃 매니저와 같은 규칙.)
    func imageDisplaySize(_ image: NSImage, widthPercent: Int = 100) -> NSSize {
        guard image.size.width > 0, image.size.height > 0 else { return image.size }
        let rectWidth =
            (textContainer.map { $0.size.width - $0.lineFragmentPadding * 2 })
            ?? bounds.width
        let maxHeight: CGFloat = 480
        let pct = CGFloat(min(100, max(10, widthPercent))) / 100
        // 컬럼 폭이 아직 안 잡혔으면(레이아웃 전·전환 순간) 세로 상한만 적용 — 폭
        // 축소로 크기가 붕괴하지 않게.
        let fit: CGFloat
        if rectWidth > 120 {
            fit = min(1, min((rectWidth - 16) / image.size.width, maxHeight / image.size.height))
        } else {
            fit = min(1, maxHeight / image.size.height)
        }
        let scale = fit * pct
        return NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// 수식·이미지 문단의 줄 높이를 렌더 크기에 맞춘다 (nil이면 기본 스타일로 복원).
    /// 표시 전용 속성 변경 — 저장 텍스트·undo에 흔적이 없다.
    private func updateRenderedLineHeight(
        _ height: CGFloat?, block: PurloryBlock, in paragraph: NSRange
    ) {
        guard let storage = textStorage, paragraph.length > 0,
            paragraph.location < storage.length,
            let ps = (styleAttributes(for: block, checked: false)[.paragraphStyle]
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        if let height {
            switch block {
            case .math:
                // 수식 박스(렌더 ±mathBoxMargin)가 이웃 줄과 겹치지 않도록,
                // 박스 높이에 숨 쉴 틈 4pt를 더한 줄 높이 (요구 5).
                ps.minimumLineHeight = height + Self.mathBoxMargin * 2 + 4
            default:
                // 위아래 여유 12pt — 배경 박스(-6 inset)와 시각적으로 맞는 값.
                ps.minimumLineHeight = height + 12
            }
        }
        let current =
            storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle
        guard current?.minimumLineHeight != ps.minimumLineHeight else { return }
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    /// 다중 행 수식 그룹용 — 문단별 최소 줄 높이를 **직접** 지정한다 (이슈 #20).
    /// 그룹 총 박스 높이를 문단 수로 나눈 값을 호출부가 계산해 넣는다.
    private func updateGroupLineHeight(_ raw: CGFloat?, in paragraph: NSRange) {
        guard let storage = textStorage, paragraph.length > 0,
            paragraph.location < storage.length,
            let ps = (styleAttributes(for: raw == nil ? blockInfo(in: paragraph).block : .math,
                checked: blockInfo(in: paragraph).checked)[.paragraphStyle]
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        if let raw { ps.minimumLineHeight = raw }
        if raw == nil {
            if let align = storage.attribute(.purloryAlign, at: paragraph.location, effectiveRange: nil) as? String {
                ps.alignment = align == "right" ? .right : .center
            }
            if let spacing = storage.attribute(.purloryLineSpacing, at: paragraph.location, effectiveRange: nil) as? Double {
                ps.minimumLineHeight = 0; ps.maximumLineHeight = 0
                ps.lineSpacing = CGFloat(spacing)
            }
        }
        let current =
            storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle
        guard current?.isEqual(ps) != true else { return }
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    /// loc가 속한 다중 행 수식 그룹의 storage 범위 — 드래그 이동·히트 판정용.
    /// 단독 완결 수식이면 nil (그룹 이동 대상이 아니다).
    func mathGroup(containing loc: Int) -> NSRange? {
        _ = indexedMediaParagraphs(in: NSRange(location: 0, length: 0))
        guard let run = mediaParagraphIndex?.mathRun(containing: loc) else { return nil }
        let paragraphs = indexedMediaParagraphs(in: run).map {
            (range: $0.range, block: $0.record.block, open: $0.record.open, close: $0.record.close)
        }
        return Self.mathGroupRanges(paragraphs, requireContiguousRanges: true).first { NSLocationInRange(loc, $0) }
    }

    // MARK: 수식 객체 복사 (이슈 #22)

    /// 우클릭 메뉴가 대상으로 삼는 수식 문단 위치 — 메뉴 표시 직전에 세팅된다.
    private var mathActionLocation: Int?

    /// loc의 수식 LaTeX 원문 — 단독 완결은 문단 내용이고, 그룹이면 구분자 줄을
    /// 걷어내고 내용 줄만 개행으로 합친다 (#22).
    func mathSource(at loc: Int) -> String? {
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let para = ns.paragraphRange(
            for: NSRange(location: min(loc, ns.length), length: 0))
        guard blockInfo(in: para).block == .math else { return nil }
        if let group = mathGroup(containing: para.location) {
            var lines: [String] = []
            var scanLoc = group.location
            while scanLoc < min(group.upperBound, ns.length) {
                let p = ns.paragraphRange(for: NSRange(location: scanLoc, length: 0))
                scanLoc = p.upperBound
                guard blockInfo(in: p).block == .math else { continue }
                var line = paragraphContent(p)
                if line == "$$" { continue }  // 열기/닫기 구분자 줄
                if line.hasSuffix("$$") { line.removeLast(2) }  // 닫기가 붙어 있는 줄
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
        // 단독 완결 수식 — 저장 내용이 곧 LaTeX (직렬화 때 $$를 덧입힌다).
        return paragraphContent(para)
    }

    private func renderedMathImage(at loc: Int, latex: String) -> NSImage? {
        mathRenders.first { $0.range.location <= loc && $0.range.upperBound > loc }?.image
            ?? MathRenderer.image(latex: latex, color: palette.ink, fontSize: mathFontSize)
    }

    @objc private func copyMathLatex(_ sender: AnyObject?) {
        guard let loc = mathActionLocation, let latex = mathSource(at: loc) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latex, forType: .string)
    }

    @objc private func copyMathImage(_ sender: AnyObject?) {
        guard let loc = mathActionLocation,
            let latex = mathSource(at: loc),
            let image = renderedMathImage(at: loc, latex: latex)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func copyMathPDF(_ sender: AnyObject?) {
        guard let loc = mathActionLocation,
            let latex = mathSource(at: loc),
            let image = renderedMathImage(at: loc, latex: latex),
            let pdf = MathRenderer.pdfData(from: image)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pdf, forType: .pdf)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let layoutManager, let textContainer {
            let containerPoint = NSPoint(
                x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let index = layoutManager.characterIndex(
                for: containerPoint, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)
            let ns = string as NSString
            if ns.length > 0 {
                let para = ns.paragraphRange(
                    for: NSRange(location: min(index, ns.length), length: 0))
                if blockInfo(in: para).block == .math,
                    let latex = mathSource(at: para.location), !latex.isEmpty
                {
                    mathActionLocation = para.location
                    let menu = NSMenu(title: "수식")
                    menu.addItem(withTitle: "LaTeX 복사", action: #selector(copyMathLatex(_:)), keyEquivalent: "")
                    menu.addItem(withTitle: "이미지 복사", action: #selector(copyMathImage(_:)), keyEquivalent: "")
                    menu.addItem(withTitle: "PDF로 복사", action: #selector(copyMathPDF(_:)), keyEquivalent: "")
                    menu.addItem(.separator())
                    if let base = super.menu(for: event) {
                        for item in base.items { menu.addItem(item.copy() as! NSMenuItem) }
                    }
                    return menu
                }
            }
        }
        return super.menu(for: event)
    }

    /// 폭이 바뀌면 수식·이미지 축소 배율이 달라진다 — 줄 높이를 다시 맞춘다.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            let inset = editorialWorkspaceStyle
                ? EditorMetrics.workspaceSideInset(forWidth: newSize.width, windowWidth: window?.frame.width ?? 640)
                : EditorMetrics.sideInset(forWidth: newSize.width)
            if abs(textContainerInset.width - inset) > 0.5 {
                textContainerInset = NSSize(width: inset, height: textContainerInset.height)
            }
        }
        workspaceInteraction?.layoutDidChange()
        guard widthChanged else { return }
        // 폭이 바뀌면 수식·이미지 축소 배율이 달라진다 — 줄 높이를 다시 맞춘다.
        if !mathRenders.isEmpty || !imageRenders.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.refreshRenderedBlocks() }
        }
    }

    // MARK: 서식 툴바 (선택 위 플로팅)

    private var toolbarHost: NSHostingView<SelectionToolbarView>?
    private(set) var workspaceSelectionPanel: NSPanel?
    private var toolbarShowTask: Task<Void, Never>?
    /// 이미지 객체 선택 시 뜨는 정렬·크기·줄바꿈 툴바 (요구 3).
    private var imageToolbarHost: NSHostingView<ImageObjectToolbarView>?
    /// alt·title 편집 카드 호스트 — 툴바와 함께 수명을 관리한다 (이슈 #14).
    private var imageAltEditorHost: NSHostingView<ImageAltEditorView>?

    /// 선택이 생기면 잠깐 안정된 뒤 툴바를 띄우고, 사라지면 감춘다.
    func updateSelectionToolbar() {
        toolbarShowTask?.cancel()
        let sel = selectedRange()
        // 공백만 있는(단어 삭제용 같은) 사소한 선택이나 IME 조합 중이면 띄우지 않는다.
        let selected = sel.length > 0 ? (string as NSString).substring(with: sel) : ""
        guard sel.length > 0, !hasMarkedText(),
            !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            hideSelectionToolbar()
            return
        }
        // 드래그 중 깜빡임 방지 — 선택이 멈춘 뒤에 띄우되, 지연은 짧게(120ms)해 굼떠
        // 보이지 않게 한다.
        toolbarShowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.presentSelectionToolbar()
        }
    }

    func hideSelectionToolbar() {
        toolbarShowTask?.cancel()
        if let panel = workspaceSelectionPanel {
            workspaceSelectionPanel = nil
            panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close()
        }
        toolbarHost?.removeFromSuperview()
    }

    private func presentSelectionToolbar() {
        guard isEditable, !hasMarkedText() else { hideSelectionToolbar(); return }
        guard let layoutManager, let textContainer else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let ns = string as NSString
        var trimmedSel = sel
        while trimmedSel.length > 0 {
            let ch = ns.character(at: trimmedSel.upperBound - 1)
            if ch == 0x0A || ch == 0x0D || ch == 0x2028 {
                trimmedSel.length -= 1
            } else {
                break
            }
        }
        guard trimmedSel.length > 0 else { hideSelectionToolbar(); return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: trimmedSel, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let view = SelectionToolbarView(
            theme: palette, state: currentSelectionState(), onAction: { [weak self] action in self?.perform(action) },
            onPolish: workspaceInteraction.map { interaction in { [weak interaction] in interaction?.polishSelection() } })
        let host: NSHostingView<SelectionToolbarView>
        if let existing = toolbarHost {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            toolbarHost = host
        }
        let size = host.fittingSize
        if editorialWorkspaceStyle, let window {
            // A fixed source popover crosses tile boundaries instead of being clipped by a column.
            let anchor = window.convertToScreen(convert(rect, to: nil))
            let screen = window.screen?.visibleFrame ?? window.frame
            let panel = workspaceSelectionPanel ?? WorkspaceSelectionPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let appeared = workspaceSelectionPanel == nil
            panel.becomesKeyOnlyIfNeeded = true
            panel.initialFirstResponder = nil
            panel.title = "선택 서식"; panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = true; panel.level = .floating
            panel.contentView = host; panel.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            if appeared {
                let point = CGPoint(x: min(screen.maxX - size.width - 8, max(screen.minX + 8, anchor.midX - size.width / 2)),
                    y: min(screen.maxY - size.height - 8, anchor.maxY + 8))
                panel.setFrameOrigin(.init(x: point.x, y: point.y - 4))
                window.addChildWindow(panel, ordered: .above)
                panel.alphaValue = 0.01
                panel.orderFront(nil)
                panel.makeFirstResponder(nil)
                WorkspaceHTMLStyle.animate(0.22) { panel.animator().alphaValue = 1; panel.animator().setFrameOrigin(point) }
            } else if !panel.isKeyWindow {
                panel.makeFirstResponder(nil)
            }
            workspaceSelectionPanel = panel
            return
        }
        // 이미 떠 있으면 위치를 고정한다 — 글자 크기를 줄이면 선택 rect가 움직여
        // 툴바가 따라다니며 연타를 방해했다. 한번 뜬 툴바는 선택이 사라질 때까지
        // 그 자리(상단 중앙 기준)에 머문다 (요구 3).
        if host.superview === self {
            let old = host.frame
            host.frame = NSRect(
                x: old.midX - size.width / 2, y: old.minY,
                width: size.width, height: size.height)
            return
        }
        // 선택 위 중앙 — 문서 맨 위라 걸리면 선택 아래로 내린다 (flipped 좌표).
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = rect.maxY + 8 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        host.frame = NSRect(origin: origin, size: size)
        addSubview(host)
        if editorialWorkspaceStyle && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            host.alphaValue = 0; host.frame.origin.y += 4
            WorkspaceHTMLStyle.animate(0.22) {
                host.animator().alphaValue = 1; host.animator().setFrameOrigin(origin)
            }
        }
    }

    func currentSelectionState() -> SelectionStyleState {
        var state = SelectionStyleState()
        guard let storage = textStorage else { return state }
        let sel = selectedRange()
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        state.block = blockInfo(in: para).block
        // 줄 간격은 문단 단위 — 선택 시작 문단의 저장값(없으면 전역 설정) 기준.
        state.lineSpacing =
            (para.location < storage.length
                ? storage.attribute(.purloryLineSpacing, at: para.location, effectiveRange: nil)
                    as? Double : nil) ?? Double(lineSpacing)
        let attrs = sel.location < storage.length
            ? storage.attributes(at: sel.location, effectiveRange: nil) : typingAttributes
        state.bold = attrs[.purloryBold] as? Bool == true
        state.italic = attrs[.purloryItalic] as? Bool == true
        state.strikethrough = attrs[.purloryStrikethrough] as? Bool == true
        state.highlight = attrs[.purloryHighlight] as? Bool == true
        state.code = attrs[.purloryCode] as? Bool == true
        state.align = attrs[.purloryAlign] as? String
        state.colorHex = attrs[.purloryColor] as? String
        state.fontSize =
            (attrs[.purloryFontSize] as? Double)
            ?? Double((attrs[.font] as? NSFont ?? bodyFont).pointSize)
        return state
    }

    /// 툴바 액션 실행 — 끝나면 포커스를 에디터로 되돌리고 하이라이트를 갱신한다.
    func perform(_ action: SelectionToolbarAction) {
        switch action {
        case .toggleBold: toggleInlineStyle(.purloryBold)
        case .toggleItalic: toggleInlineStyle(.purloryItalic)
        case .toggleStrikethrough: toggleInlineStyle(.purloryStrikethrough)
        case .toggleHighlight: toggleInlineStyle(.purloryHighlight)
        case .toggleCode: toggleInlineStyle(.purloryCode)
        case .insertLink: insertMarkdownLinkAtSelection()
        case .color(let hex): applyInlineColor(hex)
        case .fontSize(let size): applyInlineFontSize(size)
        case .lineSpacing(let v): applyLineSpacing(v)
        case .align(let align): applyAlignment(align)
        case .block(let block): convertSelectionBlock(to: block)
        }
        workspaceSelectionPanel?.makeFirstResponder(nil)
        if let window, !window.isKeyWindow { window.makeKey() }
        window?.makeFirstResponder(self)
        presentSelectionToolbar()
    }

    /// 선택 범위를 `[선택](https://)` 마크다운 링크로 감싸고 URL 자리를 선택한다.
    public func insertMarkdownLinkAtSelection() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let sel = selectedRange()
        let ns = storage.string as NSString
        let label = sel.length > 0 ? ns.substring(with: sel) : "링크"
        guard !label.contains("\n") else { return }
        let pasteboardURL: String? = {
            guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                raw.hasPrefix("https://") || raw.hasPrefix("http://"),
                !raw.contains(where: { $0.isWhitespace })
            else { return nil }
            return raw
        }()
        let urlPart = pasteboardURL ?? "https://"
        let replacement = "[\(label)](\(urlPart))"
        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        isTransforming = true
        storage.replaceCharacters(in: sel, with: replacement)
        let insertedRange = NSRange(location: sel.location, length: (replacement as NSString).length)
        redecorateParagraphs(in: insertedRange)
        isTransforming = false
        didChangeText()
        let urlStart = sel.location + 1 + (label as NSString).length + 2
        let urlLen = (urlPart as NSString).length
        setSelectedRange(NSRange(location: urlStart, length: urlLen))
    }

    /// 선택 범위의 인라인 속성 토글 — 전체가 켜져 있으면 끄고, 아니면 켠다.
    func toggleInlineStyle(_ key: NSAttributedString.Key) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        var allOn = true
        storage.enumerateAttribute(key, in: sel, options: []) { value, _, stop in
            if (value as? Bool) != true {
                allOn = false
                stop.pointee = true
            }
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        isTransforming = true
        if allOn {
            storage.removeAttribute(key, range: sel)
        } else {
            storage.addAttribute(key, value: true, range: sel)
            if key == .purloryCode {
                // 인라인 코드는 배타 — 굵게·기울임·취소선·하이라이트·색과 겹치지 않는다.
                storage.removeAttribute(.purloryBold, range: sel)
                storage.removeAttribute(.purloryItalic, range: sel)
                storage.removeAttribute(.purloryStrikethrough, range: sel)
                storage.removeAttribute(.purloryHighlight, range: sel)
                storage.removeAttribute(.purloryColor, range: sel)
            }
        }
        redecorateParagraphs(in: sel)
        isTransforming = false
        didChangeText()
    }

    /// 선택 범위 글자색 적용 (nil = 기본 잉크색으로 복원).
    func applyInlineColor(_ hex: String?) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        isTransforming = true
        if let hex {
            storage.addAttribute(.purloryColor, value: hex, range: sel)
        } else {
            storage.removeAttribute(.purloryColor, range: sel)
        }
        redecorateParagraphs(in: sel)
        isTransforming = false
        didChangeText()
    }

    /// 선택 범위 글자 크기 적용 — 블록 기본 크기와 같아지면 속성을 제거한다
    /// (저장 마크다운에 불필요한 `<font size>` 래퍼를 남기지 않는다).
    func applyInlineFontSize(_ size: Double) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let info = blockInfo(in: para)
        let baseSize =
            (styleAttributes(
                for: info.block, checked: info.checked,
                indent: info.indent)[.font] as? NSFont)?
            .pointSize ?? bodyFont.pointSize
        isTransforming = true
        if abs(CGFloat(size) - baseSize) < 0.5 {
            storage.removeAttribute(.purloryFontSize, range: sel)
        } else {
            storage.addAttribute(.purloryFontSize, value: size, range: sel)
        }
        redecorateParagraphs(in: sel)
        isTransforming = false
        didChangeText()
    }

    /// 선택이 걸친 문단들의 정렬 지정 (nil = 왼쪽 기본).
    /// 저장은 .p 문단만 지원 — 다른 블록에선 화면 정렬만 바뀐다.
    func applyAlignment(_ align: String?) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let ns = string as NSString
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            if para.length > 0, para.location < storage.length {
                _ = shouldChangeText(in: para, replacementString: nil)
                isTransforming = true
                if let align {
                    storage.addAttribute(.purloryAlign, value: align, range: para)
                } else {
                    storage.removeAttribute(.purloryAlign, range: para)
                }
                let info = blockInfo(in: para)
                applyBlock(
                    info.block, checked: info.checked, marker: info.marker,
                    indent: info.indent, codeLang: info.codeLang,
                    to: para, registerUndo: false)
                isTransforming = false
                didChangeText()
            }
            location = para.upperBound
        } while location < sel.upperBound
    }

    /// 선택이 걸친 문단들의 줄 간격(pt)을 지정한다 — 선택 줄에 한해 (요구 4).
    /// 표시 전용 속성(.purloryLineSpacing)이라 마크다운엔 저장되지 않는다.
    func applyLineSpacing(_ value: Double) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let ns = string as NSString
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            if para.length > 0, para.location < storage.length {
                _ = shouldChangeText(in: para, replacementString: nil)
                isTransforming = true
                storage.addAttribute(.purloryLineSpacing, value: value, range: para)
                let info = blockInfo(in: para)
                applyBlock(
                    info.block, checked: info.checked, marker: info.marker,
                    indent: info.indent, codeLang: info.codeLang,
                    to: para, registerUndo: false)
                isTransforming = false
                didChangeText()
            }
            location = para.upperBound
        } while location < sel.upperBound
    }

    /// 선택이 걸친 문단들을 블록으로 전환 — 이미 그 블록이면 본문으로 토글.
    func convertSelectionBlock(to target: PurloryBlock) {
        let sel = selectedRange()
        let ns = string as NSString
        let firstPara = ns.paragraphRange(
            for: NSRange(location: min(sel.location, ns.length), length: 0))
        let resolved: PurloryBlock = blockInfo(in: firstPara).block == target ? .p : target
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            let current = blockInfo(in: para)
            let keepIndent = [.bullet, .number, .todo, .quote].contains(resolved) ? current.indent : 0
            applyBlock(resolved, indent: keepIndent, to: para)
            location = para.upperBound
        } while location < sel.upperBound
        refreshRenderedBlocks()
    }

    /// 범위에 걸친 문단들을 다시 장식 (블록 기본 + 인라인 조립, undo 미등록).
    private func redecorateParagraphs(in range: NSRange) {
        let ns = string as NSString
        var location = range.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            let info = blockInfo(in: para)
            applyBlock(
                info.block, checked: info.checked, marker: info.marker,
                indent: info.indent, codeLang: info.codeLang,
                to: para, registerUndo: false)
            location = para.upperBound
        } while location < range.upperBound
    }

    /// ⌘F 검색 · ⌘G 다음/이전 매치 · ⌘B/⌘I 서식 토글(선택 있을 때만).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        // 한글 입력기에선 charactersIgnoringModifiers가 자모("ㄹ")를 돌려줘 문자
        // 비교가 조용히 실패한다 — ⌘F를 눌러도 찾기 바가 안 뜨던 버그. 레이아웃
        // 무관한 물리 keyCode(F=3 · G=5)로 함께 판정한다.
        let code = event.keyCode
        // 서식·이미지 단축키는 메뉴 막대(PurloryCommands)로 옮겨 단일 소스로 관리한다 —
        // 여기선 문서 내 검색만 처리한다.
        if flags == .command {
            if key == "f" || code == 3 {
                performFind(.showFindInterface)
                return true
            }
            if key == "g" || code == 5 {
                performFind(.nextMatch)
                return true
            }
        } else if flags == [.command, .shift], key == "g" || code == 5 {
            performFind(.previousMatch)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // 메뉴(보기 ▸ 문서에서 찾기)용 리스폰더 체인 진입점 — 단축키가 IME 사정으로
    // 뷰에 닿지 못해도 메뉴 경로로는 항상 열리게 한다.
    @objc func purloryFindInDocument(_ sender: Any?) { performFind(.showFindInterface) }
    @objc func purloryFindNext(_ sender: Any?) { performFind(.nextMatch) }
    @objc func purloryFindPrevious(_ sender: Any?) { performFind(.previousMatch) }

    // MARK: 메뉴 명령 (리스폰더 체인 — PurloryCommands가 NSApp.sendAction으로 호출)
    //
    // 선택이 있으면 선택에, 없으면 커서 문단에 적용된다(convert/align은 문단 단위,
    // toggleInlineStyle은 선택이 있어야 동작). 에디터가 first responder일 때만 도달한다.

    @objc func purloryFormatBold(_ sender: Any?) { toggleInlineStyle(.purloryBold) }
    @objc func purloryFormatItalic(_ sender: Any?) { toggleInlineStyle(.purloryItalic) }
    @objc func purloryFormatStrikethrough(_ sender: Any?) { toggleInlineStyle(.purloryStrikethrough) }
    @objc func purloryFormatHighlight(_ sender: Any?) { toggleInlineStyle(.purloryHighlight) }
    @objc func purloryFormatCode(_ sender: Any?) { toggleInlineStyle(.purloryCode) }
    @objc func purloryFormatLink(_ sender: Any?) { insertMarkdownLinkAtSelection() }
    @objc func purloryHeading1(_ sender: Any?) { convertSelectionBlock(to: .h1) }
    @objc func purloryHeading2(_ sender: Any?) { convertSelectionBlock(to: .h2) }
    @objc func purloryHeading3(_ sender: Any?) { convertSelectionBlock(to: .h3) }
    @objc func purloryHeading4(_ sender: Any?) { convertSelectionBlock(to: .h4) }
    @objc func purloryHeading5(_ sender: Any?) { convertSelectionBlock(to: .h5) }
    @objc func purloryHeading6(_ sender: Any?) { convertSelectionBlock(to: .h6) }
    @objc func purloryBodyText(_ sender: Any?) { convertSelectionBlock(to: .p) }
    @objc func purloryBulletList(_ sender: Any?) { convertSelectionBlock(to: .bullet) }
    @objc func purloryNumberedList(_ sender: Any?) { convertSelectionBlock(to: .number) }
    @objc func purloryQuoteBlock(_ sender: Any?) { convertSelectionBlock(to: .quote) }
    @objc func purloryCodeBlock(_ sender: Any?) { convertSelectionBlock(to: .code) }
    @objc func purloryAlignLeft(_ sender: Any?) { applyAlignment(nil) }
    @objc func purloryAlignCenter(_ sender: Any?) { applyAlignment("center") }
    @objc func purloryAlignRight(_ sender: Any?) { applyAlignment("right") }
    @objc func purloryMoveParagraphUp(_ sender: Any?) { moveCurrentParagraph(direction: -1) }
    @objc func purloryMoveParagraphDown(_ sender: Any?) { moveCurrentParagraph(direction: 1) }
    @objc func purloryToggleSourceMode(_ sender: Any?) { setSourceMode(!isSourceMode) }

    /// 마크다운 원문 모드 전환 (⌘/) — 현재 문서를 직렬화한 뒤 원문/블록 뷰로 다시 로드한다.
    public func setSourceMode(_ enabled: Bool) {
        guard !hasMarkedText(), isSourceMode != enabled else { return }
        let markdown = serialize()
        load(markdown: markdown, sourceMode: enabled)
        didChangeText()
    }

    /// 현재 커서 문단을 위(-1) 또는 아래(+1) 문단과 맞바꾼다 (⌥↑ / ⌥↓).
    public func moveCurrentParagraph(direction: Int) {
        guard !hasMarkedText() else { return }
        let raw = serialize()
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return }
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        var currentLineIndex = 0
        if caret > 0 {
            let prefix = ns.substring(to: caret)
            currentLineIndex = prefix.utf16.filter { $0 == 0x0A }.count
        }
        guard currentLineIndex >= 0, currentLineIndex < lines.count else { return }
        let targetIndex = currentLineIndex + direction
        guard targetIndex >= 0, targetIndex < lines.count else { return }
        lines.swapAt(currentLineIndex, targetIndex)
        let updated = lines.joined(separator: "\n")
        load(markdown: updated)
        let newNS = string as NSString
        var targetLoc = 0
        var lineIdx = 0
        while lineIdx < targetIndex && targetLoc < newNS.length {
            let para = newNS.paragraphRange(for: NSRange(location: targetLoc, length: 0))
            targetLoc = para.upperBound
            lineIdx += 1
        }
        setSelectedRange(NSRange(location: min(targetLoc, newNS.length), length: 0))
        didChangeText()
    }

    /// NSTextFinder 액션 실행 — performTextFinderAction은 sender의 tag로 동작을 읽는다.
    var workspaceFind: ((NSTextFinder.Action) -> Bool)?
    private func performFind(_ action: NSTextFinder.Action) {
        if workspaceFind?(action) == true { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    // MARK: 커서 펄스 · 리플 · 커서 줄 하이라이트 드로잉

    /// 캐럿은 본문 픽셀에 직접 그리지 않는다 — 레거시 캐럿 드로잉도, 시스템
    /// `NSTextInsertionIndicator`도 이 macOS에서 페이드 블링크 중 커서가
    /// 이동하면 사라지던 잔상을 남긴다. 대신 우리가 소유한 단일 NSView를
    /// 캐럿으로 쓴다: 뷰가 하나뿐이고 블링크 애니메이션도 그 뷰의 레이어에만
    /// 붙으므로, 프레임을 옮기면 페이드 중이던 픽셀까지 통째로 따라와
    /// 잔상이 구조적으로 불가능하다.
    /// 이 오버라이드는 시스템 캐럿을 비활성화하는 스위치 역할만 한다.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    /// 클릭을 통과시키는 장식 뷰 — 줄 하이라이트 밴드는 줄 전체 폭이라, hitTest를
    /// 막지 않으면 그 줄의 텍스트 클릭·선택이 통째로 밴드에 먹힌다.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// One translucent background for the active paragraph, below other overlays.
    private lazy var activeLineView: PassthroughView = {
        let view = PassthroughView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.isHidden = true
        // 다른 오버레이(캐럿·이미지 박스) 밑으로 — 서브뷰 맨 아래에 깐다.
        addSubview(view, positioned: .below, relativeTo: nil)
        return view
    }()

    /// Ordinary editing has no persistent paragraph background.
    private func syncActiveLineView() {
        // Source-navigation flashes are drawn by the workspace; ordinary editing
        // shows only the caret, without a persistent paragraph background.
        activeLineView.isHidden = true
    }

    /// 우리가 소유한 캐럿 뷰. 표시 조건·위치는 `syncCaretView()`가 담당.
    private lazy var caretView: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 1
        view.isHidden = true
        addSubview(view)
        return view
    }()

    /// 자체 블링크 타이머 — 시스템 블링크 대신 캐럿 뷰의 alpha를 페이드한다.
    private var caretBlinkTimer: Timer?

    /// AppKit이 캐럿 상태를 갱신하는 모든 시점(커서 이동·포커스 변화·블링크
    /// 재시작)에 캐럿 뷰·커서 줄 하이라이트를 함께 맞춘다 — 선택 변경 알림이
    /// 오지 않는 경로까지 덮는 안전망.
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        scheduleEditingOverlayRefresh(restartBlink: restartFlag)
    }

    /// 줄바꿈 폭 변경 등 재배치 후에도 캐럿 뷰·하이라이트가 글자를 따라가게 한다.
    override func layout() {
        super.layout()
        refreshActiveLineHighlight(restartBlink: false)
    }

    /// 캐럿 뷰를 현재 커서 위치·테마 색에 맞추고 블링크를 처음부터 다시 시작한다.
    ///
    /// 높이: 시스템 캐럿 rect는 라인 전체를 덮어 글자 위로 떠 보인다. 베이스라인
    /// 위 "글자 실제 높이"만큼만 잡아 글자에 딱 맞춘다. 라틴 capHeight로 자르면
    /// 한글보다 짧아 보이므로 capHeight~ascender 사이로 올려 한글 상단까지 덮는다.
    /// 이미지가 객체로 선택된 동안엔 숨긴다 — 이미지 내부는 편집 대상이 아니라
    /// 조작 대상이므로 커서가 보이면 혼란스럽다.
    private func syncCaretView(restartBlink: Bool) {
        let visible =
            window?.firstResponder === self
            && selectedRange().length == 0
            && selectedImageLocation == nil
        guard visible, let line = caretLineGeometry(), let rect = caretRectInView() else {
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            caretView.isHidden = true
            return
        }
        let font = caretLineFont()
        let baseline = line.baselineY
        let glyphTop = font.capHeight + (font.ascender - font.capHeight) * 0.4
        var caret = rect
        caret.origin.y = baseline - glyphTop
        caret.size.height = max(1, glyphTop - font.descender)  // descender 음수
        caret.size.width = 2  // firstRect의 캐럿 폭은 0 — 얇은 표준 폭으로.
        let moved = caretView.isHidden || caretView.frame != caret
        // A typing frame must never inherit a surrounding SwiftUI/AppKit animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if caretView.layer?.backgroundColor != insertionPointColor.cgColor {
                caretView.layer?.backgroundColor = insertionPointColor.cgColor
            }
            if caretView.frame != caret { caretView.frame = caret }
            if caretView.isHidden { caretView.isHidden = false }
        }
        if restartBlink || moved || caretBlinkTimer == nil { restartCaretBlink() }
    }

    /// 블링크를 "보임" 상태부터 다시 시작한다 — 타이핑·이동 중엔 캐럿이
    /// 항상 또렷하게 보이고, 멈춘 뒤부터 부드럽게 깜빡인다.
    private func restartCaretBlink() {
        caretBlinkTimer?.invalidate()
        caretView.layer?.removeAllAnimations()
        caretView.alphaValue = 1
        caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target: CGFloat = self.caretView.alphaValue > 0.5 ? 0 : 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    self.caretView.animator().alphaValue = target
                }
            }
        }
    }

    /// 커서가 놓인 줄의 폰트 — 캐럿·하이라이트가 공유하는 메트릭 소스.
    private func caretLineFont() -> NSFont {
        if hasMarkedText(), let storage = textStorage, storage.length > 0 {
            let index = min(max(markedRange().location, selectedRange().location - 1), storage.length - 1)
            if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
        }
        return (typingAttributes[.font] as? NSFont) ?? bodyFont
    }

    // MARK: 대화 기록 제안 렌더 (요구사항 §20)

    /// 제안 중인 대화 블록 범위 (스토리지 좌표) — nil이면 표시 없음.
    private var conversationPromptRange: NSRange?

    /// 인라인 pill — 「이 대화를 기록할까요?」. 모달·팝업 금지 (요구사항 §20):
    /// 캐럿 뷰와 같은 자기 소유 서브뷰 하나로, 대화 끝자락에 조용히 놓인다.
    private lazy var conversationPromptView: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = PurloryFonts.ui(10.5, weight: .medium)
        label.wantsLayer = true
        label.layer?.cornerRadius = 9
        label.layer?.borderWidth = 1
        label.alignment = .center
        label.isHidden = true
        addSubview(label)
        return label
    }()

    /// 제안 표시/숨김 — 컨트롤러의 conversationSuggestionDidChange가 부른다.
    func showConversationPrompt(_ range: NSRange?) {
        conversationPromptRange = range.flatMap {
            $0.location + $0.length <= (string as NSString).length ? $0 : nil
        }
        layoutConversationPrompt()
        needsDisplay = true
    }

    /// pill을 대화 마지막 줄 끝 아래에 놓는다 — 화면을 흔들지 않는다 (§3 조용한 UI).
    private func layoutConversationPrompt() {
        guard let range = conversationPromptRange,
            let layoutManager, let textContainer
        else {
            conversationPromptView.isHidden = true
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else {
            conversationPromptView.isHidden = true
            return
        }
        let bounding = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let label = conversationPromptView
        label.stringValue = "  이 대화를 기록할까요?  ⏎ 기록 · esc 닫기  "
        label.textColor = palette.novel
        label.layer?.backgroundColor = palette.pill.cgColor
        label.layer?.borderColor = palette.pillBorder.cgColor
        label.sizeToFit()
        var frame = label.frame
        frame.size.height += 6
        frame.origin.x = min(
            bounding.maxX + origin.x - frame.width,
            bounds.width - frame.width - textContainerInset.width)
        frame.origin.x = max(frame.origin.x, origin.x + 4)
        frame.origin.y = bounding.maxY + origin.y + 4
        label.frame = frame
        label.isHidden = false
    }

    /// 블록 전체의 아주 약한 배경 하이라이트 — draw(_:)가 본문 아래에 깐다.
    private func drawConversationHighlight(in dirtyRect: NSRect) {
        guard let range = conversationPromptRange,
            let layoutManager, let textContainer
        else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let origin = textContainerOrigin
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer
        ) { rect, _ in
            let shifted = rect.offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -3, dy: -1)
            guard shifted.intersects(dirtyRect) else { return }
            self.palette.novel.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: shifted, xRadius: 5, yRadius: 5).fill()
        }
    }

    // MARK: 고스트 렌더

    /// AI 제안을 **즉시** 표시한다 (#27 모션 감사). 과거엔 150ms 페이드인을
    /// 12ms redraw 루프로 그렸는데, 제안 하나마다 메인 액터가 12회 다시 그려졌고
    /// 첫 글자 지연 예산(PLAN §10)을 깎아 먹었다. "고스트는 조용히"의 정답은
    /// 모션이 아니라 침묵이다 — 나타나고, 거절되면 흔적 없이 사라진다.
    private func startGhostFadeIn() {
        ghostFadeTask?.cancel()
        ghostOpacity = 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The single activeLineView covers the active paragraph and clears its
        // old frame atomically when selection or layout changes.

        // 드래그 선택 영역 — 시스템 사각 하이라이트 대신 줄별 라운드 사각형을
        // 본문 아래에 깔아 그린다 (우리식 드래그 표시, 테마 selection 토큰).
        drawSelectionHighlight(in: dirtyRect)

        // 대화 기록 제안 중인 블록의 은은한 하이라이트 (요구사항 §20).
        drawConversationHighlight(in: dirtyRect)

        workspaceInteraction?.drawBackground(dirtyRect)

        super.draw(dirtyRect)
        // TextKit has now drawn the final glyph layout, including first-character
        // fallback fonts and the empty-to-nonempty paragraph transition.
        refreshActiveLineHighlight(restartBlink: false)
        workspaceInteraction?.draw(dirtyRect)

        // 이미지 이동 드래그 중 드롭 위치 표시선 (요구 B).
        if let y = imageDropIndicatorY {
            let inset = textContainerInset.width
            palette.blue.setFill()
            NSRect(x: inset, y: y - 1, width: bounds.width - inset * 2, height: 2).fill()
        }

        guard let ghost = ghostText, !ghost.isEmpty,
            !hasMarkedText(),
            selectedRange().length == 0,
            let caretRect = caretRectInView()
        else { return }

        // 커서 문단의 실제 폰트로 그린다 — 제목 줄에서도 크기가 맞는다.
        let font = (typingAttributes[.font] as? NSFont) ?? bodyFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.ghostSuggestion.withAlphaComponent(ghostOpacity),
        ]
        // 프래그먼트 top(caretRect.minY)이 아니라 본문 글리프와 같은
        // 베이스라인에 맞춰야 실제 글자 높이와 일치한다 (줄 간격과 무관하게).
        let y = caretBaselineY().map { $0 - font.ascender } ?? caretRect.minY
        let attributed = NSAttributedString(string: ghost, attributes: attributes)
        let containerWidth = textContainer?.size.width ?? bounds.width
        // 커서 오른쪽 남은 폭 — 줄 끝·좁은 창에서 클리핑되지 않게 (#24).
        let inlineAvailable = containerWidth - caretRect.maxX + textContainerOrigin.x
        if Self.ghostFitsInline(
            textWidth: attributed.size().width, availableWidth: inlineAvailable)
        {
            attributed.draw(at: NSPoint(x: caretRect.maxX, y: y))
            return
        }
        // 줄바꿈 — 다음 줄 시작(컨테이너 좌측)에서 최대 3줄로 감싸 그린다.
        let wrappedWidth = max(120, containerWidth)
        var bounding = attributed.boundingRect(
            with: NSSize(width: wrappedWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        bounding.size.height = min(bounding.height, CGFloat(Self.ghostMaxLines) * lineHeight)
        // NSTextView/TextKit view coordinates are flipped (Y grows downward).  The old
        // code subtracted a line height from the current glyph top, which moved wrapped
        // Ghost text upward.  Anchor the overlay to the actual current TextKit line
        // fragment and start at its maxY: that is the next visual line boundary and it
        // naturally includes heading/paragraph spacing and extra-line-fragment geometry.
        let wrappedY = Self.ghostWrappedOriginY(
            currentLineFragment: caretLineFragmentRectInView(),
            caretRect: caretRect,
            fallbackLineHeight: lineHeight)
        attributed.draw(
            with: NSRect(
                x: textContainerOrigin.x + 2, y: wrappedY,
                width: wrappedWidth, height: bounding.height),
            options: [.usesLineFragmentOrigin])
    }

    /// Whether the Ghost suggestion still fits to the right of the caret.
    nonisolated static func ghostFitsInline(textWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        textWidth <= availableWidth && availableWidth > 0
    }

    /// Wrapped Ghost starts at the next visual line boundary in flipped view coordinates.
    ///
    /// The preferred input is an actual TextKit line fragment already converted into
    /// view coordinates.  The caret fallback keeps empty/unlaid-out editor states safe.
    nonisolated static func ghostWrappedOriginY(
        currentLineFragment: NSRect?,
        caretRect: NSRect,
        fallbackLineHeight: CGFloat
    ) -> CGFloat {
        if let currentLineFragment, currentLineFragment.height > 0 {
            return currentLineFragment.maxY
        }
        if caretRect.height > 0 {
            return caretRect.maxY
        }
        return caretRect.minY + max(0, fallbackLineHeight)
    }
    /// 줄바꿈 상한 줄 수 — 화면을 흔들지 않는 절제 (#24).
    nonisolated static let ghostMaxLines = 3

    // MARK: 고스트 접근성 (#24)

    /// VoiceOver 사용자에게만 조용한 알림 — 일반 사용자의 시각 흐름을 건드리지 않는다.
    func postGhostAnnouncement(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.low,
            ])
    }

    /// 제안 등장 안내 — 내용과 조작법을 함께 (완료 조건 1).
    func announceGhostAppearance(_ ghost: String) {
        postGhostAnnouncement("AI 제안: \(ghost.prefix(80)) — Tab으로 수락, Esc로 거절")
    }

    /// NSAccessibility 값 위트니스 — 셀렉터를 프로토콜과 맞춰 기본 구현을
    /// 대체한다(상위 클래스 선언이 없어 override는 불가). #24
    @objc(accessibilityValue)
    public func accessibilityValue() -> Any? {
        return ghostAwareAccessibilityValue()
    }

    /// 실제 조립 본체 — 위트니스와 테스트가 공유한다(모듈 내 자기 호출은
    /// 자기 선언으로 결정적 귀결된다). #24
    func ghostAwareAccessibilityValue() -> Any? {
        // 제안은 텍스트 영역 값의 일부로 노출 — VO가 읽고 복사할 수 있게 (#24).
        guard let snapshot = ghostSnapshotForAccessibility(), !hasMarkedText() else {
            return super.accessibilityValue()
        }
        let base = super.accessibilityValue() ?? ""
        return base + "\n[AI 제안 #\(snapshot.generation) · Tab 수락 · Esc 거절] "
            + snapshot.text
    }

    /// 선택 영역을 하나의 병합 실루엣으로 그린다 — 글자 주위를 살짝(3pt) 감싸는
    /// Purlory만의 민트 틴트 영역 + 헤어라인 테두리 (요구 4).
    ///
    /// 줄별 라운드 사각형을 개별로 그리거나 union하면 폭이 다른 줄의 접합부에
    /// 각 사각형의 코너가 돌출부·계단으로 남는다. 대신 줄 rect들을 하나의
    /// 폴리곤 경계로 만들어 시계 방향으로 한 번에 추적하고, 모든 꼭짓점(볼록·오목)을
    /// 탄젠트 아크로 둥글려 TextEdit·Notes처럼 연속된 윤곽을 얻는다. 무효화는
    /// refreshActiveLineHighlight의 lastSelectionRect(전체 폭 밴드)가 담당하므로
    /// 여기선 그리기만 한다.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting flag: Bool
    ) {
        let eventType = NSApp?.currentEvent?.type
        let isMouseSelection = flag
            || eventType == .leftMouseDragged
            || eventType == .leftMouseUp
            || eventType == .leftMouseDown
        if isMouseSelection, ranges.count == 1, let storage = textStorage {
            var r = ranges[0].rangeValue
            let ns = storage.string as NSString
            if r.length > 0, r.upperBound <= ns.length {
                let firstPara = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
                // 마우스 드래그가 한 줄(단일 문단) 안에서만 이루어졌는데 줄 끝 빈 공간을
                // 스쳤다는 이유로 뒤따르는 개행이 선택에 포함되면, 줄 끝 빈 공간이 잡히고
                // 삭제·입력 시 다음 줄까지 딸려 올라온다. 단일 문단 내 마우스 드래그에서는
                // 후행 개행을 선택에서 제외한다.
                if r.upperBound == firstPara.upperBound {
                    let lastChar = ns.character(at: r.upperBound - 1)
                    if lastChar == 0x0A || lastChar == 0x0D || lastChar == 0x2028 {
                        r.length -= 1
                    }
                }
            }
            super.setSelectedRanges([NSValue(range: r)], affinity: affinity, stillSelecting: flag)
            return
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
    }

    private func drawSelectionHighlight(in dirtyRect: NSRect) {
        let sel = selectedRange()
        guard sel.length > 0, let layoutManager, let textContainer, let storage = textStorage else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let origin = textContainerOrigin
        let ns = storage.string as NSString
        let unselected = NSRange(location: NSNotFound, length: 0)

        // 줄마다 개행 문자(\n, \r, U+2028)를 제외한 실제 글자 범위만 감싼다.
        // withinSelectedGlyphRange에 선택 범위를 그대로 넘기면 AppKit이 개행이 포함된 줄의
        // 사각형을 컨테이너 우측 끝까지(줄 끝 빈 공간 전체) 늘려 버리고, 문단 아래
        // paragraphSpacing까지 높이에 포함시켜 빈 공간이 잡히는 문제가 생긴다.
        var rawRects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphRange, _ in
            let lineChars = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            var subChars = NSIntersectionRange(sel, lineChars)
            while subChars.length > 0 {
                let ch = ns.character(at: subChars.upperBound - 1)
                if ch == 0x0A || ch == 0x0D || ch == 0x2028 {
                    subChars.length -= 1
                } else {
                    break
                }
            }
            guard subChars.length > 0 else { return }
            let subGlyphs = layoutManager.glyphRange(forCharacterRange: subChars, actualCharacterRange: nil)
            guard subGlyphs.length > 0 else { return }

            let font = (subChars.location < storage.length
                ? storage.attribute(.font, at: subChars.location, effectiveRange: nil) as? NSFont
                : nil) ?? self.bodyFont
            let baselineLocalY = lineRect.minY + layoutManager.location(forGlyphAt: subGlyphs.location).y
            let glyphTop = font.capHeight + (font.ascender - font.capHeight) * 0.45
            let topY = origin.y + baselineLocalY - glyphTop - 2
            let bottomY = origin.y + baselineLocalY - font.descender + 2

            var lineUnion: NSRect?
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: subGlyphs, withinSelectedGlyphRange: unselected, in: textContainer
            ) { rect, _ in
                guard rect.width > 0 else { return }
                let r = NSRect(
                    x: rect.minX + origin.x - 3,
                    y: topY,
                    width: rect.width + 6,
                    height: max(1, bottomY - topY))
                lineUnion = lineUnion.map { $0.union(r) } ?? r
            }
            if let lineUnion {
                if let last = rawRects.last, lineUnion.minY < last.maxY - 0.5 {
                    rawRects[rawRects.count - 1] = last.union(lineUnion)
                } else {
                    rawRects.append(lineUnion)
                }
            }
        }
        guard !rawRects.isEmpty else { return }

        // 가로로 겹치고 세로로 인접한 줄들만 하나의 연결 폴리곤 그룹으로 묶는다.
        // 줄 중간 엔터로 인해 윗줄 끝과 아랫줄 시작이 가로로 겹치지 않거나 빈 줄이 끼어 있으면
        // 별도 폴리곤으로 분리해 빈 공간을 가로지르지 않게 한다.
        var groups: [[NSRect]] = [[rawRects[0]]]
        let maxBridgeGap = lineSpacing + 4
        for i in 1..<rawRects.count {
            let prev = groups[groups.count - 1].last!
            let curr = rawRects[i]
            let verticalGap = curr.minY - prev.maxY
            let horizontalOverlap = min(prev.maxX, curr.maxX) - max(prev.minX, curr.minX)
            if verticalGap <= maxBridgeGap && horizontalOverlap > 2 {
                groups[groups.count - 1].append(curr)
            } else {
                groups.append([curr])
            }
        }

        let radius: CGFloat = 5
        let snap = radius * 2 + 2
        let combinedPath = CGMutablePath()

        for var rects in groups {
            let n = rects.count
            for i in 0..<(n - 1) {
                rects[i].size.height = rects[i + 1].minY - rects[i].minY
            }
            rects[0].origin.y += 0.5
            rects[0].size.height -= 0.5
            rects[n - 1].size.height -= 0.5

            for _ in 0..<2 {
                for i in 0..<(n - 1) {
                    if abs(rects[i].minX - rects[i + 1].minX) < snap {
                        let x = min(rects[i].minX, rects[i + 1].minX)
                        rects[i].size.width = rects[i].maxX - x
                        rects[i].origin.x = x
                        rects[i + 1].size.width = rects[i + 1].maxX - x
                        rects[i + 1].origin.x = x
                    }
                    if abs(rects[i].maxX - rects[i + 1].maxX) < snap {
                        let x = max(rects[i].maxX, rects[i + 1].maxX)
                        rects[i].size.width = x - rects[i].minX
                        rects[i + 1].size.width = x - rects[i + 1].minX
                    }
                }
            }

            var corners: [CGPoint] = []
            corners.append(CGPoint(x: rects[0].maxX, y: rects[0].minY))
            for i in 0..<(n - 1) where abs(rects[i].maxX - rects[i + 1].maxX) > 0.5 {
                corners.append(CGPoint(x: rects[i].maxX, y: rects[i].maxY))
                corners.append(CGPoint(x: rects[i + 1].maxX, y: rects[i].maxY))
            }
            corners.append(CGPoint(x: rects[n - 1].maxX, y: rects[n - 1].maxY))
            corners.append(CGPoint(x: rects[n - 1].minX, y: rects[n - 1].maxY))
            for i in stride(from: n - 1, to: 0, by: -1) where abs(rects[i].minX - rects[i - 1].minX) > 0.5 {
                corners.append(CGPoint(x: rects[i].minX, y: rects[i].minY))
                corners.append(CGPoint(x: rects[i - 1].minX, y: rects[i].minY))
            }
            corners.append(CGPoint(x: rects[0].minX, y: rects[0].minY))

            let first = corners[0]
            let last = corners[corners.count - 1]
            combinedPath.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
            for i in 0..<corners.count {
                let prev = i == 0 ? last : corners[i - 1]
                let c = corners[i]
                let next = corners[(i + 1) % corners.count]
                let r = min(
                    radius,
                    hypot(c.x - prev.x, c.y - prev.y) / 2,
                    hypot(next.x - c.x, next.y - c.y) / 2)
                combinedPath.addArc(tangent1End: c, tangent2End: next, radius: max(r, 0))
            }
            combinedPath.closeSubpath()
        }

        guard combinedPath.boundingBoxOfPath.intersects(dirtyRect),
            let ctx = NSGraphicsContext.current?.cgContext
        else { return }
        ctx.saveGState()
        ctx.addPath(combinedPath)
        ctx.setFillColor(palette.selection.cgColor)
        ctx.fillPath()
        ctx.addPath(combinedPath)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(palette.selectionBorder.cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func caretRectInView() -> NSRect? {
        guard let window else { return nil }
        let caret = selectedRange().location
        guard caret != NSNotFound else { return nil }
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        guard screenRect.height > 0 else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        return convert(windowRect, from: nil)
    }

    private struct CaretLineGeometry {
        let fragment: NSRect
        let baselineY: CGFloat
    }

    /// One TextKit coordinate source for the caret and inline Ghost.
    /// Keep AppKit's insertion-point x position and selection/IME handling intact.
    private func caretLineGeometry() -> CaretLineGeometry? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        guard selectedRange().location != NSNotFound else { return nil }
        let caret = min(selectedRange().location, ns.length)
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let extra = layoutManager.extraLineFragmentRect
        // Empty documents and final hard/soft breaks have no following glyph.
        // Use the new line's font metrics, never the previous line's baseline.
        let endsWithBreak = ns.length == 0
            || [0x0A, 0x0D, 0x2028, 0x2029].contains(Int(ns.character(at: ns.length - 1)))
        if caret == ns.length,
           endsWithBreak,
           extra.height > 0,
           layoutManager.extraLineFragmentTextContainer === textContainer {
            return CaretLineGeometry(
                fragment: extra.offsetBy(dx: origin.x, dy: origin.y),
                baselineY: origin.y + extra.minY
                    + layoutManager.defaultBaselineOffset(for: caretLineFont()))
        }
        guard ns.length > 0 else { return nil }
        var glyphIndex = layoutManager.glyphIndexForCharacter(at: min(caret, ns.length - 1))
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        var glyphRange = NSRange()
        var fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
        // A soft-wrap boundary has two insertion positions. Upstream affinity
        // belongs to the preceding visual line, never across an explicit break.
        if selectionAffinity == .upstream, caret > 0, caret < ns.length,
           glyphIndex == glyphRange.location,
           ns.lineRange(for: NSRange(location: caret, length: 0)).location < caret {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: caret - 1)
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        guard fragment.height > 0 else { return nil }
        return CaretLineGeometry(
            fragment: fragment.offsetBy(dx: origin.x, dy: origin.y),
            baselineY: origin.y + fragment.minY + layoutManager.location(forGlyphAt: glyphIndex).y)
    }

    private func caretLineFragmentRectInView() -> NSRect? { caretLineGeometry()?.fragment }

    private func caretBaselineY() -> CGFloat? { caretLineGeometry()?.baselineY }

    // MARK: 타자기 존 스크롤

    /// 커서를 드러낼 때 커서 **아래로 여백(gutter)까지** 함께 보이도록 스크롤한다 —
    /// 활성 줄이 창 바닥에 붙지 않고 화면 중하단의 편안한 위치에 park한다.
    ///
    /// 기본 `scrollRangeToVisible`은 커서를 뷰 하단 끝에 딱 맞춰 park시켜, 글이 한
    /// 화면을 넘기면 그 뒤로 줄곧 바닥을 긁으며 써진다(답답함 → 그만 쓰고 싶음).
    /// 여백은 스크롤 뷰의 `contentInsets.bottom`(=`WritingScrollView`가 뷰 높이에
    /// 비례해 잡아 둔 값)에서 읽는다 — 그래야 문서 끝에서도 그 인셋만큼 더 스크롤할
    /// 수 있어 마지막 줄까지 실제로 들어 올려진다. 인셋이 0이거나(타자기 존 미적용)
    /// 드래그 선택(length>0)·수식 편집 등은 기본 동작으로 넘긴다.
    override func scrollRangeToVisible(_ range: NSRange) {
        let gutter = enclosingScrollView?.contentInsets.bottom ?? 0
        guard range.length == 0, gutter > 0, let window else {
            super.scrollRangeToVisible(range)
            return
        }
        let screen = firstRect(forCharacterRange: range, actualRange: nil)
        guard screen.height > 0 else {
            super.scrollRangeToVisible(range)
            return
        }
        let inView = convert(window.convertFromScreen(screen), from: nil)
        _ = scrollToVisible(
            NSRect(
                x: inView.minX, y: inView.minY,
                width: max(1, inView.width), height: inView.height + gutter))
    }
}

// MARK: - 블록 장식 레이아웃 매니저

/// 불릿·번호·체크박스·인용 바·코드/수식 배경·구분선·이미지를 그린다.
/// 전부 text storage 밖 — 문서·undo·IME에 흔적이 없다.
// MARK: - 마커 증분 감지 (NSTextStorageDelegate)

// storage 편집은 실제로 메인 스레드에서만 일어난다 (에디터 조작 경로뿐) —
// SidebarDragDrop의 DropDelegate와 같은 관용구로 격리를 넘긴다.
extension BlockTextView: @preconcurrency NSTextStorageDelegate {

    /// 편집된 범위에 수식·이미지 마커가 들어왔는지만 본다 — 문서 길이와 무관.
    ///
    /// 범위를 **양옆 1글자 넓혀** 검사하는 이유: `$`를 치고 다음 키에 `$`를 치면
    /// 각 편집 범위엔 `$`가 하나뿐이라 `$$`를 놓친다. 넓히면 두 번째 키에서 잡힌다.
    /// 같은 이유로 `!` 다음 `[`도 잡힌다.
    ///
    /// 삭제로 마커가 사라지는 경우는 여기서 알 수 없다 — 플래그가 true인 채 남아
    /// 전체 경로를 한 번 더 타고, 거기서 `syncMarkerFlag`가 정확히 되돌린다.
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Font/paragraph edits and undo can bypass text input overrides. Wait
        // until TextKit has processed their layout invalidation before measuring.
        scheduleEditingOverlayRefresh()
        writingProjectionCapture.storageChanged(mask: editedMask, range: editedRange, delta: delta, storage: textStorage)
        updateMediaRenderIndex(mask: editedMask, range: editedRange, delta: delta)
        // 직렬화 증분 캐시 판정 — 모든 편집에 대해 먼저(마커 조기 반환에 가리지 않게).
        updateSerialCacheState(editedMask: editedMask, editedRange: editedRange, delta: delta)

        guard editedMask.contains(.editedCharacters) else { return }
        let ns = textStorage.string as NSString
        let start = max(0, editedRange.location - 1)
        let end = min(ns.length, editedRange.upperBound + 1)
        guard end > start else { return }
        let touched = ns.substring(with: NSRange(location: start, length: end - start))
        // 인라인 수식 후보 — `$` 하나만으로도 보수적으로 켠다 (이슈 #20).
        // 접기 검사(collapseRawInlineMath)가 실측으로 다시 끝낸다.
        if touched.contains("$") {
            mayHaveInlineMath = true
        }
        // 마커 플래그가 이미 true면 더 볼 필요 없다 — syncMarkerFlag가 정리한다.
        guard !mayHaveMarkers else { return }
        if touched.contains("$$") || touched.contains("![") {
            mayHaveMarkers = true
        }
    }
}

final class PurloryLayoutManager: NSLayoutManager {
    private(set) var processingStorageEdit = false

    override func textStorage(_ textStorage: NSTextStorage, edited editedMask: Int,
                              range editedRange: NSRange, changeInLength delta: Int,
                              invalidatedRange invalidatedCharRange: NSRange) {
        let wasProcessing = processingStorageEdit
        processingStorageEdit = true
        defer { processingStorageEdit = wasProcessing }
        super.textStorage(textStorage, edited: editedMask, range: editedRange,
                          changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    // TextKit drawing uses this snapshot rather than actor-isolated view state.
    nonisolated(unsafe) var editorialWorkspaceStyle = false

    private var view: BlockTextView? {
        firstTextView as? BlockTextView
    }

    /// 문단 블록 정보 — storage 속성에서 직접 읽는다 (nonisolated 드로잉용).
    /// 문서 끝 빈 문단은 뷰의 tailBlockInfo 스냅샷으로 보완한다.
    private func blockInfo(
        _ storage: NSTextStorage, in paragraph: NSRange, view: BlockTextView
    ) -> (block: PurloryBlock, checked: Bool, marker: String?, indent: Int, codeLang: String?) {
        if paragraph.location < storage.length {
            let attrs = storage.attributes(at: paragraph.location, effectiveRange: nil)
            let block = (attrs[.purloryBlock] as? String).flatMap(PurloryBlock.init(rawValue:)) ?? .p
            return (
                block,
                attrs[.purloryChecked] as? Bool ?? false,
                attrs[.purloryMarker] as? String,
                attrs[.purloryIndent] as? Int ?? 0,
                attrs[.purloryCodeLang] as? String
            )
        }
        let snapshot = view.tailBlockInfo
        return (
            snapshot.block.flatMap(PurloryBlock.init(rawValue:)) ?? .p,
            snapshot.checked, snapshot.marker, snapshot.indent, snapshot.codeLang
        )
    }

    /// 배경(코드·수식 블록) 그리기 — **보이는 문단만** 훑는다.
    ///
    /// 예전엔 `glyphsToShow`를 인자로 받아놓고 무시한 채 문서 전체 문단을 돌았다.
    /// 그리기는 키 입력마다 일어나므로 그대로 키 입력당 O(문서)였다 —
    /// 30만 자에서 5.15ms (측정: docs/editor-perf.md). 이제 문서 길이와 무관하다.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let view, let storage = textStorage else { return }
        let theme = view.palette
        let ns = storage.string as NSString
        guard ns.length > 0, glyphsToShow.length > 0 else { return }

        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let firstPara = ns.paragraphRange(
            for: NSRange(location: min(shown.location, ns.length - 1), length: 0))
        let lastPara = ns.paragraphRange(
            for: NSRange(location: min(shown.upperBound, ns.length - 1), length: 0))

        // 코드 런은 여러 문단을 하나의 라운드 사각형으로 병합해 그린다 (디자인).
        // 화면 위/아래로 이어지는 런은 잘린 배경이 되므로 런의 시작·끝까지만
        // 넓힌다 — 넓히는 비용은 **런 길이**에 비례하지 문서 길이가 아니다.
        var start = firstPara.location
        while start > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
            guard blockInfo(storage, in: prev, view: view).block == .code else { break }
            start = prev.location
        }
        var end = lastPara.upperBound
        while end < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            guard blockInfo(storage, in: next, view: view).block == .code else { break }
            end = next.upperBound
        }

        var location = start
        var codeStart: Int? = nil
        while location < end {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let block = blockInfo(storage, in: para, view: view).block
            if block == .code {
                if codeStart == nil { codeStart = para.location }
            } else {
                if let runStart = codeStart {
                    drawGroupBackground(
                        charRange: NSRange(location: runStart, length: para.location - runStart),
                        origin: origin, color: theme.codeBg)
                    codeStart = nil
                }
                if block == .math {
                    // 렌더 모드 수식의 박스는 drawGlyphs가 **수식 크기에 맞춰**
                    // 그린다 (요구 5) — 여기선 소스 편집 중일 때만 문단 폭 배경.
                    // 다중 행 그룹 소속 문단도 렌더 중이면 박스를 생략한다 (이슈 #20).
                    let rendered = view.mathRenders.contains {
                        NSLocationInRange(para.location, $0.range)
                    }
                    if !rendered {
                        drawGroupBackground(
                            charRange: para, origin: origin, color: theme.codeBg)
                    }
                }
            }
            location = para.upperBound
        }
        if let runStart = codeStart {
            // end까지 넓혀 둔 덕에 여기가 곧 런의 끝이다.
            drawGroupBackground(
                charRange: NSRange(location: runStart, length: end - runStart),
                origin: origin, color: theme.codeBg)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let view, let storage = textStorage, storage.length > 0 else { return }
        let theme = view.palette
        let ns = storage.string as NSString
        let shownChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawWritingDiagnostics(forGlyphRange: glyphsToShow, at: origin, view: view)

        var location = shownChars.location
        while location < min(shownChars.upperBound + 1, ns.length + 1) {
            let para = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
            defer { location = max(para.upperBound, location + 1) }
            let info = blockInfo(storage, in: para, view: view)
            guard info.block != .p else { continue }
            guard let rect = paragraphRect(charRange: para, origin: origin) else { continue }
            let firstLine = firstLineRect(charRange: para, origin: origin) ?? rect
            let indentOffset = CGFloat(info.indent) * 24

            switch info.block {
            case .quote:
                (editorialWorkspaceStyle ? theme.workspaceTerracotta : theme.ink2).setFill()
                let barWidth: CGFloat = editorialWorkspaceStyle ? 2 : 3
                for level in 0...max(0, info.indent) {
                    let barX = rect.minX + CGFloat(level) * 20
                    NSRect(x: barX, y: rect.minY + 2, width: barWidth, height: rect.height - 4)
                        .fill()
                }
            case .bullet:
                let bullets = ["•", "◦", "▪"]
                let symbol = bullets[max(0, info.indent) % bullets.count]
                draw(marker: symbol, color: theme.ink2, size: 20,
                     x: leftEdge(origin) + 8 + indentOffset, line: firstLine,
                     baseline: firstBaseline(charRange: para, line: firstLine))
            case .number:
                // 본문(bodyFont serif 20)과 같은 크기·베이스라인으로 정렬.
                draw(marker: info.marker ?? "1.", color: theme.ink2, size: 20,
                     x: leftEdge(origin) + 6 + indentOffset, line: firstLine,
                     baseline: firstBaseline(charRange: para, line: firstLine))
            case .todo:
                // 체크박스는 글자 캡하이트의 세로 중앙에 맞춘다.
                let centerY = firstBaseline(charRange: para, line: firstLine)
                    .map { $0 - PurloryFonts.serif(20).capHeight / 2 } ?? firstLine.midY
                drawCheckbox(
                    checked: info.checked, theme: theme,
                    at: NSPoint(x: leftEdge(origin) + 4 + indentOffset, y: centerY - 8))
            case .code:
                if let lang = info.codeLang, !lang.isEmpty {
                    let isFirstInRun: Bool = {
                        guard para.location > 0 else { return true }
                        let prev = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
                        return blockInfo(storage, in: prev, view: view).block != .code
                    }()
                    if isFirstInRun {
                        let tag = NSAttributedString(
                            string: lang,
                            attributes: [
                                .font: PurloryFonts.mono(10), .foregroundColor: theme.ink3,
                                .kern: 0.4,
                            ])
                        tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 12, y: rect.minY + 2))
                    }
                }
            case .divider:
                theme.sepStrong.setFill()
                NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1).fill()
            case .math:
                if let render = view.mathRenders.first(
                    where: { NSLocationInRange(para.location, $0.range) })
                {
                    // 다중 행 그룹이면 그룹 **전체** rect에 한 번만 그린다 —
                    // 문단별로 그리면 같은 이미지가 줄마다 찍힌다 (이슈 #20).
                    if para.location == render.range.location {
                        let unionRect = paragraphRect(
                            charRange: render.range, origin: origin) ?? rect
                        drawMath(render.image, in: unionRect, theme: theme)
                    }
                } else {
                    // 편집 중이거나 아직 파싱 안 되는 소스 — "수식" 태그만.
                    let tag = NSAttributedString(
                        string: "수식",
                        attributes: [
                            .font: PurloryFonts.ui(10), .foregroundColor: theme.ink3,
                            .kern: 0.6,
                        ])
                    tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 12, y: rect.minY + 6))
                }
            case .image:
                if let render = view.imageRenders.first(
                    where: { $0.range.location == para.location }) {
                    drawImage(
                        render.image, in: rect, display: render.size,
                        align: render.align, selected: render.selected, theme: theme)
                } else {
                    // 편집 중이거나 파일을 못 읽음 — "이미지" 태그만.
                    let tag = NSAttributedString(
                        string: "이미지",
                        attributes: [
                            .font: PurloryFonts.ui(10), .foregroundColor: theme.ink3,
                            .kern: 0.6,
                        ])
                    tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 12, y: rect.minY + 6))
                }
            default:
                break
            }
        }
    }

    // MARK: 헬퍼

    /// 문단 좌측 기준선(들여쓰기 이전의 텍스트 시작 x).
    private func leftEdge(_ origin: NSPoint) -> CGFloat {
        guard let container = textContainers.first else { return origin.x }
        return origin.x + container.lineFragmentPadding
    }

    private func paragraphRect(charRange: NSRange, origin: NSPoint) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        let range = charRange
        // 빈 문단(개행만)도 rect가 나오도록 개행 포함 그대로 사용.
        if range.length == 0 {
            guard let extra = extraLineRect(origin: origin) else { return nil }
            return extra
        }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        rect.size.width = container.size.width - container.lineFragmentPadding * 2
        rect.origin.x = origin.x + container.lineFragmentPadding
        return rect
    }

    private func firstLineRect(charRange: NSRange, origin: NSPoint) -> NSRect? {
        guard charRange.length > 0 else { return nil }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var effective = NSRange()
        var rect = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &effective)
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    private func extraLineRect(origin: NSPoint) -> NSRect? {
        var rect = extraLineFragmentRect
        guard rect.height > 0 else { return nil }
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    /// 첫 라인의 텍스트 베이스라인 y — 프래그먼트 중앙이 아니라 글리프
    /// 베이스라인(실측) 기준으로 마커를 놓아야 본문 글자와 높이가 맞는다.
    private func firstBaseline(charRange: NSRange, line: NSRect) -> CGFloat? {
        guard charRange.length > 0 else { return nil }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return line.minY + location(forGlyphAt: glyphs.location).y
    }

    private func draw(
        marker: String, color: NSColor, size: CGFloat,
        x: CGFloat, line: NSRect, baseline: CGFloat?
    ) {
        let font = PurloryFonts.serif(size)
        let attr = NSAttributedString(
            string: marker,
            attributes: [.font: font, .foregroundColor: color])
        let y = baseline.map { $0 - font.ascender }
            ?? line.minY + (line.height - attr.size().height) / 2
        attr.draw(at: NSPoint(x: x, y: y))
    }

    /// 렌더된 LaTeX 이미지를 수식 문단 중앙에 그린다 (폭 초과 시 축소).
    /// 배경 박스는 문단 폭이 아니라 **수식 크기 + 사방 mathBoxMargin(10pt)** —
    /// 분수처럼 큰 수식이면 박스도 함께 커진다 (요구 5).
    private func drawMath(_ image: NSImage, in rect: NSRect, theme: PurloryTheme) {
        var size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let maxWidth = max(40, rect.width - 32)
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        let target = NSRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height)
        let box = target.insetBy(
            dx: -BlockTextView.mathBoxMargin, dy: -BlockTextView.mathBoxMargin)
        theme.codeBg.setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        image.draw(
            in: target, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    /// 렌더된 이미지를 지정 크기(`display`)·정렬(`align`)로 그린다. 객체 선택 시엔
    /// 선택 테두리도 두른다 (요구 3). display는 뷰의 `imageDisplaySize`가 계산한 값.
    private func drawImage(
        _ image: NSImage, in rect: NSRect, display: NSSize,
        align: String, selected: Bool, theme: PurloryTheme
    ) {
        guard display.width > 0, display.height > 0 else { return }
        // 줄 높이(=display 높이+여유)를 넘지 않게 안전하게 한 번 더 맞춘다.
        let box = rect.insetBy(dx: 8, dy: 6)
        let scale = min(box.width / display.width, box.height / display.height, 1)
        let size = NSSize(width: display.width * scale, height: display.height * scale)
        // 가로 정렬 — 좌/우는 살짝 안쪽(8pt)에서 시작한다.
        let x: CGFloat
        switch align {
        case "left": x = box.minX
        case "right": x = box.maxX - size.width
        default: x = rect.midX - size.width / 2
        }
        let target = NSRect(
            x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(
            in: target, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
        // 선택 테두리·핸들은 ImageBoxOverlay(별도 뷰)가 그린다.
    }

    private func drawCheckbox(checked: Bool, theme: PurloryTheme, at point: NSPoint) {
        let box = NSRect(x: point.x, y: point.y, width: 16, height: 16)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        path.lineWidth = 1.5
        if checked {
            theme.blue.setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
                .applying(.init(paletteColors: [theme.blue.accessibleForeground()]))
            guard let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let size = check.size
            check.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                width: size.width, height: size.height), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            theme.ink3.setStroke()
            path.stroke()
        }
    }

    private func drawGroupBackground(charRange: NSRange, origin: NSPoint, color: NSColor) {
        guard let container = textContainers.first, charRange.length > 0 else { return }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x = origin.x + container.lineFragmentPadding
        rect.origin.y += origin.y
        rect.size.width = container.size.width - container.lineFragmentPadding * 2
        rect = rect.insetBy(dx: 0, dy: -6)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
    }

}
