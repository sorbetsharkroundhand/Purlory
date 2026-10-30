import AppKit
import Combine
import QuartzCore
import SwiftUI

struct WorkspacePouchAction {
    let id: String
    let label: String
    let symbol: String
    var selected: () -> Bool = { false }
    var enabled: () -> Bool = { true }
    let perform: () -> Void
}

/// A collapsed workspace is still an open workspace, even without a visible
/// document window. Its widget must outlive transient animation panels/views.
@MainActor public enum WorkspacePouchLifetime {
    private static var retained: [ObjectIdentifier: WorkspacePouchController] = [:]

    public static var hasCollapsedWorkspace: Bool { retained.values.contains { $0.isCollapsed } }

    static func controller(for window: NSWindow) -> WorkspacePouchController? {
        retained.values.first { $0.window === window }
    }

    @discardableResult public static func restoreCollapsedWorkspaces() -> Bool {
        let workspaces = retained.values.filter { $0.isCollapsed }
        for workspace in workspaces { workspace.restore() }
        return !workspaces.isEmpty
    }

    fileprivate static func retain(_ controller: WorkspacePouchController) {
        retained[ObjectIdentifier(controller)] = controller
    }

    fileprivate static func release(_ controller: WorkspacePouchController) {
        retained.removeValue(forKey: ObjectIdentifier(controller))
    }
}

@MainActor final class WorkspacePouchController: NSObject {
    private(set) var panel: NSPanel?
    private(set) var isCollapsed = false
    private(set) var isDragging = false
    var reduceMotion = false
    var reduceTransparency = false
    var theme: PurloryTheme = .light { didSet { refresh() } }
    var actions: [WorkspacePouchAction] = [] { didSet { refresh() } }
    var extraActions: [WorkspacePouchAction] = []
    var targetTitle = "Purlory" { didSet { content?.targetTitle = targetTitle } }
    weak var requests: ProjectEditorRequests?
    fileprivate weak var window: NSWindow?
    private var collapsedWindow: NSWindow?
    private weak var workspaceView: NSView?
    private weak var previousResponder: NSResponder?
    private let model: SpatialWorkspaceController
    private let defaults: UserDefaults
    private var content: WorkspacePouchView?
    private var escapeMonitor: Any?
    private var toolsWereExpanded = false
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var start: CGPoint?
    private var grabOffset = CGPoint(x: 22, y: 22)
    private var dragMonitor: Any?
    private var draggingCursor = false
    private var target = CGPoint.zero
    private var spring = WorkspaceSpringPoint(position: .zero)
    private var timer: WorkspaceDisplayClock?
    private var lastStep = ProcessInfo.processInfo.systemUptime
    private(set) var transition: NSPanel?
    private var transitionGeneration: UInt64 = 0
    private var collapsedImage: NSImage?
    private struct SnapshotAnimation {
        weak var window: NSWindow?
        let ghost: NSPanel
        let from: CGRect
        let to: CGRect
        let began: Double
        let duration: Double
        let expanding: Bool
        let generation: UInt64
    }
    private var snapshotAnimation: SnapshotAnimation?
    private var snapshotClock: WorkspaceDisplayClock?
    // Share the canvas display clock and permit exact intermediate-frame checks.
    var snapshotAnimationTime: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var isAttached: Bool { content?.superview === model.canvas && model.canvas != nil }

