import Foundation

public struct LegacyMigrationResult: Equatable, Sendable {
    public var projectID: WritingProjectID
    public var migratedDocumentCount: Int
    public var sourceFingerprint: String
    public var reusedExistingProject: Bool
    public var selectedDocumentID: WritingDocumentID? = nil
}

struct MigrationReceipt: Codable {
    var requestFingerprint: String
    var projectID: WritingProjectID
}

/// Read legacy values without invoking EntryStore's recovery or persistence side effects.
enum LegacyProjectMigrator {
    struct Snapshot {
        var sourceData: Data
        var archiveData: Data
        var entries: [JournalEntry]
        var assets: [String: Data]
        var activeID: UUID?
        var journalSource: Data?
    }

    private struct LegacyArchive: Codable {
        var entries: [JournalEntry]
        var activeID: UUID?
        var folders: [JournalFolder]?
        var expandedFolderIDs: [UUID]?
    }

    static func restoreNavigation(from data: Data, into project: inout WritingProject) throws {
        guard project.userData[ProjectNavigation.key] == nil else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(LegacyArchive.self, from: data)
        var navigation = ProjectNavigation()
        navigation.folders = orderedFolders(archive.folders ?? []).map {
            ProjectFolder(id: $0.id, name: $0.name, parentID: $0.parentID)
        }
        let ids = Set(project.documents.map(\.id)), folders = Set(navigation.folders.map(\.id))
        for entry in archive.entries {
            let id = WritingDocumentID(rawValue: entry.id)
            guard ids.contains(id) else { continue }
            if let folder = entry.folderID, folders.contains(folder) { navigation.documentFolders[id] = folder }
            navigation.createdDates[id] = entry.createdAt
        }
        try navigation.write(to: &project)
    }

