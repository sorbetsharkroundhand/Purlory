import AppKit
import SwiftUI

struct SpatialNavigatorPane: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var model: SpatialWorkspaceController
    var completion: CompletionController? = nil
    let theme: PurloryTheme
    let onClose: () -> Void
    var body: some View {
        ProjectNavigatorView(session: session, editorRequests: requests, theme: theme,
            onClose: onClose, spatial: model, completion: completion)
    }
}

struct SpatialNavigatorDragRegion: NSViewRepresentable {
    let documentID: WritingDocumentID
    let onClick: () -> Void
    func makeNSView(context: Context) -> SpatialNavigatorDragView { SpatialNavigatorDragView() }
    func updateNSView(_ view: SpatialNavigatorDragView, context: Context) {
        view.documentID = documentID; view.onClick = onClick
        view.setAccessibilityIdentifier("purlory.navigator.drag.\(documentID.rawValue.uuidString)")
        view.setAccessibilityElement(false)
        view.toolTip = "위·아래로 순서 변경 · 작업 공간에 끌어다 놓아 열기"
    }
}

final class SpatialNavigatorDragView: NSView {
    var documentID = WritingDocumentID()
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        enclosingSpatialCanvas?.beginPanelDrag(.document(documentID), event: event, fromNavigator: true)
    }
    override func mouseDragged(with event: NSEvent) { enclosingSpatialCanvas?.continuePanelDrag(event) }
    override func mouseUp(with event: NSEvent) {
        let moved = enclosingSpatialCanvas?.model?.isDragging == true
        enclosingSpatialCanvas?.finishPanelDrag(event)
        if !moved { onClick?() }
    }
    override func cancelOperation(_ sender: Any?) { enclosingSpatialCanvas?.cancelInteraction() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
