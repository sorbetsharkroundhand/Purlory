import Foundation

/// 이미지 소스의 명시적 유형 (이슈 #12) — 문자열 하나를 상대경로로 오해하지
/// 않게 한다. 원격·차단 소스는 로컬 파일로 절대 해석하지 않는다 (완전 로컬).
public enum ImageSourceKind: Equatable {
    /// Purlory 폴더 기준 상대경로 (`images/<uuid>.png`) — Purlory가 수명을 관리하는 asset.
    case managedRelative(String)
    /// 절대경로·file:// — 사용자 파일. Purlory asset과 수명 정책이 다르다 (#15).
    case externalFile(String)
    /// http(s) — 네트워크 원본. 로드·복사·GC 어디서도 로컬 파일로 취급하지 않는다.
    case remote(URL)
    /// 그 외 스킴(mailto:, data:, javascript:)·빈 destination — 렌더 대상 아님.
    case blocked(String)
}

/// 파싱된 이미지 참조 한 건 — alt·destination·title까지 원문 그대로 보존해,
/// 직렬화가 손실 없이 되돌릴 수 있다 (Gate 3 무손실 왕복).
public struct ImageReference: Equatable {
    public let alt: String
    public let destinationRaw: String
    public let destinationKind: ImageSourceKind
    public let title: String?
    /// `[alt][label]` 형태일 때의 라벨 (정규화됨). 인라인 형태면 nil.
    public let label: String?
    /// 인라인 형태에서 destination **원문**(이스케이프 포함)의 범위 — export 등
    /// 소비자가 참조 전체를 재조립하지 않고 경로만 수술적으로 바꾸게 한다
    /// (이슈 #13). angle 괄호는 범위 밖이다. 참조 형태는 경로가 정의 줄에
    /// 있으므로 nil.
    public let destinationRange: Range<String.Index>?

    /// 원본 줄에서 이미지 구문(`![…](…)` 또는 `[…][…]`)의 범위 — {…} 옵션 스플라이스용.
    public let bodyRange: Range<String.Index>
}

/// CommonMark 규칙의 이미지 참조 파서 — 편집기 렌더·직렬화·EPUB·asset GC가
/// 같은 결과를 쓰는 단일 진실 (이슈 #12). 한 줄 정규식이 놓치던 angle
/// destination·공백·균형 괄호·title 세 형식·reference 정의를 전부 처리한다.
public enum ImageReferenceParser {

    public struct Definition: Equatable {
        public let destinationRaw: String
        public let title: String?
    }

    // MARK: - 진입점

    /// 한 줄을 이미지 참조 문단으로 해석한다. `{width align}` 확장(Purlory 고유)을
    /// 먼저 떼어내고 남은 몸통만 CommonMark 규칙으로 본다.
    /// - Parameters:
    ///   - definitions: 문서 전역 참조 정의 (`[label]: dest`). nil이면 reference
    ///     형태는 이미지로 인정하지 않는다 (CommonMark 규칙과 같다).
    public static func parse(
        _ line: String, definitions: [String: Definition] = [:]
    ) -> ImageReference? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let (body, options) = splitOptions(trimmed) else { return nil }