    static func read(from sourceURL: URL) throws -> Snapshot {
        try Task.checkCancellation()
        try ProjectPaths.rejectSymlink(sourceURL)
        let source = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: LegacyArchive
        let archiveData: Data
        let isJournal = sourceURL.pathExtension.lowercased() == "md"
        if isJournal {
            guard let body = String(data: source, encoding: .utf8) else { throw ProjectStoreError.invalidLegacy }
            // Stable identity makes retries of the same old single-document archive idempotent.
            let hex = Array(ProjectDigest.hash(source).prefix(32))
            let uuid = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
            guard let id = UUID(uuidString: uuid) else { throw ProjectStoreError.invalidLegacy }
            archive = LegacyArchive(entries: [JournalEntry(id: id, title: "Journal", createdAt: Date(timeIntervalSince1970: 0), body: body)],
                activeID: id, folders: [], expandedFolderIDs: [])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            archiveData = try encoder.encode(archive)
        } else {
            archive = try decoder.decode(LegacyArchive.self, from: source)
            archiveData = source
        }
        guard Set(archive.entries.map(\.id)).count == archive.entries.count else {
            throw ProjectStoreError.invalidLegacy
        }
        let base = sourceURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let images = try ProjectPaths.checked("images", under: base)
        var assets: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: images.path) {
            try collectAssets(relative: "images", under: base, into: &assets)
        }
        return Snapshot(sourceData: source, archiveData: archiveData, entries: orderedEntries(archive.entries),
            assets: assets, activeID: archive.activeID, journalSource: isJournal ? source : nil)
    }

    /// Only the configured root is inspected. Recovery archives require explicit selection.
    static func source(in directory: URL) throws -> URL? {
        try ProjectPaths.rejectSymlink(directory)
        let entries = try ProjectPaths.checked("entries.json", under: directory)
        if FileManager.default.fileExists(atPath: entries.path) { return entries }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        if names.contains(where: { $0.hasPrefix("entries-recovered-") || $0.hasPrefix("entries.corrupt-") }) {
            throw LegacyStartupError.recoverySelectionRequired
        }
        let journal = try ProjectPaths.checked("journal.md", under: directory)
        return FileManager.default.fileExists(atPath: journal.path) ? journal : nil
    }

    /// Missing ranks historically seeded the entire sibling group from its array order.
    private static func orderedFolders(_ folders: [JournalFolder]) -> [JournalFolder] {
        var ranks: [Int: Double] = [:]
        for group in Dictionary(grouping: folders.indices, by: { folders[$0].parentID }).values {
            let needsSeed = group.contains { folders[$0].sortOrder == nil }
            for (rank, index) in group.sorted().enumerated() {
                ranks[index] = needsSeed ? Double(rank) : folders[index].sortOrder
            }
        }
        return folders.indices.sorted {
            ranks[$0] == ranks[$1] ? $0 < $1 : (ranks[$0] ?? 0) < (ranks[$1] ?? 0)
        }.map { folders[$0] }
    }

    /// Preserve each folder's manual order, or the historical newest-first fallback.
    private static func orderedEntries(_ entries: [JournalEntry]) -> [JournalEntry] {
        var ranks: [Int: Double] = [:]
        for group in Dictionary(grouping: entries.indices, by: { entries[$0].folderID }).values {
            if group.contains(where: { entries[$0].sortOrder == nil }) {
                let ordered = group.sorted {
                    entries[$0].createdAt == entries[$1].createdAt ? $0 < $1 : entries[$0].createdAt > entries[$1].createdAt
                }
                for (rank, index) in ordered.enumerated() { ranks[index] = Double(rank) }
            } else {
                for index in group { ranks[index] = entries[index].sortOrder }
            }
        }
        return entries.indices.sorted {
            ranks[$0] == ranks[$1] ? $0 < $1 : (ranks[$0] ?? 0) < (ranks[$1] ?? 0)
        }.map { entries[$0] }
    }

    private static func collectAssets(relative: String, under base: URL, into assets: inout [String: Data]) throws {
        try Task.checkCancellation()
        let folder = try ProjectPaths.checked(relative, under: base)
        for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
            try Task.checkCancellation()
            let path = relative + "/" + child.lastPathComponent
            let url = try ProjectPaths.checked(path, under: base)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try collectAssets(relative: path, under: base, into: &assets)
            } else if values.isRegularFile == true {
                assets[path] = try Data(contentsOf: url)
            } else {
                throw ProjectStoreError.unsafePath(path)
            }
        }
    }

    static func fingerprint(_ snapshot: Snapshot, mode: WritingMode, title: String) throws -> String {
        struct Request: Encodable {
            var version = 1
            var source: String
            var mode: WritingMode
            var title: String
            var assets: [ProjectAssetRecord]
        }
        let assets = snapshot.assets.sorted(by: { $0.key < $1.key }).map {
            ProjectAssetRecord(reference: $0.key, file: ProjectFileRecord(relativePath: "", contentHash: ProjectDigest.hash($0.value)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ProjectDigest.hash(try encoder.encode(Request(
            source: ProjectDigest.hash(snapshot.sourceData), mode: mode, title: title, assets: assets)))
    }
}

extension ProjectStore {
    func prepareLocalLegacyProject(in directory: URL) throws -> LegacyMigrationResult? {
        guard let source = try LegacyProjectMigrator.source(in: directory) else { return nil }
        let snapshot = try LegacyProjectMigrator.read(from: source)
        let mode: WritingMode = snapshot.entries.contains { $0.resolvedKind == .novel } ? .fiction : .general
        return try prepareLegacyMigration(from: source, mode: mode, title: "Legacy Library")
    }
    /// Recover metadata from our verified copy, never from the live legacy store.
    func prepareDocumentNavigation(_ project: WritingProject) throws -> WritingProject {
        guard project.userData[ProjectNavigation.key] == nil, let source = try legacySource(id: project.id) else { return project }
        var prepared = project
        try LegacyProjectMigrator.restoreNavigation(from: source, into: &prepared)
        try save(prepared, replacing: project)
        let verified = try load(id: project.id)
        guard verified == prepared else { throw ProjectStoreError.changedDuringSave }
        return verified
    }
    public func migrateLegacy(
        from sourceURL: URL,
        mode: WritingMode,
        title: String
    ) throws -> LegacyMigrationResult {
        let result = try prepareLegacyMigration(from: sourceURL, mode: mode, title: title)
        _ = try activateAndLoad(id: result.projectID)
        return result
    }

    /// 명시적으로 가져온 원고만 다루며 기존 앱의 activeID는 변경하지 않는다.
    public func prepareLegacyMigration(
        from sourceURL: URL,
        mode: WritingMode,
        title: String
    ) throws -> LegacyMigrationResult {
        try withStoreLock {
            let snapshot = try LegacyProjectMigrator.read(from: sourceURL)
            let sourceHash = ProjectDigest.hash(snapshot.sourceData)
            let requestHash = try LegacyProjectMigrator.fingerprint(snapshot, mode: mode, title: title)
            let receiptURL = try rootURL("Migrations/\(requestHash).json")
            var reusedID: WritingProjectID?
            if files.fileExists(at: receiptURL) {
                do {
                    let receipt = try JSONDecoder().decode(MigrationReceipt.self, from: files.read(receiptURL))
                    let manifest = try readManifest(id: receipt.projectID)
                    _ = try materialize(manifest)
                    if receipt.requestFingerprint == requestHash,
                        manifest.legacySource?.contentHash == ProjectDigest.hash(snapshot.archiveData) {
                        reusedID = receipt.projectID
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 손상된 receipt/target을 덮지 않고 별도 프로젝트로 복구한다.
                }
            }
            let id = reusedID ?? WritingProjectID()
            if reusedID == nil {
                var project = WritingProject(id: id, title: title, mode: mode,
                    documents: snapshot.entries.map(LegacyEntryAdapter.document(from:)))
                if project.documents.isEmpty {
                    project.documents = [WritingDocument(id: WritingDocumentID(), title: "Untitled", body: "", kind: .manuscript)]
                }
                try LegacyProjectMigrator.restoreNavigation(from: snapshot.archiveData, into: &project)
                if let journal = snapshot.journalSource { project.userData["legacy-journal.md"] = journal }
                try saveUnlocked(project, importedAssets: snapshot.assets, source: snapshot.archiveData)
                let verifiedProject = try loadUnlocked(id: id)
                guard verifiedProject == project,
                    zip(verifiedProject.documents, project.documents).allSatisfy({
                        Data($0.body.utf8) == Data($1.body.utf8) && Data($0.title.utf8) == Data($1.title.utf8)
                    }) else { throw ProjectStoreError.damagedFile("project.json") }
            }
            // 이관 도중 기존 앱이 저장했으면 오래된 스냅샷으로 활성화하지 않는다.
            let latest = try LegacyProjectMigrator.read(from: sourceURL)
            guard latest.sourceData == snapshot.sourceData, latest.assets == snapshot.assets else {
                throw ProjectStoreError.damagedFile("entries.json 또는 images/")
            }
            try files.createDirectory(at: rootURL("Migrations"))
            let receipt = MigrationReceipt(requestFingerprint: requestHash, projectID: id)
            try Task.checkCancellation()
            try files.writeAtomically(JSONEncoder().encode(receipt), to: receiptURL)
            return LegacyMigrationResult(projectID: id, migratedDocumentCount: snapshot.entries.count,
                sourceFingerprint: sourceHash, reusedExistingProject: reusedID != nil,
                selectedDocumentID: snapshot.activeID.map(WritingDocumentID.init(rawValue:)))
        }
    }
}
