import Foundation

/// Centralized timing parameters for editor overlays, media refreshes, and completion cadence.
enum EditorTiming {
    /// Caret blink interval in seconds for the custom high-contrast cursor overlay.
    static let caretBlinkInterval: TimeInterval = 0.55
    /// Caret fade animation duration in seconds on each blink step.
    static let caretBlinkFadeDuration: TimeInterval = 0.18
    /// Coalescing delay before presenting the floating selection toolbar after drag/selection settles.
    static let selectionToolbarDelay: Duration = .milliseconds(120)
    /// Coalescing delay before refreshing visible math/image attachment renders on scroll.
    static let mediaRefreshDelay: Duration = .milliseconds(120)
    /// Delay before updating the live LaTeX math preview popover while typing.
    static let mathPreviewDelay: Duration = .milliseconds(150)
    /// Idle pause after typing before capturing a completed dialogue line.
    static let conversationIdleDelay: Duration = .milliseconds(1_500)
}
