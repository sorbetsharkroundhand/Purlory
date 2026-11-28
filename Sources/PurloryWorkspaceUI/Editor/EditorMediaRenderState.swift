import AppKit
import PurloryDocumentEngine
import SwiftUI

/// Math/image rendering state, incremental paragraph render index, and preview lifecycle owned by `BlockTextView`.
@MainActor
struct EditorMediaRenderState {
    var paragraphIndex: ParagraphRenderIndex?
    var dirtyRanges: [NSRange] = []
    var indexBuildCount = 0
    var lastIndexUpdateParagraphs = 0
    var lastRenderParagraphCount = 0
    var lastSelectionRange: NSRange?

    /// Rendered display-math paragraphs (single or multi-line groups) drawn by `PurloryLayoutManager`.
    var mathRenders: [(range: NSRange, image: NSImage)] = []
    /// Invalid math paragraph start UTF-16 offset → parse error description.
    var mathRenderErrors: [Int: String] = [:]
    var previousMathGroups: [NSRange] = []
    var previousClearRanges: [NSRange] = []
    var visibleRefreshTask: Task<Void, Never>?

    /// Rendered image paragraphs drawn by `PurloryLayoutManager`.
    var imageRenders: [ImageRender] = []
    var selectedImageLocation: Int?
    var resizePreview: (loc: Int, width: Int)?
    var imageBox: ImageBoxOverlay?
    var imageDropIndicatorY: CGFloat?
    var imageDefinitions: [String: ImageReferenceParser.Definition] = [:]
    var imageDefinitionsDirty = false

    /// Conservative flag indicating unconsumed display math / image markers (`$$` / `![`) may exist.
    var mayHaveMarkers = true
    /// Conservative flag indicating raw inline `$...$` spans may exist.
    var mayHaveInlineMath = true

    var mathPreviewHost: NSHostingView<MathPreviewView>?
    var mathPreviewTask: Task<Void, Never>?
    var mathPreviewPending: (source: String, para: NSRange)?
    var mathActionLocation: Int?

    mutating func cancelAsyncWork() {
        visibleRefreshTask?.cancel()
        visibleRefreshTask = nil
        mathPreviewTask?.cancel()
        mathPreviewTask = nil
        mathPreviewPending = nil
    }
}
