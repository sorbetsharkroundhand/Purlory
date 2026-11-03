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

    public static func list(in data: [String: Data], documentID: WritingDocumentID) throws -> [Self] {
        try data.filter { $0.key.hasPrefix(keyPrefix) }.map { key, bytes in
            let record = try JSONDecoder().decode(Self.self, from: bytes)
            guard record.valid, record.userDataKey == key else { throw ManuscriptVersionError.invalidRecord }
            return record
        }.filter { $0.documentID == documentID }.sorted {
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
            if let lhsDepth = lhsDistances[current], lhsDepth + depth < bestScore {
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

    public let documentID: WritingDocumentID
    public var activeBranch: String
    public var branches: [BranchHead]

    public init(
        documentID: WritingDocumentID,
        activeBranch: String = ManuscriptVersion.defaultBranchName,
        branches: [BranchHead] = []
    ) {
        self.documentID = documentID
        self.activeBranch = activeBranch
        self.branches = branches
    }

    public static func userDataKey(for documentID: WritingDocumentID) -> String {
        "manuscript-branches-" + documentID.rawValue.uuidString.lowercased()
    }

    public static func load(in userData: [String: Data], documentID: WritingDocumentID) -> Self {
        let key = userDataKey(for: documentID)
        if let bytes = userData[key],
           let decoded = try? JSONDecoder().decode(Self.self, from: bytes),
           decoded.documentID == documentID {
            return decoded
        }
        return Self(documentID: documentID)
    }

    public mutating func recordCommit(_ version: ManuscriptVersion) {
        activeBranch = version.branchName
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

    fileprivate static func paragraphs(_ text: String) -> [(text: String, start: Int)] {
        let ns = text as NSString
        let separators = try! NSRegularExpression(pattern: "\\n[\\t ]*\\n")
        var cursor = 0, result: [(String, Int)] = []
        for match in separators.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
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

    fileprivate enum Segment: Equatable, Sendable {
        case clean(String)
        case conflict(Conflict)
    }

    public let conflicts: [Conflict]
    private let segments: [Segment]

    public var hasConflicts: Bool { !conflicts.isEmpty }

    public func resolvedText(using resolutions: [Int: Resolution] = [:]) -> String {
        var blocks: [String] = []
        for segment in segments {
            switch segment {
            case .clean(let text):
                if !text.isEmpty { blocks.append(text) }
            case .conflict(let conflict):
                let choice = resolutions[conflict.id] ?? .ours
                switch choice {
                case .ours:
                    if !conflict.ours.isEmpty { blocks.append(conflict.ours) }
                case .theirs:
                    if !conflict.theirs.isEmpty { blocks.append(conflict.theirs) }
                case .both:
                    let a = conflict.ours.trimmingCharacters(in: .whitespacesAndNewlines)
                    let b = conflict.theirs.trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined = [a, b].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    if !combined.isEmpty { blocks.append(combined) }
                }
            }
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    public static func merge(base: String?, ours: String, theirs: String) -> Self {
        let splitBlocks: (String) -> [String] = { text in
            ManuscriptComparison.paragraphs(text)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let oursBlocks = splitBlocks(ours)
        let theirsBlocks = splitBlocks(theirs)
        guard let base else {
            if oursBlocks == theirsBlocks {
                return Self(conflicts: [], segments: oursBlocks.map(Segment.clean))
            }
            let conflict = Conflict(id: 0, base: "", ours: oursBlocks.joined(separator: "\n\n"), theirs: theirsBlocks.joined(separator: "\n\n"))
            return Self(conflicts: [conflict], segments: [.conflict(conflict)])
        }
        let baseBlocks = splitBlocks(base)
        let maxCount = max(baseBlocks.count, max(oursBlocks.count, theirsBlocks.count))
        var segments: [Segment] = []
        var conflicts: [Conflict] = []

        for index in 0..<maxCount {
            let b = index < baseBlocks.count ? baseBlocks[index] : nil
            let o = index < oursBlocks.count ? oursBlocks[index] : nil
            let t = index < theirsBlocks.count ? theirsBlocks[index] : nil

            if o == t {
                if let o { segments.append(.clean(o)) }
            } else if o == b {
                if let t { segments.append(.clean(t)) }
            } else if t == b {
                if let o { segments.append(.clean(o)) }
            } else {
                let conflict = Conflict(
                    id: conflicts.count,
                    base: b ?? "",
                    ours: o ?? "",
                    theirs: t ?? ""
                )
                conflicts.append(conflict)
                segments.append(.conflict(conflict))
            }
        }
        return Self(conflicts: conflicts, segments: segments)
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

        let activeHead = versions.first(where: { $0.id == branchState.headVersionID(for: branchState.activeBranch) })
            ?? versions.first(where: { $0.branchName == branchState.activeBranch })
        let hasUnsaved = activeHead.map { !$0.text.utf8.elementsEqual(document.body.utf8) }
            ?? !document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let outline = DocumentOutline.parse(document.body)
        let nsBody = document.body as NSString
        let clampedOffset = cursorOffset.map { max(0, min($0, nsBody.length)) }
        let targetScene = clampedOffset.flatMap { offset in
            outline.scenes.last(where: { $0.utf16Range.lowerBound <= offset })
        } ?? outline.scenes.last(where: { !$0.headingPath.isEmpty }) ?? outline.scenes.last
        let currentHeading = targetScene?.headingPath.last

        let paragraphs = ManuscriptComparison.paragraphs(document.body)
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: $0.start) }
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("#") }
        let relevantParagraph: String
        if let clampedOffset,
           let beforeCursor = paragraphs.last(where: { $0.start <= clampedOffset }) {
            relevantParagraph = beforeCursor.text
        } else {
            relevantParagraph = paragraphs.last?.text ?? ""
        }
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
}
