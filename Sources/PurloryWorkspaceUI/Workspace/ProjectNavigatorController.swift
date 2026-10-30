import AppKit
import Combine
import SwiftUI

@MainActor final class ProjectNavigatorController: ObservableObject {
    @Published private(set) var organization = ProjectNavigation()
    @Published private(set) var collapsed: Set<UUID> = []
    @Published private(set) var dropIndicator: ProjectNavigationDrop?
    weak var session: ProjectSession?
    weak var requests: ProjectEditorRequests?
    weak var completion: CompletionController?
    private var projectID: WritingProjectID?
    private var metadata: Data?
    private var springTask: Task<Void, Never>?
    private var monitor: Any?
    private var dragPanel: NSPanel?
    private var cursorPushed = false
    private var dragSource: ProjectNavigationNode?
    private var dragStart = CGPoint.zero
    private var dragEpoch: UInt64 = 0
    private var dragProject: WritingProjectID?
    private var moved = false
    private weak var dragRoot: NSView?
    private var click: (() -> Void)?
    private var dragDestination: ProjectNavigationDrop?

    func configure(session: ProjectSession, requests: ProjectEditorRequests, completion: CompletionController?) {
        self.session = session; self.requests = requests; self.completion = completion
        guard let project = session.activeProject else { return }
        let changed = projectID != project.id
        guard changed || metadata != project.userData[ProjectNavigation.key] else { return }
        if changed { cancelDrag(); projectID = project.id }
        metadata = project.userData[ProjectNavigation.key]
        do { organization = try ProjectNavigation.read(project) }
        catch { organization = ProjectNavigation(); session.reportError(error) }
        if changed {
            collapsed = Set((session.presentationPreferences.stringArray(forKey: expansionKey) ?? []).compactMap(UUID.init(uuidString:)))
        }
    }
    private var expansionKey: String { "purlory.navigator.collapsed.\(projectID?.rawValue.uuidString ?? "none")" }
    func toggle(_ id: UUID) {
        if collapsed.contains(id) { expand(id) }
        else { collapsed.insert(id); persistExpansion() }
    }
    func expand(_ id: UUID) {
        if collapsed.remove(id) != nil { persistExpansion() }
    }
    private func persistExpansion() { session?.presentationPreferences.set(collapsed.map(\.uuidString), forKey: expansionKey) }
    @discardableResult func perform(_ edit: ProjectNavigationEdit, undo: Bool = true,
                                    project: WritingProjectID? = nil, epoch: UInt64? = nil) -> Bool {
        guard let session, let project = project ?? projectID else { return false }
        do {
            try session.applyNavigation(edit, projectID: project, epoch: epoch,
                undoManager: undo ? requests?.nativeEditor?.undoManager : nil)
            if let requests { configure(session: session, requests: requests, completion: completion) }
            return true
        } catch { session.reportError(error); return false }
    }
    func createFolder(in parent: UUID? = nil) -> UUID? {
        let folder = ProjectFolder(parentID: parent)
        guard perform(.createFolder(folder)) else { return nil }
        if let parent { expand(parent) }
        return folder.id
    }
    func createDocument(_ kind: WritingDocument.Kind, in parent: UUID? = nil) {
        guard let id = session?.createDocument(kind: kind, in: parent) else { return }
        if let parent { expand(parent) }
        requests?.spatialWorkspace?.open(id); requests?.focusEditor()
    }
    func performDrop(_ source: ProjectNavigationNode, destination: ProjectNavigationDrop,
                     project: WritingProjectID, epoch: UInt64) {
        let before = Set(organization.folders.map(\.id))
        guard perform(.drop(source, destination), project: project, epoch: epoch) else { return }
        switch destination {
        case .before, .after: session?.presentationPreferences.set(NavigatorSortMode.manual.rawValue, forKey: "purlory.navigator.sortMode")
        default: break
        }
        if case .inside(.folder(let id)) = destination {
            expand(id)
            if case .document = source,
               organization.folders.first(where: { $0.id == id })?.name == "새 폴더", let session {
                completion?.requestFolderName(for: id, in: session)
            }
        }
        if let folder = organization.folders.first(where: { !before.contains($0.id) }), let session {
            if let parent = folder.parentID { expand(parent) }
            expand(folder.id)
            completion?.requestFolderName(for: folder.id, in: session)
            requests?.spatialWorkspace?.showToast("새 폴더로 묶었습니다")
        }
    }
    func preview(_ destination: ProjectNavigationDrop?) {
        guard dropIndicator != destination else { return }
        dropIndicator = destination
        springTask?.cancel(); springTask = nil
        if case .inside(.folder(let id)) = destination, collapsed.contains(id) {
            let project = projectID
            springTask = Task { [weak self] in
                try? await Task.sleep(for: SidebarDnD.springLoadDelay)
                guard !Task.isCancelled, let self, self.projectID == project else { return }
                self.expand(id)
            }
        }
    }

