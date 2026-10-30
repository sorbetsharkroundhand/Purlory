import AppKit
import Combine

struct SpatialNavigatorDrop: Equatable {
    let source: WritingDocumentID
    let target: WritingDocumentID
    let after: Bool
}

struct WorkspaceEntityEvent: Equatable {
    let name: String
    let note: String
    let reference: OriginalSourceReference
}

@MainActor final class SpatialWorkspaceController: ObservableObject {
    @Published private(set) var layout = SpatialWorkspaceLayout(documents: [], selected: nil)
    @Published private(set) var previewTarget: SpatialDropTarget?
    private(set) var pointer = CGPoint.zero
    @Published private(set) var isDragging = false
    @Published var typewriter = false { didSet { persist() } }
    @Published var focusDimming = false { didSet { persist() } }
    @Published var whisperTyping = false
    @Published var expandedItem: String?
    @Published private(set) var selectedTile: WorkspaceTileID?
    @Published var pouchSection: WorkspacePouchSection?
    @Published var searchRequest = WorkspaceSearchRequest()
    @Published private(set) var revealSequence = 0
    private(set) var tileToReveal: WorkspaceTileID?
    weak var canvas: SpatialWorkspaceCanvasView?
    weak var pouchController: WorkspacePouchController?
    weak var pouchAnchor: NSView?
    private(set) var pouchContentHeight: CGFloat = 0
    func setPouchContentHeight(_ height: CGFloat, for tile: WorkspaceTileID?) {
        guard height.isFinite, height > 0, abs(pouchContentHeight - ceil(height)) > 0.5 else { return }
        pouchContentHeight = ceil(height)
        pouchGeometryDidChange?()
    }
    var pouchGeometryDidChange: (() -> Void)?
    var dismissObject: ((WorkspaceTileID) -> Void)?
    var onClose: ((WorkspaceTileID) -> Void)?
    var advanceSearch: ((Int) -> Void)?
    private func reveal(_ tile: WorkspaceTileID) { tileToReveal = tile; revealSequence += 1 }

    func selectTile(_ tile: WorkspaceTileID?) {
        guard selectedTile != tile else { return }
        selectedTile = tile
    }
    func openSearch(scope: WorkspaceSearchScope = .project, query: String? = nil) {
        if !layout.contains(.search) { layout.toggle(.search); commit() }
        selectTile(.search)
        searchRequest = .init(sequence: searchRequest.sequence + 1, scope: scope,
            query: query, documentID: activeDocumentID)
        reveal(.search)
    }
    func openPouchTools() {
        whisperTyping = false
        pouchSection = .overview
    }
    @Published var navigatorDrop: SpatialNavigatorDrop?
    @Published var resonatingTerm: String?
    @Published var activeParagraph = ""
    var entityTerms: [String] = []
    @Published var entityEvents: [WorkspaceEntityEvent] = []
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?
    func showToast(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
    private(set) var activeDocumentID: WritingDocumentID?
    private(set) var restoredPreference = false
    private var whisperOrigin = CGPoint.zero
    func noteTyping(at point: CGPoint) {
        whisperOrigin = point
        if !whisperTyping { whisperTyping = true }
        if pouchSection != nil { pouchSection = nil }
    }
    func notePointer(at point: CGPoint) {
        if whisperTyping && hypot(point.x - whisperOrigin.x, point.y - whisperOrigin.y) > 48 { whisperTyping = false }
    }
    var onCommit: ((SpatialWorkspaceLayout) -> Void)?
    var onTileReorder: ((SpatialWorkspaceLayout) -> Void)?
    var onActivate: ((WritingDocumentID) -> Void)?
    var onNavigationOrder: (([WritingDocumentID]) -> Void)?
    private(set) var projectID: WritingProjectID?
    private var defaults: UserDefaults
    private var validDocuments: [WritingDocumentID] = []
    private var drag: DragSession?
    private var loading = false

    private struct DragSession {
        let draggedTileID: WorkspaceTileID
        let originLayout: SpatialWorkspaceLayout
        let initialFrame: CGRect?
        let grabOffset: CGPoint
        let startPoint: CGPoint
        let fromNavigator: Bool
        var currentPointerInCanvas: CGPoint
        var activeDropTarget: SpatialDropTarget?
        var lastTarget: SpatialDropTarget?
        var baseGeometrySnapshot: SpatialWorkspaceGeometry?
    }
    private struct Preference: Codable {
        var version = 1
        var layout: SpatialWorkspaceLayout
        var typewriter: Bool
        var focusDimming: Bool
    }

    private(set) var undoStack: [SpatialWorkspaceLayout] = []
    private(set) var redoStack: [SpatialWorkspaceLayout] = []
    var canUndoLayout: Bool { !undoStack.isEmpty }
    var canRedoLayout: Bool { !redoStack.isEmpty }

    func undoLayout() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(layout)
        layout = previous
        commit()
    }

