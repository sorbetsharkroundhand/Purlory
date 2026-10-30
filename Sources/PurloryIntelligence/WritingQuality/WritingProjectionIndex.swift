import CryptoKit
import Foundation

package struct WritingAnalysisWindow: Sendable {
    package let text: String
    package let digest: String
    package let coveredRange: WritingDiagnosticRange
    /// Source coordinates are absolute; prose coordinates are relative to this window.
    package let segments: [WritingProseSegment]
    package func contiguousSourceRange(for range: WritingDiagnosticRange) -> WritingDiagnosticRange? {
        guard let ranges = WritingRangeMapping.map(range.nsRange, length: text.utf16.count, segments: segments),
              ranges.count == 1 else { return nil }
        return ranges[0]
    }
}

package struct WritingAnalysisWindows: Sequence, Sendable {
    private let factory: @Sendable () -> AnyIterator<WritingAnalysisWindow>
    package init(_ factory: @escaping @Sendable () -> AnyIterator<WritingAnalysisWindow>) { self.factory = factory }
    package func makeIterator() -> AnyIterator<WritingAnalysisWindow> { factory() }
    package var first: WritingAnalysisWindow? { makeIterator().next() }
}

/// Immutable nodes share unchanged subtrees with already-issued window sequences.
fileprivate final class WritingProjectionNode: DocumentRopeNode, Sendable {
    private final class Record: Sendable {
        let block: WritingProseBlock
        let eligibleProseLength: Int
        init(_ block: WritingProseBlock) {
            self.block = block
            eligibleProseLength = block.segments.reduce(0) { $0 + ($1.eligible ? $1.prose.length : 0) }
        }
    }
    private let record: Record
    package var block: WritingProseBlock { record.block }
    package let priority: UInt64
    package let left: WritingProjectionNode?, right: WritingProjectionNode?
    package let count: Int, sourceLength: Int, proseLength: Int, eligibleProseLength: Int
    convenience init(_ block: WritingProseBlock, priority: UInt64, left: WritingProjectionNode? = nil, right: WritingProjectionNode? = nil) {
        self.init(record: Record(block), priority: priority, left: left, right: right)
    }
    private init(record: Record, priority: UInt64, left: WritingProjectionNode?, right: WritingProjectionNode?) {
        self.record = record; self.priority = priority; self.left = left; self.right = right
        let block = record.block
        count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
        sourceLength = block.sourceLength + (left?.sourceLength ?? 0) + (right?.sourceLength ?? 0)
        proseLength = block.proseLength + (left?.proseLength ?? 0) + (right?.proseLength ?? 0)
        let inheritedEligible = (left?.eligibleProseLength ?? 0) + (right?.eligibleProseLength ?? 0)
        eligibleProseLength = record.eligibleProseLength + inheritedEligible
    }
    package func copy(left: WritingProjectionNode?, right: WritingProjectionNode?) -> WritingProjectionNode {
        WritingProjectionNode(record: record, priority: priority, left: left, right: right)
    }
    package func sharesRecord(with other: WritingProjectionNode) -> Bool { record === other.record }

    package static func sourceBlocks(_ node: WritingProjectionNode?, range: NSRange, base: Int = 0,
                             into result: inout [WritingProseBlock]) {
        guard let node, base < range.upperBound, base + node.sourceLength > range.location else { return }
        let location = base + (node.left?.sourceLength ?? 0)
        sourceBlocks(node.left, range: range, base: base, into: &result)
        if location < range.upperBound && location + node.block.sourceLength > range.location { result.append(node.block) }
        sourceBlocks(node.right, range: range, base: location + node.block.sourceLength, into: &result)
    }
    package static func collect(_ node: WritingProjectionNode?, range: NSRange, source: Int = 0, prose: Int = 0,
                        body: (WritingProseBlock, Int, Int) -> Void) {
        guard let node, prose < range.upperBound, prose + node.proseLength > range.location else { return }
        let s = source + (node.left?.sourceLength ?? 0), p = prose + (node.left?.proseLength ?? 0)
        collect(node.left, range: range, source: source, prose: prose, body: body)
        if p < range.upperBound && p + node.block.proseLength > range.location { body(node.block, s, p) }
        collect(node.right, range: range, source: s + node.block.sourceLength,
                prose: p + node.block.proseLength, body: body)
    }
    package static func segments(_ root: WritingProjectionNode?, range: NSRange) -> [WritingProseSegment] {
        var result: [WritingProseSegment] = []
        collect(root, range: range) { block, source, prose in
            for segment in block.segments {
                let global = NSRange(location: prose + segment.prose.location, length: segment.prose.length)
                let clipped = NSIntersectionRange(global, range)
                guard clipped.length > 0 else { continue }
                let original = segment.eligible
                    ? NSRange(location: source + segment.source.location + clipped.location - global.location, length: clipped.length)
                    : NSRange(location: source + segment.source.location, length: segment.source.length)
                result.append(WritingProseSegment(source: original,
                    prose: NSRange(location: clipped.location - range.location, length: clipped.length),
                    eligible: segment.eligible, unsupported: segment.unsupported))
            }
        }
        return result
    }
}

