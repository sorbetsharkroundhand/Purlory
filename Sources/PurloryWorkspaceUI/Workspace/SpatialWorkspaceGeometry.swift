import AppKit

/// Top-left coordinates. Minimum tile sizes expand the scrollable canvas, never discard tiles.
struct SpatialWorkspaceGeometry {
    static let inset: CGFloat = 8
    static let columnGap: CGFloat = 8
    static let rowGap: CGFloat = 8
    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 8
    var columns: [CGRect] = []
    var tiles: [WorkspaceTileID: CGRect] = [:]
    var contentSize: CGSize

    init(layout: SpatialWorkspaceLayout, viewport: CGSize) {
        let availableWidth = max(0, viewport.width.isFinite ? viewport.width : 0)
        let availableHeight = max(0, viewport.height.isFinite ? viewport.height : 0)
        if layout.isSingleManuscript, let tile = layout.tiles.first {
            contentSize = CGSize(width: availableWidth, height: availableHeight)
            let paper = CGRect(origin: .zero, size: contentSize)
            columns = [paper]; tiles = [tile: paper]
            return
        }
        let gapWidth = CGFloat(max(0, layout.columns.count - 1)) * Self.columnGap
        let minimumWidths = layout.columns.map { column -> CGFloat in
            if let width = column.width, width.isFinite { return CGFloat(width) }
            return CGFloat(column.slots.map { $0.tile.minimumWidth }.max() ?? 260)
        }
        let requiredWidth = minimumWidths.reduce(0, +) + gapWidth + 2 * Self.inset
        let flexible = layout.columns.filter { $0.width == nil }.count
        let excess = max(0, availableWidth - requiredWidth)
        let requiredHeight = layout.columns.map { column -> CGFloat in
            guard let minimumWeight = column.slots.map(\.weight).min(), minimumWeight > 0 else { return 0 }
            return 95 / CGFloat(minimumWeight) + CGFloat(max(0, column.slots.count - 1)) * Self.rowGap
        }.max() ?? 0
        contentSize = CGSize(width: max(availableWidth, requiredWidth), height: max(availableHeight, requiredHeight + Self.topInset + Self.bottomInset))
        let height = max(0, contentSize.height - Self.topInset - Self.bottomInset)
        var x = Self.inset
        for (index, column) in layout.columns.enumerated() {
            var width = minimumWidths[index]
            if column.width == nil, flexible > 0 { width += excess / CGFloat(flexible) }
            if flexible == 0, index == 0 { width += excess }
            columns.append(CGRect(x: x, y: Self.topInset, width: width, height: height))
            let rowSpace = max(0, height - CGFloat(max(0, column.slots.count - 1)) * Self.rowGap)
            var y = Self.topInset
            for slot in column.slots {
                let slotHeight = rowSpace * CGFloat(slot.weight)
                tiles[slot.tile] = CGRect(x: x, y: y, width: width, height: slotHeight)
                y += slotHeight + Self.rowGap
            }
            x += width + Self.columnGap
        }
    }

    static let hysteresisMargin: CGFloat = 10
    static let outerSplitMargin: CGFloat = 80

    func dropTarget(
        at point: CGPoint,
        dragging: WorkspaceTileID,
        fromNavigator: Bool = false,
        lastTarget: SpatialDropTarget? = nil,
        tabsInTile: (WorkspaceTileID) -> Int = { _ in 1 },
        isSameSlot: (WorkspaceTileID) -> Bool = { _ in false }
    ) -> SpatialDropTarget? {
        guard CGRect(origin: .zero, size: contentSize).contains(point) else { return nil }
        if fromNavigator, let nav = tiles[.navigator], nav.contains(point) { return nil }
        if columns.isEmpty { return .end }
        if let lastTarget, isWithinHysteresis(point: point, target: lastTarget, dragging: dragging, fromNavigator: fromNavigator, tabsInTile: tabsInTile, isSameSlot: isSameSlot) {
            return lastTarget
        }
        return rawDropTarget(at: point, dragging: dragging, fromNavigator: fromNavigator, tabsInTile: tabsInTile, isSameSlot: isSameSlot)
    }

    private func rawDropTarget(
        at point: CGPoint,
        dragging: WorkspaceTileID,
        fromNavigator: Bool,
        tabsInTile: (WorkspaceTileID) -> Int,
        isSameSlot: (WorkspaceTileID) -> Bool
    ) -> SpatialDropTarget? {
        if point.x < Self.inset + 36 { return .start }
        if point.x > contentSize.width - Self.inset - 36 { return .end }
        for (tile, rect) in tiles where tile != dragging && tile != .insertionPreview && !(fromNavigator && tile == .navigator) {
            guard rect.contains(point), rect.width > 0, rect.height > 0 else { continue }
            let y = (point.y - rect.minY) / rect.height
            if y < 0.28 { return .above(tile) }
            if y > 0.72 { return .below(tile) }
            let splitBand = min(Self.outerSplitMargin, rect.width * 0.25)
            if point.x < rect.minX + splitBand { return .before(tile) }
            if point.x > rect.maxX - splitBand { return .after(tile) }
            if dragging.documentID != nil, tile.documentID != nil, !isSameSlot(tile) {
                return .tab(tile, index: max(1, tabsInTile(tile)))
            }
            return point.x < rect.midX ? .before(tile) : .after(tile)
        }
        // Check inter-column gaps for column split
        for (index, colRect) in columns.enumerated() where index + 1 < columns.count {
            let nextRect = columns[index + 1]
            let gapRect = CGRect(x: colRect.maxX, y: colRect.minY, width: nextRect.minX - colRect.maxX, height: colRect.height)
            if gapRect.contains(point) {
                if let anchor = tiles.first(where: { abs($0.value.minX - nextRect.minX) < 1 && $0.key != dragging })?.key {
                    return .before(anchor)
                }
            }
        }
        return nil
    }

