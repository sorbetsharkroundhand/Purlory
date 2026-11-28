import Foundation

package struct WritingProseSegment: Sendable {
    package let source: NSRange
    package let prose: NSRange
    package var native: NSRange? = nil
    package var eligible = true
    package var unsupported = false
    package init(source: NSRange, prose: NSRange, native: NSRange? = nil, eligible: Bool = true, unsupported: Bool = false) {
        self.source = source; self.prose = prose; self.native = native
        self.eligible = eligible; self.unsupported = unsupported
    }
}

package struct WritingProseBlock: Sendable {
    package let id: UUID
    package let sourceText: String
    package let proseText: String
    package let sourceLength: Int
    package let proseLength: Int
    package let segments: [WritingProseSegment]
    package init(id: UUID = UUID(), sourceText: String, proseText: String, segments: [WritingProseSegment]) {
        self.id = id; self.sourceText = sourceText; self.proseText = proseText; self.segments = segments
        sourceLength = sourceText.utf16.count; proseLength = proseText.utf16.count
    }
    package var hasValidMap: Bool {
        if segments.count == 1, let segment = segments.first,
           segment.eligible, !segment.unsupported, proseLength > 0,
           segment.source == NSRange(location: 0, length: sourceLength),
           segment.prose == NSRange(location: 0, length: proseLength) {
            return sourceLength == proseLength && sourceText.utf16.elementsEqual(proseText.utf16)
        }
        var sourceEnd = 0, proseEnd = 0
        func valid(_ range: NSRange, length: Int) -> Bool {
            range.location >= 0 && range.location <= length && range.length >= 0 && range.length <= length - range.location
        }
        for segment in segments {
            guard valid(segment.source, length: sourceLength), valid(segment.prose, length: proseLength),
                  segment.source.location >= sourceEnd, segment.prose.location == proseEnd,
                  segment.prose.length > 0, !segment.unsupported || !segment.eligible else { return false }
            if segment.eligible {
                guard segment.source.length == segment.prose.length,
                      Range(segment.source, in: sourceText) != nil, Range(segment.prose, in: proseText) != nil,
                      (sourceText as NSString).substring(with: segment.source).utf16.elementsEqual(
                        (proseText as NSString).substring(with: segment.prose).utf16) else { return false }
            }
            sourceEnd = segment.source.upperBound; proseEnd = segment.prose.upperBound
        }
        return proseEnd == proseLength
    }
}

package struct WritingProjectionPatch: Sendable {
    package let oldSourceRange: WritingDiagnosticRange
    package let replacement: [WritingProseBlock]
    package init(oldSourceRange: WritingDiagnosticRange, replacement: [WritingProseBlock]) {
        self.oldSourceRange = oldSourceRange; self.replacement = replacement
    }
}

