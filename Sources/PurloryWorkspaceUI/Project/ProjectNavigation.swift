import Foundation

enum ProjectNavigationNode: Hashable, Codable, Sendable {
    case document(WritingDocumentID)
    case folder(UUID)
    var identifier: String {
        switch self {
        case .document(let id): "document.\(id.rawValue.uuidString)"
        case .folder(let id): "folder.\(id.uuidString)"
        }
    }
}

enum ProjectNavigationDrop: Equatable, Sendable {
    case before(ProjectNavigationNode), after(ProjectNavigationNode), inside(ProjectNavigationNode), root
}

struct ProjectFolder: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name = "새 폴더"
    var parentID: UUID?
}

/// Writer-owned organization travels with project saves, backups and imports.
/// It is independent of the original files' paths and never moves manuscript bytes.
struct ProjectNavigation: Codable, Equatable, Sendable {
    static let key = "document-navigation.json"
    var version = 1
    var folders: [ProjectFolder] = []
    var documentFolders: [WritingDocumentID: UUID] = [:]
    var createdDates: [WritingDocumentID: Date] = [:]
    var trashedFolders: Set<UUID> = []
    var trashBundles: [UUID: TrashBundle] = [:]
    struct TrashBundle: Codable, Equatable, Sendable {
        var folders: Set<UUID>
        var documents: Set<WritingDocumentID>
    }

    static func read(_ project: WritingProject) throws -> Self {
        guard let data = project.userData[key] else { return Self() }
        let navigation = try JSONDecoder().decode(Self.self, from: data)
        try navigation.validate(in: project)
        return navigation
    }
    func write(to project: inout WritingProject) throws {
        try validate(in: project)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        project.userData[Self.key] = try encoder.encode(self)
    }
    func validate(in project: WritingProject) throws {
        let ids = Set(folders.map(\.id)), documents = Set(project.documents.map(\.id))
        guard version == 1, ids.count == folders.count, trashedFolders.isSubset(of: ids),
              Set(documentFolders.keys).isSubset(of: documents), Set(documentFolders.values).isSubset(of: ids),
              Set(createdDates.keys).isSubset(of: documents),
              createdDates.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw ProjectStoreError.invalidManifest }
        let parents = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentID) })
        for folder in folders {
            var visited: Set<UUID> = [folder.id], next = folder.parentID
            while let id = next {
                guard ids.contains(id), visited.insert(id).inserted else { throw ProjectStoreError.invalidManifest }
                next = parents[id] ?? nil
            }
        }
        for (id, bundle) in trashBundles {
            guard trashedFolders.contains(id), bundle.folders.isSubset(of: trashedFolders),
                  bundle.documents.isSubset(of: project.trashedDocumentIDs) else { throw ProjectStoreError.invalidManifest }
        }
    }
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id], pending = [id]
        while let parent = pending.popLast() {
            for folder in folders where folder.parentID == parent && result.insert(folder.id).inserted { pending.append(folder.id) }
        }
        return result
    }
    func parent(of node: ProjectNavigationNode) -> UUID? {
        switch node {
        case .document(let id): documentFolders[id]
        case .folder(let id): folders.first { $0.id == id }?.parentID
        }
    }
    /// Outer-to-inner folders, matching the visible indentation guides.
    func ancestors(of node: ProjectNavigationNode) -> [UUID] {
        var result: [UUID] = [], next = parent(of: node)
        while let id = next, !result.contains(id) {
            result.insert(id, at: 0); next = parent(of: .folder(id))
        }
        return result
    }
    func visibleFolders(in parent: UUID?) -> [ProjectFolder] {
        folders.filter { $0.parentID == parent && !trashedFolders.contains($0.id) }
    }
    func path(_ id: UUID) -> String {
        var parts: [String] = [], next: UUID? = id, seen = Set<UUID>()
        while let key = next, seen.insert(key).inserted, let folder = folders.first(where: { $0.id == key }) {
            parts.append(folder.name); next = folder.parentID
        }
        return parts.reversed().joined(separator: " / ")
    }
    func contains(_ node: ProjectNavigationNode, in project: WritingProject) -> Bool {
        switch node {
        case .document(let id): project.documents.contains { $0.id == id } && !project.trashedDocumentIDs.contains(id)
        case .folder(let id): folders.contains { $0.id == id } && !trashedFolders.contains(id)
        }
    }
    struct Row: Identifiable {
        let node: ProjectNavigationNode
        let depth: Int
        var id: ProjectNavigationNode { node }
    }
    func rows(in project: WritingProject, collapsed: Set<UUID>, sortMode: NavigatorSortMode = .manual) -> [Row] {
        var result: [Row] = []
        func append(_ parent: UUID?, depth: Int) {
            let visible = visibleFolders(in: parent)
            let sortedFolders: [ProjectFolder]
            switch sortMode {
            case .titleAscending:
                sortedFolders = visible.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .titleDescending:
                sortedFolders = visible.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            case .manual, .dateDescending, .dateAscending:
                sortedFolders = visible
            }
            for folder in sortedFolders {
                result.append(Row(node: .folder(folder.id), depth: depth))
                if !collapsed.contains(folder.id) { append(folder.id, depth: depth + 1) }
            }
            var docs = project.documents.filter { documentFolders[$0.id] == parent && !project.trashedDocumentIDs.contains($0.id) }
            switch sortMode {
            case .titleAscending:
                docs.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case .titleDescending:
                docs.sort { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
            case .dateDescending:
                docs.sort {
                    let d0 = createdDates[$0.id] ?? .distantPast
                    let d1 = createdDates[$1.id] ?? .distantPast
                    return d0 == d1 ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : d0 > d1
                }
            case .dateAscending:
                docs.sort {
                    let d0 = createdDates[$0.id] ?? .distantPast
                    let d1 = createdDates[$1.id] ?? .distantPast
                    return d0 == d1 ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : d0 < d1
                }
            case .manual:
                break
            }
            for document in docs {
                result.append(Row(node: .document(document.id), depth: depth))
            }
        }
        append(nil, depth: 0)
        return result
    }
}

public enum NavigatorSortMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case manual = "manual"
    case titleAscending = "titleAscending"
    case titleDescending = "titleDescending"
    case dateDescending = "dateDescending"
    case dateAscending = "dateAscending"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manual: return "원고순 (사용자 정렬)"
        case .titleAscending: return "이름순 (가나다순)"
        case .titleDescending: return "이름순 (내림차순)"
        case .dateDescending: return "작성일순 (최신순)"
        case .dateAscending: return "작성일순 (오래된순)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .manual: return "원고순"
        case .titleAscending: return "이름순"
        case .titleDescending: return "이름 역순"
        case .dateDescending: return "최신순"
        case .dateAscending: return "오래된순"
        }
    }
}
