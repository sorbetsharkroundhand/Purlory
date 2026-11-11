import Foundation

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

/// Captures both sides of an explicit comparison. Applying it requires the caller's
/// current runtime and exact expected body, never a refreshed offset alone.
public struct ManuscriptComparison: Sendable {
    public struct Change: Sendable, Identifiable {
        public let id: Int
        public let saved: String
        public let current: String
        public let currentRange: NSRange
    }
    public let version: ManuscriptVersion
    public let identity: ProjectRuntimeIdentity
    public let expectedBody: String
    public let currentRange: NSRange
    public let changes: [Change]
    public var currentText: String { (expectedBody as NSString).substring(with: currentRange) }

    fileprivate init(version: ManuscriptVersion, source: ProjectDocumentSnapshot, range: NSRange) {
        self.version = version; identity = source.identity; expectedBody = source.body; currentRange = range
        changes = Self.compare(version.text, (source.body as NSString).substring(with: range), offset: range.location)
    }
    public func restoredBody(change: Int? = nil) throws -> String {
        if let change {
            guard changes.indices.contains(change) else { throw ManuscriptVersionError.staleTarget }
            return (expectedBody as NSString).replacingCharacters(in: changes[change].currentRange, with: changes[change].saved)
        }
        return (expectedBody as NSString).replacingCharacters(in: currentRange, with: version.text)
    }

    private static let paragraphSeparatorRegex = try! NSRegularExpression(pattern: "\\n[\\t ]*\\n")

    fileprivate static func paragraphs(_ text: String) -> [(text: String, start: Int)] {
        let ns = text as NSString
        var cursor = 0, result: [(String, Int)] = []
        for match in paragraphSeparatorRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.upperBound
            result.append((ns.substring(with: NSRange(location: cursor, length: end - cursor)), cursor)); cursor = end
        }
        if cursor < ns.length { result.append((ns.substring(from: cursor), cursor)) }
        return result
    }
    private static func compare(_ saved: String, _ current: String, offset: Int) -> [Change] {
        guard !saved.utf8.elementsEqual(current.utf8) else { return [] }
        let a = paragraphs(saved), b = paragraphs(current)
        // Bound worst-case edit-distance work; a whole-section comparison remains exact.
        guard a.count <= 2000, b.count <= 2000 else {
            return [.init(id: 0, saved: saved, current: current, currentRange: NSRange(location: offset, length: current.utf16.count))]
        }
        let digest: ((text: String, start: Int)) -> String = { ProjectDigest.hash(Data($0.text.utf8)) }
        let difference = b.map(digest).difference(from: a.map(digest))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var i = 0, j = 0, result: [Change] = []
        while i < a.count || j < b.count {
            let fromA = i, fromB = j
            while removed.contains(i) { i += 1 }
            while inserted.contains(j) { j += 1 }
            if i != fromA || j != fromB {
                let start = fromB < b.count ? b[fromB].start : current.utf16.count
                let end = j < b.count ? b[j].start : current.utf16.count
                result.append(.init(id: result.count, saved: a[fromA..<i].map(\.text).joined(),
                    current: b[fromB..<j].map(\.text).joined(), currentRange: NSRange(location: offset + start, length: end - start)))
            }
            if i < a.count && j < b.count { i += 1; j += 1 } else { break }
        }
        return result
    }
}

/// Deterministic paragraph-level 3-way merge without developer conflict markers.
public struct ManuscriptThreeWayMerge: Equatable, Sendable {
    public enum Resolution: String, Codable, Equatable, Sendable {
        case ours
        case theirs
        case both
    }

    public struct Conflict: Equatable, Identifiable, Sendable {
        public let id: Int
        public let base: String
        public let ours: String
        public let theirs: String
    }

    fileprivate struct BlockPiece: Equatable, Sendable {
        let content: String
        let nonFinalSeparator: String
        let finalSeparator: String
    }

    fileprivate enum Segment: Equatable, Sendable {
        case raw(String)
        case clean(BlockPiece)
        case conflict(Conflict, oursSeparator: BlockPiece, theirsSeparator: BlockPiece)
    }

