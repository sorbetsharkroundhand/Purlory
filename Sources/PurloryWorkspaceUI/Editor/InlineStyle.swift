import AppKit

/// 인라인 서식 속성 키 (서식 툴바 · `**…**` 타이핑 변환).
///
/// 폰트·색 같은 실제 표시 속성은 이 키에서 파생돼 `decorateInline`이 조립한다.
/// 저장은 항상 마크다운 마커(`**` `*` `~~` `==` `` ` `` `<font>` `<p align>`)로 되돌린다 —
/// 파일 포맷은 순수 텍스트를 유지하고, 속성은 로드 때 다시 파싱된다.

/// 인라인 마크다운 ↔ purlory 인라인 속성 변환기 (파싱·직렬화 왕복 대칭).
enum InlineMarkdown {

    /// 인라인 서식 키 전체 — 블록 재스타일 시 보존 대상.
    static let inlineKeys: [NSAttributedString.Key] = [
        .purloryBold, .purloryItalic, .purloryCode, .purloryStrikethrough, .purloryHighlight,
        .purloryColor, .purloryFontSize, .purloryAlign, .purloryLineSpacing,
    ]

    typealias Segment = (text: String, attrs: [NSAttributedString.Key: Any])

    /// Marker priority and nested-font semantics are shared with prose projection.
    @MainActor
    static let typingRules: [(pattern: NSRegularExpression, attrs: [NSAttributedString.Key: Any])] = [
        (MarkdownInlineScanner.boldItalic, [.purloryBold: true, .purloryItalic: true]),
        (MarkdownInlineScanner.bold, [.purloryBold: true]),
        (MarkdownInlineScanner.italic, [.purloryItalic: true]),
        (MarkdownInlineScanner.strikethrough, [.purloryStrikethrough: true]),
        (MarkdownInlineScanner.highlight, [.purloryHighlight: true]),
        (MarkdownInlineScanner.code, [.purloryCode: true]),
    ]

    static func parse(_ text: String) -> [Segment] {
        MarkdownInlineScanner.scan(text).map { span in
            var attrs: [NSAttributedString.Key: Any] = [:]
            if span.style.bold { attrs[.purloryBold] = true }
            if span.style.italic { attrs[.purloryItalic] = true }
            if span.style.code { attrs[.purloryCode] = true }
            if span.style.strikethrough { attrs[.purloryStrikethrough] = true }
            if span.style.highlight { attrs[.purloryHighlight] = true }
            if let color = span.style.color { attrs[.purloryColor] = color }
            if let size = span.style.fontSize { attrs[.purloryFontSize] = size }
            return (span.text, attrs)
        }
    }

    // MARK: 직렬화 (속성 → 마크다운)

    /// 범위의 인라인 속성 런을 마커로 감싸 마크다운 한 줄로 되돌린다.
    /// 인라인 수식 원자(attachment)는 `$latex$`로 — 굵게 등 다른 마커로
    /// 감싸지 않는다 (원자는 서식의 대상이 아니라 객체다, 이슈 #20).
    typealias SerializedSpan = MarkdownSerializedSpan

