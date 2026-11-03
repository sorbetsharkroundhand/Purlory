import CryptoKit
import Darwin
import Foundation
import zlib

public struct ProjectGitCommitRecord: Codable, Equatable, Sendable {
    public let sha: String
    public let treeSHA: String
    public let parentSHAs: [String]
    public let branch: String
    public let message: String
    public let timestamp: Int64
}

public extension ProjectStore {
    func commitManuscriptGitVersion(
        projectID: WritingProjectID,
        documentID: WritingDocumentID,
        branch: String = "본편",
        message: String,
        text: String,
        parentSHAs: [String] = [],
        timestamp: Date = .now
    ) throws -> ProjectGitCommitRecord {
        try withStoreLock {
            let manifest = try readManifest(id: projectID)
            guard let doc = manifest.documents.first(where: { $0.id == documentID }),
                  doc.kind == .manuscript else {
                throw ProjectStoreError.invalidManifest
            }
            let projectRoot = try rootURL(projectID.rawValue.uuidString)
            return try ProjectGitRepository.commitManuscript(
                at: projectRoot,
                documentID: documentID,
                branch: branch,
                message: message,
                text: text,
                parentSHAs: parentSHAs,
                timestamp: timestamp,
                files: files
            )
        }
    }

    func readManuscriptGitBlob(
        projectID: WritingProjectID,
        commitSHA: String,
        documentID: WritingDocumentID
    ) throws -> String {
        try withStoreLock {
            let projectRoot = try rootURL(projectID.rawValue.uuidString)
            return try ProjectGitRepository.readBlobText(
                at: projectRoot,
                commitSHA: commitSHA,
                documentID: documentID,
                files: files
            )
        }
    }
}