    private struct ParagraphUnit: Equatable, Sendable {
        let content: String
        let trailingSeparator: String
    }

    private struct EditHunk: Equatable, Sendable {
        let baseRange: Range<Int>
        let targetRange: Range<Int>
    }

    private static let blankLineSeparatorRegex = try! NSRegularExpression(
        pattern: "\\r?\\n[\\t ]*\\r?\\n(?:[\\t ]*\\r?\\n)*"
    )

    public let conflicts: [Conflict]
    private let segments: [Segment]

    public var hasConflicts: Bool { !conflicts.isEmpty }

    public func resolvedText(using resolutions: [Int: Resolution] = [:]) -> String {
        if segments.count == 1, case .raw(let text) = segments[0] {
            return text
        }
        var pieces: [BlockPiece] = []
        for segment in segments {
            switch segment {
            case .raw(let text):
                if !text.isEmpty {
                    pieces.append(BlockPiece(content: text, nonFinalSeparator: "\n\n", finalSeparator: ""))
                }
            case .clean(let piece):
                if !piece.content.isEmpty {
                    pieces.append(piece)
                }
            case .conflict(let conflict, let oursSep, let theirsSep):
                let choice = resolutions[conflict.id] ?? .ours
                switch choice {
                case .ours:
                    if !conflict.ours.isEmpty {
                        pieces.append(BlockPiece(
                            content: conflict.ours,
                            nonFinalSeparator: oursSep.nonFinalSeparator,
                            finalSeparator: oursSep.finalSeparator
                        ))
                    }
                case .theirs:
                    if !conflict.theirs.isEmpty {
                        pieces.append(BlockPiece(
                            content: conflict.theirs,
                            nonFinalSeparator: theirsSep.nonFinalSeparator,
                            finalSeparator: theirsSep.finalSeparator
                        ))
                    }
                case .both:
                    let a = conflict.ours
                    let b = conflict.theirs
                    if !a.isEmpty && !b.isEmpty {
                        let sep = Self.isBlankLineSeparator(oursSep.nonFinalSeparator) ? oursSep.nonFinalSeparator : "\n\n"
                        pieces.append(BlockPiece(
                            content: a + sep + b,
                            nonFinalSeparator: theirsSep.nonFinalSeparator,
                            finalSeparator: theirsSep.finalSeparator
                        ))
                    } else if !a.isEmpty {
                        pieces.append(BlockPiece(
                            content: a,
                            nonFinalSeparator: oursSep.nonFinalSeparator,
                            finalSeparator: oursSep.finalSeparator
                        ))
                    } else if !b.isEmpty {
                        pieces.append(BlockPiece(
                            content: b,
                            nonFinalSeparator: theirsSep.nonFinalSeparator,
                            finalSeparator: theirsSep.finalSeparator
                        ))
                    }
                }
            }
        }
        guard !pieces.isEmpty else { return "" }
        var output = ""
        for (index, piece) in pieces.enumerated() {
            output += piece.content
            if index < pieces.count - 1 {
                output += piece.nonFinalSeparator
            } else {
                output += piece.finalSeparator
            }
        }
        return output
    }

