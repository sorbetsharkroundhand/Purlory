import Foundation

/// The editor's inline grammar, with original UTF-16 spans and no AppKit attributes.
package enum MarkdownInlineScanner {
    package struct Style: Sendable, Equatable {
        package init() {}
        package var bold = false, italic = false, code = false
        package var strikethrough = false, highlight = false
        package var color: String?
        package var fontSize: Double?
    }
    package struct Span: Sendable {
        package let text: String
        package let sourceRange: NSRange
        package let style: Style
    }
    // U+2028 stays inside a formatted paragraph; only Enter (LF) separates it.
    package static let fontTag = regex(##"<font ((?:color="#[0-9A-Fa-f]{6}"|size="[0-9.]+")(?: (?:color="#[0-9A-Fa-f]{6}"|size="[0-9.]+"))*)>([^\n]*?)</font>"##)
    private static let fontColor = regex(##"color="#([0-9A-Fa-f]{6})""##)
    private static let fontSize = regex(#"size="([0-9.]+)""#)
    package static let code = regex(#"`([^`\n]+)`"#)
    package static let boldItalic = regex(#"(?<!\*)\*\*\*([^*\n]+)\*\*\*(?!\*)"#)
    package static let bold = regex(#"(?<!\*)\*\*([^*\n]+)\*\*(?!\*)"#)
    package static let italic = regex(#"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
    package static let strikethrough = regex(#"(?<!~)~~([^~\n]+)~~(?!~)"#)
    package static let highlight = regex(#"(?<!=)==([^=\n]+)==(?!=)"#)
    private static let markerCharacters = CharacterSet(charactersIn: "<`*~=")
    private enum Kind { case font, code, boldItalic, bold, italic, strikethrough, highlight }
    private struct InlineMatch {
        let range: NSRange
        let group1: NSRange
        let group2: NSRange
        let kind: Kind
    }
    private static let colorPrefix: [unichar] = [99, 111, 108, 111, 114, 61, 34, 35] // color="#
    private static let sizePrefix: [unichar] = [115, 105, 122, 101, 61, 34] // size="
    private static let ruleSpecs: [(rx: NSRegularExpression, kind: Kind, literal: String)] = [
        (fontTag, .font, "<font "),
        (code, .code, "`"),
        (boldItalic, .boldItalic, "***"),
        (bold, .bold, "**"),
        (italic, .italic, "*"),
        (strikethrough, .strikethrough, "~~"),
        (highlight, .highlight, "=="),
    ]
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    package static func scan(_ text: String) -> [Span] { scan(text, inherited: Style(), offset: 0) }

    /// Cooperative yielding variant for long deferred lines: invokes `checkpoint` every ~2048 UTF-16
    /// units and aborts early if `checkpoint()` returns `false`.
    package static func scan(
        _ text: String,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> [Span]? {
        await scanAsync(text, inherited: Style(), offset: 0, isolation: isolation, checkpoint: checkpoint)
    }

    private static func initialExhausted(_ ns: NSString) -> [Bool] {
        let full = NSRange(location: 0, length: ns.length)
        return ruleSpecs.map { spec in
            if ns.range(of: spec.literal, options: .literal, range: full).location == NSNotFound {
                return true
            }
            if spec.kind == .font {
                return ns.range(of: "</font>", options: .literal, range: full).location == NSNotFound
            }
            return false
        }
    }

    private static func matchLiteral(_ ns: NSString, at pos: Int, length: Int, _ bytes: [unichar]) -> Bool {
        guard pos + bytes.count <= length else { return false }
        for offset in 0..<bytes.count {
            if ns.character(at: pos + offset) != bytes[offset] { return false }
        }
        return true
    }

    private static func isHexDigit(_ ch: unichar) -> Bool {
        (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 70) || (ch >= 97 && ch <= 102)
    }

    private static func isSizeChar(_ ch: unichar) -> Bool {
        (ch >= 48 && ch <= 57) || ch == 46
    }

    /// Parse `<font ((?:color="#[0-9A-Fa-f]{6}"|size="[0-9.]+")(?: ...)*)>` attributes linearly.
    /// Returns the index of `>` on success, or the exact failing character index (>= `start`) on failure.
    private static func parseFontAttributes(in ns: NSString, from start: Int, length: Int) -> (attrEnd: Int?, nextSearch: Int) {
        var pos = start
        while true {
            if matchLiteral(ns, at: pos, length: length, colorPrefix) {
                var k = 0
                while k < 6 {
                    let idx = pos + 8 + k
                    guard idx < length, isHexDigit(ns.character(at: idx)) else {
                        return (nil, idx)
                    }
                    k += 1
                }
                let closeQuote = pos + 14
                guard closeQuote < length, ns.character(at: closeQuote) == 34 else {
                    return (nil, closeQuote)
                }
                pos += 15
            } else if matchLiteral(ns, at: pos, length: length, sizePrefix) {
                var p = pos + 6
                while p < length, isSizeChar(ns.character(at: p)) { p += 1 }
                guard p > pos + 6, p < length, ns.character(at: p) == 34 else {
                    return (nil, p)
                }
                pos = p + 1
            } else {
                return (nil, pos)
            }
            guard pos < length else { return (nil, length) }
            let sep = ns.character(at: pos)
            if sep == 62 { // '>'
                return (pos, pos + 1)
            }
            if sep == 32 { // ' '
                pos += 1
                continue
            }
            return (nil, pos)
        }
    }

    /// Strictly O(N) linear matcher equivalent to `fontTag.firstMatch(in:range:)`, avoiding ICU backtracking
    /// on unclosed or nested `<font ...>` tags.
    private static func findNextFontTag(in ns: NSString, length: Int, from location: Int) -> InlineMatch? {
        var cursor = location
        while cursor < length {
            let open = ns.range(of: "<font ", options: .literal, range: NSRange(location: cursor, length: length - cursor))
            guard open.location != NSNotFound else { return nil }
            let attrStart = open.location + 6
            let parsed = parseFontAttributes(in: ns, from: attrStart, length: length)
            guard let attrEnd = parsed.attrEnd else {
                cursor = max(attrStart, parsed.nextSearch)
                continue
            }
            let bodyStart = attrEnd + 1
            let close = ns.range(of: "</font>", options: .literal, range: NSRange(location: bodyStart, length: length - bodyStart))
            guard close.location != NSNotFound else { return nil }
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: bodyStart, length: close.location - bodyStart))
            if nl.location != NSNotFound {
                cursor = nl.location + 1
                continue
            }
            let fullEnd = close.location + 7
            return InlineMatch(
                range: NSRange(location: open.location, length: fullEnd - open.location),
                group1: NSRange(location: attrStart, length: attrEnd - attrStart),
                group2: NSRange(location: bodyStart, length: close.location - bodyStart),
                kind: .font
            )
        }
        return nil
    }

    private static func findNextFontTagAsync(
        in ns: NSString,
        length: Int,
        from location: Int,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> (match: InlineMatch?, cancelled: Bool) {
        var cursor = location
        var nextYield = location + 2_048
        while cursor < length {
            if cursor >= nextYield {
                guard await checkpoint() else { return (nil, true) }
                nextYield = cursor + 2_048
            }
            let open = ns.range(of: "<font ", options: .literal, range: NSRange(location: cursor, length: length - cursor))
            guard open.location != NSNotFound else { return (nil, false) }
            let attrStart = open.location + 6
            let parsed = parseFontAttributes(in: ns, from: attrStart, length: length)
            guard let attrEnd = parsed.attrEnd else {
                cursor = max(attrStart, parsed.nextSearch)
                continue
            }
            let bodyStart = attrEnd + 1
            let close = ns.range(of: "</font>", options: .literal, range: NSRange(location: bodyStart, length: length - bodyStart))
            guard close.location != NSNotFound else { return (nil, false) }
            let nl = ns.range(of: "\n", options: .literal, range: NSRange(location: bodyStart, length: close.location - bodyStart))
            if nl.location != NSNotFound {
                cursor = nl.location + 1
                continue
            }
            let fullEnd = close.location + 7
            return (InlineMatch(
                range: NSRange(location: open.location, length: fullEnd - open.location),
                group1: NSRange(location: attrStart, length: attrEnd - attrStart),
                group2: NSRange(location: bodyStart, length: close.location - bodyStart),
                kind: .font
            ), false)
        }
        return (nil, false)
    }

    private static func nextBestMatch(
        in text: String,
        ns: NSString,
        length: Int,
        at location: Int,
        cached: inout [InlineMatch?],
        exhausted: inout [Bool]
    ) -> InlineMatch? {
        let search = NSRange(location: location, length: length - location)
        var best: InlineMatch?
        for i in ruleSpecs.indices {
            if exhausted[i] { continue }
            let match: InlineMatch
            if let existing = cached[i], existing.range.location >= location {
                match = existing
            } else if ruleSpecs[i].kind == .font {
                if let found = findNextFontTag(in: ns, length: length, from: location) {
                    cached[i] = found
                    match = found
                } else {
                    cached[i] = nil
                    exhausted[i] = true
                    continue
                }
            } else if let found = ruleSpecs[i].rx.firstMatch(in: text, range: search) {
                let converted = InlineMatch(
                    range: found.range,
                    group1: found.range(at: 1),
                    group2: NSRange(location: NSNotFound, length: 0),
                    kind: ruleSpecs[i].kind
                )
                cached[i] = converted
                match = converted
            } else {
                cached[i] = nil
                exhausted[i] = true
                continue
            }
            if best == nil || match.range.location < best!.range.location {
                best = match
            }
        }
        return best
    }

    private static func nextBestMatchAsync(
        in text: String,
        ns: NSString,
        length: Int,
        at location: Int,
        cached: inout [InlineMatch?],
        exhausted: inout [Bool],
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> (match: InlineMatch?, cancelled: Bool) {
        let search = NSRange(location: location, length: length - location)
        var best: InlineMatch?
        for i in ruleSpecs.indices {
            if exhausted[i] { continue }
            let match: InlineMatch
            if let existing = cached[i], existing.range.location >= location {
                match = existing
            } else if ruleSpecs[i].kind == .font {
                let found = await findNextFontTagAsync(in: ns, length: length, from: location, isolation: isolation, checkpoint: checkpoint)
                if found.cancelled { return (nil, true) }
                if let fontMatch = found.match {
                    cached[i] = fontMatch
                    match = fontMatch
                } else {
                    cached[i] = nil
                    exhausted[i] = true
                    continue
                }
            } else if let found = ruleSpecs[i].rx.firstMatch(in: text, range: search) {
                let converted = InlineMatch(
                    range: found.range,
                    group1: found.range(at: 1),
                    group2: NSRange(location: NSNotFound, length: 0),
                    kind: ruleSpecs[i].kind
                )
                cached[i] = converted
                match = converted
            } else {
                cached[i] = nil
                exhausted[i] = true
                continue
            }
            if best == nil || match.range.location < best!.range.location {
                best = match
            }
        }
        return (best, false)
    }

    private static func parsedFontStyle(_ ns: NSString, attributesRange: NSRange, base: Style) -> Style {
        var style = base
        let attributes = ns.substring(with: attributesRange) as NSString
        let all = NSRange(location: 0, length: attributes.length)
        if let color = fontColor.firstMatch(in: attributes as String, range: all) {
            style.color = attributes.substring(with: color.range(at: 1)).uppercased()
        }
        if let size = fontSize.firstMatch(in: attributes as String, range: all),
           let value = Double(attributes.substring(with: size.range(at: 1))) {
            style.fontSize = value
        }
        return style
    }

    private static func scan(_ text: String, inherited: Style, offset: Int) -> [Span] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        if ns.rangeOfCharacter(from: markerCharacters).location == NSNotFound {
            return [Span(text: text, sourceRange: NSRange(location: offset, length: ns.length), style: inherited)]
        }
        var location = 0, spans: [Span] = []
        var cached: [InlineMatch?] = Array(repeating: nil, count: ruleSpecs.count)
        var exhausted = initialExhausted(ns)
        func append(_ range: NSRange, _ style: Style) {
            spans.append(Span(text: ns.substring(with: range),
                              sourceRange: NSRange(location: offset + range.location, length: range.length), style: style))
        }
        while location < ns.length {
            let search = NSRange(location: location, length: ns.length - location)
            if ns.rangeOfCharacter(from: markerCharacters, options: [], range: search).location == NSNotFound {
                append(search, inherited)
                break
            }
            guard let match = nextBestMatch(in: text, ns: ns, length: ns.length, at: location, cached: &cached, exhausted: &exhausted) else {
                append(search, inherited)
                break
            }
            if match.range.location > location {
                append(NSRange(location: location, length: match.range.location - location), inherited)
            }
            var style = inherited
            switch match.kind {
            case .font:
                style = parsedFontStyle(ns, attributesRange: match.group1, base: inherited)
                let body = match.group2
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .code:
                var codeStyle = Style()
                codeStyle.code = true
                codeStyle.color = inherited.color
                codeStyle.fontSize = inherited.fontSize
                append(match.group1, codeStyle)
            case .boldItalic:
                style.bold = true; style.italic = true
                let body = match.group1
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .bold:
                style.bold = true
                let body = match.group1
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .italic:
                style.italic = true
                let body = match.group1
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .strikethrough:
                style.strikethrough = true
                let body = match.group1
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .highlight:
                style.highlight = true
                let body = match.group1
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            }
            location = match.range.upperBound
        }
        return spans
    }

    private static func scanAsync(
        _ text: String,
        inherited: Style,
        offset: Int,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () async -> Bool
    ) async -> [Span]? {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        if ns.rangeOfCharacter(from: markerCharacters).location == NSNotFound {
            return [Span(text: text, sourceRange: NSRange(location: offset, length: ns.length), style: inherited)]
        }
        var location = 0, spans: [Span] = []
        var nextYieldLocation = 2_048
        var cached: [InlineMatch?] = Array(repeating: nil, count: ruleSpecs.count)
        var exhausted = initialExhausted(ns)
        func append(_ range: NSRange, _ style: Style) {
            spans.append(Span(text: ns.substring(with: range),
                              sourceRange: NSRange(location: offset + range.location, length: range.length), style: style))
        }
        while location < ns.length {
            if location >= nextYieldLocation {
                guard await checkpoint() else { return nil }
                nextYieldLocation = location + 2_048
            }
            let search = NSRange(location: location, length: ns.length - location)
            if ns.rangeOfCharacter(from: markerCharacters, options: [], range: search).location == NSNotFound {
                append(search, inherited)
                break
            }
            let step = await nextBestMatchAsync(in: text, ns: ns, length: ns.length, at: location, cached: &cached, exhausted: &exhausted, isolation: isolation, checkpoint: checkpoint)
            if step.cancelled { return nil }
            guard let match = step.match else {
                append(search, inherited)
                break
            }
            if match.range.location > location {
                append(NSRange(location: location, length: match.range.location - location), inherited)
            }
            var style = inherited
            switch match.kind {
            case .font:
                style = parsedFontStyle(ns, attributesRange: match.group1, base: inherited)
                let body = match.group2
                guard let nested = await scanAsync(ns.substring(with: body), inherited: style, offset: offset + body.location, isolation: isolation, checkpoint: checkpoint) else {
                    return nil
                }
                spans += nested
            case .code:
                var codeStyle = Style()
                codeStyle.code = true
                codeStyle.color = inherited.color
                codeStyle.fontSize = inherited.fontSize
                append(match.group1, codeStyle)
            case .boldItalic:
                style.bold = true; style.italic = true
                let body = match.group1
                guard let nested = await scanAsync(ns.substring(with: body), inherited: style, offset: offset + body.location, isolation: isolation, checkpoint: checkpoint) else {
                    return nil
                }
                spans += nested
            case .bold:
                style.bold = true
                let body = match.group1
                guard let nested = await scanAsync(ns.substring(with: body), inherited: style, offset: offset + body.location, isolation: isolation, checkpoint: checkpoint) else {
                    return nil
                }
                spans += nested
            case .italic:
                style.italic = true
                let body = match.group1
                guard let nested = await scanAsync(ns.substring(with: body), inherited: style, offset: offset + body.location, isolation: isolation, checkpoint: checkpoint) else {
                    return nil
                }
                spans += nested
            case .strikethrough:
                style.strikethrough = true
                let body = match.group1
                guard let nested = await scanAsync(ns.substring(with: body), inherited: style, offset: offset + body.location, isolation: isolation, checkpoint: checkpoint) else {
                    return nil
                }
                spans += nested
            case .highlight:
                style.highlight = true
                let body = match.group1
                guard let nested = await scanAsync(ns.substring(with: body), inherited: style, offset: offset + body.location, isolation: isolation, checkpoint: checkpoint) else {
                    return nil
                }
                spans += nested
            }
            location = match.range.upperBound
        }
        return spans
    }
}
