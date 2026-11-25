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
        let spans = MarkdownInlineScanner.scan(text)
        let ns = text as NSString
        let codeRanges = spans.filter { $0.style.code }.map(\.sourceRange)
        let mathRanges: [NSRange]
        if ns.range(of: "$", options: .literal).location != NSNotFound {
            mathRanges = MathScanner.regions(in: text, skipping: codeRanges).map(\.range)
        } else {
            mathRanges = []
        }
        let links = scanLinks(in: text, protectedRanges: protectedRanges(code: codeRanges, math: mathRanges)).links
        return buildInlineRuns(spans: spans, mathRanges: mathRanges, links: links, offset: offset, limit: nil)
    }

    private static func protectedRanges(code: [NSRange], math: [NSRange]) -> [NSRange] {
        if math.isEmpty { return code }
        if code.isEmpty { return math }
        // MathScanner skips code. Keep adjacent spans separate so each owns its own delimiters.
        return (code + math).sorted { $0.location < $1.location }
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

    package struct Link: Sendable { package let source: NSRange; package let label: NSRange; package let image: Bool }
    package struct LinkScanResult: Sendable {
        package let links: [Link]
        package let unclosedDestinationStart: Int?
    }

    package static func isEscaped(_ index: Substring.Index, in body: Substring) -> Bool {
        var previous = index, count = 0
        while previous > body.startIndex {
            previous = body.index(before: previous)
            guard body[previous] == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    private struct LinkScanTable {
        let chars: [Character]
        let escaped: [Bool]
        let utf16Prefix: [Int]
        let candidates: [(open: Int, close: Int)]
        let nextNonSpace: [Int]
        let nextAngle: [Int]
        let nextBrace: [Int]
        let nextDoubleQuote: [Int]
        let nextSingleQuote: [Int]
        let nextCloseParen: [Int]
        let plainStop: [Int]
    }

    private struct ForwardLinkScan {
        let chars: [Character]
        let escaped: [Bool]
        let utf16Prefix: [Int]
        let candidates: [(open: Int, close: Int)]
        let sawUnescapedCloseParen: Bool
    }

    private static func scanForwardLinkTokens(in text: String) -> ForwardLinkScan {
        var chars: [Character] = []
        var escaped: [Bool] = []
        var utf16Prefix: [Int] = [0]
        let estimate = text.utf8.count
        chars.reserveCapacity(estimate)
        escaped.reserveCapacity(estimate)
        utf16Prefix.reserveCapacity(estimate + 1)

        var openStack: [Int] = []
        var candidates: [(open: Int, close: Int)] = []
        var sawUnescapedCloseParen = false
        var pendingCloseForOpen: Int? = nil
        var nextIsEscaped = false
        var utf16Total = 0
        var index = 0

        for ch in text {
            let isEsc = nextIsEscaped
            nextIsEscaped = false

            if let closeOpen = pendingCloseForOpen {
                if !isEsc && ch == "(" {
                    candidates.append((open: closeOpen, close: index - 1))
                }
                pendingCloseForOpen = nil
            }

            chars.append(ch)
            escaped.append(isEsc)
            utf16Total += ch.utf16.count
            utf16Prefix.append(utf16Total)

            if !isEsc {
                switch ch {
                case "\\":
                    nextIsEscaped = true
                case "[":
                    openStack.append(index)
                case "]":
                    if let open = openStack.popLast() {
                        pendingCloseForOpen = open
                    }
                case ")":
                    sawUnescapedCloseParen = true
                default:
                    break
                }
            }
            index += 1
        }

        if candidates.count > 1 {
            candidates.sort { $0.open < $1.open }
        }
        return ForwardLinkScan(
            chars: chars,
            escaped: escaped,
            utf16Prefix: utf16Prefix,
            candidates: candidates,
            sawUnescapedCloseParen: sawUnescapedCloseParen
        )
    }

    private static func scanForwardLinkTokensAsync(
        in text: String,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> ForwardLinkScan? {
        var chars: [Character] = []
        var escaped: [Bool] = []
        var utf16Prefix: [Int] = [0]
        let estimate = text.utf8.count
        chars.reserveCapacity(estimate)
        escaped.reserveCapacity(estimate)
        utf16Prefix.reserveCapacity(estimate + 1)

        var openStack: [Int] = []
        var candidates: [(open: Int, close: Int)] = []
        var sawUnescapedCloseParen = false
        var pendingCloseForOpen: Int? = nil
        var nextIsEscaped = false
        var utf16Total = 0
        var index = 0
        var stepsSinceYield = 0

        for ch in text {
            if stepsSinceYield >= 2_048 {
                guard await checkpoint() else { return nil }
                stepsSinceYield = 0
            }
            let isEsc = nextIsEscaped
            nextIsEscaped = false

            if let closeOpen = pendingCloseForOpen {
                if !isEsc && ch == "(" {
                    candidates.append((open: closeOpen, close: index - 1))
                }
                pendingCloseForOpen = nil
            }

            chars.append(ch)
            escaped.append(isEsc)
            utf16Total += ch.utf16.count
            utf16Prefix.append(utf16Total)

            if !isEsc {
                switch ch {
                case "\\":
                    nextIsEscaped = true
                case "[":
                    openStack.append(index)
                case "]":
                    if let open = openStack.popLast() {
                        pendingCloseForOpen = open
                    }
                case ")":
                    sawUnescapedCloseParen = true
                default:
                    break
                }
            }
            index += 1
            stepsSinceYield += 1
        }

        if candidates.count > 1 {
            candidates.sort { $0.open < $1.open }
        }
        return ForwardLinkScan(
            chars: chars,
            escaped: escaped,
            utf16Prefix: utf16Prefix,
            candidates: candidates,
            sawUnescapedCloseParen: sawUnescapedCloseParen
        )
    }

    private static func buildLinkScanTable(from forward: ForwardLinkScan) -> LinkScanTable {
        let chars = forward.chars
        let escaped = forward.escaped
        let n = chars.count
        var nextNonSpace = Array(repeating: n, count: n + 1)
        var nextAngle = Array(repeating: -1, count: n + 1)
        var nextBrace = Array(repeating: -1, count: n + 1)
        var nextDoubleQuote = Array(repeating: -1, count: n + 1)
        var nextSingleQuote = Array(repeating: -1, count: n + 1)
        var nextCloseParen = Array(repeating: -1, count: n + 1)
        var plainStop = Array(repeating: -1, count: n + 1)

        var segEnd = n
        var segHasTrailingBackslash = n > 0 && chars[n - 1] == "\\" && !escaped[n - 1]
        var unmatchedCloseStack: [Int] = []

        var i = n - 1
        while i >= 0 {
            let ch = chars[i]
            let isEsc = escaped[i]
            let isSpace = (ch == " " || ch == "\t")

            nextNonSpace[i] = isSpace ? nextNonSpace[i + 1] : i
            nextAngle[i] = (!isEsc && ch == ">") ? i : nextAngle[i + 1]
            nextBrace[i] = (!isEsc && ch == "}") ? i : nextBrace[i + 1]
            nextDoubleQuote[i] = (!isEsc && ch == "\"") ? i : nextDoubleQuote[i + 1]
            nextSingleQuote[i] = (!isEsc && ch == "'") ? i : nextSingleQuote[i + 1]
            nextCloseParen[i] = (!isEsc && ch == ")") ? i : nextCloseParen[i + 1]

            if !isEsc && isSpace {
                segEnd = i
                segHasTrailingBackslash = false
                if !unmatchedCloseStack.isEmpty { unmatchedCloseStack.removeAll(keepingCapacity: true) }
                plainStop[i] = -1
            } else {
                if !isEsc {
                    if ch == ")" {
                        unmatchedCloseStack.append(i)
                    } else if ch == "(" {
                        if !unmatchedCloseStack.isEmpty { _ = unmatchedCloseStack.popLast() }
                    }
                }
                if let closeParen = unmatchedCloseStack.last {
                    plainStop[i] = closeParen
                } else {
                    plainStop[i] = segHasTrailingBackslash ? -1 : segEnd
                }
            }
            i -= 1
        }

        return LinkScanTable(
            chars: chars,
            escaped: escaped,
            utf16Prefix: forward.utf16Prefix,
            candidates: forward.candidates,
            nextNonSpace: nextNonSpace,
            nextAngle: nextAngle,
            nextBrace: nextBrace,
            nextDoubleQuote: nextDoubleQuote,
            nextSingleQuote: nextSingleQuote,
            nextCloseParen: nextCloseParen,
            plainStop: plainStop
        )
    }

    private static func buildLinkScanTableAsync(
        from forward: ForwardLinkScan,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> LinkScanTable? {
        let chars = forward.chars
        let escaped = forward.escaped
        let n = chars.count
        var nextNonSpace = Array(repeating: n, count: n + 1)
        var nextAngle = Array(repeating: -1, count: n + 1)
        var nextBrace = Array(repeating: -1, count: n + 1)
        var nextDoubleQuote = Array(repeating: -1, count: n + 1)
        var nextSingleQuote = Array(repeating: -1, count: n + 1)
        var nextCloseParen = Array(repeating: -1, count: n + 1)
        var plainStop = Array(repeating: -1, count: n + 1)

        var segEnd = n
        var segHasTrailingBackslash = n > 0 && chars[n - 1] == "\\" && !escaped[n - 1]
        var unmatchedCloseStack: [Int] = []

        var i = n - 1
        var stepsSinceYield = 0
        while i >= 0 {
            if stepsSinceYield >= 2_048 {
                guard await checkpoint() else { return nil }
                stepsSinceYield = 0
            }
            let ch = chars[i]
            let isEsc = escaped[i]
            let isSpace = (ch == " " || ch == "\t")

            nextNonSpace[i] = isSpace ? nextNonSpace[i + 1] : i
            nextAngle[i] = (!isEsc && ch == ">") ? i : nextAngle[i + 1]
            nextBrace[i] = (!isEsc && ch == "}") ? i : nextBrace[i + 1]
            nextDoubleQuote[i] = (!isEsc && ch == "\"") ? i : nextDoubleQuote[i + 1]
            nextSingleQuote[i] = (!isEsc && ch == "'") ? i : nextSingleQuote[i + 1]
            nextCloseParen[i] = (!isEsc && ch == ")") ? i : nextCloseParen[i + 1]

            if !isEsc && isSpace {
                segEnd = i
                segHasTrailingBackslash = false
                if !unmatchedCloseStack.isEmpty { unmatchedCloseStack.removeAll(keepingCapacity: true) }
                plainStop[i] = -1
            } else {
                if !isEsc {
                    if ch == ")" {
                        unmatchedCloseStack.append(i)
                    } else if ch == "(" {
                        if !unmatchedCloseStack.isEmpty { _ = unmatchedCloseStack.popLast() }
                    }
                }
                if let closeParen = unmatchedCloseStack.last {
                    plainStop[i] = closeParen
                } else {
                    plainStop[i] = segHasTrailingBackslash ? -1 : segEnd
                }
            }
            i -= 1
            stepsSinceYield += 1
        }

        return LinkScanTable(
            chars: chars,
            escaped: escaped,
            utf16Prefix: forward.utf16Prefix,
            candidates: forward.candidates,
            nextNonSpace: nextNonSpace,
            nextAngle: nextAngle,
            nextBrace: nextBrace,
            nextDoubleQuote: nextDoubleQuote,
            nextSingleQuote: nextSingleQuote,
            nextCloseParen: nextCloseParen,
            plainStop: plainStop
        )
    }

    private static func resolveCandidate(
        _ candidate: (open: Int, close: Int),
        in table: LinkScanTable,
        trackUnclosed: Bool,
        protectedRanges: inout ArraySlice<NSRange>,
        cursor: inout Int,
        links: inout [Link]
    ) -> Int? {
        let start = candidate.open
        guard start >= cursor else { return nil }
        let close = candidate.close
        let labelStart = start + 1
        let open = close + 1
        let image = start > 0 && table.chars[start - 1] == "!" && !table.escaped[start - 1]
        let sourceStart = image ? start - 1 : start

        // Candidates arrive in source order. Ignore a literal "[label](" inside one code or
        // math span. A bracket in a formatted label can still pair with a closer outside it.
        let offset = table.utf16Prefix[start]
        while let range = protectedRanges.first, range.upperBound <= offset {
            protectedRanges.removeFirst()
        }
        let openingIsProtected = protectedRanges.first.map { $0.location <= offset } ?? false
        if openingIsProtected, let range = protectedRanges.first, table.utf16Prefix[open + 1] <= range.upperBound {
            return nil
        }
        let unclosedOffset = trackUnclosed && !openingIsProtected ? table.utf16Prefix[sourceStart] : nil

        let n = table.chars.count
        var end = table.nextNonSpace[open + 1]
        if end < n, table.chars[end] == "<" {
            let angle = table.nextAngle[end + 1]
            guard angle >= 0 else { return unclosedOffset }
            end = angle + 1
        } else {
            let destination = table.plainStop[end]
            guard destination >= 0 else { return unclosedOffset }
            end = destination
        }

        let beforeSpace = end
        end = table.nextNonSpace[end]
        if beforeSpace != end, end < n {
            let titleClose: Int
            switch table.chars[end] {
            case "\"": titleClose = table.nextDoubleQuote[end + 1]
            case "'": titleClose = table.nextSingleQuote[end + 1]
            case "(": titleClose = table.nextCloseParen[end + 1]
            default: titleClose = -1
            }
            if titleClose >= 0 {
                end = table.nextNonSpace[titleClose + 1]
            }
        }

        guard end < n else { return unclosedOffset }
        guard table.chars[end] == ")" else { return nil }

        end += 1
        if image, end < n, table.chars[end] == "{" {
            let brace = table.nextBrace[end + 1]
            if brace >= 0 {
                end = brace + 1
            }
        }

        let srcLoc = table.utf16Prefix[sourceStart]
        let lblLoc = table.utf16Prefix[labelStart]
        let lblEnd = table.utf16Prefix[close]
        let srcEnd = table.utf16Prefix[end]
        links.append(Link(
            source: NSRange(location: srcLoc, length: srcEnd - srcLoc),
            label: NSRange(location: lblLoc, length: lblEnd - lblLoc),
            image: image
        ))
        // A delimiter originating inside an accepted link or image cannot suppress a later link.
        while let range = protectedRanges.first, range.location < srcEnd {
            protectedRanges.removeFirst()
        }
        cursor = end
        return nil
    }

    /// Strictly O(N) Markdown link/image scanner sharing Purlory's balanced/escaped destination grammar.
    /// Precomputed next-delimiter and paren-balance tables resolve every candidate in O(1) without mutable failure caches.
    /// Sorted code and math ranges keep literal link openers from consuming following prose.
    package static func scanLinks(
        in text: String,
        trackUnclosed: Bool = false,
        protectedRanges: [NSRange] = []
    ) -> LinkScanResult {
        guard (text as NSString).range(of: "](", options: .literal).location != NSNotFound else {
            return LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        let forward = scanForwardLinkTokens(in: text)
        guard !forward.candidates.isEmpty else {
            return LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        if !trackUnclosed, !forward.sawUnescapedCloseParen {
            return LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        let table = buildLinkScanTable(from: forward)
        var cursor = 0
        var remainingProtected = protectedRanges[...]
        var links: [Link] = []
        for candidate in table.candidates {
            if let unclosed = resolveCandidate(
                candidate,
                in: table,
                trackUnclosed: trackUnclosed,
                protectedRanges: &remainingProtected,
                cursor: &cursor,
                links: &links
            ) {
                return LinkScanResult(links: links, unclosedDestinationStart: unclosed)
            }
        }
        return LinkScanResult(links: links, unclosedDestinationStart: nil)
    }

    private static func scanLinksAsync(
        in text: String,
        trackUnclosed: Bool,
        protectedRanges: [NSRange],
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> LinkScanResult? {
        guard (text as NSString).range(of: "](", options: .literal).location != NSNotFound else {
            return LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        guard let forward = await scanForwardLinkTokensAsync(in: text, isolation: isolation, checkpoint: checkpoint) else {
            return nil
        }
        guard !forward.candidates.isEmpty else {
            return LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        if !trackUnclosed, !forward.sawUnescapedCloseParen {
            return LinkScanResult(links: [], unclosedDestinationStart: nil)
        }
        guard let table = await buildLinkScanTableAsync(from: forward, isolation: isolation, checkpoint: checkpoint) else {
            return nil
        }
        var cursor = 0
        var remainingProtected = protectedRanges[...]
        var links: [Link] = []
        var processed = 0
        for candidate in table.candidates {
            if processed >= 2_048 {
                guard await checkpoint() else { return nil }
                processed = 0
            }
            if let unclosed = resolveCandidate(
                candidate,
                in: table,
                trackUnclosed: trackUnclosed,
                protectedRanges: &remainingProtected,
                cursor: &cursor,
                links: &links
            ) {
                return LinkScanResult(links: links, unclosedDestinationStart: unclosed)
            }
            processed += 1
        }
        return LinkScanResult(links: links, unclosedDestinationStart: nil)
    }

    /// Reuse Purlory's balanced/escaped destination grammar; never expose a URL tail as prose.
    package static func links(in text: String) -> [Link] {
        scanLinks(in: text, trackUnclosed: false).links
    }

    /// Full-line syntax runs for a long deferred line, resolving closed inline code/math before
    /// detecting unclosed `[alt](...` destination tails so code spans containing link-like literals
    /// remain protected and never suppress trailing prose.
    package static func deferredLineRuns(in line: String) -> [Run] {
        let spans = MarkdownInlineScanner.scan(line)
        let ns = line as NSString
        let codeRanges = spans.filter { $0.style.code }.map(\.sourceRange)
        let mathRanges = ns.range(of: "$", options: .literal).location != NSNotFound
            ? MathScanner.regions(in: line, skipping: codeRanges).map(\.range)
            : []
        let protectedRanges = protectedRanges(code: codeRanges, math: mathRanges)
        let linkReport = scanLinks(in: line, trackUnclosed: true, protectedRanges: protectedRanges)
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
        guard let spans = await MarkdownInlineScanner.scan(line, isolation: isolation, checkpoint: checkpoint) else { return nil }
        let ns = line as NSString
        let codeRanges = spans.filter { $0.style.code }.map(\.sourceRange)
        let mathRanges: [NSRange]
        if ns.range(of: "$", options: .literal).location != NSNotFound {
            guard let regions = await MathScanner.regions(in: line, skipping: codeRanges, isolation: isolation, checkpoint: checkpoint) else {
                return nil
            }
            mathRanges = regions.map(\.range)
        } else {
            mathRanges = []
        }
        let protectedRanges = protectedRanges(code: codeRanges, math: mathRanges)
        guard let linkReport = await scanLinksAsync(
            in: line,
            trackUnclosed: true,
            protectedRanges: protectedRanges,
            isolation: isolation,
            checkpoint: checkpoint
        ) else { return nil }
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
