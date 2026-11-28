import Foundation
import PurloryFoundation

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

    init(version: ManuscriptVersion, source: ProjectDocumentSnapshot, range: NSRange) {
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

    static func paragraphs(_ text: String) -> [(text: String, start: Int)] {
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
