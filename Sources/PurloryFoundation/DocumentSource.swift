import Foundation

/// An immutable, exact manuscript version. Reading a range or editing a piece never
/// joins the document. Persistence and explicit consumers share one cached string.
public struct DocumentSource: Sendable, Equatable {
    public enum EditError: Error { case outOfBounds, invalidUTF16Boundary }

    private final class Node: DocumentRopeNode, Sendable {
        let text: String
        let textLength: Int
        let priority: UInt64
        let left: Node?, right: Node?
        let count: Int, length: Int
        init(_ text: String, priority: UInt64, left: Node? = nil, right: Node? = nil) {
            self.text = text; textLength = text.utf16.count; self.priority = priority
            self.left = left; self.right = right
            count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
            length = textLength + (left?.length ?? 0) + (right?.length ?? 0)
        }
        private init(copying node: Node, left: Node?, right: Node?) {
            text = node.text; textLength = node.textLength; priority = node.priority
            self.left = left; self.right = right
            count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
            length = textLength + (left?.length ?? 0) + (right?.length ?? 0)
        }
        func copy(left: Node?, right: Node?) -> Node { Node(copying: self, left: left, right: right) }
    }
    private typealias Tree = DocumentRopeIndex<Node>

    /// The only mutable state is the synchronized cache, never the manuscript tree.
    private final class Storage: @unchecked Sendable {
        let root: Node?
        let random: UInt64
        private let lock = NSLock()
        private var cached: String?
        private var builds = 0
        init(root: Node?, random: UInt64, cached: String? = nil) {
            self.root = root; self.random = random; self.cached = cached
        }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            if let cached { return cached }
            var pieces: [String] = [], stack: [Node] = [], next = root
            pieces.reserveCapacity(root?.count ?? 0)
            while next != nil || !stack.isEmpty {
                while let node = next { stack.append(node); next = node.left }
                let node = stack.removeLast(); pieces.append(node.text); next = node.right
            }
            let result = pieces.joined()
            cached = result; builds += 1
            return result
        }
        var materializationCount: Int {
            lock.lock(); defer { lock.unlock() }; return builds
        }
    }
    private let storage: Storage
    package let lastMutationVisits: Int
    public var utf16Length: Int { storage.root?.length ?? 0 }
    public var isEmpty: Bool { utf16Length == 0 }
    public var string: String { storage.string }
    package var materializationCount: Int { storage.materializationCount }
    package var chunkCount: Int { storage.root?.count ?? 0 }

    public init(_ text: String) {
        var random: UInt64 = 0x7075726c6f727973, visits = 0
        let root = Self.tree(Self.chunks(text), random: &random, visits: &visits)
        storage = Storage(root: root, random: random, cached: text); lastMutationVisits = 0
    }
    package init(chunks: [String]) {
        var random: UInt64 = 0x7075726c6f727973, visits = 0
        let root = Self.tree(chunks, random: &random, visits: &visits)
        storage = Storage(root: root, random: random); lastMutationVisits = 0
    }
    private init(root: Node?, random: UInt64, visits: Int) {
        storage = Storage(root: root, random: random); lastMutationVisits = visits
    }
    public func isSameVersion(as other: DocumentSource) -> Bool { storage === other.storage }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isSameVersion(as: rhs) || (lhs.utf16Length == rhs.utf16Length && lhs.string.utf16.elementsEqual(rhs.string.utf16))
    }

    public func substring(in range: NSRange) throws -> String {
        try validate(range)
        var result: [String] = []
        func collect(_ node: Node?, base: Int) {
            guard let node, base < range.upperBound, base + node.length > range.location else { return }
            let start = base + (node.left?.length ?? 0)
            collect(node.left, base: base)
            let clipped = NSIntersectionRange(range, NSRange(location: start, length: node.textLength))
            if clipped.length > 0 {
                result.append((node.text as NSString).substring(with: NSRange(location: clipped.location - start, length: clipped.length)))
            }
            collect(node.right, base: start + node.textLength)
        }
        collect(storage.root, base: 0)
        return result.joined()
    }

    public func replacing(_ range: NSRange, with text: String) throws -> DocumentSource {
        try validate(range)
        if range.length == 0, text.isEmpty { return self }
        var random = storage.random, visits = 0
        let (before, rest) = Self.split(storage.root, at: range.location, random: &random, visits: &visits)
        let (_, after) = Self.split(rest, at: range.length, random: &random, visits: &visits)
        let replacement = Self.tree(Self.chunks(text), random: &random, visits: &visits)
        let root = Tree.merge(Tree.merge(before, replacement, visits: &visits), after, visits: &visits)
        return DocumentSource(root: root, random: random, visits: visits)
    }

    /// Codec rows retain stable ranks even when a row contributes no source characters.
    package func replacingChunk(at rank: Int, with text: String) throws -> DocumentSource {
        guard rank >= 0, rank < chunkCount else { throw EditError.outOfBounds }
        var current = storage.root, remaining = rank
        while let node = current {
            let left = node.left?.count ?? 0
            if remaining < left { current = node.left }
            else if remaining > left { remaining -= left + 1; current = node.right }
            else {
                if node.text.utf16.elementsEqual(text.utf16) { return self }
                break
            }
        }
        var visits = 0, random = storage.random
        let (before, rest) = Tree.split(storage.root, count: rank, visits: &visits)
        let (_, after) = Tree.split(rest, count: 1, visits: &visits)
        let replacement = Node(text, priority: Tree.nextPriority(&random))
        let root = Tree.merge(Tree.merge(before, replacement, visits: &visits), after, visits: &visits)
        return DocumentSource(root: root, random: random, visits: visits)
    }

    package func replacingChunks(in range: Range<Int>, with texts: [String]) throws -> DocumentSource {
        guard range.lowerBound >= 0, range.upperBound <= chunkCount else { throw EditError.outOfBounds }
        if range.count == 1, texts.count == 1 {
            return try replacingChunk(at: range.lowerBound, with: texts[0])
        }
        var visits = 0, random = storage.random
        let (before, rest) = Tree.split(storage.root, count: range.lowerBound, visits: &visits)
        let (_, after) = Tree.split(rest, count: range.count, visits: &visits)
        let replacement = Self.tree(texts, random: &random, visits: &visits)
        let root = Tree.merge(Tree.merge(before, replacement, visits: &visits), after, visits: &visits)
        return DocumentSource(root: root, random: random, visits: visits)
    }

    private func validate(_ range: NSRange) throws {
        guard range.location >= 0, range.location <= utf16Length, range.length >= 0,
              range.length <= utf16Length - range.location else { throw EditError.outOfBounds }
        for offset in [range.location, range.upperBound] where offset > 0 && offset < utf16Length {
            var next = storage.root, point = offset
            while let node = next {
                let left = node.left?.length ?? 0
                if point < left { next = node.left }
                else if point >= left + node.textLength { point -= left + node.textLength; next = node.right }
                else {
                    let relative = point - left
                    if relative > 0, (0xDC00...0xDFFF).contains((node.text as NSString).character(at: relative)) {
                        throw EditError.invalidUTF16Boundary
                    }
                    break
                }
            }
        }
    }
    private static func chunks(_ text: String) -> [String] {
        let units = Array(text.utf16)
        var result: [String] = [], start = 0
        while start < units.count {
            var end = min(start + 2048, units.count)
            if end < units.count, (0xDC00...0xDFFF).contains(units[end]) { end -= 1 }
            result.append(String(decoding: units[start..<end], as: UTF16.self)); start = end
        }
        return result
    }
    private static func tree(_ chunks: [String], random: inout UInt64, visits: inout Int) -> Node? {
        var root: Node?
        for chunk in chunks { root = Tree.merge(root, Node(chunk, priority: Tree.nextPriority(&random)), visits: &visits) }
        return root
    }
    private static func split(_ root: Node?, at offset: Int, random: inout UInt64, visits: inout Int) -> (Node?, Node?) {
        if offset == 0 { return (nil, root) }
        if offset == root?.length { return (root, nil) }
        var next = root, point = offset, rank = 0
        while let node = next {
            visits += 1
            let leftLength = node.left?.length ?? 0, leftCount = node.left?.count ?? 0
            if point < leftLength { next = node.left }
            else if point >= leftLength + node.textLength {
                point -= leftLength + node.textLength; rank += leftCount + 1; next = node.right
            } else {
                rank += leftCount
                let relative = point - leftLength
                let (before, rest) = Tree.split(root, count: rank, visits: &visits)
                if relative == 0 { return (before, rest) }
                let (_, after) = Tree.split(rest, count: 1, visits: &visits)
                let ns = node.text as NSString
                let prefix = Node(ns.substring(to: relative), priority: Tree.nextPriority(&random))
                let suffix = Node(ns.substring(from: relative), priority: Tree.nextPriority(&random))
                return (Tree.merge(before, prefix, visits: &visits), Tree.merge(suffix, after, visits: &visits))
            }
        }
        return (root, nil)
    }
}