package final class WritingProjectionIndex {
    package init() {}
    package struct Piece: Sendable { package let block: WritingProseBlock; package let range: WritingDiagnosticRange; package let proseOffset: Int }
    private var root: WritingProjectionNode?
    private var random: UInt64 = 0x6d696e742d70726f
    package private(set) var resetCount = 0, lastMutationSourceUTF16 = 0, lastMutationVisits = 0
    package private(set) var lastDiffVisits = 0
    package var sourceLength: Int { root?.sourceLength ?? 0 }
    package var proseLength: Int { root?.proseLength ?? 0 }
    package var eligibleProseLength: Int { root?.eligibleProseLength ?? 0 }
    package func freeze() -> WritingProjectionSnapshot { WritingProjectionSnapshot(root: root) }

    package func snapshot() -> WritingProjectionIndex {
        let copy = WritingProjectionIndex()
        copy.root = root; copy.random = random; copy.resetCount = resetCount
        return copy
    }
    /// Exact record identity skips shared subtrees. No text comparison/hash is needed.
    package func patch(from previous: WritingProjectionIndex) -> WritingProjectionPatch? {
        lastDiffVisits = 0
        guard root !== previous.root else { return nil }
        let prefix = commonSourceLength(root, previous.root, reverse: false)
        if prefix == sourceLength && prefix == previous.sourceLength { return nil }
        let suffix = commonSourceLength(root, previous.root, reverse: true)
        var replacement: [WritingProseBlock] = []
        WritingProjectionNode.sourceBlocks(root, range: NSRange(location: prefix, length: sourceLength - prefix - suffix), into: &replacement)
        return WritingProjectionPatch(oldSourceRange: .init(location: prefix, length: previous.sourceLength - prefix - suffix), replacement: replacement)
    }
    private func commonSourceLength(_ first: WritingProjectionNode?, _ second: WritingProjectionNode?, reverse: Bool) -> Int {
        typealias Item = (node: WritingProjectionNode, record: Bool)
        var left: [Item] = first.map { [($0, false)] } ?? []
        var right: [Item] = second.map { [($0, false)] } ?? []
        var length = 0
        func expand(_ stack: inout [Item]) {
            let item = stack.removeLast(), node = item.node
            if let trailing = reverse ? node.left : node.right { stack.append((trailing, false)) }
            stack.append((node, true))
            if let leading = reverse ? node.right : node.left { stack.append((leading, false)) }
        }
        while let a = left.last, let b = right.last {
            lastDiffVisits += 1
            if !a.record && !b.record && a.node === b.node {
                length += a.node.sourceLength; left.removeLast(); right.removeLast()
            } else if a.record && b.record {
                guard a.node.sharesRecord(with: b.node) else { break }
                length += a.node.block.sourceLength; left.removeLast(); right.removeLast()
            } else {
                if !a.record { expand(&left) }
                if !b.record { expand(&right) }
            }
        }
        return length
    }

    package func reset(source: String) {
        root = nil; resetCount += 1
        for block in WritingProseProjection.blocks(source: source) { root = merge(root, node(block)) }
        lastMutationSourceUTF16 = source.utf16.count; lastMutationVisits = 0
    }
    /// The caller supplies complete affected pieces, with captured Markdown/native state.
    /// Reject an unknown edit rather than silently rebuilding the document on typing.
    @discardableResult
    package func apply(_ patch: WritingProjectionPatch, admission: @Sendable () -> Bool = { true }) -> Bool {
        let range = patch.oldSourceRange.nsRange
        lastMutationVisits = 0; lastMutationSourceUTF16 = 0
        guard admission(), WritingRangeMapping.valid(range, in: sourceLength),
              let first = rank(range.location), let end = rank(range.upperBound) else { return false }
        for block in patch.replacement {
            guard admission(), !block.sourceText.isEmpty,
                  block.sourceLength <= 2048 || block.segments.allSatisfy({ $0.unsupported && !$0.eligible }) else { return false }
            lastMutationSourceUTF16 += block.sourceLength
            guard block.hasValidMap else { return false }
        }
        guard admission() else { return false }
        let (before, remaining) = split(root, count: first)
        let (_, after) = split(remaining, count: end - first)
        var replacement: WritingProjectionNode?
        for block in patch.replacement {
            guard admission() else { return false }
            replacement = merge(replacement, node(block))
        }
        let updated = merge(merge(before, replacement), after)
        guard admission() else { return false }
        root = updated
        return true
    }
    package func sourcePiece(containing offset: Int) -> Piece? { freeze().sourcePiece(containing: offset) }
    package func windows(intersecting range: WritingDiagnosticRange) -> WritingAnalysisWindows { freeze().windows(intersecting: range) }
    package func sourceText(in range: WritingDiagnosticRange, maximum: Int = 8192) -> String? { freeze().sourceText(in: range, maximum: maximum) }

    package func sourceRanges(for range: WritingDiagnosticRange, in window: WritingAnalysisWindow) -> [WritingDiagnosticRange]? {
        WritingRangeMapping.map(range.nsRange, length: window.text.utf16.count, segments: window.segments)
    }
    package func sourceRanges(forProse range: WritingDiagnosticRange) -> [WritingDiagnosticRange]? { freeze().sourceRanges(forProse: range) }
    private func node(_ block: WritingProseBlock) -> WritingProjectionNode {
        WritingProjectionNode(block, priority: DocumentRopeIndex<WritingProjectionNode>.nextPriority(&random))
    }
    private func rank(_ offset: Int) -> Int? {
        if offset == sourceLength { return root?.count ?? 0 }
        var next = root, offset = offset, rank = 0
        while let node = next {
            lastMutationVisits += 1
            let left = node.left?.sourceLength ?? 0, count = node.left?.count ?? 0
            if offset < left { next = node.left }
            else if offset == left { return rank + count }
            else if offset < left + node.block.sourceLength { return nil }
            else { offset -= left + node.block.sourceLength; rank += count + 1; next = node.right }
        }
        return nil
    }
    private func split(_ node: WritingProjectionNode?, count: Int) -> (WritingProjectionNode?, WritingProjectionNode?) {
        DocumentRopeIndex<WritingProjectionNode>.split(node, count: count, visits: &lastMutationVisits)
    }
    private func merge(_ left: WritingProjectionNode?, _ right: WritingProjectionNode?) -> WritingProjectionNode? {
        DocumentRopeIndex<WritingProjectionNode>.merge(left, right, visits: &lastMutationVisits)
    }

}

