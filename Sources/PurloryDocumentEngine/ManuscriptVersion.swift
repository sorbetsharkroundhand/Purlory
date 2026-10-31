import Foundation

/// Explicit, writer-owned original text. A version UUID identifies a saved decision;
/// a document ID identifies its manuscript; content digests identify only revisions.
public struct ManuscriptVersion: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable { case document, scene }
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
    public var userDataKey: String { Self.keyPrefix + id.uuidString.lowercased() }
    private static let keyPrefix = "manuscript-version-"

    public static func capture(_ source: ProjectDocumentSnapshot, sceneAt: Int? = nil, label: String = "") throws -> Self {
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
        return Self(formatVersion: 1, id: UUID(), documentID: source.identity.key.documentID, createdAt: .now,
            label: String((title.isEmpty ? (path.last ?? source.title) : title).prefix(120)), scope: sceneAt == nil ? .document : .scene,
            text: text, contentVersion: .init(rawValue: ProjectDigest.hash(Data(text.utf8))),
            sourceRevision: DocumentOutline.stableHash(body), sourceStart: range.location, headingPath: path, heading: heading)
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
        formatVersion == 1 && sourceStart >= 0 && sourceRevision.count == 16
            && contentVersion.rawValue == ProjectDigest.hash(Data(text.utf8))
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

public enum ManuscriptVersionError: Error, LocalizedError {
    case invalidRecord, staleTarget
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "저장된 원고 기록을 읽을 수 없습니다. 원본은 보존됩니다."
        case .staleTarget: "장면이 바뀌었거나 같은 제목이 여러 개입니다. 현재 원고에서 다시 비교해 주세요."
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

    private static func paragraphs(_ text: String) -> [(text: String, start: Int)] {
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