    static func serialize(_ storage: NSAttributedString, in range: NSRange,
                          capture: ((SerializedSpan) -> Void)? = nil) -> String {
        guard range.length > 0 else { return "" }
        // TextKit splits presentation runs for fallback fonts (notably emoji).
        // Source formatting follows writer attributes, not those display boundaries.
        struct Run { let attrs: [NSAttributedString.Key: Any]; var range: NSRange }
        func style(_ attrs: [NSAttributedString.Key: Any]) -> MarkdownInlineScanner.Style {
            var value = MarkdownInlineScanner.Style()
            value.code = attrs[.purloryCode] as? Bool == true
            if !value.code {
                value.bold = attrs[.purloryBold] as? Bool == true
                value.italic = attrs[.purloryItalic] as? Bool == true
                value.strikethrough = attrs[.purloryStrikethrough] as? Bool == true
                value.highlight = attrs[.purloryHighlight] as? Bool == true
            }
            value.color = attrs[.purloryColor] as? String; value.fontSize = attrs[.purloryFontSize] as? Double
            return value
        }
        var runs: [Run] = []
        storage.enumerateAttributes(in: range, options: []) { attrs, range, _ in
            if let last = runs.last, last.range.upperBound == range.location,
               attrs[.attachment] == nil, last.attrs[.attachment] == nil, style(attrs) == style(last.attrs) {
                runs[runs.count - 1].range.length += range.length
            } else { runs.append(Run(attrs: attrs, range: range)) }
        }
        var out = "", sourceOffset = 0
        for item in runs {
            let attrs = item.attrs, run = item.range
            var text = (storage.string as NSString).substring(with: run)
            if let atom = attrs[.attachment] as? MathAtomAttachment {
                let fragment = "$\(atom.latex)$"
                if let capture {
                    let length = atom.latex.utf16.count + 2
                    capture(SerializedSpan(source: NSRange(location: sourceOffset, length: length),
                                           body: nil, native: run, style: .init(), prefix: fragment, opaqueID: ObjectIdentifier(atom)))
                    sourceOffset += length
                }
                out += fragment
                continue
            }
            var style = MarkdownInlineScanner.Style()
            style.code = attrs[.purloryCode] as? Bool == true
            var prefixLength = 0, suffixLength = 0
            var prefix = "", suffix = ""
            if style.code {
                text = "`\(text)`"
                prefixLength = 1; suffixLength = 1
                prefix = "`"; suffix = "`"
            } else {
                let isBold = attrs[.purloryBold] as? Bool == true
                let isItalic = attrs[.purloryItalic] as? Bool == true
                let isStrike = attrs[.purloryStrikethrough] as? Bool == true
                let isHighlight = attrs[.purloryHighlight] as? Bool == true
                style.bold = isBold; style.italic = isItalic
                style.strikethrough = isStrike; style.highlight = isHighlight
                if isStrike {
                    text = "~~\(text)~~"
                    prefixLength += 2; suffixLength += 2
                    prefix = "~~" + prefix; suffix += "~~"
                }
                if isHighlight {
                    text = "==\(text)=="
                    prefixLength += 2; suffixLength += 2
                    prefix = "==" + prefix; suffix += "=="
                }
                if isBold && isItalic {
                    text = "***\(text)***"
                    prefixLength += 3; suffixLength += 3
                    prefix = "***" + prefix; suffix += "***"
                } else if isBold {
                    text = "**\(text)**"
                    prefixLength += 2; suffixLength += 2
                    prefix = "**" + prefix; suffix += "**"
                } else if isItalic {
                    text = "*\(text)*"
                    prefixLength += 1; suffixLength += 1
                    prefix = "*" + prefix; suffix += "*"
                }

            }
            var tagAttrs: [String] = []
            if let hex = attrs[.purloryColor] as? String {
                tagAttrs.append("color=\"#\(hex)\"")
                style.color = hex
            }
            if let size = attrs[.purloryFontSize] as? Double {
                tagAttrs.append("size=\"\(String(format: "%g", size))\"")
                style.fontSize = size
            }
            if !tagAttrs.isEmpty {
                let opening = "<font \(tagAttrs.joined(separator: " "))>"
                text = "\(opening)\(text)</font>"
                if capture != nil {
                    prefixLength += opening.utf16.count; suffixLength += 7
                    prefix = opening + prefix; suffix += "</font>"
                }
            }
            if let capture {
                // Native run lengths already give body UTF-16 size, including emoji/NFD.
                let length = prefixLength + run.length + suffixLength
                capture(SerializedSpan(source: NSRange(location: sourceOffset, length: length),
                    body: NSRange(location: sourceOffset + prefixLength, length: run.length), native: run, style: style,
                    prefix: prefix, suffix: suffix))
                sourceOffset += length
            }
            out += text
        }
        return out
    }
}

extension NSColor {
    /// "FF453A" 형태의 인라인 색상 hex → NSColor.
    convenience init?(inlineHex: String) {
        var value: UInt64 = 0
        guard inlineHex.count == 6, Scanner(string: inlineHex).scanHexInt64(&value) else {
            return nil
        }
        self.init(hex: UInt32(value))
    }
}
