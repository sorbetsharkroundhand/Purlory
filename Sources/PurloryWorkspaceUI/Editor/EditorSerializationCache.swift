import Foundation
import PurloryDocumentEngine

/// Incremental Markdown serialization cache owned by `BlockTextView`.
/// Tracks per-paragraph serialized lines, dirty ranges, and single-paragraph fast-path cursors.
@MainActor
struct EditorSerializationCache {
    var markdownCodec = MarkdownDocumentCodec()
    var lines: [(text: String, isCode: Bool, codeLang: String?)] = []
    var rebuildCount = 0
    /// When `false`, the next `serialize()` rebuilds every paragraph as a safe fallback.
    var isValid = false
    /// When `true`, only the tracked cursor paragraph needs re-serialization.
    var isFastDirty = false
    var fastIndex: Int?
    var fastStart = 0
    var syncedLength = 0
    var dirtyRange: NSRange?
    var pendingTracked = false
    var pendingRemovedNewlines = 0

    var isClean: Bool { isValid && dirtyRange == nil && !isFastDirty }

    mutating func invalidate() {
        isValid = false
        isFastDirty = false
        dirtyRange = nil
    }

    mutating func notePendingEdit(tracked: Bool, removedNewlines: Int) {
        pendingTracked = tracked
        pendingRemovedNewlines = removedNewlines
    }

    mutating func consumePendingEdit(hasCharacterEdit: Bool) -> (tracked: Bool, removedNewlines: Int) {
        let result = hasCharacterEdit ? (pendingTracked, pendingRemovedNewlines) : (false, 0)
        if hasCharacterEdit {
            pendingTracked = false
            pendingRemovedNewlines = 0
        }
        return result
    }
}
