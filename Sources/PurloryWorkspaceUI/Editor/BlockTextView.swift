import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers
import PurloryFoundation
import PurloryStorage
import PurloryDocumentEngine
import PurloryIntelligence

/// Native editor state shared by the codec, decoration, attachment, overlay and input roles.
/// Keep all accepted text, IME and undo ownership on this single NSTextView instance.
@MainActor
final class BlockTextView: NSTextView {
    var inputTraceRecorder: EditorInputTraceRecorder?
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

    /// Encapsulated sub-states separating serialization, media rendering, and overlay lifecycles.
    var serializationCache = EditorSerializationCache()
    var mediaState = EditorMediaRenderState()
    var overlayState = EditorOverlayState()

    var palette: PurloryTheme = .light

    /// Raw Markdown source editing mode toggle (⌘/).
    var isSourceMode = false

    /// Block metadata snapshot for an empty trailing paragraph (held only in typingAttributes).
    var tailBlockInfo:
        (block: String?, checked: Bool, marker: String?, indent: Int, codeLang: String?) = (nil, false, nil, 0, nil)

    /// Base body font size (pt) injected from settings; headings/code/math scale proportionally.
    var baseFontSize: CGFloat = 20 {
        didSet {
            guard baseFontSize != oldValue else { return }
            bodyFont = PurloryFonts.serif(baseFontSize)
            if window != nil { rerenderInlineAtoms() }
        }
    }

    var bodyFont = PurloryFonts.serif(20)
    var fontScale: CGFloat { baseFontSize / 20 }
    var editorialWorkspaceStyle = false

    var lineSpacing: CGFloat = CGFloat(CompletionSettings.defaultLineSpacing)
    var proseLayout: EditorProseLayout = .spaced

    /// Current Ghost completion suggestion; nil/empty hides the overlay.
    var ghostText: String? {
        didSet {
            guard ghostText != oldValue else { return }
            if let ghost = ghostText, !ghost.isEmpty, (oldValue == nil || oldValue?.isEmpty == true) {
                overlayState.ghostGeneration += 1
                announceGhostAppearance(ghost)
            }
            if let ghost = ghostText, !ghost.isEmpty, oldValue == nil {
                startGhostFadeIn()
            } else if ghostText == nil {
                overlayState.ghostFadeTask?.cancel()
                overlayState.ghostFadeTask = nil
                overlayState.ghostOpacity = 1
            }
            needsDisplay = true
        }
    }

    /// Re-entry guard during Markdown marker consumption and styling.
    var isTransforming = false
    /// Pure presentation restyle guard so theme/font updates do not dirty serialization or projection caches.
    var isRestylingPresentation = false

    var mathFontSize: CGFloat { baseFontSize }
    nonisolated static let mathBoxMargin: CGFloat = 10

    var nativeTextUpdateDepth = 0
    var writingDecorationLookupCount = 0

    var isEditingMath: Bool {
        guard window?.firstResponder === self else { return false }
        let ns = string as NSString
        let location = min(selectedRange().location, ns.length)
        return blockInfo(in: ns.paragraphRange(for: NSRange(location: location, length: 0))).block == .math
    }

    /// Native editing gestures take precedence over workspace dismissal.
    var ownsEscapeKey: Bool {
        hasMarkedText() || !(ghostText ?? "").isEmpty || mediaState.selectedImageLocation != nil
            || isEditingMath || workspaceInteraction?.ownsEscapeKey == true
    }

    var didInitialFocus = false
    var editorWindowDidChange: ((NSTextView) -> Void)?

    /// `<p align="center|right">...</p>` wrapper used for aligned prose paragraphs.
    static let alignWrapper = try! NSRegularExpression(
        pattern: #"^<p align="(center|right)">([^\n]*)</p>$"#)

    /// Key actions handled when an image block is selected as an atomic object.
    enum ImageObjectKeyAction: Equatable {
        case exitBefore
        case exitAfter
        case align(String)
        case adjustWidth(Int)
        case move(Int)
        case revealToolbar
    }

    var lastTypingKeyTimestamp: TimeInterval?
    var isHandlingSoftReturn = false

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Plain-text NSTextView otherwise disables Paste for bitmap-only clipboards
        // before our managed-image paste handler can run.
        [.purloryImageObject, .png, .tiff, .init(UTType.jpeg.identifier)] + super.readablePasteboardTypes
    }

    static let projectImageBytesType = NSPasteboard.PasteboardType("app.purlory.project-image-bytes")
    static let attachmentCharacter = "\u{FFFC}"

    /// Workspace find delegation invoked by `performTextFinderAction(_:)`.
    var workspaceFind: ((NSTextFinder.Action) -> Bool)?

    /// Hit-test transparent decoration view for the active paragraph highlight band.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// One translucent background for the active paragraph, below other overlays.
    lazy var activeLineView: PassthroughView = {
        let view = PassthroughView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: nil)
        return view
    }()

    /// Custom high-contrast caret view positioned by `syncCaretView()`.
    lazy var caretView: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 1
        view.isHidden = true
        addSubview(view)
        return view
    }()

    /// Inline pill prompting to record a detected conversation block.
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

    nonisolated static let ghostMaxLines = 3

    struct CaretLineGeometry {
        let fragment: NSRect
        let baselineY: CGFloat
    }

    // MARK: - Sub-state inspection facades (diagnostics, benchmarks & tests)

    var serialCacheRebuildCount: Int { serializationCache.rebuildCount }
    var serialDirtyRange: NSRange? { serializationCache.dirtyRange }

    var mediaParagraphIndex: ParagraphRenderIndex? { mediaState.paragraphIndex }
    var mediaIndexBuildCount: Int { mediaState.indexBuildCount }
    var lastMediaIndexUpdateParagraphs: Int { mediaState.lastIndexUpdateParagraphs }
    var lastMediaRenderParagraphCount: Int { mediaState.lastRenderParagraphCount }
    var mathRenders: [(range: NSRange, image: NSImage)] { mediaState.mathRenders }
    var mathRenderErrors: [Int: String] { mediaState.mathRenderErrors }
    var imageRenders: [ImageRender] { mediaState.imageRenders }
    var selectedImageLocation: Int? {
        get { mediaState.selectedImageLocation }
        set { mediaState.selectedImageLocation = newValue }
    }
    var mayHaveInlineMathForTesting: Bool {
        get { mediaState.mayHaveInlineMath }
        set { mediaState.mayHaveInlineMath = newValue }
    }

    var ghostGeneration: Int { overlayState.ghostGeneration }
    var caretBlinkTimer: Timer? { overlayState.caretBlinkTimer }
    var workspaceSelectionPanel: NSPanel? { overlayState.workspaceSelectionPanel }
}