    init(model: SpatialWorkspaceController, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        super.init()
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.model.canvas?.layoutTiles()
                self?.refresh(); self?.syncAttachment()
            }
        }
        model.pouchGeometryDidChange = { [weak self] in self?.syncAttachment() }
        model.dismissObject = { [weak self] tile in self?.dismissObject(tile) }
        model.pouchController = self
    }

    func attach(to window: NSWindow, from workspaceView: NSView? = nil) {
        guard self.window !== window else {
            if let workspaceView { self.workspaceView = workspaceView }
            refresh(); syncAttachment(); return
        }
        detach(); self.window = window; self.workspaceView = workspaceView
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Purlory 주머니"; panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = WorkspacePouchView(); content.controller = self
        content.setAccessibilityIdentifier("purlory.workspace.rail"); content.setAccessibilityLabel("주머니 도구창")
        panel.contentView = content; self.panel = panel; self.content = content
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type != .keyDown {
                let trigger = self.model.pouchAnchor
                let hitsTrigger = trigger.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                if self.model.pouchSection != nil, !hitsTrigger, let content = self.content,
                   !content.containsControl(at: content.convert(event.locationInWindow, from: nil)) { self.dismissTools() }
                return event
            }
            guard event.keyCode == 53,
                  self.window?.attachedSheet == nil, NSApp.modalWindow == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !self.isCollapsed, !self.isDragging, !self.model.isDragging else { return event }
            if let text = self.window?.firstResponder as? NSTextView, text.hasMarkedText() { return event }
            if let editor = self.window?.firstResponder as? BlockTextView, editor.ownsEscapeKey { return event }
            guard self.model.pouchSection != nil else { return event }
            if event.isARepeat { return nil }
            self.dismissTools()
            return nil
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dock(immediate: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dock(immediate: true) }
        })
        refresh(); dock(immediate: true)
    }

    func detach() {
        stopDragTracking()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        cancelTransition(); collapsedImage = nil
        content?.removeFromSuperview()
        panel?.orderOut(nil); panel?.close(); panel = nil; content = nil; window = nil
        start = nil; isDragging = false; isCollapsed = false
        collapsedWindow = nil
        workspaceView = nil
        WorkspacePouchLifetime.release(self)
    }

    func detachFromWorkspaceView(_ view: NSView) {
        guard workspaceView === view else { return }
        workspaceView = nil
        // SwiftUI may detach the bridge while the document window is hidden.
        // Only an actual window close or an explicit detach disposes its widget.
        guard !isCollapsed else { return }
        detach()
    }

    func setTools(_ root: AnyView) { content?.setTools(root) }

    private weak var grabButton: WorkspacePouchButton?
    func beginDrag(at point: CGPoint, from button: WorkspacePouchButton? = nil) {
        guard isCollapsed else { return }
        stopDragTracking()
        grabButton = button
        start = point; isDragging = false
        if isCollapsed, let panel {
            grabOffset = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        } else { grabOffset = CGPoint(x: 22, y: 22) }
        // Own the gesture before the rail's buttons are hidden or its parent window
        // is ordered out. Tracking must not depend on the original hit-test view.
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.start != nil else { return event }
            // The pouch moves between events. Sample desktop coordinates directly
            // instead of converting through the panel's newly moved origin.
            let point = NSEvent.mouseLocation
            if event.type == .leftMouseDragged {
                self.updateDrag(to: point)
                return nil
            }
            let moved = self.endDrag(at: point)
            // Preserve a stationary button click; consume a drag's mouse-up so the
            // newly exposed orb cannot immediately reopen the collapsed window.
            return moved ? nil : event
        }
    }
    func updateDrag(to point: CGPoint) {
        guard isCollapsed, let start else { return }
        if !isDragging {
            guard hypot(point.x - start.x, point.y - start.y) > 7 else { return }
            isDragging = true; NSCursor.closedHand.push(); draggingCursor = true
        }
        target = WorkspacePouchGeometry.clampOrb(
            CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y), screen: screenFrame(for: point), margin: 6)
        moveTowardTarget()
    }
    @discardableResult func endDrag(at point: CGPoint) -> Bool {
        guard start != nil else { return false }
        if isDragging { updateDrag(to: point) }
        start = nil
        let moved = isDragging; isDragging = false
        content?.clearPressedState(); stopDragTracking()
        if moved {
            target = WorkspacePouchGeometry.clampOrb(target, screen: screenFrame(for: point))
            moveTowardTarget()
        }
        refresh(); return moved
    }

    private func stopDragTracking() {
        grabButton?.highlight(false); grabButton = nil
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        if draggingCursor { NSCursor.pop(); draggingCursor = false }
    }

    func collapse() {
        guard !isCollapsed, let window, let panel else { return }
        model.pouchSection = nil
        releaseContentToPanel()
        target = CGPoint(x: panel.frame.midX - 22, y: panel.frame.midY - 22)
        spring.position = target
        previousResponder = window.firstResponder
        // Hiding a retained window is a presentation change, not an editor commit.
        // Keep marked text and the native selection with the same first responder;
        // do not enqueue diagnostics/autosave by synthesizing didChangeText here.
        target = WorkspacePouchGeometry.clampOrb(target, screen: screenFrame(for: target))
        collapsedWindow = window
        isCollapsed = true
        WorkspacePouchLifetime.retain(self)
        cancelTransition()
        // Make the orb independent of application activation before hiding the window.
        refresh()
        panel.orderFrontRegardless()
        if !reduceMotion {
            animateSnapshot(of: window, toward: collapsedSnapshotFrame(window: window, orb: CGRect(origin: target, size: CGSize(width: 44, height: 44))))
        }
        window.orderOut(nil)
        panel.orderFrontRegardless(); moveTowardTarget()
    }
    func restore() {
        guard isCollapsed, let window else { return }
        let origin = panel?.frame ?? CGRect(origin: target, size: CGSize(width: 44, height: 44))
        stopDragTracking(); cancelTransition()
        isCollapsed = false; isDragging = false; start = nil
        if !reduceMotion { window.alphaValue = 0 }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let previousResponder { window.makeFirstResponder(previousResponder) }
        collapsedWindow = nil
        // Retain the controller until an actual detach/close. A recreated SwiftUI
        // bridge adopts it, including when restoration happens before that bridge.
        refresh(); dock(immediate: false)
        if !reduceMotion {
            animateSnapshot(of: window, toward: window.frame, expandingFrom: collapsedSnapshotFrame(window: window, orb: origin))
        } else { collapsedImage = nil }
    }

    func refresh() {
        guard let panel, let content else { return }
        // The pouch is an independent panel and does not inherit SwiftUI's
        // preferredColorScheme from the manuscript window.
        let appearanceName: NSAppearance.Name = theme.editorSurface.relativeLuminance < 0.5 ? .darkAqua : .aqua
        if panel.appearance?.name != appearanceName {
            panel.appearance = NSAppearance(named: appearanceName)
        }
        content.appearance = panel.appearance
        content.toolsExpanded = isAttached && model.pouchSection != nil
        content.targetTitle = targetTitle
        content.configure(orb: isCollapsed, horizontal: false, actions: [], theme: theme, attached: isAttached)
        panel.hidesOnDeactivate = !isCollapsed; panel.canHide = !isCollapsed
        panel.alphaValue = 1; panel.ignoresMouseEvents = false
        if isCollapsed {
            panel.setFrame(CGRect(origin: spring.position, size: CGSize(width: 44, height: 44)), display: false)
            panel.orderFrontRegardless()
        } else { panel.orderOut(nil) }
        content.needsLayout = true; content.needsDisplay = true
    }
    func toggleTools(for tile: WorkspaceTileID? = nil) {
        if let tile { model.selectTile(tile) }
        if model.pouchSection != nil { dismissTools(); return }
        model.openPouchTools()
        refresh(); syncAttachment()
    }
    private func dock(immediate: Bool) {
        guard let window, let panel else { return }
        guard isCollapsed else { panel.orderOut(nil); syncAttachment(); return }
        target = WorkspacePouchGeometry.clampOrb(target, screen: screenFrame(for: target))
        if immediate { spring = WorkspaceSpringPoint(position: target); panel.setFrameOrigin(target) }
        else { moveTowardTarget() }
        if window.isVisible || isCollapsed { panel.orderFrontRegardless() }
    }
    private func moveTowardTarget() {
        guard let panel else { return }
        if reduceMotion {
            timer?.invalidate(); timer = nil
            spring = WorkspaceSpringPoint(position: target); panel.setFrameOrigin(target)
            return
        }
        guard timer == nil else { return }
        lastStep = ProcessInfo.processInfo.systemUptime
        guard let view = panel.contentView else { return }
        timer = WorkspaceDisplayClock(view: view) { [weak self] in
            guard let self else { return false }
            self.step()
            return self.timer != nil
        }
    }
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - lastStep; lastStep = now
        spring.step(target: target, stiffness: isDragging ? 640 : 280, damping: isDragging ? 50 : 34, elapsed: elapsed)
        panel?.setFrameOrigin(spring.position)
        if spring.isSettled(at: target) {
            timer?.invalidate(); timer = nil
            panel?.setFrameOrigin(target)
        }
    }

    private func attachmentFrame() -> (canvas: SpatialWorkspaceCanvasView, local: CGRect, screen: CGRect)? {
        guard let canvas = model.canvas, canvas.window === window,
              let placement = canvas.pouchPlacement(), let window else { return nil }
        let local = placement.trigger.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY)
        return (canvas, local, window.convertToScreen(canvas.convert(local, to: nil)))
    }

    /// The card is always anchored to window chrome, independently of tile selection.
    func syncAttachment() {
        guard !isCollapsed, !isDragging, window?.isVisible == true,
              let destination = attachmentFrame(), let content, let panel else { return }
        if !isAttached {
            panel.contentView = nil; content.removeFromSuperview()
            destination.canvas.addSubview(content, positioned: .above, relativeTo: nil)
            content.autoresizingMask = []
        }
        panel.orderOut(nil); refresh(); updateAttachedFrame()
    }

    private func releaseContentToPanel() {
        guard isAttached, let content, let panel, let window else { return }
        returnToolFocus()
        // Preserve the grab origin when the expanded card leaves the canvas.
        let lip = content.placement?.trigger ?? content.bounds
        let rect = window.convertToScreen(content.convert(lip, to: nil))
        content.hideToolsImmediately(); content.placement = nil; toolsWereExpanded = false
        content.removeFromSuperview(); panel.contentView = content
        panel.setFrame(rect, display: false)
        spring = WorkspaceSpringPoint(position: CGPoint(x: rect.midX - 22, y: rect.midY - 22))
    }

    private func returnToolFocus() {
        guard content?.toolsOwnFirstResponder == true else { return }
        let editor = model.projectID.flatMap { project in
            model.selectedTile?.documentID.flatMap { requests?.editor(for: .init(projectID: project, documentID: $0)) }
        } ?? requests?.nativeEditor
        window?.makeFirstResponder(editor)
    }

    private func updateAttachedFrame() {
        guard let content, let placement = model.canvas?.pouchPlacement() else { return }
        if let canvas = model.canvas, canvas.subviews.last !== content {
            canvas.addSubview(content, positioned: .above, relativeTo: nil)
        }
        let opened = !toolsWereExpanded && model.pouchSection != nil
        toolsWereExpanded = model.pouchSection != nil
        if content.placement != placement {
            content.placement = placement; content.frame = placement.frame
        }
        if opened { content.revealTools(reduceMotion: reduceMotion) }
    }
    func dismissTools() {
        guard model.pouchSection != nil else { return }
        returnToolFocus()
        model.pouchSection = nil
        content?.hideToolsImmediately()
        refresh(); syncAttachment()
        content?.layoutSubtreeIfNeeded()
    }
    func dismissObject(_ tile: WorkspaceTileID) {
        returnToolFocus()
        if tile.documentID != nil && model.layout.openDocuments.count <= 1 {
            window?.performClose(nil)
        } else if model.close(tile) { requests?.focusEditor() }
    }
    private func screenFrame(for point: CGPoint) -> CGRect {
        (NSScreen.screens.first { $0.visibleFrame.contains(point) } ?? window?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
    func showMoreMenu(in view: NSView) {
        moreMenu().popUp(positioning: nil, at: CGPoint(x: view.bounds.maxX, y: view.bounds.midY), in: view)
    }
    func moreMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (index, action) in menuActions.enumerated() {
            let item = NSMenuItem(title: action.label, action: #selector(invokeExtra(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.state = action.selected() ? .on : .off; item.isEnabled = action.enabled()
            item.setAccessibilityIdentifier(action.id); menu.addItem(item)
        }
        return menu
    }
    @objc private func invokeExtra(_ item: NSMenuItem) {
        guard menuActions.indices.contains(item.tag), menuActions[item.tag].enabled() else { return }; menuActions[item.tag].perform()
    }
    private var menuActions: [WorkspacePouchAction] { (isAttached ? actions : []) + extraActions }
    private func cancelTransition() {
        snapshotClock?.invalidate(); snapshotClock = nil; snapshotAnimation = nil
        transitionGeneration &+= 1
        transition?.orderOut(nil); transition?.close(); transition = nil
        window?.alphaValue = 1
    }

    private func animateSnapshot(of window: NSWindow, toward rect: CGRect, expandingFrom origin: CGRect? = nil) {
        let image: NSImage
        if origin != nil, let cached = collapsedImage {
            image = cached
        } else {
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                window.alphaValue = 1
                return
            }
            // Capture once per collapse, never on pointer movement or animation ticks.
            view.cacheDisplay(in: view.bounds, to: bitmap)
            image = NSImage(size: view.bounds.size); image.addRepresentation(bitmap)
            if origin == nil { collapsedImage = image }
        }
        let generation = transitionGeneration
        let ghost = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ghost.isReleasedWhenClosed = false; ghost.ignoresMouseEvents = true; ghost.level = .floating
        ghost.isOpaque = false; ghost.backgroundColor = .clear; ghost.hasShadow = false
        ghost.hidesOnDeactivate = false; ghost.animationBehavior = .none
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: window.frame.size))
        imageView.image = image; imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = "collapseBlur"
        blur?.setValue(origin == nil ? 12 : 0, forKey: kCIInputRadiusKey)
        if let blur { imageView.layer?.filters = [blur] }
        let blurAnimation = CABasicAnimation(keyPath: "filters.collapseBlur.inputRadius")
        blurAnimation.fromValue = origin == nil ? 0 : 10; blurAnimation.toValue = origin == nil ? 12 : 0
        blurAnimation.duration = origin == nil ? 0.12 : 0.14
        blurAnimation.timingFunction = origin == nil ? CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1) : WorkspaceHTMLStyle.calm
        imageView.layer?.add(blurAnimation, forKey: "pouch.blur")
        ghost.contentView = imageView; transition = ghost
        if let origin { ghost.setFrame(origin, display: false); ghost.alphaValue = 0; window.alphaValue = 0 }
        ghost.orderFrontRegardless()
        snapshotAnimation = SnapshotAnimation(window: window, ghost: ghost, from: ghost.frame,
            to: rect, began: snapshotAnimationTime(), duration: origin == nil ? 0.12 : 0.14,
            expanding: origin != nil, generation: generation)
        snapshotClock = WorkspaceDisplayClock(view: imageView) { [weak self] in
            guard let self else { return false }
            self.stepSnapshotAnimation()
            return self.snapshotAnimation != nil
        }
    }

    func stepSnapshotAnimation() {
        guard let animation = snapshotAnimation,
              transitionGeneration == animation.generation, transition === animation.ghost else { return }
        let elapsed = max(0, (snapshotAnimationTime() - animation.began) / animation.duration)
        let t = animation.expanding ? WorkspaceHTMLStyle.progress(elapsed)
            : WorkspaceHTMLStyle.progress(elapsed, x1: 0.4, y1: 0, x2: 0.2, y2: 1)
        let from = animation.from, to = animation.to
        animation.ghost.setFrame(CGRect(x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t), display: true)
        animation.ghost.alphaValue = animation.expanding ? t : 1 - t
        guard elapsed >= 1 else { return }
        animation.window?.alphaValue = 1
        animation.ghost.orderOut(nil); animation.ghost.close()
        transition = nil; snapshotAnimation = nil
        snapshotClock?.invalidate(); snapshotClock = nil
        if animation.expanding { collapsedImage = nil }
    }
    private func collapsedSnapshotFrame(window: NSWindow, orb: CGRect) -> CGRect {
        let size = CGSize(width: window.frame.width * 0.03, height: window.frame.height * 0.03)
        return CGRect(x: orb.midX - size.width / 2, y: orb.midY - size.height / 2, width: size.width, height: size.height)
    }
}
