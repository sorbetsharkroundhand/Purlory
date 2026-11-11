import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

/// Native editor state shared by the codec, decoration, attachment, overlay and input roles.
/// Keep all accepted text, IME and undo ownership on this single NSTextView instance.
@MainActor
final class BlockTextView: NSTextView {
    var workspaceInteraction: (any EditorWorkspaceInteraction)?
    var workspaceTrackingArea: NSTrackingArea?
    var documentUndoManager: UndoManager?
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }
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
    var projectImageCache = ImageLRU(budgetBytes: 128 * 1024 * 1024)

    struct ProjectImageOperation {
        let importer: @MainActor (Data, String) async throws -> ProjectAssetCatalog
        let body: String
        let selection: NSRange
        let projectID: WritingProjectID
    }

    /// 레이아웃 매니저(nonisolated 드로잉)에서도 읽는다 — 쓰기는 메인 스레드뿐.
    /// nonisolated 드로잉이 읽기 때문에 @MainActor 전환이 불가능하다 — 이 탈출구는
    /// 렌더 경로 재설계(#53·#61)에서 스냅샷 패턴으로 없앨 과제다 (이슈 #45).
    nonisolated(unsafe) var palette: PurloryTheme = .light

    /// 원본 마크다운 소스 직접 편집 모드 여부 (⌘/).
    var isSourceMode = false

    /// 문서 끝 빈 문단(typingAttributes에만 존재)의 블록 스냅샷 —
    /// 레이아웃 매니저가 nonisolated 드로잉 중에 읽는다.
    nonisolated(unsafe) var tailBlockInfo:
        (block: String?, checked: Bool, marker: String?, indent: Int, codeLang: String?) = (nil, false, nil, 0, nil)

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
    var bodyFont = PurloryFonts.serif(20)

    /// 디자인 기준(20pt) 대비 배율 — 제목·코드·수식 크기를 함께 확대/축소한다.
    var fontScale: CGFloat { baseFontSize / 20 }
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
    var ghostOpacity: CGFloat = 1
    /// 페이드 인 애니메이션 태스크 — 새 제안·폐기 때 취소하고 다시 건다.
    var ghostFadeTask: Task<Void, Never>?

    /// 고스트 세대 (#24) — 새 제안이 뜰 때마다 증가한다. 시각 고스트와 접근성
    /// 노출이 같은 원천(`ghostText`)에서 같은 세대로 읽힘을 보장하는 근거다.
    /// 사라짐(→nil)은 세대를 올리지 않는다 — 같은 제안의 생애주기 동안 불변.
    var ghostGeneration = 0

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
    var isTransforming = false
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
    nonisolated(unsafe) var mathRenders: [(range: NSRange, image: NSImage)] = []
    /// 무효 수식 문단(location) → 파싱 오류 원인 — 우클릭 메뉴·접근성 안내용 (이슈 #22).
    nonisolated(unsafe) var mathRenderErrors: [Int: String] = [:]

    /// 직전 패스에서 감지된 다중 행 수식 그룹 범위 — 구조 편집 후 줄 높이 잔상을
    /// 되돌리는 기준 (이슈 #22 valid→invalid→valid 잔상 예방).
    var previousMathGroups: [NSRange] = []
    /// 이번 패스에서 clear 전경을 심은 범위들 (#18) — 다음 패스에서 **이 범위만**
    /// 제거한다. 과거엔 문서 전체(0..length)를 지웠는데, 이것이 매 키 입력·커서
    /// 이동마다 O(문서) 레이아웃 무효화를 만드는 주범이었다. 편집 범위의 임시
    /// 속성은 TextStorage가 스스로 떨어뜨리므로, 기록된 범위(문단 경계 확장)만
    /// 닦으면 누수가 없다.
    var previousClearRanges: [NSRange] = []
    /// 스크롤 틱 coalescing (#18 2단계) — 연속 스크롤 중 마지막 위치만 갱신.
    var visibleRefreshTask: Task<Void, Never>?

    /// 현재 렌더 모드인 이미지 문단들 — 문단 range·이미지·표시 크기·정렬·선택 여부.
    /// 정렬/크기는 소스(`![](src){width=NN align=X}`)에서 파싱해 담고, 레이아웃
    /// 매니저의 `drawImage`가 그대로 쓴다 (요구 3).
    nonisolated(unsafe) var imageRenders: [ImageRender] = []

    /// 객체로 선택된 이미지 문단의 시작 위치 — 클릭하면 소스(![](…)) 대신 이미지가
    /// 선택 테두리와 함께 남고, 정렬·줄바꿈 툴바가 뜬다 (요구 3).
    var selectedImageLocation: Int?

    /// 드래그 중 미리보기 너비(%) — refreshRenderedBlocks가 소스 대신 이 값을 쓴다.
    var resizePreview: (loc: Int, width: Int)?
    /// 선택된 이미지를 감싸는 오버레이 박스 (요구: 이미지를 하나의 박스로).
    var imageBox: ImageBoxOverlay?
    /// 이미지 이동 드래그 중 표시할 드롭 위치 y (뷰 좌표). nil이면 표시 안 함.
    var imageDropIndicatorY: CGFloat?

    // MARK: 커서 효과 (에디터 v3.1 — 글로우 대체)

    /// 직전 선택(길이>0) 하이라이트가 걸친 영역 — 더블클릭으로 잡힌 공백·개행
    /// 선택은 글리프 rect 바깥까지 그려져, 선택 해제 시 AppKit의 무효화가
    /// 다 덮지 못하고 잔상이 남는다. 선택이 바뀔 때 이 rect를 직접 지운다.
    var lastSelectionRect: NSRect?
    var nativeTextUpdateDepth = 0
    var refreshingEditingOverlays = false
    var editingOverlayRefreshPending = false
    var pendingCaretBlinkRestart = false

    var isEditingMath: Bool {
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
    var didInitialFocus = false
    var editorWindowDidChange: ((NSTextView) -> Void)?

    /// `<p align="center|right">…</p>` — 정렬 저장 래퍼 (.p 문단 전용).
    static let alignWrapper = try! NSRegularExpression(
        pattern: #"^<p align="(center|right)">([^\n]*)</p>$"#)

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

    // MARK: 직렬화 증분 캐시 (docs/editor-perf.md)

    /// 문단별 직렬화 줄 캐시 — 네이티브 문자열. `assembleSerialized`가 join한다.
    /// 메모리는 대략 문서 크기의 사본 하나(600k자 ≈ 1.2MB) — 지연을 위한 거래.
    var markdownCodec = MarkdownDocumentCodec()
    var serialLines: [(text: String, isCode: Bool, codeLang: String?)] = []
    var serialCacheRebuildCount = 0
    var writingDecorationLookupCount = 0
    /// false면 다음 `serialize()`가 전체 재구축한다 — 정답이 보장되는 폴백.
    var serialLinesValid = false
    /// 추적 중인 문단만 다시 브리지하면 되는 상태.
    var serialFastDirty = false
    /// 빠른 경로가 갱신할 `serialLines`의 인덱스 (커서 문단).
    var serialFastIndex: Int?
    /// 그 문단의 시작 오프셋 — 편집이 같은 문단인지 확인하는 키.
    var serialFastStart = 0
    /// 마지막으로 `serialLines`가 동기화되었을 때의 `textStorage` UTF-16 길이.
    var serialSyncedLength = 0
    /// 줄바꿈/병합/속성 편집 등 다중 문단 범위를 부분 갱신하기 위한 더티 범위.
    var serialDirtyRange: NSRange?
    /// `shouldChangeText`가 이 편집을 가로챘는가 — 못 가로챈 편집(프로그래matic)은
    /// 삭제 개행 수를 알 수 없어 안전하게 전체 재구축한다.
    var serialPendingTracked = false
    /// `shouldChangeText`가 편집 전에 센 "삭제될 텍스트의 개행 수". 0이 아니면
    /// 문단이 병합되므로 빠른 경로를 쓰지 않는다.
    var serialPendingRemovedNewlines = 0

    /// 객체 모드에서 소비할 수 있는 키 동작 (이슈 #16).
    enum ImageObjectKeyAction: Equatable {
        case exitBefore  // 이미지 앞 경계로 나온다
        case exitAfter  // 이미지 뒤 경계로 나온다
        case align(String)
        case adjustWidth(Int)
        case move(Int)
        case revealToolbar
    }

    var lastTypingKeyTimestamp: TimeInterval?
    var isHandlingSoftReturn = false
    /// 문서 내 `[label]: dest` 이미지 참조 정의 캐시 — 로드 시 수집하고 필요 시 갱신한다 (F19).
    var imageDefinitions: [String: ImageReferenceParser.Definition] = [:]
    var imageDefinitionsDirty = false

    // MARK: 이미지 삽입 (붙여넣기 · 드롭 · 파일 선택)

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Plain-text NSTextView otherwise disables Paste for bitmap-only clipboards
        // before our managed-image paste handler can run.
        [.purloryImageObject, .png, .tiff, .init(UTType.jpeg.identifier)] + super.readablePasteboardTypes
    }

    static let projectImageBytesType = NSPasteboard.PasteboardType("app.purlory.project-image-bytes")

    // MARK: 인라인 수식 원자 (이슈 #20)

    /// raw `$…$` 스팬이 문서에 남아 있을 가능성 — 빠른 경로 판정용.
    /// `$` 입력·소스 펼치기·로드 시 남은 스팬에서 켜지고, 접기 검사가 실측으로 끈다.
    var mayHaveInlineMath = true

    /// 회귀 테스트용 — 붙여넣기 등 외부 편집 후의 상태를 흉내 낸다 (이슈 #20).
    var mayHaveInlineMathForTesting: Bool {
        get { mayHaveInlineMath }
        set { mayHaveInlineMath = newValue }
    }
    /// 인라인 수식 원자의 storage 문자 — U+FFFC (attachment 글자 하나).
    static let attachmentCharacter = "\u{FFFC}"

    // MARK: 수식 라이브 미리보기 (수식 블럭 완성도)

    /// Live preview shares the active source block instead of floating below it.
    var mathPreviewHost: NSHostingView<MathPreviewView>?
    /// 미리보기 디바운스 (#53) — 글자마다 MTMathList 조판(메인)을 하지 않고
    /// 입력이 150ms 멈췄을 때 마지막 소스만 렌더한다. 대기 중 소스는 계속 갈아끼운다.
    var mathPreviewTask: Task<Void, Never>?
    var mathPreviewPending: (source: String, para: NSRange)?

    // MARK: 수식 객체 복사 (이슈 #22)

    /// 우클릭 메뉴가 대상으로 삼는 수식 문단 위치 — 메뉴 표시 직전에 세팅된다.
    var mathActionLocation: Int?

    // MARK: 서식 툴바 (선택 위 플로팅)

    var toolbarHost: NSHostingView<SelectionToolbarView>?
    var workspaceSelectionPanel: NSPanel?
    var toolbarShowTask: Task<Void, Never>?
    /// 이미지 객체 선택 시 뜨는 정렬·크기·줄바꿈 툴바 (요구 3).
    var imageToolbarHost: NSHostingView<ImageObjectToolbarView>?
    /// alt·title 편집 카드 호스트 — 툴바와 함께 수명을 관리한다 (이슈 #14).
    var imageAltEditorHost: NSHostingView<ImageAltEditorView>?

    /// NSTextFinder 액션 실행 — performTextFinderAction은 sender의 tag로 동작을 읽는다.
    var workspaceFind: ((NSTextFinder.Action) -> Bool)?

    /// 클릭을 통과시키는 장식 뷰 — 줄 하이라이트 밴드는 줄 전체 폭이라, hitTest를
    /// 막지 않으면 그 줄의 텍스트 클릭·선택이 통째로 밴드에 먹힌다.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// One translucent background for the active paragraph, below other overlays.
    lazy var activeLineView: PassthroughView = {
        let view = PassthroughView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.isHidden = true
        // 다른 오버레이(캐럿·이미지 박스) 밑으로 — 서브뷰 맨 아래에 깐다.
        addSubview(view, positioned: .below, relativeTo: nil)
        return view
    }()

    /// 우리가 소유한 캐럿 뷰. 표시 조건·위치는 `syncCaretView()`가 담당.
    lazy var caretView: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 1
        view.isHidden = true
        addSubview(view)
        return view
    }()

    /// 자체 블링크 타이머 — 시스템 블링크 대신 캐럿 뷰의 alpha를 페이드한다.
    var caretBlinkTimer: Timer?

    // MARK: 대화 기록 제안 렌더 (요구사항 §20)

    /// 제안 중인 대화 블록 범위 (스토리지 좌표) — nil이면 표시 없음.
    var conversationPromptRange: NSRange?

    /// 인라인 pill — 「이 대화를 기록할까요?」. 모달·팝업 금지 (요구사항 §20):
    /// 캐럿 뷰와 같은 자기 소유 서브뷰 하나로, 대화 끝자락에 조용히 놓인다.
    lazy var conversationPromptView: NSTextField = {
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
    /// 줄바꿈 상한 줄 수 — 화면을 흔들지 않는 절제 (#24).
    nonisolated static let ghostMaxLines = 3

    struct CaretLineGeometry {
        let fragment: NSRect
        let baselineY: CGFloat
    }
}