    public static func merge(base: String?, ours: String, theirs: String) -> Self {
        if ours.utf8.elementsEqual(theirs.utf8) {
            return Self(conflicts: [], segments: ours.isEmpty ? [] : [.raw(ours)])
        }
        if let base {
            if ours.utf8.elementsEqual(base.utf8) {
                return Self(conflicts: [], segments: theirs.isEmpty ? [] : [.raw(theirs)])
            }
            if theirs.utf8.elementsEqual(base.utf8) {
                return Self(conflicts: [], segments: ours.isEmpty ? [] : [.raw(ours)])
            }
        }

        let oursUnits = splitUnits(ours)
        let theirsUnits = splitUnits(theirs)
        let defaultEOF = resolveEOF(base: base.map(splitUnits), ours: oursUnits, theirs: theirsUnits)

        guard let base else {
            return mergeTwoWay(oursUnits: oursUnits, theirsUnits: theirsUnits, defaultEOF: defaultEOF)
        }

        let baseUnits = splitUnits(base)
        let oursHunks = computeEditHunks(base: baseUnits, target: oursUnits)
        let theirsHunks = computeEditHunks(base: baseUnits, target: theirsUnits)

        var segments: [Segment] = []
        var conflicts: [Conflict] = []
        var bCursor = 0
        var oCursor = 0
        var tCursor = 0
        var i = 0
        var j = 0

        func emitUnchangedAnchor(baseIndex: Int, oursIndex: Int, theirsIndex: Int) {
            let bUnit = baseUnits[baseIndex]
            let oUnit = oursUnits[oursIndex]
            let tUnit = theirsUnits[theirsIndex]
            let nonFinal = resolveNonFinalSeparator(base: bUnit, ours: oUnit, theirs: tUnit)
            let finalSep = resolveAnchorFinalSeparator(base: bUnit, ours: oUnit, theirs: tUnit, defaultEOF: defaultEOF)
            segments.append(.clean(BlockPiece(
                content: oUnit.content,
                nonFinalSeparator: nonFinal,
                finalSeparator: finalSep
            )))
        }

        func emitCleanSlice(_ slice: ArraySlice<ParagraphUnit>) {
            for unit in slice where !unit.content.isEmpty {
                let nonFinal = isBlankLineSeparator(unit.trailingSeparator) ? unit.trailingSeparator : "\n\n"
                let finalSep = isBlankLineSeparator(unit.trailingSeparator) ? defaultEOF : unit.trailingSeparator
                segments.append(.clean(BlockPiece(
                    content: unit.content,
                    nonFinalSeparator: nonFinal,
                    finalSeparator: finalSep
                )))
            }
        }

        while i < oursHunks.count || j < theirsHunks.count {
            let nextO = i < oursHunks.count ? oursHunks[i] : nil
            let nextT = j < theirsHunks.count ? theirsHunks[j] : nil

            let hunkBaseStart: Int
            if let nextO, let nextT {
                hunkBaseStart = min(nextO.baseRange.lowerBound, nextT.baseRange.lowerBound)
            } else if let nextO {
                hunkBaseStart = nextO.baseRange.lowerBound
            } else {
                hunkBaseStart = nextT!.baseRange.lowerBound
            }

            while bCursor < hunkBaseStart {
                emitUnchangedAnchor(baseIndex: bCursor, oursIndex: oCursor, theirsIndex: tCursor)
                bCursor += 1
                oCursor += 1
                tCursor += 1
            }

            if let nextO, let nextT, hunksConflict(nextO, nextT) {
                var groupO = [nextO]
                var groupT = [nextT]
                i += 1
                j += 1
                var bEnd = max(nextO.baseRange.upperBound, nextT.baseRange.upperBound)

                while true {
                    if i < oursHunks.count,
                       oursHunks[i].baseRange.lowerBound < bEnd
                        || groupT.contains(where: { hunksConflict(oursHunks[i], $0) }) {
                        bEnd = max(bEnd, oursHunks[i].baseRange.upperBound)
                        groupO.append(oursHunks[i])
                        i += 1
                        continue
                    }
                    if j < theirsHunks.count,
                       theirsHunks[j].baseRange.lowerBound < bEnd
                        || groupO.contains(where: { hunksConflict($0, theirsHunks[j]) }) {
                        bEnd = max(bEnd, theirsHunks[j].baseRange.upperBound)
                        groupT.append(theirsHunks[j])
                        j += 1
                        continue
                    }
                    break
                }

                let bStart = bCursor
                let oStart = oCursor
                let lastO = groupO.last!
                let oEnd = lastO.targetRange.upperBound + (bEnd - lastO.baseRange.upperBound)
                let tStart = tCursor
                let lastT = groupT.last!
                let tEnd = lastT.targetRange.upperBound + (bEnd - lastT.baseRange.upperBound)

                let baseSlice = baseUnits[bStart..<bEnd]
                let oursSlice = oursUnits[oStart..<oEnd]
                let theirsSlice = theirsUnits[tStart..<tEnd]

                bCursor = bEnd
                oCursor = oEnd
                tCursor = tEnd

                if oursSlice.map(\.content) == theirsSlice.map(\.content) {
                    emitCleanSlice(oursSlice)
                } else {
                    let conflict = Conflict(
                        id: conflicts.count,
                        base: joinUnitContents(baseSlice),
                        ours: joinUnitContents(oursSlice),
                        theirs: joinUnitContents(theirsSlice)
                    )
                    conflicts.append(conflict)
                    segments.append(.conflict(
                        conflict,
                        oursSeparator: sliceSeparatorPiece(oursSlice, defaultEOF: defaultEOF),
                        theirsSeparator: sliceSeparatorPiece(theirsSlice, defaultEOF: defaultEOF)
                    ))
                }
            } else {
                let takeOurs: Bool
                if let nextO, let nextT {
                    if nextO.baseRange.lowerBound != nextT.baseRange.lowerBound {
                        takeOurs = nextO.baseRange.lowerBound < nextT.baseRange.lowerBound
                    } else {
                        takeOurs = nextO.baseRange.isEmpty
                    }
                } else {
                    takeOurs = nextO != nil
                }

                if takeOurs, let hunk = nextO {
                    emitCleanSlice(oursUnits[hunk.targetRange])
                    let count = hunk.baseRange.count
                    bCursor = hunk.baseRange.upperBound
                    oCursor = hunk.targetRange.upperBound
                    tCursor += count
                    i += 1
                } else if let hunk = nextT {
                    emitCleanSlice(theirsUnits[hunk.targetRange])
                    let count = hunk.baseRange.count
                    bCursor = hunk.baseRange.upperBound
                    oCursor += count
                    tCursor = hunk.targetRange.upperBound
                    j += 1
                }
            }
        }

        while bCursor < baseUnits.count {
            emitUnchangedAnchor(baseIndex: bCursor, oursIndex: oCursor, theirsIndex: tCursor)
            bCursor += 1
            oCursor += 1
            tCursor += 1
        }

        return Self(conflicts: conflicts, segments: segments)
    }

