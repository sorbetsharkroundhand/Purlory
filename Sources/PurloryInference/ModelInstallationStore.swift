import Foundation
import CryptoKit

public actor ModelInstallationStore {
    public enum State: Equatable, Sendable {
        case missing, downloading, verifying, ready, interrupted, removing
        case failed(String)
    }
    public typealias Download = @Sendable (ModelInstallManifest, ModelInstallManifest.File, URL) async throws -> Void
    public static let shared = ModelInstallationStore(root: PurloryStorageLocation.standard.rootDirectory.appendingPathComponent("Models"))
    private let root: URL
    private struct Job { let token: UUID; let manifest: ModelInstallManifest; let task: Task<URL, Error> }
    private var jobs: [String: Job] = [:]
    private var removals: [String: Task<Void, Error>] = [:]
    private var phases: [String: State] = [:]
    public init(root: URL) { self.root = root.standardizedFileURL }

    public func directory(for manifest: ModelInstallManifest) throws -> URL {
        try manifest.validate()
        return try ProjectPaths.checked("\(modelKey(manifest.id))/\(manifest.revision)", under: root)
    }
    private func modelKey(_ id: String) -> String { hex(SHA256.hash(data: Data(id.utf8))) }
    private func staging(for manifest: ModelInstallManifest) throws -> URL {
        try ProjectPaths.checked("\(modelKey(manifest.id))/\(manifest.revision).partial", under: root)
    }
    public func state(for manifest: ModelInstallManifest) async -> State {
        do {
            let directory = try directory(for: manifest)
            if removals[manifest.id] != nil { return .removing }
            if try hasTombstones(manifest.id) { return .interrupted }
            if let job = jobs[manifest.id] {
                guard job.manifest == manifest else { return .failed(ModelInstallError.busy.localizedDescription) }
                return phases[manifest.id] ?? .downloading
            }
            if FileManager.default.fileExists(atPath: directory.path) {
                try await verify(manifest, in: directory, requireReceipt: true)
                return .ready
            }
            return FileManager.default.fileExists(atPath: try staging(for: manifest).path) ? .interrupted : .missing
        } catch { return .failed(error.localizedDescription) }
    }
    public func install(_ manifest: ModelInstallManifest, download: @escaping Download,
                        onState: @Sendable @escaping (State, Double) -> Void = { _, _ in }) async throws -> URL {
        try manifest.validate()
        try requireInstallAllowed(manifest.id)
        try Task.checkCancellation()
        let current = await state(for: manifest)
        // Recheck after the suspension: another caller may have started a lifecycle operation.
        try requireInstallAllowed(manifest.id)
        if let job = jobs[manifest.id] {
            guard job.manifest == manifest else { throw ModelInstallError.busy }
            onState(phases[manifest.id] ?? .downloading, 0)
            let directory = try await job.task.value
            try Task.checkCancellation()
            return directory
        }
        if current == .ready { return try directory(for: manifest) }
        try Task.checkCancellation()
        let task = Task(priority: .utility) { try await self.perform(manifest, download: download, onState: onState) }
        let token = UUID()
        jobs[manifest.id] = Job(token: token, manifest: manifest, task: task)
        defer {
            if jobs[manifest.id]?.token == token { jobs[manifest.id] = nil; phases[manifest.id] = nil }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func ownedModelIDs() -> [String] {
        guard let keys = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var ids = Set<String>()
        for key in keys {
            guard let folder = try? ProjectPaths.checked(key, under: root),
                  let versions = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for version in versions {
                guard let directory = try? ProjectPaths.checked(version, under: folder),
                      let receipt = try? readReceipt(in: directory), modelKey(receipt.id) == key,
                      (try? ownedVersions(receipt.id)) != nil else { continue }
                ids.insert(receipt.id)
            }
        }
        return ids.sorted()
    }
    public func remove(_ id: String, onRetire: @Sendable @escaping () -> Void = {}) async throws {
        try await removeVersions(id, keeping: nil, onRetire: onRetire)
    }
    public func replace(_ id: String, with manifest: ModelInstallManifest, download: @escaping Download) async throws -> URL {
        let target = try await install(manifest, download: download)
        try Task.checkCancellation()
        try await removeVersions(id, keeping: id == manifest.id ? manifest.revision : nil, onRetire: {})
        guard await state(for: manifest) == .ready else { throw ModelInstallError.integrity }
        return target
    }
    private func removeVersions(_ id: String, keeping revision: String?, onRetire: @Sendable @escaping () -> Void) async throws {
        try validateID(id)
        try Task.checkCancellation()
        if let operation = removals[id] { try await operation.value; return }
        let task = Task(priority: .utility) {
            onRetire()
            if let job = self.jobs[id] {
                job.task.cancel(); _ = try? await job.task.value
                if self.jobs[id]?.token == job.token { self.jobs[id] = nil; self.phases[id] = nil }
            }
            // Preflight every version before mutating any of them.
            let versions = try self.ownedVersions(id)
            for directory in versions where directory.lastPathComponent != revision {
                let tombstone = directory.pathExtension == "removing" ? directory : directory.appendingPathExtension("removing")
                if directory != tombstone {
                    guard !FileManager.default.fileExists(atPath: tombstone.path) else { throw ModelInstallError.integrity }
                    try FileManager.default.moveItem(at: directory, to: tombstone)
                }
                try FileManager.default.removeItem(at: tombstone)
            }
            let folder = try ProjectPaths.checked(self.modelKey(id), under: self.root)
            self.verified = self.verified.filter { !$0.key.path.hasPrefix(folder.path + "/") }
            if FileManager.default.fileExists(atPath: folder.path),
               try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty {
                try FileManager.default.removeItem(at: folder)
            }
        }
        removals[id] = task
        defer { removals[id] = nil }
        // Once retirement begins it finishes even if the UI caller disappears.
        try await task.value
    }
    private func validateID(_ id: String) throws {
        try ProjectPaths.validateRelative(id)
        guard case .success(let valid) = ModelIDCommit.validate(id), valid == id else { throw ModelInstallError.metadata }
    }
    private func ownedVersions(_ id: String) throws -> [URL] {
        try validateID(id)
        let folder = try ProjectPaths.checked(modelKey(id), under: root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        guard !names.contains(where: { names.contains($0 + ".removing") }) else { throw ModelInstallError.integrity }
        return try names.map { name in
            let directory = try ProjectPaths.checked(name, under: folder)
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                let revision = String(name.prefix(40))
                guard revision.utf8.count == 40, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      [revision, revision + ".partial", revision + ".removing", revision + ".partial.removing"].contains(name)
                else { throw ModelInstallError.integrity }
                return directory
            }
            let receipt = try readReceipt(in: directory)
            guard receipt.id == id,
                  [receipt.revision, receipt.revision + ".partial", receipt.revision + ".removing", receipt.revision + ".partial.removing"].contains(name)
            else { throw ModelInstallError.integrity }
            try checkInventory(receipt, in: directory)
            return directory
        }
    }
    private func hasTombstones(_ id: String) throws -> Bool {
        let folder = try ProjectPaths.checked(modelKey(id), under: root)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains { $0.hasSuffix(".removing") } ?? false
    }
    private func requireInstallAllowed(_ id: String) throws {
        if try removals[id] != nil || hasTombstones(id) { throw ModelInstallError.busy }
    }
    public func cancel(_ id: String) { jobs[id]?.task.cancel() }

    private func perform(_ manifest: ModelInstallManifest, download: @escaping Download,
                         onState: @Sendable @escaping (State, Double) -> Void) async throws -> URL {
        let stage = try staging(for: manifest)
        if FileManager.default.fileExists(atPath: stage.path) { try requireOwnership(manifest, in: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        do { try checkInventory(manifest, in: stage) }
        catch ModelInstallError.integrity {
            try FileManager.default.removeItem(at: stage)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        }
        // A staging intent establishes ownership, but only publication can make it ready.
        try JSONEncoder().encode(manifest).write(to: try ProjectPaths.checked("receipt.json", under: stage), options: .atomic)
        func emit(_ state: State, _ progress: Double) { phases[manifest.id] = state; onState(state, progress) }
        let total = manifest.files.reduce(0.0) { $0 + Double($1.size) }
        var completed = 0.0
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = try ProjectPaths.checked(file.path, under: stage)
            emit(.downloading, completed / total)
            if (try? await verify(file, in: stage)) == nil {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await download(manifest, file, destination)
            }
            try Task.checkCancellation()
            emit(.verifying, completed / total)
            try await verify(file, in: stage)
            completed += Double(file.size)
        }
        try await verify(manifest, in: stage, requireReceipt: false)
        try Task.checkCancellation()
        let receipt = try ProjectPaths.checked("receipt.json", under: stage)
        try JSONEncoder().encode(manifest).write(to: receipt, options: .atomic)
        let final = try directory(for: manifest)
        if FileManager.default.fileExists(atPath: final.path) {
            try requireOwnership(manifest, in: final)
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: stage, to: final)
        emit(.ready, 1)
        return final
    }

    private func verify(_ manifest: ModelInstallManifest, in directory: URL, requireReceipt: Bool) async throws {
        try checkInventory(manifest, in: directory)
        if requireReceipt {
            guard try readReceipt(in: directory) == manifest else { throw ModelInstallError.integrity }
        }
        for file in manifest.files { try await verify(file, in: directory) }
        if let index = manifest.files.first(where: { $0.path == "model.safetensors.index.json" }) {
            guard index.size < 8_388_608,
                  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(index.path))) as? [String: Any],
                  let map = json["weight_map"] as? [String: String], !map.isEmpty,
                  Set(map.values).isSubset(of: Set(manifest.files.filter { $0.path.hasSuffix(".safetensors") }.map(\.path)))
            else { throw ModelInstallError.integrity }
        }
    }
    private func readReceipt(in directory: URL) throws -> ModelInstallManifest {
        let receipt = try ProjectPaths.checked("receipt.json", under: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: receipt.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 1_048_576
        else { throw ModelInstallError.integrity }
        let manifest = try JSONDecoder().decode(ModelInstallManifest.self, from: Data(contentsOf: receipt))
        try manifest.validate()
        return manifest
    }
    private func requireOwnership(_ manifest: ModelInstallManifest, in directory: URL) throws {
        // An interrupted intent write can leave an empty directory; there is no data to retire.
        if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { return }
        let receipt = try readReceipt(in: directory)
        guard receipt.id == manifest.id, receipt.revision == manifest.revision else { throw ModelInstallError.integrity }
    }
    private func checkInventory(_ manifest: ModelInstallManifest, in directory: URL) throws {
        let allowed = Set(manifest.files.map(\.path) + ["receipt.json"])
        guard let entries = FileManager.default.enumerator(atPath: directory.path)
        else { throw ModelInstallError.integrity }
        for case let relative as String in entries {
            let checked = try ProjectPaths.checked(relative, under: directory)
            let attributes = try FileManager.default.attributesOfItem(atPath: checked.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                guard allowed.contains(where: { $0.hasPrefix(relative + "/") }) else { throw ModelInstallError.integrity }
            } else {
                guard allowed.contains(relative) else { throw ModelInstallError.integrity }
            }
        }
    }

    private struct VerifiedFile {
        let file: ModelInstallManifest.File
        let modified: Date
        let inode: UInt64
    }
    private var verified: [URL: VerifiedFile] = [:]
    private func verify(_ file: ModelInstallManifest.File, in directory: URL) async throws {
        try Task.checkCancellation()
        let url = try ProjectPaths.checked(file.path, under: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == file.size
        else { throw ModelInstallError.integrity }
        let modified = attributes[.modificationDate] as? Date
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if let known = verified[url], known.file == file, known.modified == modified, known.inode == inode { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        if file.algorithm == .gitBlobSHA1 { sha1.update(data: Data("blob \(file.size)\0".utf8)) }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            if file.algorithm == .sha256 { sha256.update(data: data) } else { sha1.update(data: data) }
            await Task.yield()
        }
        let digest = file.algorithm == .sha256 ? hex(sha256.finalize()) : hex(sha1.finalize())
        guard digest == file.digest else { throw ModelInstallError.integrity }
        if let modified, let inode { verified[url] = VerifiedFile(file: file, modified: modified, inode: inode) }
    }
    private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
