import Foundation

enum WorkspaceTileID: Hashable, Codable, Sendable, Identifiable {
    case document(WritingDocumentID)
    case navigator, characters, narrative, margin, context, outline, map, review, search, inspector
    case insertionPreview

    var id: String {
        switch self {
        case .document(let id): "document.\(id.rawValue.uuidString)"
        case .navigator: "navigator"
        case .characters: "characters"
        case .narrative: "narrative"
        case .margin: "margin"
        case .context: "context"
        case .outline: "outline"
        case .map: "map"
        case .review: "review"
        case .search: "search"
        case .inspector: "inspector"
        case .insertionPreview: "insertion-preview"
        }
    }
    var documentID: WritingDocumentID? {
        if case .document(let id) = self { id } else { nil }
    }
    var minimumWidth: Double {
        switch self { case .navigator: 165; case .document, .insertionPreview: 260; case .search, .inspector: 300; default: 210 }
    }
    var maximumWidth: Double {
        switch self { case .navigator: 320; case .document: 1600; default: 420 }
    }
    var idealWidth: Double? {
        switch self { case .navigator: 204; case .document, .insertionPreview: nil; case .search, .inspector: 340; default: 256 }
    }
}

enum SpatialDropTarget: Equatable, Sendable {
    case start, end
    case before(WorkspaceTileID), after(WorkspaceTileID)
    case above(WorkspaceTileID), below(WorkspaceTileID)
    case tab(WorkspaceTileID, index: Int)
    case documentList

    var tile: WorkspaceTileID? {
        switch self {
        case .before(let id), .after(let id), .above(let id), .below(let id), .tab(let id, _): id
        case .documentList: .navigator
        case .start, .end: nil
        }
    }
}

struct SpatialWorkspaceSlot: Equatable, Codable, Sendable {
    var tile: WorkspaceTileID
    var weight: Double = 1
    var tabs: [WritingDocumentID]

    init(tile: WorkspaceTileID, weight: Double = 1, tabs: [WritingDocumentID]? = nil) {
        self.tile = tile; self.weight = weight
        self.tabs = tile.documentID.map { tabs ?? [$0] } ?? []
    }

    private enum CodingKeys: String, CodingKey { case tile, weight, tabs }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let tile = try values.decode(WorkspaceTileID.self, forKey: .tile)
        self.init(tile: tile, weight: try values.decodeIfPresent(Double.self, forKey: .weight) ?? 1,
            tabs: try values.decodeIfPresent([WritingDocumentID].self, forKey: .tabs))
    }

    func contains(_ candidate: WorkspaceTileID) -> Bool {
        if let id = candidate.documentID { return tabs.contains(id) }
        return tile == candidate
    }
}

struct SpatialWorkspaceColumn: Equatable, Codable, Sendable, Identifiable {
    var id = UUID()
    var width: Double?
    var slots: [SpatialWorkspaceSlot]

    mutating func normalize() {
        guard !slots.isEmpty else { return }
        for index in slots.indices where !slots[index].weight.isFinite || slots[index].weight <= 0 {
            slots[index].weight = 1
        }
        let scale = slots.map(\.weight).max() ?? 1
        let sum = slots.reduce(0) { $0 + $1.weight / scale }
        for index in slots.indices { slots[index].weight = (slots[index].weight / scale) / sum }
        if let width, !width.isFinite { self.width = nil }
    }
}

/// Presentation only. Document IDs refer back to the sole ProjectSession owner.
struct SpatialWorkspaceLayout: Equatable, Codable, Sendable {
    var columns: [SpatialWorkspaceColumn]
    var tiles: [WorkspaceTileID] { columns.flatMap { $0.slots.map(\.tile) } }
    var openDocuments: [WritingDocumentID] { columns.flatMap { $0.slots.flatMap(\.tabs) } }
    var allTiles: [WorkspaceTileID] { columns.flatMap { $0.slots.flatMap { slot in
        slot.tile.documentID == nil ? [slot.tile] : slot.tabs.map(WorkspaceTileID.document)
    } } }
    var isSingleManuscript: Bool { tiles.count == 1 && tiles.first?.documentID != nil }

    init(documents: [WritingDocumentID], selected: WritingDocumentID?, navigatorVisible: Bool = true) {
        columns = navigatorVisible ? [.init(width: 204, slots: [.init(tile: .navigator)])] : []
        guard let first = selected.flatMap({ documents.contains($0) ? $0 : nil }) ?? documents.first else { return }
        openDocument(first)
        if let next = documents.first(where: { $0 != first }) { openDocument(next) }
        activate(first)
    }

