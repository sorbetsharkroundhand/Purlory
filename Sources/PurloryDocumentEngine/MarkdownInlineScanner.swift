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
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    package static func scan(_ text: String) -> [Span] { scan(text, inherited: Style(), offset: 0) }

    private static func scan(_ text: String, inherited: Style, offset: Int) -> [Span] {
        let ns = text as NSString
        var location = 0, spans: [Span] = []
        func append(_ range: NSRange, _ style: Style) {
            spans.append(Span(text: ns.substring(with: range),
                              sourceRange: NSRange(location: offset + range.location, length: range.length), style: style))
        }
        let rules: [(NSRegularExpression, Kind)] = [
            (fontTag, .font),
            (code, .code),
            (boldItalic, .boldItalic),
            (bold, .bold),
            (italic, .italic),
            (strikethrough, .strikethrough),
            (highlight, .highlight),
        ]
        while location < ns.length {
            let search = NSRange(location: location, length: ns.length - location)
            if ns.rangeOfCharacter(from: markerCharacters, options: [], range: search).location == NSNotFound {
                append(search, inherited)
                break
            }
            var best: (NSTextCheckingResult, Kind)?
            for (rx, kind) in rules {
                if let match = rx.firstMatch(in: text, range: search),
                   best == nil || match.range.location < best!.0.range.location { best = (match, kind) }
            }
            guard let (match, kind) = best else { append(search, inherited); break }
            if match.range.location > location {
                append(NSRange(location: location, length: match.range.location - location), inherited)
            }
            var style = inherited
            switch kind {
            case .font:
                let attributes = ns.substring(with: match.range(at: 1)) as NSString
                let all = NSRange(location: 0, length: attributes.length)
                if let color = fontColor.firstMatch(in: attributes as String, range: all) {
                    style.color = attributes.substring(with: color.range(at: 1)).uppercased()
                }
                if let size = fontSize.firstMatch(in: attributes as String, range: all),
                   let value = Double(attributes.substring(with: size.range(at: 1))) { style.fontSize = value }
                let body = match.range(at: 2)
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .code:
                var codeStyle = Style()
                codeStyle.code = true
                codeStyle.color = inherited.color
                codeStyle.fontSize = inherited.fontSize
                append(match.range(at: 1), codeStyle)
            case .boldItalic:
                style.bold = true; style.italic = true
                let body = match.range(at: 1)
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .bold:
                style.bold = true
                let body = match.range(at: 1)
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .italic:
                style.italic = true
                let body = match.range(at: 1)
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .strikethrough:
                style.strikethrough = true
                let body = match.range(at: 1)
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            case .highlight:
                style.highlight = true
                let body = match.range(at: 1)
                spans += scan(ns.substring(with: body), inherited: style, offset: offset + body.location)
            }
            location = match.range.upperBound
        }
        return spans
    }
}
