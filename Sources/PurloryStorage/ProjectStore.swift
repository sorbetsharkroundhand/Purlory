import Darwin
import Foundation

/// 디스크 작업은 actor 안에서 수행한다. 같은 루트의 다른 인스턴스/프로세스도 잠근다 (PLAN §5.2).
public actor ProjectStore {
    package let root: URL
    package let files: any ProjectFileSystem
    var saveBaseline: ProjectSaveBaseline?

    public init(root: URL, fileSystem: any ProjectFileSystem = LocalProjectFileSystem()) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.files = fileSystem
    }

    public func save(_ project: WritingProject) throws {
        try withStoreLock { try saveUnlocked(project) }
    }

    /// A preparation task must not replace a newer durable owner snapshot.
    public func save(_ project: WritingProject, replacing expected: WritingProject) throws {
        try withStoreLock {
            guard project.id == expected.id, try loadUnlocked(id: project.id) == expected else {
                throw ProjectStoreError.changedDuringSave
            }
            try saveUnlocked(project)
        }
    }

    public func load(id: WritingProjectID) throws -> WritingProject {
        try withStoreLock { try loadUnlocked(id: id) }
    }

    public func previousProject(id: WritingProjectID) throws -> WritingProject {
        try withStoreLock {
            try materialize(readManifest(id: id, name: "previous-project.json"))
        }
    }

    public func activate(id: WritingProjectID) throws {
        try withStoreLock { _ = try activateUnlocked(id: id) }
    }

    public func activateAndLoad(id: WritingProjectID, expected: WritingProject? = nil) throws -> WritingProject {
        try withStoreLock { try activateUnlocked(id: id, expected: expected) }
    }

    /// Another process may establish an active project while startup prepares a copy.
    package func activateInitialProject(id: WritingProjectID, expected: WritingProject?) throws -> WritingProject {
        try withStoreLock {
            guard !files.fileExists(at: try rootURL("active-project.json")) else {
                throw ProjectStoreError.changedDuringSave
            }
            return try activateUnlocked(id: id, expected: expected)
        }
    }

    public func activeProject() throws -> WritingProject? {
        try withStoreLock {
            let url = try rootURL("active-project.json")
            guard files.fileExists(at: url) else { return nil }
            let id = try JSONDecoder().decode(WritingProjectID.self, from: files.read(url))
            return try loadUnlocked(id: id)
        }
    }

    public func legacySource(id: WritingProjectID) throws -> Data? {
        try withStoreLock {
            guard let record = try readManifest(id: id).legacySource else { return nil }
            return try verified(record, in: id)
        }
    }

    /// 기존 본문의 상대경로를 바꾸지 않고 이관된 사본을 읽는다.
    public func assetData(reference: String, in id: WritingProjectID) throws -> Data? {
        try withStoreLock {
            try ProjectPaths.validateRelative(reference)
            guard let record = try readManifest(id: id).assets.first(where: { $0.reference == reference })
            else { return nil }
            return try verified(record.file, in: id)
        }
    }

    public func assetCatalog(id: WritingProjectID) throws -> ProjectAssetCatalog {
        try withStoreLock {
            var assets: [String: Data] = [:]
            for record in try readManifest(id: id).assets {
                try Task.checkCancellation()
                assets[record.reference] = try verified(record.file, in: id)
            }
            return ProjectAssetCatalog(projectID: id, verifiedAssets: assets)
        }
    }

    /// Commit immutable bytes before changing their reference; retain previous blobs for recovery.
    public func addAsset(_ data: Data, reference: String, to id: WritingProjectID) throws {
        try withStoreLock {
            try ProjectPaths.validateRelative(reference)
            var manifest = try readManifest(id: id)
            _ = try materialize(manifest)
            let manifestURL = try projectURL(id, "project.json")
            let oldData = try files.read(manifestURL)
            let hash = ProjectDigest.hash(data)
            let record = ProjectAssetRecord(reference: reference,
                file: ProjectFileRecord(relativePath: "Assets/\(hash)", contentHash: hash))
            try writeImmutable(data, path: record.file.relativePath, id: id)
            if let index = manifest.assets.firstIndex(where: { $0.reference == reference }) {
                if manifest.assets[index] == record { return }
                manifest.assets[index] = record
            } else {
                manifest.assets.append(record)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let updated = try encoder.encode(manifest)
            try files.writeAtomically(oldData, to: projectURL(id, "previous-project.json"))
            try Task.checkCancellation()
            try files.writeAtomically(updated, to: manifestURL)
        }
    }

    /// Reads rebuildable document intelligence without adding it to the durable manifest.
    public func readIntelligence(
        projectID: WritingProjectID,
        documentID: WritingDocumentID
    ) throws -> Data? {
        try withStoreLock {
            try validateDocument(documentID, in: projectID)
            let url = try projectURL(projectID, intelligencePath(documentID))
            guard files.fileExists(at: url) else { return nil }
            return try files.read(url)
        }
    }

    /// Atomically writes rebuildable intelligence. Manuscript and UserData are untouched.
    public func writeIntelligence(
        _ data: Data,
        projectID: WritingProjectID,
        documentID: WritingDocumentID
    ) throws {
        try withStoreLock {
            try Task.checkCancellation()
            try validateDocument(documentID, in: projectID)
            let directory = try projectURL(projectID, "Intelligence")
            try files.createDirectory(at: directory)
            try Task.checkCancellation()
            try files.writeAtomically(data, to: projectURL(projectID, intelligencePath(documentID)))
        }
    }

    public func removeIntelligence(
        projectID: WritingProjectID,
        documentID: WritingDocumentID
    ) throws {
        try withStoreLock {
            try validateDocument(documentID, in: projectID)
            let url = try projectURL(projectID, intelligencePath(documentID))
            guard files.fileExists(at: url) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }

    package func withStoreLock<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try ProjectPaths.rejectSymlink(root)
        try files.createDirectory(at: root)
        let lockURL = try rootURL(".store.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try operation()
    }

    package func rootURL(_ path: String) throws -> URL { try ProjectPaths.checked(path, under: root) }

    package func projectURL(_ id: WritingProjectID, _ path: String) throws -> URL {
        try rootURL("\(id.rawValue.uuidString)/\(path)")
    }

    package func readManifest(id: WritingProjectID, name: String = "project.json") throws -> ProjectManifest {
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: files.read(projectURL(id, name)))
        guard ProjectManifest.supportsSchema(manifest.schemaVersion) else {
            throw ProjectStoreError.unsupportedSchema(manifest.schemaVersion)
        }
        let documentIDs = Set(manifest.documents.map(\.id))
        guard manifest.id == id,
            documentIDs.count == manifest.documents.count,
            manifest.trashedDocumentIDs.isSubset(of: documentIDs),
            Set(manifest.assets.map(\.reference)).count == manifest.assets.count
        else { throw ProjectStoreError.invalidManifest }
        for record in manifest.documents {
            guard ProjectDigest.isValid(record.contentHash), record.relativePath == documentPath(
                id: record.id, kind: record.kind, hash: record.contentHash)
            else { throw ProjectStoreError.invalidManifest }
        }
        for asset in manifest.assets {
            try ProjectPaths.validateRelative(asset.reference)
            guard asset.file.relativePath == "Assets/\(asset.file.contentHash)" else {
                throw ProjectStoreError.invalidManifest
            }
        }
        if let source = manifest.legacySource,
            source.relativePath != "UserData/legacy-\(source.contentHash).json" {
            throw ProjectStoreError.invalidManifest
        }
        for (key, record) in manifest.userData {
            guard record.relativePath == (try userDataPath(key: key, hash: record.contentHash)) else {
                throw ProjectStoreError.invalidManifest
            }
        }
        return manifest
    }

    package func verified(_ record: ProjectFileRecord, in id: WritingProjectID) throws -> Data {
        guard ProjectDigest.isValid(record.contentHash) else { throw ProjectStoreError.invalidManifest }
        let data = try files.read(projectURL(id, record.relativePath))
        guard ProjectDigest.hash(data) == record.contentHash else {
            throw ProjectStoreError.damagedFile(record.relativePath)
        }
        return data
    }

    package func materialize(_ manifest: ProjectManifest) throws -> WritingProject {
        try materialize(manifest, read: { try verified($0, in: manifest.id) })
    }

    package func materialize(_ manifest: ProjectManifest, read: (ProjectFileRecord) throws -> Data) throws -> WritingProject {
        var documents: [WritingDocument] = []
        for record in manifest.documents {
            try Task.checkCancellation()
            let data = try read(ProjectFileRecord(relativePath: record.relativePath, contentHash: record.contentHash))
            guard let body = String(data: data, encoding: .utf8) else {
                throw ProjectStoreError.damagedFile(record.relativePath)
            }
            documents.append(WritingDocument(id: record.id, title: record.title, body: body, kind: record.kind))
        }
        for record in manifest.assets {
            try Task.checkCancellation()
            _ = try read(record.file)
        }
        if let source = manifest.legacySource { _ = try read(source) }
        var userData: [String: Data] = [:]
        for (key, record) in manifest.userData {
            try Task.checkCancellation()
            userData[key] = try read(record)
        }
        return WritingProject(
            id: manifest.id,
            title: manifest.title,
            mode: manifest.mode,
            documents: documents,
            trashedDocumentIDs: manifest.trashedDocumentIDs,
            userData: userData)
    }

    package func loadUnlocked(id: WritingProjectID) throws -> WritingProject { try materialize(readManifest(id: id)) }

    package func documentPath(id: WritingDocumentID, kind: WritingDocument.Kind, hash: String) -> String {
        "\(kind == .note ? "Notes" : "Documents")/\(id.rawValue.uuidString)/\(hash).md"
    }

    package func intelligencePath(_ documentID: WritingDocumentID) -> String {
        "Intelligence/\(documentID.rawValue.uuidString).knowledge.json"
    }

    package func userDataPath(key: String, hash: String) throws -> String {
        try ProjectUserDataKey.validate(key)
        guard ProjectDigest.isValid(hash) else { throw ProjectStoreError.invalidManifest }
        return "UserData/records/\(ProjectDigest.hash(Data(key.utf8)))/\(hash).data"
    }

    private func validateDocument(_ documentID: WritingDocumentID, in projectID: WritingProjectID) throws {
        let manifest = try readManifest(id: projectID)
        guard manifest.documents.contains(where: { $0.id == documentID }) else {
            throw ProjectStoreError.invalidManifest
        }
    }

    package func writeImmutable(_ data: Data, path: String, id: WritingProjectID) throws {
        try Task.checkCancellation()
        let url = try projectURL(id, path)
        if files.fileExists(at: url) {
            guard try files.read(url) == data else { throw ProjectStoreError.damagedFile(path) }
            return
        }
        try files.createDirectory(at: url.deletingLastPathComponent())
        try files.writeAtomically(data, to: url)
        guard try files.read(url) == data else { throw ProjectStoreError.damagedFile(path) }
    }

    package func saveUnlocked(_ project: WritingProject, importedAssets: [String: Data] = [:], source: Data? = nil) throws {
        let baseline = saveBaseline
        // Any throw leaves no reusable baseline, including a failed manifest commit.
        saveBaseline = nil
        let documentIDs = Set(project.documents.map(\.id))
        guard documentIDs.count == project.documents.count,
            project.trashedDocumentIDs.isSubset(of: documentIDs)
        else {
            throw ProjectStoreError.invalidManifest
        }
        let manifestURL = try projectURL(project.id, "project.json")
        let oldData = files.fileExists(at: manifestURL) ? try files.read(manifestURL) : nil
        let old = oldData == nil ? nil : try readManifest(id: project.id)
        var versions: [String: ProjectFileVersion] = [:]
        let previous: WritingProject?
        if let old {
            if let baseline, baseline.project.id == project.id, baseline.manifestBytes == oldData, baseline.manifest == old {
                versions = baseline.versions
                try verifyForSave(old, versions: &versions)
                previous = baseline.project
            } else {
                previous = try materialize(old, read: { try readForSave($0, in: project.id, versions: &versions) })
            }
        } else { previous = nil }
        let previousDocuments = Dictionary(uniqueKeysWithValues: (previous?.documents ?? []).map { ($0.id, $0) })
        let previousRecords = Dictionary(uniqueKeysWithValues: (old?.documents ?? []).map { ($0.id, $0) })
        for directory in ["Documents", "Notes", "Assets", "Intelligence", "UserData"] {
            try files.createDirectory(at: projectURL(project.id, directory))
        }
        var manifest = ProjectManifest(
            id: project.id,
            title: project.title,
            mode: project.mode,
            documents: [],
            trashedDocumentIDs: project.trashedDocumentIDs)
        manifest.assets = old?.assets ?? []
        manifest.legacySource = old?.legacySource
        for (key, data) in project.userData.sorted(by: { $0.key < $1.key }) {
            if previous?.userData[key] == data, let record = old?.userData[key] {
                manifest.userData[key] = record
                continue
            }
            let hash = ProjectDigest.hash(data)
            let path = try userDataPath(key: key, hash: hash)
            try writeImmutable(data, path: path, id: project.id)
            manifest.userData[key] = ProjectFileRecord(relativePath: path, contentHash: hash)
        }
        for document in project.documents {
            try Task.checkCancellation()
            if let prior = previousDocuments[document.id], prior.kind == document.kind,
               prior.body.utf8.elementsEqual(document.body.utf8), var record = previousRecords[document.id] {
                record.title = document.title
                manifest.documents.append(record)
                continue
            }
            let data = Data(document.body.utf8)
            let hash = ProjectDigest.hash(data)
            let path = documentPath(id: document.id, kind: document.kind, hash: hash)
            try writeImmutable(data, path: path, id: project.id)
            manifest.documents.append(ProjectDocumentRecord(
                id: document.id, title: document.title, kind: document.kind, relativePath: path, contentHash: hash))
        }
        for (reference, data) in importedAssets.sorted(by: { $0.key < $1.key }) {
            try ProjectPaths.validateRelative(reference)
            let hash = ProjectDigest.hash(data)
            let record = ProjectFileRecord(relativePath: "Assets/\(hash)", contentHash: hash)
            try writeImmutable(data, path: record.relativePath, id: project.id)
            manifest.assets.append(ProjectAssetRecord(reference: reference, file: record))
        }
        if let source {
            let hash = ProjectDigest.hash(source)
            let record = ProjectFileRecord(relativePath: "UserData/legacy-\(hash).json", contentHash: hash)
            try writeImmutable(source, path: record.relativePath, id: project.id)
            manifest.legacySource = record
        }
        // 검증은 최종 커밋 전에 끝낸다. 그 뒤 실패 보고로 성공한 저장을 오인시키지 않는다.
        try verifyForSave(manifest, versions: &versions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        if data != oldData {
            if let oldData {
                try files.writeAtomically(oldData, to: projectURL(project.id, "previous-project.json"))
            }
            try Task.checkCancellation()
            try files.writeAtomically(data, to: manifestURL)
        }
        let livePaths = Set(manifest.durableFiles.map(\.relativePath))
        saveBaseline = ProjectSaveBaseline(project: project, manifest: manifest, manifestBytes: data,
            versions: versions.filter { livePaths.contains($0.key) })
    }

    package func activateUnlocked(id: WritingProjectID, expected: WritingProject? = nil) throws -> WritingProject {
        let project = try loadUnlocked(id: id)
        if let expected, project != expected { throw ProjectStoreError.changedDuringSave }
        let data = try JSONEncoder().encode(id)
        try Task.checkCancellation()
        try files.writeAtomically(data, to: rootURL("active-project.json"))
        return project
    }
}
