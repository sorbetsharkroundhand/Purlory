import AppKit

/// Native presentation hooks. Knowledge and manuscript transactions remain in workspace owners.
@MainActor protocol EditorWorkspaceInteraction: AnyObject {
    var ownsEscapeKey: Bool { get }
    func mouseDown(_ event: NSEvent) -> Bool
    func mouseDragged(_ event: NSEvent) -> Bool
    func mouseUp(_ event: NSEvent) -> Bool
    func mouseMoved(_ event: NSEvent)
    func mouseExited()
    func keyDown(_ event: NSEvent)
    func selectionDidChange()
    func layoutDidChange()
    func drawBackground(_ dirtyRect: CGRect)
    func draw(_ dirtyRect: CGRect)
    func detach()
    func polishSelection()
    func flash(_ range: NSRange)
}

extension EditorWorkspaceInteraction {
    var ownsEscapeKey: Bool { false }
}