/// A report can prepare and map exact source without sharing a mutable index across actors.
package struct WritingProjectionSnapshot: Sendable {
    private let root: WritingProjectionNode?
    fileprivate init(root: WritingProjectionNode?) { self.root = root }
    package var sourceLength: Int { root?.sourceLength ?? 0 }
    package var proseLength: Int { root?.proseLength ?? 0 }
    package var eligibleProseLength: Int { root?.eligibleProseLength ?? 0 }
    package static func prepare(source: String, admission: @Sendable () -> Bool = { !Task.isCancelled }) throws -> WritingProjectionSnapshot {
        let blocks = try WritingProseProjection.blocks(source: source, admission: admission)
        let index = WritingProjectionIndex()
        guard index.apply(.init(oldSourceRange: .init(location: 0, length: 0), replacement: blocks), admission: admission) else {
            throw CancellationError()
        }
        return index.freeze()
    }
    package func sourcePiece(containing offset: Int) -> WritingProjectionIndex.Piece? {
        guard sourceLength > 0, offset >= 0, offset <= sourceLength else { return nil }
        var next = root, source = 0, prose = 0
        let point = min(offset, sourceLength - 1)
        while let node = next {
            let s = source + (node.left?.sourceLength ?? 0), p = prose + (node.left?.proseLength ?? 0)
            if point < s { next = node.left }
            else if point < s + node.block.sourceLength {
                return WritingProjectionIndex.Piece(block: node.block, range: .init(location: s, length: node.block.sourceLength), proseOffset: p)
            } else {
                source = s + node.block.sourceLength; prose = p + node.block.proseLength; next = node.right
            }
        }
        return nil
    }
    package func windows(intersecting range: WritingDiagnosticRange) -> WritingAnalysisWindows {
        guard WritingRangeMapping.valid(range.nsRange, in: sourceLength),
              var first = sourcePiece(containing: range.location),
              var last = sourcePiece(containing: range.location + max(0, range.length - 1)) else {
            return WritingAnalysisWindows { AnyIterator { nil } }
        }
        if first.range.location > 0, let previous = sourcePiece(containing: first.range.location - 1) { first = previous }
        let lastEnd = last.range.location + last.range.length
        if lastEnd < sourceLength, let next = sourcePiece(containing: lastEnd) { last = next }
        let frozen = root, start = first.proseOffset, limit = last.proseOffset + last.block.proseLength
        return WritingAnalysisWindows {
            var cursor = start
            return AnyIterator {
                while cursor < limit {
                    // Read whole bounded pieces at the trailing edge to retain grapheme context.
                    var buffer = ""
                    WritingProjectionNode.collect(frozen, range: NSRange(location: cursor, length: min(4096, limit - cursor))) { block, _, prose in
                        let text = block.proseText as NSString, lower = max(0, cursor - prose)
                        buffer += text.substring(from: lower)
                    }
                    guard let local = WritingWindowSplitter.ranges(in: buffer).makeIterator().next() else { cursor = limit; return nil }
                    let text = (buffer as NSString).substring(with: local.nsRange), location = cursor + local.location
                    let end = location + local.length
                    cursor = end >= limit ? limit : end - WritingWindowSplitter.overlapUTF16(in: text)
                    let covered = NSRange(location: location, length: local.length)
                    return WritingAnalysisWindow(text: text, digest: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                        coveredRange: .init(covered), segments: WritingProjectionNode.segments(frozen, range: covered))
                }
                return nil
            }
        }
    }
    package func sourceText(in range: WritingDiagnosticRange, maximum: Int = 8192) -> String? {
        guard WritingRangeMapping.valid(range.nsRange, in: sourceLength), range.length <= maximum else { return nil }
        var blocks: [WritingProseBlock] = []
        WritingProjectionNode.sourceBlocks(root, range: range.nsRange, into: &blocks)
        guard let first = sourcePiece(containing: range.location) else { return range.length == 0 ? "" : nil }
        var offset = first.range.location, text = ""
        for block in blocks {
            let overlap = NSIntersectionRange(NSRange(location: offset, length: block.sourceLength), range.nsRange)
            if overlap.length > 0 { text += (block.sourceText as NSString).substring(with: NSRange(location: overlap.location - offset, length: overlap.length)) }
            offset += block.sourceLength
        }
        return text.utf16.count == range.length ? text : nil
    }

    package func boundedEvidence(for ranges: [WritingDiagnosticRange], documentID: WritingDocumentID) -> EvidenceAnchor? {
        guard let first = ranges.first, first.length > 0,
              WritingRangeMapping.valid(first.nsRange, in: sourceLength), let piece = sourcePiece(containing: first.location) else { return nil }
        let available = piece.range.length - (first.location - piece.range.location)
        let range = WritingDiagnosticRange(location: first.location, length: min(first.length, available))
        guard let quote = sourceText(in: range, maximum: 2048), !quote.isEmpty else { return nil }
        return EvidenceAnchor(documentID: documentID, quote: quote, utf16Hint: first.location)
    }

    /// Explicit-report evidence verification streams bounded pieces instead of joining a long quote.
    package func matchesSource(_ expected: String, in range: WritingDiagnosticRange) -> Bool {
        guard WritingRangeMapping.valid(range.nsRange, in: sourceLength), expected.utf16.count == range.length else { return false }
        if range.length == 0 { return expected.isEmpty }
        guard let first = sourcePiece(containing: range.location) else { return false }
        var blocks: [WritingProseBlock] = []
        WritingProjectionNode.sourceBlocks(root, range: range.nsRange, into: &blocks)
        var offset = first.range.location, units = expected.utf16.makeIterator()
        for block in blocks {
            let clipped = NSIntersectionRange(NSRange(location: offset, length: block.sourceLength), range.nsRange)
            let local = NSRange(location: clipped.location - offset, length: clipped.length)
            for unit in (block.sourceText as NSString).substring(with: local).utf16 {
                guard units.next() == unit else { return false }
            }
            offset += block.sourceLength
        }
        return units.next() == nil
    }

    package func segments(inProse range: WritingDiagnosticRange) -> [WritingProseSegment] {
        guard WritingRangeMapping.valid(range.nsRange, in: proseLength) else { return [] }
        return WritingProjectionNode.segments(root, range: range.nsRange)
    }
    package func sourceRanges(forProse range: WritingDiagnosticRange) -> [WritingDiagnosticRange]? {
        guard WritingRangeMapping.valid(range.nsRange, in: proseLength) else { return nil }
        return WritingRangeMapping.map(NSRange(location: 0, length: range.length), length: range.length,
                                       segments: segments(inProse: range))
    }
}

private enum WritingRangeMapping {
    package static func valid(_ range: NSRange, in length: Int) -> Bool {
        range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
    }
    package static func map(_ range: NSRange, length: Int, segments: [WritingProseSegment]) -> [WritingDiagnosticRange]? {
        guard range.length > 0, valid(range, in: length) else { return nil }
        var cursor = range.location, result: [WritingDiagnosticRange] = []
        for segment in segments {
            let overlap = NSIntersectionRange(segment.prose, range)
            guard overlap.length > 0 else { continue }
            guard segment.eligible, segment.source.length == segment.prose.length, overlap.location == cursor else { return nil }
            let source = NSRange(location: segment.source.location + overlap.location - segment.prose.location, length: overlap.length)
            if let last = result.last, last.location + last.length == source.location {
                result[result.count - 1].length += source.length
            } else { result.append(.init(source)) }
            cursor = overlap.upperBound
        }
        return cursor == range.upperBound ? result : nil
    }
}
