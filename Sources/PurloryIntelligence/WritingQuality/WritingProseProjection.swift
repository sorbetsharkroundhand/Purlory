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
    package struct Run {
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
            var prose = "", segments: [WritingProseSegment] = [], i = firstRun
            while i < runs.count && runs[i].source.location < bounds.upperBound {
                guard admission() else { throw CancellationError() }
                let run = runs[i], clipped = NSIntersectionRange(run.source, bounds)
                if clipped.length > 0 {
                    let text = run.eligible ? ns.substring(with: clipped) : (clipped.location == run.source.location ? "\n" : "")
                    if !text.isEmpty {
                        segments.append(WritingProseSegment(source: NSRange(location: clipped.location - bounds.location, length: clipped.length),
                            prose: NSRange(location: prose.utf16.count, length: text.utf16.count), eligible: run.eligible))
                        prose += text
                    }
                }
                i += 1
            }
            result.append(WritingProseBlock(sourceText: ns.substring(with: bounds), proseText: prose, segments: segments))
        }
        return result
    }

    package static func inlineRuns(_ text: String, offset: Int) -> [Run] {
        var omitted: [NSRange] = [], barriers: [NSRange] = []
        let spans = MarkdownInlineScanner.scan(text)
        let ns = text as NSString
        if ns.range(of: "$", options: .literal).location != NSNotFound {
            for region in MathScanner.regions(in: text, skipping: spans.filter { $0.style.code }.map(\.sourceRange)) {
                omitted.append(region.range); barriers.append(region.range)
            }
        }
        for link in links(in: text) {
            if link.image { omitted.append(link.source); barriers.append(link.source) }
            else {
                omitted.append(NSRange(location: link.source.location, length: link.label.location - link.source.location))
                omitted.append(NSRange(location: link.label.upperBound, length: link.source.upperBound - link.label.upperBound))
            }
        }
        var result: [Run] = []
        for span in spans {
            if span.style.code { barriers.append(span.sourceRange); continue }
            var pieces = [span.sourceRange]
            for exclusion in omitted {
                pieces = pieces.flatMap { range -> [NSRange] in
                    let overlap = NSIntersectionRange(range, exclusion)
                    guard overlap.length > 0 else { return [range] }
                    var kept: [NSRange] = []
                    if overlap.location > range.location { kept.append(NSRange(location: range.location, length: overlap.location - range.location)) }
                    if overlap.upperBound < range.upperBound { kept.append(NSRange(location: overlap.upperBound, length: range.upperBound - overlap.upperBound)) }
                    return kept
                }
            }
            result += pieces.map { Run(source: NSRange(location: offset + $0.location, length: $0.length), eligible: true) }
        }
        // Collapse overlapping exclusions so a nested image/code fragment has one barrier.
        var end = -1
        for range in barriers.sorted(by: { $0.location < $1.location }) where range.location >= end {
            result.append(Run(source: NSRange(location: offset + range.location, length: range.length), eligible: false))
            end = range.upperBound
        }
        return result
    }

    package struct Link { package let source: NSRange; package let label: NSRange; package let image: Bool }
    /// Reuse Purlory's balanced/escaped destination grammar; never expose a URL tail as prose.
    package static func links(in text: String) -> [Link] {
        guard (text as NSString).range(of: "](", options: .literal).location != NSNotFound else { return [] }
        let body = text[...]
        var cursor = body.startIndex, result: [Link] = []
        func skipSpaces(_ index: inout String.Index) {
            while index < body.endIndex && (body[index] == " " || body[index] == "\t") { index = body.index(after: index) }
        }
        func escaped(_ index: String.Index) -> Bool {
            var previous = index, count = 0
            while previous > body.startIndex {
                previous = body.index(before: previous)
                guard body[previous] == "\\" else { break }
                count += 1
            }
            return count % 2 == 1
        }
        while cursor < body.endIndex {
            let start = cursor
            cursor = body.index(after: cursor)
            guard body[start] == "[", !escaped(start),
                  let close = ImageReferenceParser.scanAlt(body, from: cursor) else { continue }
            let open = body.index(after: close)
            guard open < body.endIndex, body[open] == "(" else { continue }
            var end = body.index(after: open)
            skipSpaces(&end)
            if end < body.endIndex, body[end] == "<" {
                guard let angle = ImageReferenceParser.scanUntilUnescaped(body, from: body.index(after: end), stoppingAt: ">") else { continue }
                end = body.index(after: angle)
            } else {
                guard let destination = ImageReferenceParser.scanPlainDestination(body, from: end) else { continue }
                end = destination
            }
            let beforeSpace = end
            skipSpaces(&end)
            if beforeSpace != end, let (_, after) = ImageReferenceParser.scanTitle(body, from: end) {
                end = after; skipSpaces(&end)
            }
            guard end < body.endIndex, body[end] == ")" else { continue }
            end = body.index(after: end)
            let preceding = start > body.startIndex ? body.index(before: start) : start
            let image = preceding != start && body[preceding] == "!" && !escaped(preceding)
            if image, end < body.endIndex, body[end] == "{",
               let options = ImageReferenceParser.scanUntilUnescaped(body, from: body.index(after: end), stoppingAt: "}") {
                end = body.index(after: options)
            }
            result.append(Link(source: NSRange((image ? preceding : start)..<end, in: text),
                               label: NSRange(cursor..<close, in: text), image: image))
            cursor = end
        }
        return result
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