    func contains(_ tile: WorkspaceTileID) -> Bool { location(of: tile) != nil }
    func slot(containing tile: WorkspaceTileID) -> SpatialWorkspaceSlot? {
        guard let (column, row) = location(of: tile) else { return nil }
        return columns[column].slots[row]
    }
    private func location(of tile: WorkspaceTileID) -> (Int, Int)? {
        for column in columns.indices {
            if let row = columns[column].slots.firstIndex(where: { $0.contains(tile) }) { return (column, row) }
        }
        return nil
    }
    @discardableResult mutating func activate(_ id: WritingDocumentID) -> Bool {
        guard let (column, row) = location(of: .document(id)) else { return false }
        columns[column].slots[row].tile = .document(id)
        return true
    }

    mutating func openDocument(_ id: WritingDocumentID, in preferred: WritingDocumentID? = nil) {
        if activate(id) { return }
        if let (column, row) = preferred.flatMap({ location(of: .document($0)) })
            ?? openDocuments.last.flatMap({ location(of: .document($0)) }) {
            columns[column].slots[row].tabs.append(id)
            columns[column].slots[row].tile = .document(id)
            return
        }
        let position = columns.lastIndex { $0.slots.contains { $0.tile.documentID != nil } }
            .map { $0 + 1 } ?? columns.endIndex
        columns.insert(.init(width: nil, slots: [.init(tile: .document(id))]), at: position)
    }

    mutating func openAll(_ documents: [WritingDocumentID]) {
        for id in documents {
            if !contains(.document(id)) { columns.append(.init(width: nil, slots: [.init(tile: .document(id))])) }
            else if let slot = slot(containing: .document(id)), slot.tabs.count > 1 {
                move(.document(id), to: .end)
            }
        }
    }

    @discardableResult mutating func close(_ tile: WorkspaceTileID) -> Bool {
        guard contains(tile), tile.documentID == nil || openDocuments.count > 1 else { return false }
        remove(tile)
        return true
    }

    mutating func toggle(_ tile: WorkspaceTileID) {
        guard tile.documentID == nil else { return }
        if contains(tile) { remove(tile); return }
        if tile == .navigator {
            columns.insert(.init(width: 204, slots: [.init(tile: tile)]), at: 0)
        } else if let last = columns.indices.last,
                  !columns[last].slots.contains(where: { $0.tile.documentID != nil || $0.tile == .navigator }) {
            let weight = 1 / Double(columns[last].slots.count + 1)
            columns[last].slots.append(.init(tile: tile, weight: weight))
            columns[last].normalize()
        } else {
            columns.append(.init(width: tile.idealWidth, slots: [.init(tile: tile)]))
        }
    }

    /// Used only by a reversible drag transaction; unlike close, a temporary layout may be empty.
    mutating func remove(_ tile: WorkspaceTileID) {
        for index in columns.indices {
            for row in columns[index].slots.indices {
                guard let id = tile.documentID,
                      let tab = columns[index].slots[row].tabs.firstIndex(of: id) else { continue }
                columns[index].slots[row].tabs.remove(at: tab)
                if columns[index].slots[row].tile == tile, !columns[index].slots[row].tabs.isEmpty {
                    let neighbor = min(tab, columns[index].slots[row].tabs.count - 1)
                    columns[index].slots[row].tile = .document(columns[index].slots[row].tabs[neighbor])
                }
            }
            columns[index].slots.removeAll { $0.tile == tile || ($0.tile.documentID != nil && $0.tabs.isEmpty) }
            columns[index].normalize()
        }
        columns.removeAll { $0.slots.isEmpty }
    }

    mutating func move(_ tile: WorkspaceTileID, to target: SpatialDropTarget, swapSingleColumns: Bool = false) {
        if target == .documentList {
            if tile.documentID != nil { _ = close(tile) }
            return
        }
        if case .tab(let anchor, let index) = target {
            moveTab(tile, to: anchor, index: index); return
        }
        guard target.tile != tile else { return }
        if swapSingleColumns, case .before = target, swapColumns(tile, target.tile) { return }
        if swapSingleColumns, case .after = target, swapColumns(tile, target.tile) { return }
        remove(tile)
        let newColumn = SpatialWorkspaceColumn(width: tile.idealWidth, slots: [.init(tile: tile)])
        switch target {
        case .start: columns.insert(newColumn, at: 0)
        case .end: columns.append(newColumn)
        case .before(let anchor), .after(let anchor), .above(let anchor), .below(let anchor):
            guard let (column, row) = location(of: anchor) else {
                columns.append(newColumn); return
            }
            switch target {
            case .before: columns.insert(newColumn, at: column)
            case .after: columns.insert(newColumn, at: column + 1)
            case .above, .below:
                let half = max(0.25, columns[column].slots[row].weight / 2)
                columns[column].slots[row].weight = half
                let insertion = target == .above(anchor) ? row : row + 1
                columns[column].slots.insert(.init(tile: tile, weight: half), at: insertion)
                columns[column].normalize()
            default: break
            }
        case .tab, .documentList: break
        }
    }

