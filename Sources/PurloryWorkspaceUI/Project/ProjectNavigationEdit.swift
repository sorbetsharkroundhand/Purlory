import Foundation

enum ProjectNavigationEdit {
    case createFolder(ProjectFolder)
    case renameFolder(UUID, String)
    case drop(ProjectNavigationNode, ProjectNavigationDrop)
    case date(WritingDocumentID, Date)
    case kind(WritingDocumentID, WritingDocument.Kind)
    case trash(ProjectNavigationNode)
    case restore(ProjectNavigationNode)
    case purge(ProjectNavigationNode)
}

extension ProjectNavigation {
    /// Pure transaction: the caller publishes the project only after validation succeeds.
    mutating func apply(_ edit: ProjectNavigationEdit, to project: inout WritingProject) throws {
        switch edit {
        case .createFolder(let folder):
            try requireParent(folder.parentID)
            guard !folders.contains(where: { $0.id == folder.id }) else { throw ProjectSessionError.staleRuntime }
            folders.insert(folder, at: 0)
        case .renameFolder(let id, let name):
            guard let index = folders.firstIndex(where: { $0.id == id }), !trashedFolders.contains(id),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectSessionError.staleRuntime }
            folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .date(let id, let date):
            guard contains(.document(id), in: project), date.timeIntervalSince1970.isFinite else { throw ProjectSessionError.staleRuntime }
            createdDates[id] = date
        case .kind(let id, let kind):
            guard contains(.document(id), in: project), let index = project.documents.firstIndex(where: { $0.id == id }) else { throw ProjectSessionError.staleRuntime }
            project.documents[index].kind = kind
        case .drop(let source, let destination): try drop(source, at: destination, project: &project)
        case .trash(let node):
            guard contains(node, in: project) else { throw ProjectSessionError.staleRuntime }
            switch node {
            case .document(let id): project.trashedDocumentIDs.insert(id)
            case .folder(let id):
                let subtree = descendants(of: id).subtracting(trashedFolders)
                let documents = Set(documentFolders.filter { subtree.contains($0.value) }.keys).subtracting(project.trashedDocumentIDs)
                trashBundles[id] = TrashBundle(folders: subtree, documents: documents)
                trashedFolders.formUnion(subtree); project.trashedDocumentIDs.formUnion(documents)
            }
        case .restore(let node):
            switch node {
            case .document(let id):
                guard project.trashedDocumentIDs.contains(id) else { throw ProjectSessionError.staleRuntime }
                project.trashedDocumentIDs.remove(id)
                if let parent = documentFolders[id], trashedFolders.contains(parent) { documentFolders[id] = nil }
                for key in Array(trashBundles.keys) { trashBundles[key]?.documents.remove(id) }
            case .folder(let id):
                guard let bundle = trashBundles.removeValue(forKey: id) else { throw ProjectSessionError.staleRuntime }
                trashedFolders.subtract(bundle.folders); project.trashedDocumentIDs.subtract(bundle.documents)
                if let index = folders.firstIndex(where: { $0.id == id }), let parent = folders[index].parentID, trashedFolders.contains(parent) { folders[index].parentID = nil }
            }
        case .purge(let node):
            let removedFolders: Set<UUID>, removedDocuments: Set<WritingDocumentID>
            switch node {
            case .document(let id):
                guard project.trashedDocumentIDs.contains(id) else { throw ProjectSessionError.staleRuntime }
                removedFolders = []; removedDocuments = [id]
            case .folder(let id):
                guard trashedFolders.contains(id) else { throw ProjectSessionError.staleRuntime }
                removedFolders = descendants(of: id)
                removedDocuments = Set(documentFolders.filter { removedFolders.contains($0.value) }.keys).intersection(project.trashedDocumentIDs)
            }
            project.documents.removeAll { removedDocuments.contains($0.id) }
            project.trashedDocumentIDs.subtract(removedDocuments)
            folders.removeAll { removedFolders.contains($0.id) }; trashedFolders.subtract(removedFolders)
            documentFolders = documentFolders.filter { !removedDocuments.contains($0.key) && !removedFolders.contains($0.value) }
            createdDates = createdDates.filter { !removedDocuments.contains($0.key) }
            for key in Array(trashBundles.keys) {
                if removedFolders.contains(key) { trashBundles[key] = nil }
                else { trashBundles[key]?.folders.subtract(removedFolders); trashBundles[key]?.documents.subtract(removedDocuments) }
            }
        }
        try write(to: &project)
    }

    private func requireParent(_ id: UUID?) throws {
        if let id, !folders.contains(where: { $0.id == id && !trashedFolders.contains(id) }) { throw ProjectSessionError.staleRuntime }
    }
    private mutating func drop(_ source: ProjectNavigationNode, at destination: ProjectNavigationDrop, project: inout WritingProject) throws {
        guard contains(source, in: project) else { throw ProjectSessionError.staleRuntime }
        var parent: UUID?, before: ProjectNavigationNode?
        switch destination {
        case .root: break
        case .inside(.folder(let id)): parent = id
        case .inside(.document(let target)):
            guard case .document(let id) = source, id != target, contains(.document(target), in: project) else { throw ProjectSessionError.staleRuntime }
            let folder = ProjectFolder(parentID: documentFolders[target])
            folders.append(folder); documentFolders[id] = folder.id; documentFolders[target] = folder.id
            // Preserve the legacy grouping order: destination first, dropped file second.
            let moved = project.documents.remove(at: project.documents.firstIndex { $0.id == id }!)
            let targetIndex = project.documents.firstIndex { $0.id == target }!
            project.documents.insert(moved, at: targetIndex + 1)
            return
        case .before(let target), .after(let target):
            guard source != target, contains(target, in: project) else { throw ProjectSessionError.staleRuntime }
            parent = self.parent(of: target)
            switch (source, target) {
            case (.document, .document), (.folder, .folder): break
            default: throw ProjectSessionError.staleRuntime
            }
            if case .before = destination { before = target }
            else {
                let siblings: [ProjectNavigationNode]
                if case .folder = source { siblings = visibleFolders(in: parent).map { .folder($0.id) } }
                else { siblings = project.documents.filter { documentFolders[$0.id] == parent && !project.trashedDocumentIDs.contains($0.id) }.map { .document($0.id) } }
                before = siblings.drop(while: { $0 != target }).dropFirst().first { $0 != source }
            }
        }
        try requireParent(parent)
        switch source {
        case .document(let id):
            documentFolders[id] = parent
            let index = project.documents.firstIndex { $0.id == id }!
            let document = project.documents.remove(at: index)
            let insertion = before.flatMap { node in project.documents.firstIndex { .document($0.id) == node } } ?? project.documents.count
            project.documents.insert(document, at: insertion)
        case .folder(let id):
            guard parent.map({ !descendants(of: id).contains($0) }) ?? true else { throw ProjectSessionError.staleRuntime }
            let index = folders.firstIndex { $0.id == id }!
            var folder = folders.remove(at: index); folder.parentID = parent
            let insertion = before.flatMap { node in folders.firstIndex { .folder($0.id) == node } } ?? folders.count
            folders.insert(folder, at: insertion)
        }
    }
}
