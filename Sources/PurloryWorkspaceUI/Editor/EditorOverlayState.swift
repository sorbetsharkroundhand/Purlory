import AppKit
import SwiftUI

/// Caret blink, active-line selection rect, ghost fade, floating toolbar, and conversation prompt state owned by `BlockTextView`.
@MainActor
struct EditorOverlayState {
    var ghostOpacity: CGFloat = 1
    var ghostFadeTask: Task<Void, Never>?
    var ghostGeneration = 0

    var lastSelectionRect: NSRect?
    var refreshingEditingOverlays = false
    var editingOverlayRefreshPending = false
    var pendingCaretBlinkRestart = false

    var toolbarHost: NSHostingView<SelectionToolbarView>?
    var workspaceSelectionPanel: NSPanel?
    var toolbarShowTask: Task<Void, Never>?
    var imageToolbarHost: NSHostingView<ImageObjectToolbarView>?
    var imageAltEditorHost: NSHostingView<ImageAltEditorView>?

    var caretBlinkTimer: Timer?
    var conversationPromptRange: NSRange?

    mutating func teardown() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        ghostFadeTask?.cancel()
        ghostFadeTask = nil
        toolbarShowTask?.cancel()
        toolbarShowTask = nil
    }
}