    private mutating func moveTab(_ tile: WorkspaceTileID, to anchor: WorkspaceTileID, index: Int) {
        guard let id = tile.documentID, anchor.documentID != nil,
              let (column, row) = location(of: anchor) else { return }
        // Capture a surviving destination member before removal can change its active tile or indices.
        let destination = columns[column].slots[row]
        if let old = destination.tabs.firstIndex(of: id) {
            var tabs = destination.tabs
            tabs.remove(at: old)
            tabs.insert(id, at: min(tabs.count, max(0, index - (old < index ? 1 : 0))))
            columns[column].slots[row].tabs = tabs
            columns[column].slots[row].tile = tile
        } else {
            remove(tile)
            guard let (column, row) = location(of: anchor) else { return }
            columns[column].slots[row].tabs.insert(id, at: min(destination.tabs.count, max(0, index)))
            columns[column].slots[row].tile = tile
        }
    }

    private mutating func swapColumns(_ tile: WorkspaceTileID, _ anchor: WorkspaceTileID?) -> Bool {
        guard let anchor,
              let from = columns.firstIndex(where: { $0.slots.count == 1 && $0.slots[0].tile == tile && $0.slots[0].tabs.count <= 1 }),
              let to = columns.firstIndex(where: { $0.slots.count == 1 && $0.slots[0].tile == anchor }), from != to else { return false }
        columns.swapAt(from, to); return true
    }

    mutating func setColumnWidth(_ column: Int, width: Double) {
        guard columns.indices.contains(column), width.isFinite,
              let tile = columns[column].slots.first?.tile else { return }
        columns[column].width = min(tile.maximumWidth, max(tile.minimumWidth, width)).rounded()
    }

    mutating func resizeRows(column: Int, row: Int, delta: Double, height: Double) {
        guard columns.indices.contains(column), columns[column].slots.indices.contains(row),
              columns[column].slots.indices.contains(row + 1), delta.isFinite, height.isFinite else { return }
        let combined = columns[column].slots[row].weight + columns[column].slots[row + 1].weight
        let top = columns[column].slots[row].weight + delta / max(200, height) * combined
        columns[column].slots[row].weight = min(combined * 0.8, max(combined * 0.2, top))
        columns[column].slots[row + 1].weight = combined - columns[column].slots[row].weight
    }

    mutating func equalizeRows(column: Int, row: Int) {
        guard columns.indices.contains(column), columns[column].slots.indices.contains(row),
              columns[column].slots.indices.contains(row + 1) else { return }
        let half = (columns[column].slots[row].weight + columns[column].slots[row + 1].weight) / 2
        columns[column].slots[row].weight = half; columns[column].slots[row + 1].weight = half
    }

    func reorderedDocuments(_ original: [WritingDocumentID]) -> [WritingDocumentID] {
        let open = openDocuments.filter { original.contains($0) }
        var result = original, offset = 0
        for index in result.indices where open.contains(result[index]) {
            result[index] = open[offset]; offset += 1
        }
        return result
    }

    mutating func normalize(validDocuments: [WritingDocumentID]) {
        var seen: Set<WorkspaceTileID> = [], columnIDs: Set<UUID> = []
        for index in columns.indices {
            if !columnIDs.insert(columns[index].id).inserted { columns[index].id = UUID() }
            columns[index].slots = columns[index].slots.compactMap { original in
                var slot = original
                // Keep the legacy enum case decodable without restoring a settings tile.
                if slot.tile == .insertionPreview || slot.tile == .inspector { return nil }
                if let active = slot.tile.documentID {
                    if !slot.tabs.contains(active) { slot.tabs.insert(active, at: 0) }
                    slot.tabs = slot.tabs.filter { validDocuments.contains($0) && seen.insert(.document($0)).inserted }
                    guard let first = slot.tabs.first else { return nil }
                    if !slot.tabs.contains(active) { slot.tile = .document(first) }
                } else {
                    slot.tabs = []
                    guard seen.insert(slot.tile).inserted else { return nil }
                }
                return slot
            }
            columns[index].normalize()
            if let width = columns[index].width { setColumnWidth(index, width: width) }
        }
        columns.removeAll { $0.slots.isEmpty }
        if openDocuments.isEmpty, let first = validDocuments.first { openDocument(first) }
    }
}