/// Load/recovery projection. Ordinary edits supply already bounded, authoritative pieces.
package enum WritingProseProjection {
    package struct Run: Sendable {
        package let source: NSRange
        package let eligible: Bool
        package var unsupported: Bool
        package init(source: NSRange, eligible: Bool, unsupported: Bool = false) {
            self.source = source; self.eligible = eligible; self.unsupported = unsupported
        }
    }
    private static let alignment = rx(#"^<p align="(?:center|right)">([^\n]*)</p>$"#)
    private static let prefix = rx(#"^(?:#{1,6} |(?:  ){0,6}(?:[-*] |\d+\.\s|- \[[ x]\] )|(?:> )+|>+$)"#)
    private static let divider = rx(#"^---+\s*$"#)
    private static func rx(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    package static func blocks(source: String) -> [WritingProseBlock] {
        // The existing synchronous load path always admits its complete projection.
        try! blocks(source: source, admission: { true })
    }

    package static func blocks(source: String, admission: @Sendable () -> Bool) throws -> [WritingProseBlock] {
        guard admission() else { throw CancellationError() }
        let ns = source as NSString
        guard ns.length > 0 else { return [] }
        var runs: [Run] = [], offset = 0, inCode = false, inMath = false
        while offset < ns.length {
            guard admission() else { throw CancellationError() }
            let newline = ns.range(of: "\n", range: NSRange(location: offset, length: ns.length - offset))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let range = NSRange(location: offset, length: end - offset)
            let line = ns.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inMath, !inCode, trimmed.hasPrefix("```"), !trimmed.dropFirst(3).contains("`") { inCode = true }
            else if !inMath, inCode, trimmed == "```" { inCode = false }
            else if inCode { }
            else if inMath {
                if trimmed == "$$" || (trimmed.hasSuffix("$$") && trimmed.count >= 2) { inMath = false }
            } else {
                var body = range
                if line.hasPrefix("<p "),
                   let match = alignment.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) {
                    body = NSRange(location: offset + match.range(at: 1).location, length: match.range(at: 1).length)
                }
                let content = body == range ? line : ns.substring(with: body)
                let completeMath = content.hasPrefix("$$") && content.hasSuffix("$$") && content.count >= 4
                let opensMath = content.trimmingCharacters(in: .whitespaces) == "$$"
                    || (content.hasPrefix("$$") && !content.dropFirst(2).hasPrefix("$"))
                if completeMath || opensMath {
                    inMath = !completeMath
                } else if !(content.hasPrefix("---") && divider.firstMatch(in: content, range: NSRange(location: 0, length: body.length)) != nil) {
                    if let first = content.unicodeScalars.first,
                       "#-* >0123456789".unicodeScalars.contains(first),
                       let match = prefix.firstMatch(in: content, range: NSRange(location: 0, length: body.length)) {
                        // Checkbox prefixes take precedence over the shorter bullet marker.
                        let trimmedContent = content.drop(while: { $0 == " " || $0 == "\t" })
                        let indentUTF16 = content.utf16.count - trimmedContent.utf16.count
                        let count = (trimmedContent.hasPrefix("- [ ] ") || trimmedContent.hasPrefix("- [x] "))
                            ? indentUTF16 + 6 : match.range.length
                        body.location += count; body.length -= count
                    }
                    runs += inlineRuns(body == range ? content : ns.substring(with: body), offset: body.location)
                }
            }
            if end < ns.length { runs.append(Run(source: NSRange(location: end, length: 1), eligible: true)) }
            offset = end + 1
        }
        runs.sort { $0.source.location < $1.source.location }
        var result: [WritingProseBlock] = [], firstRun = 0
        for piece in WritingWindowSplitter.pieces(in: source, maximum: 2048) {
            guard admission() else { throw CancellationError() }
            let bounds = piece.nsRange
            if bounds.length > 2048 {
                // A single oversized composed character cannot fit a native window.
                // Preserve it in source, with an ineligible barrier, then resume prose.
                result.append(WritingProseBlock(sourceText: ns.substring(with: bounds), proseText: "\n",
                    segments: [.init(source: NSRange(location: 0, length: bounds.length), prose: NSRange(location: 0, length: 1), eligible: false, unsupported: true)]))
                continue
            }
            while firstRun < runs.count && runs[firstRun].source.upperBound <= bounds.location { firstRun += 1 }
            var segments: [WritingProseSegment] = [], proseOffset = 0, i = firstRun
            while i < runs.count && runs[i].source.location < bounds.upperBound {
                guard admission() else { throw CancellationError() }
                let run = runs[i], clipped = NSIntersectionRange(run.source, bounds)
                if clipped.length > 0 {
                    let localSource = NSRange(location: clipped.location - bounds.location, length: clipped.length)
                    if run.eligible {
                        if !run.unsupported, let last = segments.last, last.eligible, !last.unsupported,
                           last.source.upperBound == localSource.location, last.prose.upperBound == proseOffset {
                            segments[segments.count - 1] = WritingProseSegment(
                                source: NSRange(location: last.source.location, length: last.source.length + localSource.length),
                                prose: NSRange(location: last.prose.location, length: last.prose.length + clipped.length),
                                eligible: true,
                                unsupported: false
                            )
                        } else {
                            segments.append(WritingProseSegment(
                                source: localSource,
                                prose: NSRange(location: proseOffset, length: clipped.length),
                                eligible: true,
                                unsupported: run.unsupported
                            ))
                        }
                        proseOffset += clipped.length
                    } else if clipped.location == run.source.location {
                        segments.append(WritingProseSegment(
                            source: localSource,
                            prose: NSRange(location: proseOffset, length: 1),
                            eligible: false,
                            unsupported: run.unsupported
                        ))
                        proseOffset += 1
                    }
                }
                i += 1
            }
            let sourceText = ns.substring(with: bounds)
            if segments.count == 1, let only = segments.first, only.eligible, !only.unsupported,
               only.source == NSRange(location: 0, length: bounds.length) {
                result.append(WritingProseBlock(sourceText: sourceText, proseText: sourceText, segments: segments))
            } else {
                let localNS = sourceText as NSString
                var prose = ""
                for segment in segments {
                    prose += segment.eligible ? localNS.substring(with: segment.source) : "\n"
                }
                result.append(WritingProseBlock(sourceText: sourceText, proseText: prose, segments: segments))
            }
        }
        return result
    }

    package static func inlineRuns(_ text: String, offset: Int) -> [Run] {
        let ns = text as NSString
        let links = ns.range(of: "](", options: .literal).location != NSNotFound
            ? MarkdownLinkScanner.links(in: text)
            : []
        let spans = MarkdownInlineScanner.scan(text, links: links)
        let mathRanges: [NSRange]
        if ns.range(of: "$", options: .literal).location != NSNotFound {
            let codeRanges = spans.filter { $0.style.code }.map(\.sourceRange)
            let mathSkips = links.isEmpty ? codeRanges : (codeRanges + links.map(\.opaqueRange))
            mathRanges = MathScanner.regions(in: text, skipping: mathSkips).map(\.range)
        } else {
            mathRanges = []
        }
        return buildInlineRuns(spans: spans, mathRanges: mathRanges, links: links, offset: offset, limit: nil)
    }

    private static func mergeSortedRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        var merged: [NSRange] = []
        merged.reserveCapacity(ranges.count)
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = merged.last, range.location <= last.upperBound {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func buildInlineRuns(
        spans: [MarkdownInlineScanner.Span],
        mathRanges: [NSRange],
        links: [Link],
        offset: Int,
        limit: Int?
    ) -> [Run] {
        var omitted: [NSRange] = [], barriers: [NSRange] = []
        for range in mathRanges {
            if let limit, range.location >= limit { continue }
            let clipped = limit.map { NSIntersectionRange(range, NSRange(location: 0, length: $0)) } ?? range
            if clipped.length > 0 {
                omitted.append(clipped)
                barriers.append(clipped)
            }
        }
        for link in links {
            if let limit, link.source.location >= limit { continue }
            if link.image {
                omitted.append(link.source)
                barriers.append(link.source)
            } else {
                omitted.append(NSRange(location: link.source.location, length: link.label.location - link.source.location))
                omitted.append(NSRange(location: link.label.upperBound, length: link.source.upperBound - link.label.upperBound))
            }
        }
        let mergedOmitted = mergeSortedRanges(omitted)
        var result: [Run] = []
        var omittedCursor = 0
        for span in spans {
            let rawRange = span.sourceRange
            if let limit, rawRange.location >= limit { break }
            let spanRange = limit.map { NSIntersectionRange(rawRange, NSRange(location: 0, length: $0)) } ?? rawRange
            guard spanRange.length > 0 else { continue }
            if span.style.code {
                barriers.append(spanRange)
                continue
            }
            var pieceStart = spanRange.location
            let pieceEnd = spanRange.upperBound
            while omittedCursor < mergedOmitted.count && mergedOmitted[omittedCursor].upperBound <= pieceStart {
                omittedCursor += 1
            }
            var j = omittedCursor
            while j < mergedOmitted.count && mergedOmitted[j].location < pieceEnd {
                let exclusion = mergedOmitted[j]
                if exclusion.location > pieceStart {
                    result.append(Run(source: NSRange(location: offset + pieceStart, length: exclusion.location - pieceStart), eligible: true))
                }
                pieceStart = max(pieceStart, exclusion.upperBound)
                if pieceStart >= pieceEnd { break }
                j += 1
            }
            if pieceStart < pieceEnd {
                result.append(Run(source: NSRange(location: offset + pieceStart, length: pieceEnd - pieceStart), eligible: true))
            }
        }
        // Collapse overlapping exclusions so a nested image/code fragment has one barrier.
        var end = -1
        for range in barriers.sorted(by: { $0.location < $1.location }) where range.location >= end {
            result.append(Run(source: NSRange(location: offset + range.location, length: range.length), eligible: false))
            end = range.upperBound
        }
        return result
    }

    package typealias Link = MarkdownLinkScanner.Link
    package typealias LinkScanResult = MarkdownLinkScanner.ScanResult

    package static func isEscaped(_ index: Substring.Index, in body: Substring) -> Bool {
        var previous = index, count = 0
        while previous > body.startIndex {
            previous = body.index(before: previous)
            guard body[previous] == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    /// Strictly O(N) Markdown link/image scanner sharing Purlory's balanced/escaped destination grammar
    /// coordinated in source order with inline code and math delimiters.
    package static func scanLinks(
        in text: String,
        trackUnclosed: Bool = false,
        protectedRanges: [NSRange] = []
    ) -> LinkScanResult {
        MarkdownLinkScanner.scan(in: text, trackUnclosed: trackUnclosed, preProtectedRanges: protectedRanges)
    }

    /// Reuse Purlory's balanced/escaped destination grammar; never expose a URL tail as prose.
    package static func links(in text: String) -> [Link] {
        MarkdownLinkScanner.links(in: text)
    }

    /// Full-line syntax runs for a long deferred line, coordinating inline code, math, and
    /// links/images in source order so link openers inside code/math stay protected while
    /// delimiters inside real link/image destinations never bleed into surrounding prose.
    package static func deferredLineRuns(in line: String) -> [Run] {
        let ns = line as NSString
        let linkReport = ns.range(of: "](", options: .literal).location != NSNotFound
            ? MarkdownLinkScanner.scan(in: line, trackUnclosed: true)
            : LinkScanResult(links: [], unclosedDestinationStart: nil)
        let spans = MarkdownInlineScanner.scan(line, links: linkReport.links)
        let mathRanges: [NSRange]
        if ns.range(of: "$", options: .literal).location != NSNotFound {
            let codeRanges = spans.filter { $0.style.code }.map(\.sourceRange)
            let mathSkips = linkReport.links.isEmpty ? codeRanges : (codeRanges + linkReport.links.map(\.opaqueRange))
            mathRanges = MathScanner.regions(in: line, skipping: mathSkips).map(\.range)
        } else {
            mathRanges = []
        }
        return finalizeDeferredRuns(
            lineLength: ns.length,
            spans: spans,
            mathRanges: mathRanges,
            linkReport: linkReport
        )
    }

    /// Cooperative yielding variant of `deferredLineRuns(in:)` for main-actor deferred projection.
    package static func deferredLineRuns(
        in line: String,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> [Run]? {
        let ns = line as NSString
        let linkReport: LinkScanResult
        if ns.range(of: "](", options: .literal).location != NSNotFound {
            guard let resolved = await MarkdownLinkScanner.scan(
                in: line,
                trackUnclosed: true,
                isolation: isolation,
                checkpoint: checkpoint
            ) else { return nil }
            linkReport = resolved
        } else {
            linkReport = LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        guard let spans = await MarkdownInlineScanner.scan(
            line,
            links: linkReport.links,
            isolation: isolation,
            checkpoint: checkpoint
        ) else { return nil }
        let mathRanges: [NSRange]
        if ns.range(of: "$", options: .literal).location != NSNotFound {
            let codeRanges = spans.filter { $0.style.code }.map(\.sourceRange)
            let mathSkips = linkReport.links.isEmpty ? codeRanges : (codeRanges + linkReport.links.map(\.opaqueRange))
            guard let regions = await MathScanner.regions(
                in: line,
                skipping: mathSkips,
                isolation: isolation,
                checkpoint: checkpoint
            ) else {
                return nil
            }
            mathRanges = regions.map(\.range)
        } else {
            mathRanges = []
        }
        return finalizeDeferredRuns(
            lineLength: ns.length,
            spans: spans,
            mathRanges: mathRanges,
            linkReport: linkReport
        )
    }

    private static func finalizeDeferredRuns(
        lineLength: Int,
        spans: [MarkdownInlineScanner.Span],
        mathRanges: [NSRange],
        linkReport: LinkScanResult
    ) -> [Run] {
        var runs = buildInlineRuns(
            spans: spans,
            mathRanges: mathRanges,
            links: linkReport.links,
            offset: 0,
            limit: linkReport.unclosedDestinationStart
        )
        if let unresolvedStart = linkReport.unclosedDestinationStart, unresolvedStart < lineLength {
            runs.append(Run(
                source: NSRange(location: unresolvedStart, length: lineLength - unresolvedStart),
                eligible: false,
                unsupported: true
            ))
        }
        return runs.sorted { $0.source.location < $1.source.location }
    }
}

package enum WritingWindowSplitter {
    package static func overlapUTF16(in text: String) -> Int {
        var cursor = text.endIndex, length = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor), size = text[previous..<cursor].utf16.count
            if length + size > 256 { break }
            length += size; cursor = previous
        }
        return length
    }
    package static func ranges(in text: String) -> AnySequence<WritingDiagnosticRange> {
        split(text, maximum: 4096, overlap: 256, skipOversized: true)
    }
    package static func pieces(in text: String, maximum: Int) -> AnySequence<WritingDiagnosticRange> {
        split(text, maximum: maximum, overlap: 0, skipOversized: false)
    }
    private static func split(_ text: String, maximum: Int, overlap: Int, skipOversized: Bool) -> AnySequence<WritingDiagnosticRange> {
        AnySequence {
            var cursor = text.startIndex, offset = 0
            return AnyIterator {
                while cursor < text.endIndex {
                    let start = cursor, startOffset = offset
                    var end = start, length = 0
                    while end < text.endIndex {
                        let next = text.index(after: end), size = text[end..<next].utf16.count
                        if length + size > maximum { break }
                        length += size; end = next
                    }
                    if end == start {
                        let next = text.index(after: start), size = text[start..<next].utf16.count
                        cursor = next; offset += size
                        if skipOversized { continue }
                        return WritingDiagnosticRange(location: startOffset, length: size)
                    }
                    cursor = end; offset += length
                    if end < text.endIndex && overlap > 0 {
                        var count = 0
                        while cursor > start {
                            let previous = text.index(before: cursor), size = text[previous..<cursor].utf16.count
                            if count + size > overlap { break }
                            count += size; cursor = previous; offset -= size
                        }
                    }
                    return WritingDiagnosticRange(location: startOffset, length: length)
                }
                return nil
            }
        }
    }
}
