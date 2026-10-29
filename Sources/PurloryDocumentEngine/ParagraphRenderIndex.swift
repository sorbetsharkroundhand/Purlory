import Foundation

/// Paragraph metadata over UTF-16 lengths. An implicit treap keeps later offsets
/// derived from subtree totals, so an early edit never shifts every later record.
/// Text storage remains authoritative; callers rebuild only for load/recovery.
package final class ParagraphRenderIndex {
    package struct Record: Equatable {
        package init(length: Int, block: PurloryBlock, open: Bool = false, close: Bool = false) {
            self.length = length; self.block = block; self.open = open; self.close = close
        }
        package var length: Int
        package var block: PurloryBlock
        package var open = false
        package var close = false
    }
    package struct Paragraph: Equatable {
        package let range: NSRange
        package let record: Record
    }
    private final class Node {
        let record: Record
        let priority: UInt64
        var left: Node?, right: Node?
        var count = 1, length: Int
        init(_ record: Record, priority: UInt64) { self.record = record; self.priority = priority; length = record.length }
        func refresh() {
            count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
            length = record.length + (left?.length ?? 0) + (right?.length ?? 0)
        }
    }
    private var root: Node?
    private var randomState: UInt64 = 0x6d696e742d72656e
    package private(set) var lastLookupVisits = 0
    package private(set) var lastMutationVisits = 0
    package var utf16Length: Int { root?.length ?? 0 }
    package var paragraphCount: Int { root?.count ?? 0 }

    package init(records: [Record]) {
        for record in records where record.length > 0 { root = merge(root, makeNode(record)) }
        lastMutationVisits = 0
    }

    /// Zero-length queries select the containing paragraph, or the last at EOF.
    package func paragraphs(in range: NSRange) -> [Paragraph] {
        lastLookupVisits = 0
        guard valid(range), utf16Length > 0 else { return [] }
        let start = range.length == 0 ? min(range.location, utf16Length - 1) : range.location
        let end = range.length == 0 ? start + 1 : range.upperBound
        var result: [Paragraph] = []
        collect(root, base: 0, start: start, end: end, into: &result)
        return result
    }

    /// Replacement must cover complete indexed paragraphs. Reject stale/non-aligned
    /// assumptions instead of silently corrupting all later media locations.
    @discardableResult
    package func replace(_ range: NSRange, with records: [Record]) -> Bool {
        lastMutationVisits = 0
        guard valid(range), records.allSatisfy({ $0.length > 0 }),
              let first = boundaryRank(range.location), let end = boundaryRank(range.upperBound) else { return false }
        let (before, remaining) = split(root, count: first)
        let (_, after) = split(remaining, count: end - first)
        var replacement: Node?
        for record in records { replacement = merge(replacement, makeNode(record)) }
        root = merge(merge(before, replacement), after)
        return true
    }

    /// A viewport/dirty edge inside math expands through that contiguous run. The
    /// existing delimiter grouping then preserves complete multiline math boundaries.
    package func mathRun(containing offset: Int) -> NSRange? {
        guard offset >= 0, offset < utf16Length,
              let paragraph = paragraphs(in: NSRange(location: offset, length: 0)).first,
              paragraph.record.block == .math else { return nil }
        var start = paragraph.range.location, end = paragraph.range.upperBound
        while start > 0,
              let previous = paragraphs(in: NSRange(location: start - 1, length: 0)).first,
              previous.record.block == .math { start = previous.range.location }
        while end < utf16Length,
              let next = paragraphs(in: NSRange(location: end, length: 0)).first,
              next.record.block == .math { end = next.range.upperBound }
        return NSRange(location: start, length: end - start)
    }

    private func valid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location <= utf16Length && range.length >= 0
            && range.length <= utf16Length - range.location
    }
    private func makeNode(_ record: Record) -> Node {
        randomState ^= randomState << 13
        randomState ^= randomState >> 7
        randomState ^= randomState << 17
        return Node(record, priority: randomState)
    }
    private func boundaryRank(_ offset: Int) -> Int? {
        if offset == utf16Length { return paragraphCount }
        var node = root, remaining = offset, rank = 0
        while let current = node {
            lastMutationVisits += 1
            let leftLength = current.left?.length ?? 0, leftCount = current.left?.count ?? 0
            if remaining < leftLength { node = current.left }
            else if remaining == leftLength { return rank + leftCount }
            else if remaining < leftLength + current.record.length { return nil }
            else {
                remaining -= leftLength + current.record.length
                rank += leftCount + 1
                node = current.right
            }
        }
        return nil
    }
    private func collect(_ node: Node?, base: Int, start: Int, end: Int, into result: inout [Paragraph]) {
        guard let node else { return }
        lastLookupVisits += 1
        guard base < end, base + node.length > start else { return }
        let location = base + (node.left?.length ?? 0)
        collect(node.left, base: base, start: start, end: end, into: &result)
        if location < end, location + node.record.length > start {
            result.append(.init(range: NSRange(location: location, length: node.record.length), record: node.record))
        }
        collect(node.right, base: location + node.record.length, start: start, end: end, into: &result)
    }
    private func split(_ node: Node?, count: Int) -> (Node?, Node?) {
        guard let node else { return (nil, nil) }
        lastMutationVisits += 1
        let leftCount = node.left?.count ?? 0
        if count <= leftCount {
            let (before, after) = split(node.left, count: count)
            node.left = after; node.refresh()
            return (before, node)
        } else {
            let (before, after) = split(node.right, count: count - leftCount - 1)
            node.right = before; node.refresh()
            return (node, after)
        }
    }
    private func merge(_ left: Node?, _ right: Node?) -> Node? {
        guard let left else { return right }
        guard let right else { return left }
        lastMutationVisits += 1
        if left.priority < right.priority {
            left.right = merge(left.right, right); left.refresh(); return left
        } else {
            right.left = merge(left, right.left); right.refresh(); return right
        }
    }
}