    private static func mergeTwoWay(
        oursUnits: [ParagraphUnit],
        theirsUnits: [ParagraphUnit],
        defaultEOF: String
    ) -> Self {
        let diff = theirsUnits.map(\.content).difference(from: oursUnits.map(\.content))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let idx, _, _): removed.insert(idx)
            case .insert(let idx, _, _): inserted.insert(idx)
            }
        }
        let unremovedO = (0..<oursUnits.count).filter { !removed.contains($0) }
        let uninsertedT = (0..<theirsUnits.count).filter { !inserted.contains($0) }
        guard !unremovedO.isEmpty else {
            let conflict = Conflict(
                id: 0,
                base: "",
                ours: joinUnitContents(oursUnits[...]),
                theirs: joinUnitContents(theirsUnits[...])
            )
            return Self(
                conflicts: [conflict],
                segments: [.conflict(
                    conflict,
                    oursSeparator: sliceSeparatorPiece(oursUnits[...], defaultEOF: defaultEOF),
                    theirsSeparator: sliceSeparatorPiece(theirsUnits[...], defaultEOF: defaultEOF)
                )]
            )
        }

        var segments: [Segment] = []
        var conflicts: [Conflict] = []
        var oCursor = 0
        var tCursor = 0

        for (oAnchor, tAnchor) in zip(unremovedO, uninsertedT) {
            if oCursor < oAnchor || tCursor < tAnchor {
                let oSlice = oursUnits[oCursor..<oAnchor]
                let tSlice = theirsUnits[tCursor..<tAnchor]
                let conflict = Conflict(
                    id: conflicts.count,
                    base: "",
                    ours: joinUnitContents(oSlice),
                    theirs: joinUnitContents(tSlice)
                )
                conflicts.append(conflict)
                segments.append(.conflict(
                    conflict,
                    oursSeparator: sliceSeparatorPiece(oSlice, defaultEOF: defaultEOF),
                    theirsSeparator: sliceSeparatorPiece(tSlice, defaultEOF: defaultEOF)
                ))
            }
            let oUnit = oursUnits[oAnchor]
            let nonFinal = isBlankLineSeparator(oUnit.trailingSeparator) ? oUnit.trailingSeparator : "\n\n"
            let finalSep = isBlankLineSeparator(oUnit.trailingSeparator) ? defaultEOF : oUnit.trailingSeparator
            segments.append(.clean(BlockPiece(
                content: oUnit.content,
                nonFinalSeparator: nonFinal,
                finalSeparator: finalSep
            )))
            oCursor = oAnchor + 1
            tCursor = tAnchor + 1
        }

        if oCursor < oursUnits.count || tCursor < theirsUnits.count {
            let oSlice = oursUnits[oCursor..<oursUnits.count]
            let tSlice = theirsUnits[tCursor..<theirsUnits.count]
            let conflict = Conflict(
                id: conflicts.count,
                base: "",
                ours: joinUnitContents(oSlice),
                theirs: joinUnitContents(tSlice)
            )
            conflicts.append(conflict)
            segments.append(.conflict(
                conflict,
                oursSeparator: sliceSeparatorPiece(oSlice, defaultEOF: defaultEOF),
                theirsSeparator: sliceSeparatorPiece(tSlice, defaultEOF: defaultEOF)
            ))
        }

        return Self(conflicts: conflicts, segments: segments)
    }

    private static func splitUnits(_ text: String) -> [ParagraphUnit] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let matches = blankLineSeparatorRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        var units: [ParagraphUnit] = []

        for match in matches {
            if match.range.location == 0 {
                if match.range.upperBound == ns.length {
                    return [ParagraphUnit(content: "", trailingSeparator: text)]
                }
                continue
            }
            guard match.range.location > cursor else { continue }
            let content = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let sep = ns.substring(with: match.range)
            units.append(ParagraphUnit(content: content, trailingSeparator: sep))
            cursor = match.range.upperBound
        }

        if cursor < ns.length {
            let remainder = ns.substring(from: cursor)
            if remainder.hasSuffix("\r\n") {
                units.append(ParagraphUnit(content: String(remainder.dropLast(2)), trailingSeparator: "\r\n"))
            } else if remainder.hasSuffix("\n") {
                units.append(ParagraphUnit(content: String(remainder.dropLast(1)), trailingSeparator: "\n"))
            } else {
                units.append(ParagraphUnit(content: remainder, trailingSeparator: ""))
            }
        }
        return units
    }

    private static func computeEditHunks(
        base: [ParagraphUnit],
        target: [ParagraphUnit]
    ) -> [EditHunk] {
        let diff = target.map(\.content).difference(from: base.map(\.content))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let idx, _, _): removed.insert(idx)
            case .insert(let idx, _, _): inserted.insert(idx)
            }
        }
        let unremovedBase = (0..<base.count).filter { !removed.contains($0) }
        let uninsertedTarget = (0..<target.count).filter { !inserted.contains($0) }
        let baseToTarget = Dictionary(uniqueKeysWithValues: zip(unremovedBase, uninsertedTarget))

        var hunks: [EditHunk] = []
        var b = 0
        var t = 0
        while b < base.count || t < target.count {
            if b < base.count, let matchedT = baseToTarget[b] {
                if matchedT == t {
                    b += 1
                    t += 1
                } else {
                    hunks.append(EditHunk(baseRange: b..<b, targetRange: t..<matchedT))
                    t = matchedT
                }
            } else if b < base.count {
                var bNext = b + 1
                while bNext < base.count && baseToTarget[bNext] == nil {
                    bNext += 1
                }
                let tNext = bNext < base.count ? baseToTarget[bNext]! : target.count
                hunks.append(EditHunk(baseRange: b..<bNext, targetRange: t..<tNext))
                b = bNext
                t = tNext
            } else {
                hunks.append(EditHunk(baseRange: base.count..<base.count, targetRange: t..<target.count))
                t = target.count
            }
        }
        return hunks
    }

    private static func hunksConflict(_ hO: EditHunk, _ hT: EditHunk) -> Bool {
        if max(hO.baseRange.lowerBound, hT.baseRange.lowerBound) < min(hO.baseRange.upperBound, hT.baseRange.upperBound) {
            return true
        }
        if hO.baseRange.isEmpty && hT.baseRange.isEmpty && hO.baseRange.lowerBound == hT.baseRange.lowerBound {
            return true
        }
        if hO.targetRange.isEmpty && hT.targetRange.isEmpty
            && (hO.baseRange.upperBound == hT.baseRange.lowerBound || hT.baseRange.upperBound == hO.baseRange.lowerBound) {
            return true
        }
        return false
    }

    private static func isBlankLineSeparator(_ separator: String) -> Bool {
        var newlineCount = 0
        for scalar in separator.unicodeScalars where scalar == "\n" {
            newlineCount += 1
            if newlineCount >= 2 { return true }
        }
        return false
    }

    private static func resolveEOF(
        base: [ParagraphUnit]?,
        ours: [ParagraphUnit],
        theirs: [ParagraphUnit]
    ) -> String {
        let oEOF = ours.last?.trailingSeparator ?? ""
        let tEOF = theirs.last?.trailingSeparator ?? ""
        if oEOF == tEOF { return oEOF }
        if let bEOF = base?.last?.trailingSeparator {
            if oEOF == bEOF { return tEOF }
            if tEOF == bEOF { return oEOF }
        }
        return oEOF
    }

    private static func resolveNonFinalSeparator(
        base: ParagraphUnit,
        ours: ParagraphUnit,
        theirs: ParagraphUnit
    ) -> String {
        let bSep = isBlankLineSeparator(base.trailingSeparator) ? base.trailingSeparator : "\n\n"
        let oSep = isBlankLineSeparator(ours.trailingSeparator) ? ours.trailingSeparator : nil
        let tSep = isBlankLineSeparator(theirs.trailingSeparator) ? theirs.trailingSeparator : nil
        if let oSep, let tSep {
            if oSep == tSep { return oSep }
            if oSep == bSep { return tSep }
            return oSep
        }
        return oSep ?? tSep ?? bSep
    }

    private static func resolveAnchorFinalSeparator(
        base: ParagraphUnit,
        ours: ParagraphUnit,
        theirs: ParagraphUnit,
        defaultEOF: String
    ) -> String {
        let oFinal = isBlankLineSeparator(ours.trailingSeparator) ? nil : ours.trailingSeparator
        let tFinal = isBlankLineSeparator(theirs.trailingSeparator) ? nil : theirs.trailingSeparator
        let bFinal = isBlankLineSeparator(base.trailingSeparator) ? nil : base.trailingSeparator
        if let oFinal, let tFinal {
            if oFinal == tFinal { return oFinal }
            if let bFinal, oFinal == bFinal { return tFinal }
            return oFinal
        }
        return oFinal ?? tFinal ?? defaultEOF
    }

    private static func joinUnitContents(_ slice: ArraySlice<ParagraphUnit>) -> String {
        guard !slice.isEmpty else { return "" }
        var output = ""
        for (offset, unit) in slice.enumerated() {
            output += unit.content
            if offset < slice.count - 1 {
                output += isBlankLineSeparator(unit.trailingSeparator) ? unit.trailingSeparator : "\n\n"
            }
        }
        return output
    }

    private static func sliceSeparatorPiece(
        _ slice: ArraySlice<ParagraphUnit>,
        defaultEOF: String
    ) -> BlockPiece {
        guard let last = slice.last else {
            return BlockPiece(content: "", nonFinalSeparator: "\n\n", finalSeparator: defaultEOF)
        }
        let nonFinal = isBlankLineSeparator(last.trailingSeparator) ? last.trailingSeparator : "\n\n"
        let finalSep = isBlankLineSeparator(last.trailingSeparator) ? defaultEOF : last.trailingSeparator
        return BlockPiece(content: "", nonFinalSeparator: nonFinal, finalSeparator: finalSep)
    }
}