    static func destination(for source: ProjectNavigationNode, at point: CGPoint, in root: NSView) -> (ProjectNavigatorController, ProjectNavigationDrop)? {
        let rootPoint = root.convert(point, from: nil)
        guard !root.isHiddenOrHasHiddenAncestor, root.bounds.contains(rootPoint),
              root.window?.isVisible != true || root.visibleRect.contains(rootPoint) else { return nil }
        func rows(_ view: NSView) -> [ProjectNavigatorRowDragView] {
            (view as? ProjectNavigatorRowDragView).map { [$0] } ?? view.subviews.flatMap(rows)
        }
        let targets = rows(root)
        func hit(_ row: ProjectNavigatorRowDragView) -> Bool {
            let local = row.convert(point, from: nil)
            // NSHostingView can report an unclipped visibleRect larger than this
            // representable. Never let it expand a row's actual drop bounds.
            return !row.isHiddenOrHasHiddenAncestor && row.bounds.contains(local) && row.visibleRect.contains(local)
        }
        func accepted(_ owner: ProjectNavigatorController, _ destination: ProjectNavigationDrop) -> (ProjectNavigatorController, ProjectNavigationDrop)? {
            if case .folder(let sourceID) = source {
                let parent: UUID?
                switch destination {
                case .root: parent = nil
                case .inside(.folder(let id)): parent = id
                case .inside(.document): return nil
                case .before(let node), .after(let node): parent = owner.organization.parent(of: node)
                }
                if let parent, owner.organization.descendants(of: sourceID).contains(parent) { return nil }
            }
            return (owner, destination)
        }
        // The existing folder boundary belongs to the enclosing list, not the child
        // row above it. Check these small regions before the general background.
        for row in targets where row.node == nil && row.backgroundDrop != nil && hit(row) {
            if let owner = row.owner, let drop = row.backgroundDrop { return accepted(owner, drop) }
        }
        for row in targets where row.node != nil {
            guard let node = row.node, let owner = row.owner else { continue }
            let local = row.convert(point, from: nil)
            guard hit(row) else { continue }
            let ancestors = owner.organization.ancestors(of: node)
            if local.x < CGFloat(ancestors.count) * 14 {
                let level = max(0, Int(local.x / 14))
                let drop: ProjectNavigationDrop = level == 0 ? .root : .inside(.folder(ancestors[level - 1]))
                return accepted(owner, drop)
            }
            if node == source { return nil }
            let fraction = local.y / max(1, row.bounds.height)
            if case .folder(let id) = node, case .document = source {
                return (owner, .inside(.folder(id)))
            }
            if case .folder = source, case .document = node { return nil }
            // Match SidebarDragDrop: edge quarters insert; the center groups/nests.
            // An expanded folder's bottom leads into its children, not after them.
            if fraction < SidebarDnD.edgeZoneFraction { return accepted(owner, .before(node)) }
            if fraction > 1 - SidebarDnD.edgeZoneFraction {
                if case .folder(let id) = node, !owner.collapsed.contains(id) { return accepted(owner, .inside(node)) }
                return accepted(owner, .after(node))
            }
            return accepted(owner, .inside(node))
        }
        if let row = targets.first(where: { $0.node == nil && hit($0) }), let owner = row.owner {
            return (owner, .root)
        }
        return nil
    }

    /// Folder gestures stay in the navigator; manuscript gestures retain the canvas path.
    func beginDrag(_ source: ProjectNavigationNode, event: NSEvent, from view: NSView, click: @escaping () -> Void) {
        cancelDrag()
        guard let session, let projectID, event.buttonNumber == 0 else { return }
        dragSource = source; dragStart = screenLocation(for: event); dragProject = projectID
        dragEpoch = session.activationEpoch; self.click = click
        dragRoot = view.enclosingSpatialCanvas?.hosts[.navigator] ?? view.window?.contentView
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.cancelDrag(); return nil }
            if event.type == .leftMouseDragged { self.continueDrag(event); return nil }
            if event.type == .leftMouseUp { self.finishDrag(event); return nil }
            return event
        }
    }
    func continueDrag(_ event: NSEvent) {
        guard let root = dragRoot, let source = dragSource else { return }
        let pointer = screenLocation(for: event)
        if !moved {
            guard hypot(pointer.x - dragStart.x, pointer.y - dragStart.y) > 5 else { return }
            moved = true; NSCursor.closedHand.push(); cursorPushed = true
            let name: String
            switch source {
            case .folder(let id): name = organization.folders.first { $0.id == id }?.name ?? "폴더"
            case .document(let id): name = session?.document(id)?.title ?? "문서"
            }
            let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 150, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true; panel.level = .floating
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 12).frame(width: 150, height: 32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)))
            panel.orderFrontRegardless(); dragPanel = panel
        }
        let point = root.window?.convertPoint(fromScreen: pointer) ?? event.locationInWindow
        let destination = Self.destination(for: source, at: point, in: root)?.1
        dragDestination = destination; preview(destination)
        dragPanel?.setFrameOrigin(CGPoint(x: pointer.x + 12, y: pointer.y - 20))
        root.enclosingScrollView?.contentView.autoscroll(with: event)
    }
    func finishDrag(_ event: NSEvent) {
        guard dragSource != nil else { return }
        if moved { continueDrag(event) }
        let source = dragSource, destination = dragDestination, project = dragProject, epoch = dragEpoch
        let click = moved ? nil : self.click
        cancelDrag()
        if let source, let destination, let project {
            performDrop(source, destination: destination, project: project, epoch: epoch)
        } else {
            click?()
        }
    }
    private func screenLocation(for event: NSEvent) -> CGPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    func cancelDrag() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        dragPanel?.orderOut(nil); dragPanel?.close(); dragPanel = nil
        if cursorPushed { NSCursor.pop() }; cursorPushed = false
        dragSource = nil; dragDestination = nil; dragProject = nil; moved = false; click = nil
        preview(nil)
    }
}