    func redoLayout() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(layout)
        layout = next
        commit()
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var draggedTile: WorkspaceTileID? { isDragging ? drag?.draggedTileID : nil }
    var dragFromNavigator: Bool { drag?.fromNavigator == true }
    var isTabDrop: Bool { if case .tab = previewTarget { true } else { false } }
    var isDocumentListDrop: Bool { previewTarget == .documentList }
    var retainedTiles: [WorkspaceTileID] { drag?.originLayout.allTiles ?? layout.allTiles }
    var baseDragGeometry: SpatialWorkspaceGeometry? { drag?.baseGeometrySnapshot }
    var presentationLayout: SpatialWorkspaceLayout {
        layout
    }

    func configure(project: WritingProject, selected: WritingDocumentID?, defaults: UserDefaults? = nil) {
        if let defaults { self.defaults = defaults }
        let previousDocument = projectID == project.id ? activeDocumentID : nil
        activeDocumentID = selected
        let nextDocuments = project.documents.filter { !project.trashedDocumentIDs.contains($0.id) }.map(\.id)
        if nextDocuments != validDocuments { cancelDrag() }
        validDocuments = nextDocuments
        if projectID != project.id {
            cancelDrag(); loading = true; projectID = project.id
            undoStack.removeAll(); redoStack.removeAll()
            selectedTile = nil; pouchSection = nil; searchRequest = .init(); advanceSearch = nil
            if let data = self.defaults.data(forKey: preferenceKey),
               let saved = try? JSONDecoder().decode(Preference.self, from: data), saved.version == 1 {
                layout = saved.layout; typewriter = saved.typewriter; focusDimming = saved.focusDimming
                restoredPreference = true
            } else {
                restoredPreference = false
                layout = SpatialWorkspaceLayout(documents: validDocuments, selected: selected,
                    navigatorVisible: self.defaults.object(forKey: "purlory.sidebarVisible") as? Bool ?? true)
                typewriter = false; focusDimming = false
            }
            whisperTyping = false; expandedItem = nil; toastTask?.cancel(); toast = nil
            entityEvents = []; loading = false
        }
        guard !isDragging else { return }
        var normalized = layout
        normalized.normalize(validDocuments: validDocuments)
        if let selected, validDocuments.contains(selected) { normalized.openDocument(selected, in: previousDocument) }
        if normalized != layout { layout = normalized }
        persist()
    }

    func open(_ id: WritingDocumentID) {
        guard validDocuments.contains(id) else { return }
        cancelDrag()
        layout.openDocument(id, in: activeDocumentID)
        activeDocumentID = id; selectTile(.document(id))
        commit(); reveal(.document(id)); onActivate?(id)
    }
    func openAll() { cancelDrag(); layout.openAll(validDocuments); commit(); showToast("\(validDocuments.count)개 파일을 나란히 펼쳤습니다") }
    func toggle(_ tile: WorkspaceTileID) {
        // Decode old layouts/commands, but never recreate the retired settings object.
        if tile == .inspector { openPouchTools(); return }
        cancelDrag(); layout.toggle(tile)
        if layout.contains(tile) { selectTile(tile); reveal(tile) }
        else if selectedTile == tile { selectTile(nil) }
        commit()
    }
    @discardableResult func close(_ tile: WorkspaceTileID) -> Bool {
        cancelDrag()
        guard layout.contains(tile) else { return false }
        let siblings = layout.slot(containing: tile)?.tabs ?? []
        guard layout.close(tile) else { showToast("최소 1개의 원고는 열려 있어야 합니다"); return false }
        if selectedTile == tile { selectTile(nil) }
        if let closed = tile.documentID, activeDocumentID == closed {
            let next = siblings.compactMap { layout.slot(containing: .document($0))?.tile.documentID }.first
                ?? layout.tiles.compactMap(\.documentID).first
            activeDocumentID = next
            if let next { selectTile(.document(next)); onActivate?(next) }
        }
        commit(); onClose?(tile); return true
    }
    func setLayout(_ value: SpatialWorkspaceLayout, persist: Bool = true) {
        layout = value
        if persist { commit() }
    }

    func beginDrag(_ tile: WorkspaceTileID, at point: CGPoint, fromNavigator: Bool = false, initialFrame: CGRect? = nil, baseGeometry: SpatialWorkspaceGeometry? = nil) {
        cancelDrag()
        if let id = tile.documentID { guard validDocuments.contains(id), fromNavigator || layout.contains(tile) else { return } }
        else { guard layout.contains(tile) else { return } }
        let offset = initialFrame.map { CGPoint(x: point.x - $0.minX, y: point.y - $0.minY) } ?? .zero
        drag = DragSession(
            draggedTileID: tile,
            originLayout: layout,
            initialFrame: initialFrame,
            grabOffset: offset,
            startPoint: point,
            fromNavigator: fromNavigator,
            currentPointerInCanvas: point,
            activeDropTarget: nil,
            lastTarget: nil,
            baseGeometrySnapshot: baseGeometry
        )
        pointer = point
    }

