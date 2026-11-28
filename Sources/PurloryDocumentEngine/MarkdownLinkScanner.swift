import Foundation

/// Strictly O(N) Markdown inline link/image scanner coordinated with inline code and math delimiters.
/// Resolves backticks, `$`/`$$`, and `[label](dest)` / `![alt](dest){opts}` in left-to-right source order
/// so literal link openers inside code/math remain protected while delimiters inside real link/image
/// destinations never escape into surrounding prose or subsequent links.
package enum MarkdownLinkScanner {
    package struct Link: Sendable, Equatable {
        package let source: NSRange
        package let label: NSRange
        package let image: Bool

        package init(source: NSRange, label: NSRange, image: Bool) {
            self.source = source
            self.label = label
            self.image = image
        }

        /// Non-prose syntax range whose delimiters must never open or close inline code, math, or formatting.
        /// For images this covers the whole `![alt](dest){opts}`; for links it covers `](dest "title")`.
        package var opaqueRange: NSRange {
            image ? source : NSRange(location: label.upperBound, length: source.upperBound - label.upperBound)
        }
    }

    package struct ScanResult: Sendable, Equatable {
        package let links: [Link]
        package let unclosedDestinationStart: Int?

        package init(links: [Link], unclosedDestinationStart: Int?) {
            self.links = links
            self.unclosedDestinationStart = unclosedDestinationStart
        }
    }

    private static let tab: UInt16 = 0x09
    private static let newline: UInt16 = 0x0A
    private static let space: UInt16 = 0x20
    private static let bang: UInt16 = 0x21
    private static let doubleQuote: UInt16 = 0x22
    private static let dollar: UInt16 = 0x24
    private static let singleQuote: UInt16 = 0x27
    private static let openParen: UInt16 = 0x28
    private static let closeParen: UInt16 = 0x29
    private static let zero: UInt16 = 0x30
    private static let nine: UInt16 = 0x39
    private static let lessThan: UInt16 = 0x3C
    private static let greaterThan: UInt16 = 0x3E
    private static let openBracket: UInt16 = 0x5B
    private static let backslash: UInt16 = 0x5C
    private static let closeBracket: UInt16 = 0x5D
    private static let backtick: UInt16 = 0x60
    private static let openBrace: UInt16 = 0x7B
    private static let closeBrace: UInt16 = 0x7D
    private static let atomChar: UInt16 = 0xFFFC

    private static func isSpace(_ u: UInt16) -> Bool {
        u == space || u == tab
    }

    private static func isUnicodeWhitespace(_ u: UInt16) -> Bool {
        u == space || u == tab || u == 0x00A0 || u == 0x1680
            || (u >= 0x2000 && u <= 0x200A) || u == 0x202F || u == 0x205F || u == 0x3000
    }

    private enum DestinationResolution {
        case valid(end: Int)
        case unclosed
        case invalid
    }

    private struct ScanTable {
        let units: [UInt16]
        let escaped: [Bool]
        let nextNonSpace: [Int]
        let nextNonWhitespace: [Int]
        let nextAngle: [Int]
        let nextBrace: [Int]
        let nextDoubleQuote: [Int]
        let nextSingleQuote: [Int]
        let nextCloseParen: [Int]
        let plainStop: [Int]
        let nextBacktick: [Int]
        let nextNewline: [Int]
        let nextAtom: [Int]
        let nextUnescapedMathDollar: [Int]
        let nextUnescapedDoubleDollar: [Int]
        let nextEnclosingCloseBracket: [Int]
    }

    private static func normalizeProtected(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        if ranges.count == 1 {
            return ranges[0].length > 0 ? ranges : []
        }
        var normalized = ranges[0].length > 0
        if normalized {
            for idx in 1..<ranges.count {
                if ranges[idx].length <= 0 || ranges[idx - 1].upperBound > ranges[idx].location {
                    normalized = false
                    break
                }
            }
        }
        if normalized { return ranges }
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

    private static func buildScanTable(from text: String) -> ScanTable {
        let units = Array(text.utf16)
        let n = units.count
        var escaped = Array(repeating: false, count: n)
        var nextIsEscaped = false
        for i in 0..<n {
            escaped[i] = nextIsEscaped
            nextIsEscaped = !nextIsEscaped && units[i] == backslash
        }
        return buildBackwardTables(units: units, escaped: escaped)
    }

    private static func buildScanTableAsync(
        from text: String,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> ScanTable? {
        let units = Array(text.utf16)
        let n = units.count
        var escaped = Array(repeating: false, count: n)
        var nextIsEscaped = false
        var steps = 0
        for i in 0..<n {
            if steps >= 2_048 {
                guard await checkpoint() else { return nil }
                steps = 0
            }
            escaped[i] = nextIsEscaped
            nextIsEscaped = !nextIsEscaped && units[i] == backslash
            steps += 1
        }
        return await buildBackwardTablesAsync(units: units, escaped: escaped, isolation: isolation, checkpoint: checkpoint)
    }

    private static func buildBackwardTables(units: [UInt16], escaped: [Bool]) -> ScanTable {
        let n = units.count
        var nextNonSpace = Array(repeating: n, count: n + 1)
        var nextNonWhitespace = Array(repeating: n, count: n + 1)
        var nextAngle = Array(repeating: -1, count: n + 1)
        var nextBrace = Array(repeating: -1, count: n + 1)
        var nextDoubleQuote = Array(repeating: -1, count: n + 1)
        var nextSingleQuote = Array(repeating: -1, count: n + 1)
        var nextCloseParen = Array(repeating: -1, count: n + 1)
        var plainStop = Array(repeating: -1, count: n + 1)
        var nextBacktick = Array(repeating: -1, count: n + 1)
        var nextNewline = Array(repeating: -1, count: n + 1)
        var nextAtom = Array(repeating: -1, count: n + 1)
        var nextUnescapedMathDollar = Array(repeating: -1, count: n + 1)
        var nextUnescapedDoubleDollar = Array(repeating: -1, count: n + 1)
        var nextEnclosingCloseBracket = Array(repeating: -1, count: n + 1)

        var segEnd = n
        var segHasTrailingBackslash = n > 0 && units[n - 1] == backslash && !escaped[n - 1]
        var unmatchedCloseParenStack: [Int] = []
        var unmatchedCloseBracketStack: [Int] = []

        var i = n - 1
        while i >= 0 {
            let u = units[i]
            let isEsc = escaped[i]
            let sp = isSpace(u)

            nextNonSpace[i] = sp ? nextNonSpace[i + 1] : i
            nextNonWhitespace[i] = isUnicodeWhitespace(u) ? nextNonWhitespace[i + 1] : i
            nextAngle[i] = (!isEsc && u == greaterThan) ? i : nextAngle[i + 1]
            nextBrace[i] = (!isEsc && u == closeBrace) ? i : nextBrace[i + 1]
            nextDoubleQuote[i] = (!isEsc && u == doubleQuote) ? i : nextDoubleQuote[i + 1]
            nextSingleQuote[i] = (!isEsc && u == singleQuote) ? i : nextSingleQuote[i + 1]
            nextCloseParen[i] = (!isEsc && u == closeParen) ? i : nextCloseParen[i + 1]
            nextBacktick[i] = (u == backtick) ? i : nextBacktick[i + 1]
            nextNewline[i] = (u == newline) ? i : nextNewline[i + 1]
            nextAtom[i] = (u == atomChar) ? i : nextAtom[i + 1]

            let mathDollar = u == dollar && !(i > 0 && units[i - 1] == backslash)
            nextUnescapedMathDollar[i] = mathDollar ? i : nextUnescapedMathDollar[i + 1]
            let mathDoubleDollar = mathDollar && i + 1 < n && units[i + 1] == dollar
            nextUnescapedDoubleDollar[i] = mathDoubleDollar ? i : nextUnescapedDoubleDollar[i + 1]

            if !isEsc {
                if u == closeBracket {
                    unmatchedCloseBracketStack.append(i)
                } else if u == openBracket {
                    if !unmatchedCloseBracketStack.isEmpty { _ = unmatchedCloseBracketStack.popLast() }
                }
            }
            nextEnclosingCloseBracket[i] = unmatchedCloseBracketStack.last ?? -1

            if !isEsc && sp {
                segEnd = i
                segHasTrailingBackslash = false
                if !unmatchedCloseParenStack.isEmpty { unmatchedCloseParenStack.removeAll(keepingCapacity: true) }
                plainStop[i] = -1
            } else {
                if !isEsc {
                    if u == closeParen {
                        unmatchedCloseParenStack.append(i)
                    } else if u == openParen {
                        if !unmatchedCloseParenStack.isEmpty { _ = unmatchedCloseParenStack.popLast() }
                    }
                }
                if let close = unmatchedCloseParenStack.last {
                    plainStop[i] = close
                } else {
                    plainStop[i] = segHasTrailingBackslash ? -1 : segEnd
                }
            }
            i -= 1
        }

        return ScanTable(
            units: units,
            escaped: escaped,
            nextNonSpace: nextNonSpace,
            nextNonWhitespace: nextNonWhitespace,
            nextAngle: nextAngle,
            nextBrace: nextBrace,
            nextDoubleQuote: nextDoubleQuote,
            nextSingleQuote: nextSingleQuote,
            nextCloseParen: nextCloseParen,
            plainStop: plainStop,
            nextBacktick: nextBacktick,
            nextNewline: nextNewline,
            nextAtom: nextAtom,
            nextUnescapedMathDollar: nextUnescapedMathDollar,
            nextUnescapedDoubleDollar: nextUnescapedDoubleDollar,
            nextEnclosingCloseBracket: nextEnclosingCloseBracket
        )
    }

    private static func buildBackwardTablesAsync(
        units: [UInt16],
        escaped: [Bool],
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> ScanTable? {
        let n = units.count
        var nextNonSpace = Array(repeating: n, count: n + 1)
        var nextNonWhitespace = Array(repeating: n, count: n + 1)
        var nextAngle = Array(repeating: -1, count: n + 1)
        var nextBrace = Array(repeating: -1, count: n + 1)
        var nextDoubleQuote = Array(repeating: -1, count: n + 1)
        var nextSingleQuote = Array(repeating: -1, count: n + 1)
        var nextCloseParen = Array(repeating: -1, count: n + 1)
        var plainStop = Array(repeating: -1, count: n + 1)
        var nextBacktick = Array(repeating: -1, count: n + 1)
        var nextNewline = Array(repeating: -1, count: n + 1)
        var nextAtom = Array(repeating: -1, count: n + 1)
        var nextUnescapedMathDollar = Array(repeating: -1, count: n + 1)
        var nextUnescapedDoubleDollar = Array(repeating: -1, count: n + 1)
        var nextEnclosingCloseBracket = Array(repeating: -1, count: n + 1)

        var segEnd = n
        var segHasTrailingBackslash = n > 0 && units[n - 1] == backslash && !escaped[n - 1]
        var unmatchedCloseParenStack: [Int] = []
        var unmatchedCloseBracketStack: [Int] = []

        var i = n - 1
        var steps = 0
        while i >= 0 {
            if steps >= 2_048 {
                guard await checkpoint() else { return nil }
                steps = 0
            }
            let u = units[i]
            let isEsc = escaped[i]
            let sp = isSpace(u)

            nextNonSpace[i] = sp ? nextNonSpace[i + 1] : i
            nextNonWhitespace[i] = isUnicodeWhitespace(u) ? nextNonWhitespace[i + 1] : i
            nextAngle[i] = (!isEsc && u == greaterThan) ? i : nextAngle[i + 1]
            nextBrace[i] = (!isEsc && u == closeBrace) ? i : nextBrace[i + 1]
            nextDoubleQuote[i] = (!isEsc && u == doubleQuote) ? i : nextDoubleQuote[i + 1]
            nextSingleQuote[i] = (!isEsc && u == singleQuote) ? i : nextSingleQuote[i + 1]
            nextCloseParen[i] = (!isEsc && u == closeParen) ? i : nextCloseParen[i + 1]
            nextBacktick[i] = (u == backtick) ? i : nextBacktick[i + 1]
            nextNewline[i] = (u == newline) ? i : nextNewline[i + 1]
            nextAtom[i] = (u == atomChar) ? i : nextAtom[i + 1]

            let mathDollar = u == dollar && !(i > 0 && units[i - 1] == backslash)
            nextUnescapedMathDollar[i] = mathDollar ? i : nextUnescapedMathDollar[i + 1]
            let mathDoubleDollar = mathDollar && i + 1 < n && units[i + 1] == dollar
            nextUnescapedDoubleDollar[i] = mathDoubleDollar ? i : nextUnescapedDoubleDollar[i + 1]

            if !isEsc {
                if u == closeBracket {
                    unmatchedCloseBracketStack.append(i)
                } else if u == openBracket {
                    if !unmatchedCloseBracketStack.isEmpty { _ = unmatchedCloseBracketStack.popLast() }
                }
            }
            nextEnclosingCloseBracket[i] = unmatchedCloseBracketStack.last ?? -1

            if !isEsc && sp {
                segEnd = i
                segHasTrailingBackslash = false
                if !unmatchedCloseParenStack.isEmpty { unmatchedCloseParenStack.removeAll(keepingCapacity: true) }
                plainStop[i] = -1
            } else {
                if !isEsc {
                    if u == closeParen {
                        unmatchedCloseParenStack.append(i)
                    } else if u == openParen {
                        if !unmatchedCloseParenStack.isEmpty { _ = unmatchedCloseParenStack.popLast() }
                    }
                }
                if let close = unmatchedCloseParenStack.last {
                    plainStop[i] = close
                } else {
                    plainStop[i] = segHasTrailingBackslash ? -1 : segEnd
                }
            }
            i -= 1
            steps += 1
        }

        return ScanTable(
            units: units,
            escaped: escaped,
            nextNonSpace: nextNonSpace,
            nextNonWhitespace: nextNonWhitespace,
            nextAngle: nextAngle,
            nextBrace: nextBrace,
            nextDoubleQuote: nextDoubleQuote,
            nextSingleQuote: nextSingleQuote,
            nextCloseParen: nextCloseParen,
            plainStop: plainStop,
            nextBacktick: nextBacktick,
            nextNewline: nextNewline,
            nextAtom: nextAtom,
            nextUnescapedMathDollar: nextUnescapedMathDollar,
            nextUnescapedDoubleDollar: nextUnescapedDoubleDollar,
            nextEnclosingCloseBracket: nextEnclosingCloseBracket
        )
    }

    /// Resolve `(dest "title"){opts}` starting at `openParenIndex` in O(1) time.
    private static func resolveDestination(
        afterOpenParen open: Int,
        image: Bool,
        in table: ScanTable
    ) -> DestinationResolution {
        let n = table.units.count
        var end = table.nextNonSpace[open + 1]
        if end < n, table.units[end] == lessThan {
            let angle = table.nextAngle[end + 1]
            guard angle >= 0 else { return .unclosed }
            end = angle + 1
        } else {
            let destination = table.plainStop[end]
            guard destination >= 0 else { return .unclosed }
            end = destination
        }

        let beforeSpace = end
        end = table.nextNonSpace[end]
        if beforeSpace != end, end < n {
            let titleClose: Int
            switch table.units[end] {
            case doubleQuote: titleClose = table.nextDoubleQuote[end + 1]
            case singleQuote: titleClose = table.nextSingleQuote[end + 1]
            case openParen: titleClose = table.nextCloseParen[end + 1]
            default: titleClose = -1
            }
            if titleClose >= 0 {
                end = table.nextNonSpace[titleClose + 1]
            }
        }

        guard end < n else { return .unclosed }
        guard !table.escaped[end], table.units[end] == closeParen else { return .invalid }

        end += 1
        if image, end < n, !table.escaped[end], table.units[end] == openBrace {
            let brace = table.nextBrace[end + 1]
            if brace >= 0 {
                end = brace + 1
            }
        }
        return .valid(end: end)
    }

    private static func isImageBracket(at open: Int, in table: ScanTable) -> Bool {
        open > 0 && table.units[open - 1] == bang && !table.escaped[open - 1]
    }

    /// Reject a putative code/math span `[open ... closeEnd)` when it starts inside an open link/image
    /// label and would cross that label's valid closing `](dest)` into following prose or another URL.
    private static func escapesEnclosingValidLink(
        from start: Int,
        closingAt closeEnd: Int,
        openBrackets: [Int],
        in table: ScanTable
    ) -> Bool {
        guard let open = openBrackets.last else { return false }
        let enclosing = table.nextEnclosingCloseBracket[start]
        guard enclosing >= 0, enclosing < closeEnd else { return false }
        let paren = enclosing + 1
        guard paren < table.units.count, !table.escaped[paren], table.units[paren] == openParen else {
            return false
        }
        if case .valid = resolveDestination(afterOpenParen: paren, image: isImageBracket(at: open, in: table), in: table) {
            return true
        }
        return false
    }

    private static func nextProtectedLimit(after pos: Int, in protected: [NSRange], cursor: Int) -> Int {
        guard cursor < protected.count else { return Int.max }
        return protected[cursor].location > pos ? protected[cursor].location : Int.max
    }

    /// Try to consume an inline code span starting at `i` (`units[i] == backtick`).
    /// Returns the exclusive end index (`close + 1`) on match, or `nil`.
    private static func tryConsumeCode(
        at i: Int,
        in table: ScanTable,
        openBrackets: [Int],
        protectedLimit: Int
    ) -> Int? {
        let n = table.units.count
        guard i + 2 < n else { return nil }
        let close = table.nextBacktick[i + 1]
        guard close > i + 1, close < protectedLimit else { return nil }
        let nl = table.nextNewline[i + 1]
        if nl >= 0 && nl < close { return nil }
        if escapesEnclosingValidLink(from: i, closingAt: close, openBrackets: openBrackets, in: table) {
            return nil
        }
        return close + 1
    }

    /// Try to consume an inline `$...$` or display `$$...$$` math span starting at `i`.
    /// Returns `(consumedEnd, advanceWhenRejected)` — note an incomplete `$$` still consumes 2 chars.
    private static func tryConsumeMath(
        at i: Int,
        in table: ScanTable,
        openBrackets: [Int],
        protectedLimit: Int
    ) -> (matchedEnd: Int?, fallbackStep: Int) {
        let units = table.units
        let n = units.count
        // Display math `$$...$$`
        if i + 1 < n, units[i + 1] == dollar {
            guard i + 1 < protectedLimit, i + 4 <= n else {
                return (nil, 2)
            }
            let close = table.nextUnescapedDoubleDollar[i + 2]
            guard close >= i + 2, close + 2 <= protectedLimit else {
                return (nil, 2)
            }
            let atom = table.nextAtom[i + 2]
            if atom >= 0 && atom < close + 2 {
                return (nil, 2)
            }
            let nl = table.nextNewline[i + 2]
            if nl >= 0 && nl < close {
                return (nil, 2)
            }
            guard table.nextNonWhitespace[i + 2] < close else {
                return (nil, 2)
            }
            if escapesEnclosingValidLink(from: i, closingAt: close + 1, openBrackets: openBrackets, in: table) {
                return (nil, 2)
            }
            return (close + 2, 2)
        }

        // Inline math `$...$`
        guard i + 2 <= n else { return (nil, 1) }
        let first = units[i + 1]
        if first == dollar || first == space || first == tab || first == newline {
            return (nil, 1)
        }
        let close = table.nextUnescapedMathDollar[i + 1]
        guard close > i + 1, close < protectedLimit else { return (nil, 1) }
        let nl = table.nextNewline[i + 1]
        if nl >= 0 && nl < close { return (nil, 1) }
        let tick = table.nextBacktick[i + 1]
        if tick >= 0 && tick < close { return (nil, 1) }
        let atom = table.nextAtom[i + 1]
        if atom >= 0 && atom < close { return (nil, 1) }
        let beforeClose = units[close - 1]
        if beforeClose == space || beforeClose == tab { return (nil, 1) }
        if close + 1 < n {
            let after = units[close + 1]
            if after >= zero && after <= nine { return (nil, 1) }
        }
        if escapesEnclosingValidLink(from: i, closingAt: close, openBrackets: openBrackets, in: table) {
            return (nil, 1)
        }
        return (close + 1, 1)
    }

    private static func runScan(
        in table: ScanTable,
        trackUnclosed: Bool,
        protected: [NSRange]
    ) -> ScanResult {
        let units = table.units
        let escaped = table.escaped
        let n = units.count
        var openBrackets: [Int] = []
        var links: [Link] = []
        var protIdx = 0
        var i = 0

        while i < n {
            while protIdx < protected.count && protected[protIdx].upperBound <= i {
                protIdx += 1
            }
            if protIdx < protected.count && protected[protIdx].location <= i {
                i = protected[protIdx].upperBound
                continue
            }

            let u = units[i]
            let isEsc = escaped[i]
            let protectedLimit = nextProtectedLimit(after: i, in: protected, cursor: protIdx)

            if u == backtick {
                if let end = tryConsumeCode(at: i, in: table, openBrackets: openBrackets, protectedLimit: protectedLimit) {
                    i = end
                    continue
                }
                i += 1
                continue
            }

            if u == dollar && !(i > 0 && units[i - 1] == backslash) {
                let outcome = tryConsumeMath(at: i, in: table, openBrackets: openBrackets, protectedLimit: protectedLimit)
                if let end = outcome.matchedEnd {
                    i = end
                } else {
                    i += outcome.fallbackStep
                }
                continue
            }

            if !isEsc {
                if u == openBracket {
                    openBrackets.append(i)
                } else if u == closeBracket {
                    if let open = openBrackets.popLast(),
                       i + 1 < n, !escaped[i + 1], units[i + 1] == openParen {
                        let image = isImageBracket(at: open, in: table)
                        let sourceStart = image ? open - 1 : open
                        switch resolveDestination(afterOpenParen: i + 1, image: image, in: table) {
                        case .valid(let end):
                            // Outermost valid link subsumes any nested inner link recorded inside its label.
                            while let last = links.last, last.source.location >= sourceStart {
                                links.removeLast()
                            }
                            links.append(Link(
                                source: NSRange(location: sourceStart, length: end - sourceStart),
                                label: NSRange(location: open + 1, length: i - (open + 1)),
                                image: image
                            ))
                            i = end
                            continue
                        case .unclosed:
                            if trackUnclosed {
                                while let last = links.last, last.source.location >= sourceStart {
                                    links.removeLast()
                                }
                                return ScanResult(links: links, unclosedDestinationStart: sourceStart)
                            }
                        case .invalid:
                            break
                        }
                    }
                }
            }
            i += 1
        }
        return ScanResult(links: links, unclosedDestinationStart: nil)
    }

    private static func runScanAsync(
        in table: ScanTable,
        trackUnclosed: Bool,
        protected: [NSRange],
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> ScanResult? {
        let units = table.units
        let escaped = table.escaped
        let n = units.count
        var openBrackets: [Int] = []
        var links: [Link] = []
        var protIdx = 0
        var i = 0
        var steps = 0

        while i < n {
            if steps >= 2_048 {
                guard await checkpoint() else { return nil }
                steps = 0
            }
            while protIdx < protected.count && protected[protIdx].upperBound <= i {
                protIdx += 1
            }
            if protIdx < protected.count && protected[protIdx].location <= i {
                i = protected[protIdx].upperBound
                steps += 1
                continue
            }

            let u = units[i]
            let isEsc = escaped[i]
            let protectedLimit = nextProtectedLimit(after: i, in: protected, cursor: protIdx)

            if u == backtick {
                if let end = tryConsumeCode(at: i, in: table, openBrackets: openBrackets, protectedLimit: protectedLimit) {
                    i = end
                    steps += 1
                    continue
                }
                i += 1
                steps += 1
                continue
            }

            if u == dollar && !(i > 0 && units[i - 1] == backslash) {
                let outcome = tryConsumeMath(at: i, in: table, openBrackets: openBrackets, protectedLimit: protectedLimit)
                if let end = outcome.matchedEnd {
                    i = end
                } else {
                    i += outcome.fallbackStep
                }
                steps += 1
                continue
            }

            if !isEsc {
                if u == openBracket {
                    openBrackets.append(i)
                } else if u == closeBracket {
                    if let open = openBrackets.popLast(),
                       i + 1 < n, !escaped[i + 1], units[i + 1] == openParen {
                        let image = isImageBracket(at: open, in: table)
                        let sourceStart = image ? open - 1 : open
                        switch resolveDestination(afterOpenParen: i + 1, image: image, in: table) {
                        case .valid(let end):
                            while let last = links.last, last.source.location >= sourceStart {
                                links.removeLast()
                            }
                            links.append(Link(
                                source: NSRange(location: sourceStart, length: end - sourceStart),
                                label: NSRange(location: open + 1, length: i - (open + 1)),
                                image: image
                            ))
                            i = end
                            steps += 1
                            continue
                        case .unclosed:
                            if trackUnclosed {
                                while let last = links.last, last.source.location >= sourceStart {
                                    links.removeLast()
                                }
                                return ScanResult(links: links, unclosedDestinationStart: sourceStart)
                            }
                        case .invalid:
                            break
                        }
                    }
                }
            }
            i += 1
            steps += 1
        }
        return ScanResult(links: links, unclosedDestinationStart: nil)
    }

    package static func scan(
        in text: String,
        trackUnclosed: Bool = false,
        preProtectedRanges: [NSRange] = []
    ) -> ScanResult {
        guard (text as NSString).range(of: "](", options: .literal).location != NSNotFound else {
            return ScanResult(links: [], unclosedDestinationStart: nil)
        }
        let table = buildScanTable(from: text)
        return runScan(in: table, trackUnclosed: trackUnclosed, protected: normalizeProtected(preProtectedRanges))
    }

    package static func scan(
        in text: String,
        trackUnclosed: Bool = false,
        preProtectedRanges: [NSRange] = [],
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> ScanResult? {
        guard (text as NSString).range(of: "](", options: .literal).location != NSNotFound else {
            return ScanResult(links: [], unclosedDestinationStart: nil)
        }
        guard let table = await buildScanTableAsync(from: text, isolation: isolation, checkpoint: checkpoint) else {
            return nil
        }
        return await runScanAsync(
            in: table,
            trackUnclosed: trackUnclosed,
            protected: normalizeProtected(preProtectedRanges),
            isolation: isolation,
            checkpoint: checkpoint
        )
    }

    package static func links(in text: String, preProtectedRanges: [NSRange] = []) -> [Link] {
        scan(in: text, trackUnclosed: false, preProtectedRanges: preProtectedRanges).links
    }
}
