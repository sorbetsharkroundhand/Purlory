import Foundation
import PurloryFoundation

/// Explicit, writer-owned original text. A version UUID identifies a saved decision;
/// a document ID identifies its manuscript; content digests identify only revisions.
public struct ManuscriptVersion: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable { case document, scene }
    public static let defaultBranchName = "본편"

    public let formatVersion: Int
    public let id: UUID
    public let documentID: WritingDocumentID
    public let createdAt: Date
    public let label: String
    public let scope: Scope
    public let text: String
    public let contentVersion: SceneContentVersion
    public let sourceRevision: String
    public let sourceStart: Int
    public let headingPath: [String]
    public let heading: EvidenceAnchor?
    public var parentIDs: [UUID]
    public var branchName: String
    public var gitCommitSHA: String?

    public var userDataKey: String { Self.keyPrefix + id.uuidString.lowercased() }
    private static let keyPrefix = "manuscript-version-"

    public init(
        formatVersion: Int = 2,
        id: UUID = UUID(),
        documentID: WritingDocumentID,
        createdAt: Date = .now,
        label: String,
        scope: Scope,
        text: String,
        contentVersion: SceneContentVersion,
        sourceRevision: String,
        sourceStart: Int,
        headingPath: [String],
        heading: EvidenceAnchor?,
        parentIDs: [UUID] = [],
        branchName: String = Self.defaultBranchName,
        gitCommitSHA: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.documentID = documentID
        self.createdAt = createdAt
        self.label = label
        self.scope = scope
        self.text = text
        self.contentVersion = contentVersion
        self.sourceRevision = sourceRevision
        self.sourceStart = sourceStart
        self.headingPath = headingPath
        self.heading = heading
        self.parentIDs = parentIDs
        self.branchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultBranchName
            : branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gitCommitSHA = gitCommitSHA
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, documentID, createdAt, label, scope, text
        case contentVersion, sourceRevision, sourceStart, headingPath, heading
        case parentIDs, branchName, gitCommitSHA
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(UUID.self, forKey: .id)
        documentID = try container.decode(WritingDocumentID.self, forKey: .documentID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        label = try container.decode(String.self, forKey: .label)
        scope = try container.decode(Scope.self, forKey: .scope)
        text = try container.decode(String.self, forKey: .text)
        contentVersion = try container.decode(SceneContentVersion.self, forKey: .contentVersion)
        sourceRevision = try container.decode(String.self, forKey: .sourceRevision)
        sourceStart = try container.decode(Int.self, forKey: .sourceStart)
        headingPath = try container.decode([String].self, forKey: .headingPath)
        heading = try container.decodeIfPresent(EvidenceAnchor.self, forKey: .heading)
        parentIDs = try container.decodeIfPresent([UUID].self, forKey: .parentIDs) ?? []
        let decodedBranch = try container.decodeIfPresent(String.self, forKey: .branchName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        branchName = decodedBranch.isEmpty ? Self.defaultBranchName : decodedBranch
        gitCommitSHA = try container.decodeIfPresent(String.self, forKey: .gitCommitSHA)
    }

    public static func capture(
        _ source: ProjectDocumentSnapshot,
        sceneAt: Int? = nil,
        label: String = "",
        parentIDs: [UUID] = [],
        branchName: String = Self.defaultBranchName,
        gitCommitSHA: String? = nil
    ) throws -> Self {
        guard source.kind == .manuscript else { throw ManuscriptVersionError.unsupportedDocumentKind }
        let body = source.body, ns = body as NSString
        var range = NSRange(location: 0, length: ns.length), path: [String] = [], heading: EvidenceAnchor?
        if let sceneAt {
            guard sceneAt >= 0, sceneAt <= ns.length,
                  let section = sections(in: body).last(where: { $0.range.location <= sceneAt }) else { throw ManuscriptVersionError.staleTarget }
            range = section.range; path = section.path
            if !path.isEmpty {
                let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
                heading = .init(documentID: source.identity.key.documentID, quote: ns.substring(with: line), utf16Hint: line.location)
            }
        }
        let text = ns.substring(with: range)
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultBranchName
            : branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            formatVersion: 2,
            id: UUID(),
            documentID: source.identity.key.documentID,
            createdAt: .now,
            label: String((title.isEmpty ? (path.last ?? source.title) : title).prefix(120)),
            scope: sceneAt == nil ? .document : .scene,
            text: text,
            contentVersion: .init(rawValue: ProjectDigest.hash(Data(text.utf8))),
            sourceRevision: DocumentOutline.stableHash(body),
            sourceStart: range.location,
            headingPath: path,
            heading: heading,
            parentIDs: parentIDs,
            branchName: resolvedBranch,
            gitCommitSHA: gitCommitSHA
        )
    }

    private struct DocumentOwnershipProbe: Decodable {
        let documentID: WritingDocumentID

        private enum CodingKeys: String, CodingKey {
            case documentID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let id = try? container.decode(WritingDocumentID.self, forKey: .documentID) {
                self.documentID = id
            } else {
                let raw = try container.decode(UUID.self, forKey: .documentID)
                self.documentID = WritingDocumentID(rawValue: raw)
            }
        }
    }

    public static func list(in data: [String: Data], documentID: WritingDocumentID) throws -> [Self] {
        let ownBranchKey = ManuscriptBranchState.userDataKey(for: documentID)
        var ownBranchVersionIDs = Set<UUID>()
        var foreignBranchVersionIDs = Set<UUID>()
        for (key, bytes) in data where key.hasPrefix("manuscript-branches-") {
            guard let state = try? JSONDecoder().decode(ManuscriptBranchState.self, from: bytes) else { continue }
            if key == ownBranchKey || state.documentID == documentID {
                ownBranchVersionIDs.formUnion(state.branches.map(\.headVersionID))
            } else {
                foreignBranchVersionIDs.formUnion(state.branches.map(\.headVersionID))
            }
        }

        var results: [Self] = []
        for (key, bytes) in data where key.hasPrefix(keyPrefix) {
            if let probe = try? JSONDecoder().decode(DocumentOwnershipProbe.self, from: bytes) {
                guard probe.documentID == documentID else { continue }
            } else {
                let suffix = String(key.dropFirst(keyPrefix.count))
                if let versionUUID = UUID(uuidString: suffix),
                   foreignBranchVersionIDs.contains(versionUUID),
                   !ownBranchVersionIDs.contains(versionUUID) {
                    continue
                }
                throw ManuscriptVersionError.invalidRecord
            }
            guard let record = try? JSONDecoder().decode(Self.self, from: bytes),
                  record.valid,
                  record.userDataKey == key,
                  record.documentID == documentID
            else {
                throw ManuscriptVersionError.invalidRecord
            }
            results.append(record)
        }
        return results.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }

    public static func lowestCommonAncestor(of lhs: UUID, and rhs: UUID, in versions: [Self]) -> Self? {
        let byID = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })
        var lhsDistances: [UUID: Int] = [:]
        var queue: [(UUID, Int)] = [(lhs, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            guard lhsDistances[current] == nil else { continue }
            lhsDistances[current] = depth
            if let node = byID[current] {
                for parent in node.parentIDs {
                    queue.append((parent, depth + 1))
                }
            }
        }
        var visited = Set<UUID>()
        var rhsQueue: [(UUID, Int)] = [(rhs, 0)]
        var bestID: UUID?
        var bestScore = Int.max
        while !rhsQueue.isEmpty {
            let (current, depth) = rhsQueue.removeFirst()
            guard visited.insert(current).inserted else { continue }
            if let lhsDepth = lhsDistances[current],
               let candidate = byID[current],
               candidate.scope == .document,
               lhsDepth + depth < bestScore {
                bestScore = lhsDepth + depth
                bestID = current
            }
            if let node = byID[current] {
                for parent in node.parentIDs {
                    rhsQueue.append((parent, depth + 1))
                }
            }
        }
        return bestID.flatMap { byID[$0] }
    }

    public func comparison(with source: ProjectDocumentSnapshot) throws -> ManuscriptComparison {
        guard valid, source.identity.key.documentID == documentID else { throw ManuscriptVersionError.staleTarget }
        let body = source.body, ns = body as NSString
        let range: NSRange
        if scope == .document { range = NSRange(location: 0, length: ns.length) }
        else {
            // Logical heading sections are not the indexer's size-dependent CDC chunks.
            // Duplicate/renamed headings refuse rather than guessing a new target.
            let sections = Self.sections(in: body)
            let matches = sections.filter { $0.path == headingPath }
            if sourceRevision == DocumentOutline.stableHash(body),
               let exact = matches.first(where: { $0.range.location == sourceStart }),
               ns.substring(with: exact.range).utf8.elementsEqual(text.utf8) { range = exact.range }
            else if let heading,
                    let anchor = SourceAnchor.uniqueOriginalRange(for: heading.quote, in: body, within: NSRange(location: 0, length: ns.length)),
                    matches.count == 1, matches[0].range.location == anchor.location { range = matches[0].range }
            else if heading == nil, headingPath.isEmpty, sections.count == 1, matches.count == 1 { range = matches[0].range }
            else { throw ManuscriptVersionError.staleTarget }
        }
        return ManuscriptComparison(version: self, source: source, range: range)
    }

    private var valid: Bool {
        (formatVersion == 1 || formatVersion == 2) && sourceStart >= 0 && sourceRevision.count == 16
            && contentVersion.rawValue == ProjectDigest.hash(Data(text.utf8))
            && !branchName.isEmpty
            && (heading == nil || (heading?.documentID == documentID && heading?.quote.isEmpty == false))
    }
    private struct Section { var range: NSRange; let path: [String] }
    private static func sections(in body: String) -> [Section] {
        var result: [Section] = []
        for scene in DocumentOutline.parse(body).scenes {
            if scene.segmentIndex > 0, let last = result.indices.last {
                result[last].range.length = scene.utf16Range.upperBound - result[last].range.location
            } else { result.append(.init(range: NSRange(location: scene.utf16Range.lowerBound, length: scene.utf16Range.count), path: scene.headingPath)) }
        }
        return result
    }
}