/// Summarizes where the writer left off in a manuscript and surfaces quick notes linked to it.
public struct ManuscriptResumeBrief: Equatable, Sendable {
    public let documentID: WritingDocumentID
    public let documentTitle: String
    public let activeBranch: String
    public let hasMultipleBranches: Bool
    public let currentSceneHeading: String?
    public let trailingExcerpt: String
    public let linkedNotes: [String]
    public let latestVersionLabel: String?
    public let hasUnsavedVersionChanges: Bool

    public init(
        documentID: WritingDocumentID,
        documentTitle: String,
        activeBranch: String,
        hasMultipleBranches: Bool,
        currentSceneHeading: String?,
        trailingExcerpt: String,
        linkedNotes: [String],
        latestVersionLabel: String?,
        hasUnsavedVersionChanges: Bool
    ) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.activeBranch = activeBranch
        self.hasMultipleBranches = hasMultipleBranches
        self.currentSceneHeading = currentSceneHeading
        self.trailingExcerpt = trailingExcerpt
        self.linkedNotes = linkedNotes
        self.latestVersionLabel = latestVersionLabel
        self.hasUnsavedVersionChanges = hasUnsavedVersionChanges
    }

    public static func build(
        for documentID: WritingDocumentID,
        in project: WritingProject,
        cursorOffset: Int? = nil
    ) -> Self? {
        guard !project.trashedDocumentIDs.contains(documentID),
              let document = project.documents.first(where: { $0.id == documentID }),
              document.kind == .manuscript else { return nil }

        let branchState = ManuscriptBranchState.load(in: project.userData, documentID: documentID)
        let versions = (try? ManuscriptVersion.list(in: project.userData, documentID: documentID)) ?? []
        var branchNames = branchState.branches.map(\.name)
        for v in versions where !branchNames.contains(v.branchName) { branchNames.append(v.branchName) }
        if branchNames.isEmpty { branchNames.append(ManuscriptVersion.defaultBranchName) }

        let source = document.source
        let activeHead = branchState.resolveDocumentHead(for: branchState.activeBranch, in: versions)
        let hasUnsaved: Bool
        if let activeHead {
            if (activeHead.text as NSString).length != source.utf16Length {
                hasUnsaved = true
            } else {
                hasUnsaved = !activeHead.text.utf8.elementsEqual(document.body.utf8)
            }
        } else {
            hasUnsaved = Self.containsNonWhitespace(in: source)
        }

        let clampedOffset = cursorOffset.map { max(0, min($0, source.utf16Length)) }
        let currentHeading = Self.resolveCurrentHeading(in: source, clampedOffset: clampedOffset)
        let relevantParagraph = clampedOffset.flatMap {
            Self.lastRelevantParagraph(in: source, maxStartOffset: $0)
        } ?? Self.lastRelevantParagraph(in: source, maxStartOffset: nil) ?? ""
        let singleLine = relevantParagraph
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = singleLine.count > 90 ? String(singleLine.prefix(90)) + "…" : singleLine

        let tagPrefix = "[\(document.title)]"
        var extractedNotes: [String] = []
        for noteDoc in project.documents where noteDoc.kind == .note && !project.trashedDocumentIDs.contains(noteDoc.id) {
            for rawLine in noteDoc.body.components(separatedBy: .newlines) {
                var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if line.hasPrefix(tagPrefix) {
                    let content = String(line.dropFirst(tagPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        extractedNotes.append(content)
                    }
                }
            }
        }

        return Self(
            documentID: documentID,
            documentTitle: document.title,
            activeBranch: branchState.activeBranch,
            hasMultipleBranches: branchNames.count > 1,
            currentSceneHeading: currentHeading,
            trailingExcerpt: excerpt,
            linkedNotes: Array(extractedNotes.reversed()),
            latestVersionLabel: activeHead?.label,
            hasUnsavedVersionChanges: hasUnsaved
        )
    }

    private static func containsNonWhitespace(in source: DocumentSource) -> Bool {
        source.containsNonWhitespace()
    }

    private static func resolveCurrentHeading(in source: DocumentSource, clampedOffset: Int?) -> String? {
        guard source.utf16Length > 0 else { return nil }
        if let clampedOffset {
            if let before = scanHeadingBackward(in: source, maxStartOffset: clampedOffset) {
                return before
            }
            let prefix = source.clampedSlice(in: NSRange(location: 0, length: min(source.utf16Length, 8_192)))
            var lineStart = prefix.startIndex
            var hasNonWhitespaceBeforeFirstHeading = false
            while lineStart < prefix.endIndex {
                let lineEnd = prefix[lineStart...].firstIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.endIndex
                let line = prefix[lineStart..<lineEnd]
                if DocumentOutline.headingLine(line) != nil { break }
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasNonWhitespaceBeforeFirstHeading = true
                    break
                }
                lineStart = lineEnd
            }
            if hasNonWhitespaceBeforeFirstHeading {
                return nil
            }
        }
        return scanHeadingBackward(in: source, maxStartOffset: nil)
    }

    private static func scanHeadingBackward(in source: DocumentSource, maxStartOffset: Int?) -> String? {
        let total = source.utf16Length
        guard total > 0 else { return nil }
        let step = 16_384
        let overlap = 512
        var windowEnd = min(total, (maxStartOffset ?? total) + overlap)
        while windowEnd > 0 {
            let rawStart = max(0, windowEnd - step)
            let slice = source.clampedSlice(in: NSRange(location: rawStart, length: windowEnd - rawStart))
            var lineStart = slice.startIndex
            var utf16Pos = rawStart
            if rawStart > 0, let firstNewline = slice.firstIndex(of: "\n") {
                let nextStart = slice.index(after: firstNewline)
                utf16Pos += slice[..<nextStart].utf16.count
                lineStart = nextStart
            }
            var found: String?
            while lineStart < slice.endIndex {
                let lineEnd = slice[lineStart...].firstIndex(of: "\n").map { slice.index(after: $0) } ?? slice.endIndex
                if let maxStartOffset, utf16Pos > maxStartOffset { break }
                let line = slice[lineStart..<lineEnd]
                if let (_, title) = DocumentOutline.headingLine(line) {
                    found = title
                }
                utf16Pos += line.utf16.count
                lineStart = lineEnd
            }
            if let found { return found }
            if rawStart == 0 { break }
            windowEnd = min(windowEnd - 1, rawStart + overlap)
        }
        return nil
    }

    private static func lastRelevantParagraph(in source: DocumentSource, maxStartOffset: Int?) -> String? {
        let total = source.utf16Length
        guard total > 0 else { return nil }
        let step = 16_384
        let overlap = 2_048
        var windowEnd = min(total, (maxStartOffset ?? total) + overlap)
        while windowEnd > 0 {
            let rawStart = max(0, windowEnd - step)
            let slice = source.clampedSlice(in: NSRange(location: rawStart, length: windowEnd - rawStart))
            let paragraphs = ManuscriptComparison.paragraphs(slice)
            let usable = rawStart > 0 && paragraphs.count > 1 ? Array(paragraphs.dropFirst()) : paragraphs
            let candidates = usable.compactMap { item -> (text: String, start: Int)? in
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return (text: trimmed, start: rawStart + item.start)
            }
            if let maxStartOffset {
                if let match = candidates.last(where: { $0.start <= maxStartOffset }) {
                    return match.text
                }
            } else if let match = candidates.last {
                return match.text
            }
            if rawStart == 0 { break }
            windowEnd = min(windowEnd - 1, rawStart + overlap)
        }
        return nil
    }
}