        if let inline = parseInline(body) { return inline }
        return parseReferenceForm(body, definitions: definitions, optionsRangeHint: options != nil)
    }

    // MARK: - Purlory 확장 {…}

    /// 줄 끝의 `{…}` 옵션 블록을 분리한다 — 이미지 구문 바로 뒤(공백 허용)에 붙은 것만.
    /// 반환: (몸통, 옵션 내부 문자열). 옵션이 없으면 options=nil.
    package static func splitOptions(_ line: String) -> (body: Substring, options: String?)? {
        guard let open = line.lastIndex(of: "{") else { return (line[...], nil) }
        guard line[line.index(before: line.endIndex)] == "}" else { return (line[...], nil) }
        let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
        let body = line[..<open].trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return (line[...], nil) }
        // 옵션 토큰 검증 — `key=value` 모양만 확장으로 인정한다. width·align은
        // 알려진 키, 나머지는 미지 확장 속성으로 소비자(ImageAttrs)에 그대로
        // 전달된다 (이슈 #14 — `{custom=x}`를 몰라서 버리지 않게). 값에 공백을
        // 허용하지 않는다 — 토큰 경계와 충돌하기 때문.
        let tokens = inner.split(separator: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return (line[...], nil) }
        for token in tokens {
            guard let eq = token.firstIndex(of: "="), eq != token.startIndex,
                !token[token.index(after: eq)...].isEmpty
            else { return (line[...], nil) }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            // 키는 글자·숫자·_- 만 — 문장부호 오탐({…} 꾸미기)을 걸러낸다.
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { return (line[...], nil) }
            switch key {
            case "width" where Int(value) != nil: continue
            case "align" where ["left", "center", "right"].contains(value): continue
            default: continue
            }
        }
        return (Substring(body), String(inner))
    }

    // MARK: - 인라인 형태 `![alt](dest "title")`

    package static func parseInline(_ body: Substring) -> ImageReference? {
        var index = body.startIndex
        guard match(body, &index, "!["), var altClose = scanAlt(body, from: index)
        else { return nil }
        // alt 텍스트는 닫는 괄호를 소비하기 **전에** 잘라 둔다 — 아니면 ']('까지 끼어든다.
        let altText = String(body[index..<altClose])
        guard match(body, &altClose, "]"), match(body, &altClose, "(")
        else { return nil }

        // destination — angle(<…>) 또는 균형 괄호 일반 형태.
        var work = altClose
        skipSpaces(body, &work)
        let dest: (raw: String, end: Substring.Index, range: Range<Substring.Index>)?
        if match(body, &work, "<") {
            guard let close = scanUntilUnescaped(body, from: work, stoppingAt: ">") else { return nil }
            let raw = String(body[work..<close])
            dest = (raw, body.index(after: close), work..<close)
        } else {
            guard let end = scanPlainDestination(body, from: work) else { return nil }
            dest = (String(body[work..<end]), end, work..<end)
        }
        // title — 세 인용 형식. destination 뒤 공백이 있어야 시작한다.
        var cursor = dest!.end
        var title: String?
        let sawSpace = skipSpaces(body, &cursor) > 0
        if sawSpace, let (t, after) = scanTitle(body, from: cursor) {
            title = t
            cursor = after
            _ = skipSpaces(body, &cursor)
        } else {
            // title 없이 닫는 괄호로 끝나야 한다 — 공백 없이 바로 닫히는 것도 허용.
            if sawSpace { /* 이미 스킵됨 */ }
        }
        guard match(body, &cursor, ")") else { return nil }
        // Purlory의 이미지는 **문단 전체**다 — 괄호 뒤에 텍스트가 더 있으면 이미지
        // 문단이 아니다 (뒤 텍스트는 일반 문장으로 남는다).
        guard body[cursor...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let raw = dest!.raw
        return ImageReference(
            alt: unescape(altText),
            destinationRaw: unescape(raw),
            destinationKind: classify(raw),
            title: title.map(unescape),
            label: nil,
            destinationRange: dest!.range,
            bodyRange: body.startIndex..<cursor)
    }

    // MARK: - 참조 형태 `[alt][label]` / `[alt][]` / `[alt]`

    package static func parseReferenceForm(
        _ body: Substring, definitions: [String: Definition],
        optionsRangeHint: Bool
    ) -> ImageReference? {
        var index = body.startIndex
        guard match(body, &index, "!["), var altClose = scanAlt(body, from: index)
        else { return nil }
        let altText = String(body[index..<altClose])
        guard match(body, &altClose, "]")
        else { return nil }

        // alt 닫는 괄호 다음부터 — [라벨] 형태인지 본다.
        var cursor = altClose
        var explicitLabel: String?
        if match(body, &cursor, "[") {
            guard var close = scanAlt(body, from: cursor)
            else { return nil }
            let labelText = String(body[cursor..<close])
            guard match(body, &close, "]")
            else { return nil }
            explicitLabel = labelText
            cursor = close
        }
        // 전체/축약/접힘 모두 줄 끝까지 깨끗해야 한다 — 뒤에 텍스트가 남으면 그냥 문장.
        guard body[cursor...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // 축약 `![alt]` 및 접힘 `![alt][]`는 라벨=alt. 정의가 없으면 이미지가 아니다 (CommonMark).
        let rawLabel: String
        if let explicitLabel, !explicitLabel.isEmpty {
            rawLabel = explicitLabel
        } else {
            rawLabel = altText
        }
        guard let def = definitions[normalizeLabel(rawLabel)] else { return nil }
        return ImageReference(
            alt: unescape(altText),
            destinationRaw: def.destinationRaw,
            destinationKind: classify(def.destinationRaw),
            title: def.title,
            label: normalizeLabel(rawLabel),
            destinationRange: nil,
            bodyRange: body.startIndex..<cursor)
    }

    // MARK: - 참조 정의 수집

    /// `[label]: dest "title"` 정의를 문서에서 모은다. 라벨은 CommonMark 규칙대로
    /// 대소문자·공백을 정규화해 비교하며, 코드 블록 내부는 건너뛰고 중복 라벨은 첫 정의가 우선한다.
    public static func collectDefinitions(in document: String) -> [String: Definition] {
        var result: [String: Definition] = [:]
        var fence = MarkdownFenceTracker()
        for rawLine in document.split(separator: "\n", omittingEmptySubsequences: false) {
            if fence.consumeLine(rawLine) { continue }
            if hasIndentedCodePrefix(rawLine) { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["),
                let close = line.firstIndex(of: "]"),
                line.index(after: close) < line.endIndex,
                line[line.index(after: close)] == ":"
            else { continue }
            let label = normalizeLabel(String(line[line.index(after: line.startIndex)..<close]))
            guard !label.isEmpty else { continue }
            var rest = line[line.index(close, offsetBy: 2)...]
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard !rest.isEmpty else { continue }

            let dest: String
            if rest.first == "<",
                let closeAngle = scanUntilUnescaped(rest, from: rest.index(after: rest.startIndex),
                                                    stoppingAt: ">") {
                dest = unescape(String(rest[rest.index(after: rest.startIndex)..<closeAngle]))
                rest = rest[rest.index(after: closeAngle)...]
            } else {
                var i = rest.startIndex
                while i < rest.endIndex, ![" ", "\t"].contains(rest[i]) {
                    if rest[i] == "\\" { i = rest.index(after: i) }
                    if i < rest.endIndex { i = rest.index(after: i) }
                }
                dest = unescape(String(rest[rest.startIndex..<i]))
                rest = rest[i...]
            }
            guard !dest.isEmpty else { continue }
            let trimmedRest = rest.drop(while: { $0 == " " || $0 == "\t" })
            let title: String?
            if let (t, _) = scanTitle(rest, from: trimmedRest.startIndex) {
                title = unescape(t)
            } else {
                title = nil
            }
            if result[label] == nil {
                result[label] = Definition(destinationRaw: dest, title: title)
            }
        }
        return result
    }

    private static func hasIndentedCodePrefix(_ rawLine: Substring) -> Bool {
        if rawLine.first == "\t" { return true }
        var spaces = 0
        for ch in rawLine {
            if ch == " " {
                spaces += 1
                if spaces >= 4 { return true }
            } else {
                break
            }
        }
        return false
    }

    // MARK: - source 유형 분류 (이슈 #12 핵심)

    /// 문자열 소스를 명시적 유형으로 분류한다 — 원격·차단 소스가 로컬 상대경로처럼
    /// 오해되는 것을 타입 수준에서 막는다.
    public static func classify(_ raw: String) -> ImageSourceKind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blocked("빈 destination") }

        // 스킴 판별 — "xxx:" 가 경로 구분자보다 먼저 나오면 스킴이 있다.
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = String(trimmed[trimmed.startIndex..<colon]).lowercased()
            let afterColon = trimmed.index(after: colon)
            guard afterColon < trimmed.endIndex else { return .blocked(scheme) }
            let looksLikePathColon = colon > trimmed.startIndex
                && trimmed[afterColon] == "/"
            if let url = URL(string: trimmed), let s = url.scheme?.lowercased() {
                if s == "http" || s == "https" { return .remote(url) }
                if s == "file" {
                    guard url.path.hasPrefix("/") else { return .blocked(scheme) }
                    return .externalFile(url.path)
                }
                return .blocked(scheme)
            }
            if looksLikePathColon { return .blocked(scheme) }
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return .externalFile(trimmed)
        }
        do {
            try ProjectPaths.validateRelative(trimmed)
            return .managedRelative(trimmed)
        } catch {
            return .blocked(trimmed)
        }
    }

    // MARK: - 저수준 스캐너

    package static func normalizeLabel(_ label: String) -> String {
        label.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    private static func match(_ s: Substring, _ index: inout Substring.Index, _ token: String) -> Bool {
        if s[index...].hasPrefix(token) {
            index = s.index(index, offsetBy: token.count)
            return true
        }
        return false
    }

    /// `![` 다음부터 escape를 존중해 닫는 `]` 위치를 찾는다. 중첩 대괄호는
    /// 균형을 맞춰 센다 (CommonMark link text 규칙의 단순화 — 이미지 alt는
    /// 중첩 링크를 못 가지므로 균형 카운트만으로 충분하다).
    package static func scanAlt(_ s: Substring, from start: Substring.Index) -> Substring.Index? {
        var depth = 1
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return nil }
                i = next
            }
            else if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    @discardableResult
    private static func skipSpaces(_ s: Substring, _ index: inout Substring.Index) -> Int {
        var n = 0
        while index < s.endIndex, s[index] == " " || s[index] == "\t" {
            index = s.index(after: index)
            n += 1
        }
        return n
    }

    package static func scanUntilUnescaped(
        _ s: Substring, from start: Substring.Index, stoppingAt stop: Character
    ) -> Substring.Index? {
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return nil }
                i = next
            }
            else if c == stop { return i }
            i = s.index(after: i)
        }
        return nil
    }

    /// 일반 destination — 공백·여닫는 괄호 앞에서 끝나고, 괄호는 균형을 맞춘다.
    package static func scanPlainDestination(_ s: Substring, from start: Substring.Index) -> Substring.Index? {
        var depth = 0
        var i = start
        var sawAny = false
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return nil }
                i = next; sawAny = true
            }
            else if c == "(" { depth += 1; sawAny = true }
            else if c == ")" {
                if depth == 0 {
                    // 시작에서 곧장 닫히면 빈 destination — CommonMark 허용 (`![]()`).
                    return i
                }
                depth -= 1
                sawAny = true
            }
            else if c == " " || c == "\t" { break }
            else { sawAny = true }
            i = s.index(after: i)
        }
        return sawAny ? i : nil
    }

    /// title — `"…"`, `'…'`, `(…)` 세 형식. 이스케이프 존중, 같은 종류 닫힘까지.
    package static func scanTitle(_ s: Substring, from start: Substring.Index) -> (String, Substring.Index)? {
        guard start < s.endIndex else { return nil }
        let open = s[start]
        let close: Character
        switch open {
        case "\"": close = "\""
        case "'": close = "'"
        case "(": close = ")"
        default: return nil
        }
        var i = s.index(after: start)
        var out = ""
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return nil }
                out.append(s[next])
                i = next
            } else if c == close {
                return (out, s.index(after: i))
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// 백슬래시 이스케이프 제거 — `\X`를 `X`로 되돌린다. 홀로 남은 백슬래시는
    /// 그대로 둔다 (CommonMark의 문장부호 한정을 단순화).
    package static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for c in text {
            if escaped {
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}

/// Tracks CommonMark fenced code blocks (backtick `` ` `` and tilde `~` runs of length >= 3)
/// across line-by-line scans so headings, scene breaks, image references, and link definitions
/// inside fenced code blocks are not misinterpreted as top-level document syntax.
public struct MarkdownFenceTracker: Sendable, Equatable {
    private var openMarker: Character?
    private var openLength: Int = 0

    public init() {}

    public var isInsideFence: Bool {
        openMarker != nil
    }

    /// Processes a single line and returns `true` if the line is an opening fence, inside an open fence,
    /// or a closing fence line. Returns `false` for normal top-level markdown lines.
    @discardableResult
    public mutating func consumeLine(_ rawLine: Substring) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return openMarker != nil
        }

        var count = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == first {
            count += 1
            idx = trimmed.index(after: idx)
        }
        guard count >= 3 else {
            return openMarker != nil
        }

        let remainder = trimmed[idx...]
        if let currentMarker = openMarker {
            if first == currentMarker,
               count >= openLength,
               remainder.trimmingCharacters(in: .whitespaces).isEmpty
            {
                openMarker = nil
                openLength = 0
            }
            return true
        } else {
            // Backtick fence info strings cannot contain backticks (e.g. inline ```code``` on one line).
            if first == "`", remainder.contains("`") {
                return false
            }
            openMarker = first
            openLength = count
            return true
        }
    }

    @discardableResult
    public mutating func consumeLine(_ rawLine: String) -> Bool {
        consumeLine(rawLine[...])
    }
}