    private func isWithinHysteresis(
        point: CGPoint,
        target: SpatialDropTarget,
        dragging: WorkspaceTileID,
        fromNavigator: Bool,
        tabsInTile: (WorkspaceTileID) -> Int,
        isSameSlot: (WorkspaceTileID) -> Bool
    ) -> Bool {
        let m = Self.hysteresisMargin
        switch target {
        case .start:
            return point.x < Self.inset + 36 + m
        case .end:
            return point.x > contentSize.width - Self.inset - 36 - m
        case .above(let tile):
            guard let rect = tiles[tile], tile != dragging, !(fromNavigator && tile == .navigator),
                  rect.insetBy(dx: -m, dy: -m).contains(point) else { return false }
            return point.y <= rect.minY + rect.height * 0.28 + m
        case .below(let tile):
            guard let rect = tiles[tile], tile != dragging, !(fromNavigator && tile == .navigator),
                  rect.insetBy(dx: -m, dy: -m).contains(point) else { return false }
            return point.y >= rect.minY + rect.height * 0.72 - m
        case .before(let tile):
            guard let rect = tiles[tile], tile != dragging, !(fromNavigator && tile == .navigator),
                  rect.insetBy(dx: -m, dy: -m).contains(point) else { return false }
            let top = rect.minY + rect.height * 0.28 - m
            let bottom = rect.minY + rect.height * 0.72 + m
            guard point.y >= top && point.y <= bottom else { return false }
            if dragging.documentID != nil, tile.documentID != nil, !isSameSlot(tile) {
                let splitBand = min(Self.outerSplitMargin, rect.width * 0.25)
                return point.x <= rect.minX + splitBand + m
            }
            return point.x <= rect.midX + m
        case .after(let tile):
            guard let rect = tiles[tile], tile != dragging, !(fromNavigator && tile == .navigator),
                  rect.insetBy(dx: -m, dy: -m).contains(point) else { return false }
            let top = rect.minY + rect.height * 0.28 - m
            let bottom = rect.minY + rect.height * 0.72 + m
            guard point.y >= top && point.y <= bottom else { return false }
            if dragging.documentID != nil, tile.documentID != nil, !isSameSlot(tile) {
                let splitBand = min(Self.outerSplitMargin, rect.width * 0.25)
                return point.x >= rect.maxX - splitBand - m
            }
            return point.x >= rect.midX - m
        case .tab(let tile, let index):
            guard dragging.documentID != nil, tile.documentID != nil, !isSameSlot(tile),
                  let rect = tiles[tile], tile != dragging,
                  rect.insetBy(dx: -m, dy: -m).contains(point) else { return false }
            // Only apply center-zone hysteresis when index matches the center-merge index;
            // header tab bar targets are managed by the tab strip itself.
            guard index == max(1, tabsInTile(tile)) else { return false }
            let splitBand = min(Self.outerSplitMargin, rect.width * 0.25)
            let centerRect = CGRect(
                x: rect.minX + splitBand - m,
                y: rect.minY + rect.height * 0.28 - m,
                width: max(0, rect.width - 2 * splitBand + 2 * m),
                height: max(0, rect.height * 0.44 + 2 * m)
            )
            return centerRect.contains(point)
        case .documentList:
            guard let nav = tiles[.navigator] else { return false }
            return nav.insetBy(dx: -m, dy: -m).contains(point)
        }
    }

    enum DropIndicator: Equatable {
        case line(CGRect)
        case groupHighlight(CGRect)
    }

    func dropIndicator(for target: SpatialDropTarget) -> DropIndicator? {
        let thickness: CGFloat = 3
        switch target {
        case .start:
            let y = columns.first?.minY ?? Self.topInset
            let h = columns.first?.height ?? max(0, contentSize.height - Self.topInset - Self.bottomInset)
            return .line(CGRect(x: max(2, Self.inset / 2 - thickness / 2), y: y, width: thickness, height: h))
        case .end:
            let y = columns.last?.minY ?? Self.topInset
            let h = columns.last?.height ?? max(0, contentSize.height - Self.topInset - Self.bottomInset)
            let x = (columns.last?.maxX ?? (contentSize.width - Self.inset)) + Self.columnGap / 2 - thickness / 2
            return .line(CGRect(x: min(contentSize.width - thickness - 2, x), y: y, width: thickness, height: h))
        case .before(let tile):
            guard let rect = tiles[tile] else { return nil }
            let colRect = columns.first { abs($0.minX - rect.minX) < 1 } ?? rect
            return .line(CGRect(x: colRect.minX - Self.columnGap / 2 - thickness / 2, y: colRect.minY, width: thickness, height: colRect.height))
        case .after(let tile):
            guard let rect = tiles[tile] else { return nil }
            let colRect = columns.first { abs($0.minX - rect.minX) < 1 } ?? rect
            return .line(CGRect(x: colRect.maxX + Self.columnGap / 2 - thickness / 2, y: colRect.minY, width: thickness, height: colRect.height))
        case .above(let tile):
            guard let rect = tiles[tile] else { return nil }
            return .line(CGRect(x: rect.minX, y: rect.minY - Self.rowGap / 2 - thickness / 2, width: rect.width, height: thickness))
        case .below(let tile):
            guard let rect = tiles[tile] else { return nil }
            return .line(CGRect(x: rect.minX, y: rect.maxY + Self.rowGap / 2 - thickness / 2, width: rect.width, height: thickness))
        case .tab(let tile, _):
            guard let rect = tiles[tile] else { return nil }
            return .groupHighlight(rect)
        case .documentList:
            guard let rect = tiles[.navigator] else { return nil }
            return .groupHighlight(rect)
        }
    }
}
