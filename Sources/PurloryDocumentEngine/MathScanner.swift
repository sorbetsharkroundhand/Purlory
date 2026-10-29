import Foundation

/// Deterministic single-line inline/display delimiter scanner. No inference or
/// disk work; multiline display ownership remains with the editor and export.
///
/// 오인 방지 규칙 (Pandoc·cmark-gfm 수식 확장의 관습을 따른다):
/// - 이스케이프 `\$`는 구분자가 아니다 — 가격 강조 `\~\$5\~` 같은 원문 보존.
/// - 여는 `$` 뒤에 공백·탭이 오면 수식이 아니다 — "$ 5"는 문장 부호다.
/// - 닫는 `$` 앞에 공백이 오면 안 되고, **바로 뒤에 숫자가 오면 안 된다** —
///   "5달러와 10달러($5와 $10)"처럼 통화 두 개가 한 쌍으로 뭉치는 것을 막는다.
/// - 내용은 비어 있으면 안 되고, 안에 `$`(display 시작)를 못 넣는다.

package enum MathScanner {

    private static let dollar: unichar = 36
    private static let backslash: unichar = 92
    private static let newline: unichar = 10
    private static let space: unichar = 32
    private static let tab: unichar = 9
    private static let tick: unichar = 96
    /// 인라인 수식 원자(attachment 글자) — 스캔 대상이 아니라 불투명 객체다.
    /// 원자를 끼고 `$`가 재결합하면 이중 변환으로 내용이 삼켜진다 (이슈 #20).
    private static let atomChar: unichar = 0xFFFC
    /// 발견된 수식 영역. range는 입력 문자열의 UTF-16 범위.
    package struct Region: Equatable {
        package enum Kind: Equatable {
            /// `$…$` — SwiftMath text 모드로 렌더한다.
            case inlineText
            /// `$$…$$` (한 줄) — SwiftMath display 모드.
            case displayLine
        }

        package var kind: Kind
        /// `$…$` 전체(구분자 포함) UTF-16 범위.
        package var range: NSRange
        /// 구분자를 벗긴 LaTeX 소스.
        package var latex: String
    }

    /// 한 줄(개행 없음 가정)에서 수식 영역을 앞에서부터 찾는다.
    ///
    /// `skipRanges`에는 코드 스팬(`` `…` ``) 등 수식 후보에서 제외할 범위를 넣는다 —
    /// 코드 안의 `$x$`는 문자 그대로다.
    package static func regions(in line: String, skipping skipRanges: [NSRange] = []) -> [Region] {
        guard line.contains("$") else { return [] }
        let ns = line as NSString
        let length = ns.length
        var result: [Region] = []
        var i = 0
        while i < length {
            defer { i += 1 }
            guard character(ns, i) == dollar, !inSkipped(NSRange(location: i, length: 1), skipRanges)
            else { continue }
            // 이스케이프된 `\$` — 구분자가 아니라 글자 그대로의 달러다.
            if i > 0, character(ns, i - 1) == backslash { continue }

            if character(ns, i + 1) == dollar {
                // display 후보 $$ … $$
                if let region = scanDisplay(ns, from: i, skipping: skipRanges) {
                    result.append(region)
                    i = region.range.upperBound - 1  // 루프의 += 1과 합쳐 다음 문자부터
                } else {
                    // An incomplete display opener still owns both dollars.
                    i += 1
                }
                continue
            }

            // inline 후보 $ … $
            if let region = scanInline(ns, at: i, skipping: skipRanges) {
                result.append(region)
                i = region.range.upperBound - 1
            }
        }
        return result
    }

    /// 타이핑 변환용 — 커서 바로 앞에서 **방금 닫힌** 인라인 수식 하나만 찾는다.
    /// `$`를 누른 순간 완성되는 쌍만 소비해 편집 중 오변환을 막는다 (bold·code와
    /// 같은 타이밍 규칙 — transformInlineMarkerIfNeeded의 관습).
    @discardableResult
    package static func closingInline(in line: String, atCaret caret: Int) -> Region? {
        let ns = line as NSString
        guard caret >= 2, caret <= ns.length, character(ns, caret - 1) == dollar else {
            return nil
        }
        // 커서 직전 `$`가 닫는 구분자인지 검사 — 열린 위치를 역방향으로 훑는다.
        var open = -1
        var j = caret - 2
        while j >= 0 {
            let ch = character(ns, j)
            if ch == newline { break }
            if ch == dollar {
                if j > 0, character(ns, j - 1) == backslash { j -= 1; continue }
                open = j
                break
            }
            j -= 1
        }
        guard open >= 0 else { return nil }
        if open > 0, character(ns, open - 1) == dollar,
            (open < 2 || character(ns, open - 2) != backslash) {
            // Adjacent dollars may belong to display or to two inline formulas.
            // Resolve only this ambiguity with the shared scanner; ordinary
            // inline typing retains its bounded backward search.
            return regions(in: line).first {
                $0.kind == .inlineText && $0.range.upperBound == caret
            }
        }
        return scanInline(ns, at: open).flatMap { $0.range.upperBound == caret ? $0 : nil }
    }

    // MARK: - 내부

    private static func character(_ ns: NSString, _ index: Int) -> unichar {
        index >= 0 && index < ns.length ? ns.character(at: index) : 0
    }

    private static func inSkipped(_ range: NSRange, _ skips: [NSRange]) -> Bool {
        skips.contains { NSIntersectionRange($0, range).length > 0 }
    }

    /// `$…$` — 여는 규칙: 다음 문자가 공백·또 다른 `$`면 실패.
    /// 닫는 규칙: 바로 앞이 공백이면 실패, 바로 뒤가 숫자면 통화로 보고 실패.
    private static func scanInline(
        _ ns: NSString, at open: Int, skipping skipRanges: [NSRange] = []
    ) -> Region? {
        let length = ns.length
        // 내용은 최소 1글자 — "$$"·"$ $"는 수식이 아니다.
        guard open + 2 <= length else { return nil }
        let first = character(ns, open + 1)
        if first == dollar || first == space || first == tab { return nil }
        var close = -1
        var j = open + 1
        while j < length {
            let ch = character(ns, j)
            if ch == dollar {
                // 이스케이프된 달러는 내용의 일부 — 건너뛴다.
                if j > open + 1, character(ns, j - 1) == backslash { j += 1; continue }
                close = j
                break
            }
            if ch == tick, !inSkipped(NSRange(location: j, length: 1), skipRanges) {
                return nil  // 인라인 코드가 먼저 끊는다 — `$a `b` c$`는 수식이 아니다
            }
            if ch == atomChar {
                return nil  // 기존 원자를 끼고 새 쌍을 만들지 않는다
            }
            j += 1
        }
        guard close > open + 1 else { return nil }
        if character(ns, close - 1) == space || character(ns, close - 1) == tab { return nil }
        // 닫는 `$` 뒤 숫자 — "$5와 $10"의 두 번째 $ 쌍을 통화로 판정.
        let after = character(ns, close + 1)
        if after >= 48 && after <= 57 { return nil }
        let latex = ns.substring(with: NSRange(location: open + 1, length: close - open - 1))
        return Region(
            kind: .inlineText, range: NSRange(location: open, length: close - open + 1),
            latex: latex)
    }

    /// `$$…$$` — 같은 줄에서 짝이 닫혀야 한다. 내용이 곧장 붙든(`$$x$$`)
    /// 띄어쓰여 있든(`$$ x $$`) 상관없지만 빈 내용은 실패한다.
    private static func scanDisplay(
        _ ns: NSString, from open: Int, skipping skipRanges: [NSRange]
    ) -> Region? {
        let length = ns.length
        var close = -1
        var j = open + 2
        while j < length - 1 {
            if character(ns, j) == atomChar || character(ns, j + 1) == atomChar {
                return nil
            }
            if character(ns, j) == dollar, character(ns, j + 1) == dollar,
                !inSkipped(NSRange(location: j, length: 2), skipRanges)
            {
                if j > open + 2, character(ns, j - 1) == backslash { j += 1; continue }
                close = j
                break
            }
            j += 1
        }
        guard close > 0 else { return nil }
        let latex = ns.substring(with: NSRange(location: open + 2, length: close - open - 2))
            .trimmingCharacters(in: .whitespaces)
        guard !latex.isEmpty else { return nil }
        return Region(
            kind: .displayLine,
            range: NSRange(location: open, length: close - open + 2), latex: latex)
    }
}