public struct ManuscriptBranchState: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public struct BranchHead: Codable, Equatable, Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public var headVersionID: UUID
        public var updatedAt: Date

        public init(name: String, headVersionID: UUID, updatedAt: Date = .now) {
            self.name = name
            self.headVersionID = headVersionID
            self.updatedAt = updatedAt
        }
    }

    public let formatVersion: Int
    public let documentID: WritingDocumentID
    public var activeBranch: String
    public var branches: [BranchHead]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        documentID: WritingDocumentID,
        activeBranch: String = ManuscriptVersion.defaultBranchName,
        branches: [BranchHead] = []
    ) {
        self.formatVersion = formatVersion
        self.documentID = documentID
        self.activeBranch = activeBranch
        self.branches = branches
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, documentID, activeBranch, branches
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        documentID = try container.decode(WritingDocumentID.self, forKey: .documentID)
        activeBranch = try container.decode(String.self, forKey: .activeBranch)
        branches = try container.decode([BranchHead].self, forKey: .branches)
    }

    public static func userDataKey(for documentID: WritingDocumentID) -> String {
        "manuscript-branches-" + documentID.rawValue.uuidString.lowercased()
    }

    public static func loadValid(in userData: [String: Data], documentID: WritingDocumentID) throws -> Self {
        let key = userDataKey(for: documentID)
        guard let bytes = userData[key] else {
            return Self(documentID: documentID)
        }
        guard let decoded = try? JSONDecoder().decode(Self.self, from: bytes),
              decoded.formatVersion >= 1,
              decoded.formatVersion <= Self.currentFormatVersion,
              decoded.documentID == documentID,
              !decoded.activeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(decoded.branches.map(\.name)).count == decoded.branches.count
        else {
            throw ManuscriptVersionError.invalidRecord
        }
        return decoded
    }

    public static func load(in userData: [String: Data], documentID: WritingDocumentID) -> Self {
        (try? loadValid(in: userData, documentID: documentID)) ?? Self(documentID: documentID)
    }

    public mutating func recordCommit(_ version: ManuscriptVersion) {
        activeBranch = version.branchName
        guard version.scope == .document else { return }
        if let index = branches.firstIndex(where: { $0.name == version.branchName }) {
            branches[index].headVersionID = version.id
            branches[index].updatedAt = version.createdAt
        } else {
            branches.append(.init(name: version.branchName, headVersionID: version.id, updatedAt: version.createdAt))
        }
    }

    public func headVersionID(for branch: String) -> UUID? {
        branches.first(where: { $0.name == branch })?.headVersionID
    }

    public func resolveDocumentHead(for branch: String, in versions: [ManuscriptVersion]) -> ManuscriptVersion? {
        let byID = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })
        if let headID = headVersionID(for: branch), let head = byID[headID] {
            if head.scope == .document {
                return head
            }
            var visited: Set<UUID> = [headID]
            var queue = head.parentIDs
            var candidates: [ManuscriptVersion] = []
            while !queue.isEmpty {
                let currentBatch = queue
                queue = []
                for parentID in currentBatch where visited.insert(parentID).inserted {
                    guard let parent = byID[parentID] else { continue }
                    if parent.scope == .document {
                        candidates.append(parent)
                    } else {
                        queue.append(contentsOf: parent.parentIDs)
                    }
                }
                if !candidates.isEmpty {
                    return candidates.sorted {
                        $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
                    }.first
                }
            }
        }
        return versions
            .filter { $0.branchName == branch && $0.scope == .document }
            .sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
            .first
    }
}

public enum ManuscriptVersionError: Error, LocalizedError, Equatable {
    case invalidRecord
    case staleTarget
    case unsupportedDocumentKind
    case duplicateBranchName
    case unknownBranch

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "저장된 원고 기록을 읽을 수 없습니다. 원본은 보존됩니다."
        case .staleTarget: "장면이 바뀌었거나 같은 제목이 여러 개입니다. 현재 원고에서 다시 비교해 주세요."
        case .unsupportedDocumentKind: "단순 메모와 참고자료는 버전 관리 대상이 아닙니다."
        case .duplicateBranchName: "이미 같은 이름의 갈림길이 있습니다."
        case .unknownBranch: "선택한 갈림길 기록을 찾을 수 없습니다."
        }
    }
}