    func updateDrag(to point: CGPoint, geometry: SpatialWorkspaceGeometry, tabTarget: SpatialDropTarget? = nil) {
        guard var drag else { return }
        pointer = point
        drag.currentPointerInCanvas = point
        if drag.baseGeometrySnapshot == nil {
            drag.baseGeometrySnapshot = geometry
        }
        if !isDragging {
            guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) > 5 else {
                self.drag = drag
                return
            }
            isDragging = true
        }
        var hitGeometry = drag.baseGeometrySnapshot ?? geometry
        if let source = drag.originLayout.slot(containing: drag.draggedTileID), source.tabs.count > 1,
           let sibling = source.tabs.first(where: { $0 != drag.draggedTileID.documentID }),
           let rect = hitGeometry.tiles[drag.draggedTileID] {
            hitGeometry.tiles.removeValue(forKey: drag.draggedTileID)
            hitGeometry.tiles[.document(sibling)] = rect
        }
        let originLayout = drag.originLayout
        let draggedTileID = drag.draggedTileID
        let nextTarget = tabTarget ?? hitGeometry.dropTarget(
            at: point,
            dragging: draggedTileID,
            fromNavigator: drag.fromNavigator,
            lastTarget: drag.activeDropTarget,
            tabsInTile: { originLayout.slot(containing: $0)?.tabs.count ?? 1 },
            isSameSlot: { originLayout.slot(containing: $0)?.contains(draggedTileID) == true }
        )
        drag.activeDropTarget = nextTarget
        if previewTarget != nextTarget {
            previewTarget = nextTarget
        }
        if let nextTarget { drag.lastTarget = nextTarget }
        // Invariant: Keep layout identical to originLayout throughout the entire drag session.
        if layout != drag.originLayout { layout = drag.originLayout }
        self.drag = drag
    }

    func endDrag() {
        guard let drag else { return }
        guard isDragging else { self.drag = nil; return }
        if drag.fromNavigator, let navigatorDrop {
            var order = validDocuments.filter { $0 != navigatorDrop.source }
            if let target = order.firstIndex(of: navigatorDrop.target) {
                order.insert(navigatorDrop.source, at: target + (navigatorDrop.after ? 1 : 0))
                validDocuments = order; layout = drag.originLayout
                self.drag = nil; isDragging = false; previewTarget = nil; self.navigatorDrop = nil
                persist(); onNavigationOrder?(order); return
            }
        }
        // Only commit a valid activeDropTarget (or remembered tab drop if explicitly tested);
        // invalid regions or returning to the origin without a target restore the original layout.
        let target: SpatialDropTarget?
        if let active = previewTarget {
            target = active
        } else if case .tab = drag.lastTarget {
            target = drag.lastTarget
        } else {
            target = nil
        }
        if target == .documentList {
            cancelDrag()
            if !drag.fromNavigator, drag.draggedTileID.documentID != nil { _ = close(drag.draggedTileID) }
            return
        }
        var nextLayout = drag.originLayout
        if let target {
            nextLayout.move(drag.draggedTileID, to: target, swapSingleColumns: drag.fromNavigator)
        } else if drag.fromNavigator, let id = drag.draggedTileID.documentID {
            let canvasBounds = CGRect(origin: .zero, size: drag.baseGeometrySnapshot?.contentSize ?? .zero)
            if canvasBounds.contains(drag.currentPointerInCanvas) {
                nextLayout.openDocument(id)
            }
        }
        let layoutChanged = nextLayout != drag.originLayout
        let reordered: Bool
        switch target {
        case .tab, .none: reordered = false
        default: reordered = layoutChanged
        }
        self.drag = nil; isDragging = false; previewTarget = nil; navigatorDrop = nil
        if layoutChanged {
            undoStack.append(drag.originLayout)
            redoStack.removeAll()
            layout = nextLayout
            commit()
            if reordered { onTileReorder?(layout) }
            if let id = drag.draggedTileID.documentID { activeDocumentID = id; onActivate?(id) }
        } else {
            layout = drag.originLayout
        }
    }

    func cancelDrag() {
        if let drag, isDragging { layout = drag.originLayout }
        drag = nil; isDragging = false; previewTarget = nil; navigatorDrop = nil
    }
    func previewNavigator(_ drop: SpatialNavigatorDrop?) {
        if navigatorDrop != drop { navigatorDrop = drop }
        if drop != nil, previewTarget != nil { previewTarget = nil }
    }
    func commit() { persist(); onCommit?(layout) }
    private var preferenceKey: String { "purlory.spatial-workspace.\(projectID?.rawValue.uuidString ?? "none")" }
    private func persist() {
        guard projectID != nil, !loading, !isDragging else { return }
        if let data = try? JSONEncoder().encode(Preference(layout: layout, typewriter: typewriter, focusDimming: focusDimming)) {
            defaults.set(data, forKey: preferenceKey)
        }
    }
}