/// Manages a standard Git v2 repository (.git) inside a project folder for manuscript version control.
/// Notes, references, and derived Intelligence sidecars are excluded via .gitignore.
package enum ProjectGitRepository {
    private static let authorName = "Purlory Writer"
    private static let authorEmail = "writer@purlory.local"
    private static let gitignoreContent = """
    Intelligence/
    Notes/
    References/
    UserData/
    .store.lock
    previous-project.json
    *.tmp
    """

    package static func ensureInitialized(at projectRoot: URL, files: any ProjectFileSystem) throws {
        try ProjectPaths.rejectSymlink(projectRoot)
        let gitDir = try ProjectPaths.checked(".git", under: projectRoot)
        let objectsDir = try ProjectPaths.checked(".git/objects", under: projectRoot)
        let refsHeadsDir = try ProjectPaths.checked(".git/refs/heads", under: projectRoot)
        let refsTagsDir = try ProjectPaths.checked(".git/refs/tags", under: projectRoot)
        try files.createDirectory(at: gitDir)
        try files.createDirectory(at: objectsDir)
        try files.createDirectory(at: refsHeadsDir)
        try files.createDirectory(at: refsTagsDir)

        let headURL = try ProjectPaths.checked(".git/HEAD", under: projectRoot)
        if !files.fileExists(at: headURL) {
            try files.writeAtomically(Data("ref: refs/heads/main\n".utf8), to: headURL)
        }
        let configURL = try ProjectPaths.checked(".git/config", under: projectRoot)
        if !files.fileExists(at: configURL) {
            let config = """
            [core]
            \trepositoryformatversion = 0
            \tfilemode = true
            \tbare = false
            \tlogallrefupdates = true
            """ + "\n"
            try files.writeAtomically(Data(config.utf8), to: configURL)
        }
        let ignoreURL = try ProjectPaths.checked(".gitignore", under: projectRoot)
        if !files.fileExists(at: ignoreURL) {
            try files.writeAtomically(Data((gitignoreContent + "\n").utf8), to: ignoreURL)
        }
    }

    package static func sanitizedBranchToken(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "main" }
        var scalars: [UnicodeScalar] = []
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                scalars.append(scalar)
            } else if scalar.value >= 0xAC00 && scalar.value <= 0xD7A3 {
                scalars.append(scalar)
            } else {
                scalars.append("-")
            }
        }
        let token = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return token.isEmpty ? "branch" : String(token.prefix(64))
    }

    package static func branchRefPath(documentID: WritingDocumentID, branch: String) -> String {
        let token = sanitizedBranchToken(branch)
        return ".git/refs/heads/manuscripts/\(documentID.rawValue.uuidString.lowercased())/\(token)"
    }

    package static func commitManuscript(
        at projectRoot: URL,
        documentID: WritingDocumentID,
        branch: String,
        message: String,
        text: String,
        parentSHAs: [String] = [],
        timestamp: Date = .now,
        files: any ProjectFileSystem
    ) throws -> ProjectGitCommitRecord {
        try Task.checkCancellation()
        try ensureInitialized(at: projectRoot, files: files)

        // Also update the canonical working-tree file at Manuscripts/<doc-id>.md for external Git tools.
        let workingDir = try ProjectPaths.checked("Manuscripts", under: projectRoot)
        try files.createDirectory(at: workingDir)
        let workingFileName = "\(documentID.rawValue.uuidString.lowercased()).md"
        let workingFileURL = try ProjectPaths.checked("Manuscripts/\(workingFileName)", under: projectRoot)
        let textData = Data(text.utf8)
        try files.writeAtomically(textData, to: workingFileURL)

        let (blobSHA, blobBytes) = try writeObject(type: "blob", body: textData, at: projectRoot, files: files)
        _ = blobSHA

        var treeEntry = Data("100644 \(workingFileName)\0".utf8)
        treeEntry.append(contentsOf: blobBytes)
        let (subTreeSHA, subTreeBytes) = try writeObject(type: "tree", body: treeEntry, at: projectRoot, files: files)
        _ = subTreeSHA

        var rootTreeEntry = Data("40000 Manuscripts\0".utf8)
        rootTreeEntry.append(contentsOf: subTreeBytes)
        let (rootTreeSHA, _) = try writeObject(type: "tree", body: rootTreeEntry, at: projectRoot, files: files)

        let refPath = branchRefPath(documentID: documentID, branch: branch)
        let refURL = try ProjectPaths.checked(refPath, under: projectRoot)
        var resolvedParents = parentSHAs.filter { isValidSHA($0) }
        if resolvedParents.isEmpty, files.fileExists(at: refURL),
           let existing = String(data: try files.read(refURL), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValidSHA(existing) {
            resolvedParents = [existing]
        }

        let unixTime = Int64(timestamp.timeIntervalSince1970)
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "원고 버전 저장"
            : message.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = ["tree \(rootTreeSHA)"]
        for parent in resolvedParents {
            lines.append("parent \(parent)")
        }
        lines.append("author \(authorName) <\(authorEmail)> \(unixTime) +0900")
        lines.append("committer \(authorName) <\(authorEmail)> \(unixTime) +0900")
        lines.append("")
        lines.append(cleanMessage)
        let commitBody = Data((lines.joined(separator: "\n") + "\n").utf8)
        let (commitSHA, _) = try writeObject(type: "commit", body: commitBody, at: projectRoot, files: files)

        try files.createDirectory(at: refURL.deletingLastPathComponent())
        try files.writeAtomically(Data((commitSHA + "\n").utf8), to: refURL)

        let mainRefURL = try ProjectPaths.checked(".git/refs/heads/main", under: projectRoot)
        try files.writeAtomically(Data((commitSHA + "\n").utf8), to: mainRefURL)

        return ProjectGitCommitRecord(
            sha: commitSHA,
            treeSHA: rootTreeSHA,
            parentSHAs: resolvedParents,
            branch: branch,
            message: cleanMessage,
            timestamp: unixTime
        )
    }

    package static func readBlobText(
        at projectRoot: URL,
        commitSHA: String,
        documentID: WritingDocumentID,
        files: any ProjectFileSystem
    ) throws -> String {
        guard isValidSHA(commitSHA) else { throw ProjectStoreError.invalidManifest }
        let (commitType, commitBody) = try readObject(sha: commitSHA, at: projectRoot, files: files)
        guard commitType == "commit",
              let commitString = String(data: commitBody, encoding: .utf8),
              let treeLine = commitString.split(separator: "\n").first(where: { $0.hasPrefix("tree ") })
        else { throw ProjectStoreError.damagedFile(commitSHA) }
        let rootTreeSHA = String(treeLine.dropFirst("tree ".count))
        let (rootType, rootBody) = try readObject(sha: rootTreeSHA, at: projectRoot, files: files)
        guard rootType == "tree" else { throw ProjectStoreError.damagedFile(rootTreeSHA) }
        guard let subTreeSHA = parseTreeEntrySHA(named: "Manuscripts", in: rootBody) else {
            throw ProjectStoreError.damagedFile(rootTreeSHA)
        }
        let (subType, subBody) = try readObject(sha: subTreeSHA, at: projectRoot, files: files)
        guard subType == "tree" else { throw ProjectStoreError.damagedFile(subTreeSHA) }
        let targetFile = "\(documentID.rawValue.uuidString.lowercased()).md"
        guard let blobSHA = parseTreeEntrySHA(named: targetFile, in: subBody) else {
            throw ProjectStoreError.damagedFile(subTreeSHA)
        }
        let (blobType, blobBody) = try readObject(sha: blobSHA, at: projectRoot, files: files)
        guard blobType == "blob", let text = String(data: blobBody, encoding: .utf8) else {
            throw ProjectStoreError.damagedFile(blobSHA)
        }
        return text
    }

    private static func isValidSHA(_ sha: String) -> Bool {
        sha.utf8.count == 40 && sha.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func writeObject(
        type: String,
        body: Data,
        at projectRoot: URL,
        files: any ProjectFileSystem
    ) throws -> (String, [UInt8]) {
        var raw = Data("\(type) \(body.count)\0".utf8)
        raw.append(body)
        let digest = Insecure.SHA1.hash(data: raw)
        let bytes = Array(digest)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let dirPath = ".git/objects/\(hex.prefix(2))"
        let filePath = "\(dirPath)/\(hex.dropFirst(2))"
        let objectURL = try ProjectPaths.checked(filePath, under: projectRoot)
        if !files.fileExists(at: objectURL) {
            try files.createDirectory(at: ProjectPaths.checked(dirPath, under: projectRoot))
            let compressed = try zlibCompress(raw)
            try files.writeAtomically(compressed, to: objectURL)
        }
        return (hex, bytes)
    }

    private static func readObject(
        sha: String,
        at projectRoot: URL,
        files: any ProjectFileSystem
    ) throws -> (String, Data) {
        let filePath = ".git/objects/\(sha.prefix(2))/\(sha.dropFirst(2))"
        let objectURL = try ProjectPaths.checked(filePath, under: projectRoot)
        let compressed = try files.read(objectURL)
        let raw = try zlibDecompress(compressed)
        let actualHex = Insecure.SHA1.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard actualHex == sha, let nulIndex = raw.firstIndex(of: 0),
              let header = String(data: raw[..<nulIndex], encoding: .utf8)
        else { throw ProjectStoreError.damagedFile(filePath) }
        let parts = header.split(separator: " ")
        guard parts.count == 2, let expectedSize = Int(parts[1]) else {
            throw ProjectStoreError.damagedFile(filePath)
        }
        let body = Data(raw[(raw.index(after: nulIndex))...])
        guard body.count == expectedSize else { throw ProjectStoreError.damagedFile(filePath) }
        return (String(parts[0]), body)
    }

    private static func parseTreeEntrySHA(named targetName: String, in treeData: Data) -> String? {
        var index = treeData.startIndex
        while index < treeData.endIndex {
            guard let nul = treeData[index...].firstIndex(of: 0) else { return nil }
            let header = String(data: treeData[index..<nul], encoding: .utf8) ?? ""
            let shaStart = treeData.index(after: nul)
            guard treeData.distance(from: shaStart, to: treeData.endIndex) >= 20 else { return nil }
            let shaEnd = treeData.index(shaStart, offsetBy: 20)
            if let space = header.firstIndex(of: " ") {
                let entryName = String(header[header.index(after: space)...])
                if entryName == targetName {
                    return treeData[shaStart..<shaEnd].map { String(format: "%02x", $0) }.joined()
                }
            }
            index = shaEnd
        }
        return nil
    }

    private static func zlibCompress(_ data: Data) throws -> Data {
        var destLen = uLongf(compressBound(uLong(data.count)))
        var out = Data(count: Int(destLen))
        let result = data.withUnsafeBytes { srcPtr -> Int32 in
            out.withUnsafeMutableBytes { dstPtr -> Int32 in
                guard let dst = dstPtr.bindMemory(to: Bytef.self).baseAddress else { return Z_MEM_ERROR }
                let src = srcPtr.bindMemory(to: Bytef.self).baseAddress
                return compress2(dst, &destLen, src, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard result == Z_OK else { throw ProjectStoreError.damagedFile(".git/objects") }
        out.count = Int(destLen)
        return out
    }

    private static func zlibDecompress(_ data: Data) throws -> Data {
        var capacity = max(256, data.count * 4)
        while capacity <= 64 * 1024 * 1024 {
            var destLen = uLongf(capacity)
            var out = Data(count: capacity)
            let result = data.withUnsafeBytes { srcPtr -> Int32 in
                out.withUnsafeMutableBytes { dstPtr -> Int32 in
                    guard let dst = dstPtr.bindMemory(to: Bytef.self).baseAddress,
                          let src = srcPtr.bindMemory(to: Bytef.self).baseAddress else { return Z_MEM_ERROR }
                    return uncompress(dst, &destLen, src, uLong(data.count))
                }
            }
            if result == Z_OK {
                out.count = Int(destLen)
                return out
            } else if result == Z_BUF_ERROR {
                capacity *= 2
                continue
            } else {
                throw ProjectStoreError.damagedFile(".git/objects")
            }
        }
        throw ProjectStoreError.damagedFile(".git/objects")
    }
}
