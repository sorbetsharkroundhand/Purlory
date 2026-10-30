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
