import Foundation

/// Source Evidence 재앵커 (요구사항 §28) — 인용이 원문에서 사라졌을 때의
/// 회복 사다리.
///
/// 우선순위: ① exact match (인용이 그대로 있다 — 대부분) → ② 접두 축약
/// (모델·사용자가 꼬리만 다듬은 경우) → ③ 어절 지문 fuzzy (문장이 소폭
/// 수정된 경우 — 인용의 어절 다수를 담은 줄을 찾는다).
///
/// ③까지 실패하면 nil — **엉뚱한 위치로 조용히 잇는 것보다 stale이 낫다**
/// (요구사항 §28). 호출부는 nil이면 점프를 포기하거나 씬 시작으로 폴백한다.
public enum SourceAnchor {

    /// One literal original occurrence in a captured context; ambiguity and invalid bounds refuse.
    public static func uniqueOriginalRange(for quote: String, in body: String, within: NSRange) -> NSRange? {
        let text = body as NSString, units = Array(quote.utf16)
        guard !units.isEmpty, within.location >= 0, within.location <= text.length,
              within.length >= units.count, within.length <= text.length - within.location else { return nil }
        let first = text.range(of: quote, options: .literal, range: within)
        guard first.location != NSNotFound, first.length == units.count,
              units.indices.allSatisfy({ units[$0] == text.character(at: first.location + $0) }) else { return nil }
        // Start one unit after the first match so overlapping occurrences also refuse.
        let next = first.location + 1, end = within.location + within.length
        guard text.range(of: quote, options: .literal, range: NSRange(location: next, length: end - next)).location == NSNotFound else { return nil }
        return first
    }

    /// Exact original evidence only. Offsets disambiguate solely on the captured revision;
    /// edited duplicate quotes remain stale instead of silently choosing the first match.
    public static func exactRange(for anchor: EvidenceAnchor, in body: String, revision: String) -> NSRange? {
        let ns = body as NSString, quote = anchor.quote as NSString
        guard quote.length > 0 else { return nil }
        if String(ProjectDigest.hash(Data(body.utf8)).prefix(16)) == revision, let hint = anchor.utf16Hint,
            hint >= 0, hint <= ns.length, quote.length <= ns.length - hint,
            ns.substring(with: NSRange(location: hint, length: quote.length)) == anchor.quote {
            return NSRange(location: hint, length: quote.length)
        }
        let first = ns.range(of: anchor.quote)
        guard first.location != NSNotFound else { return nil }
        let remaining = first.location + 1
        guard ns.range(of: anchor.quote, range: NSRange(location: remaining,
            length: ns.length - remaining)).location == NSNotFound else { return nil }
        return first
    }

    /// 인용 → 에디터 점프에 쓸 검색 질의. 원문에 exact가 있으면 인용 그대로,
    /// 소폭 수정됐으면 재앵커된 줄의 앞부분(본문 부분 문자열이라 exact 검색
    /// 가능)을 돌려준다. 실패는 nil.
    public static func resilientQuery(for quote: String, in body: String) -> String? {
        let cleaned = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return nil }
        // ① exact — 인용이 그대로 본문에 있다.
        if body.contains(cleaned) { return cleaned }
        // ② 접두 — 앞 12자만으로 한 번 더 (꼬리 수정 대응).
        let head = String(cleaned.prefix(12))
        if head.count >= 6, body.contains(head) { return head }
        // ③ 어절 지문 — 인용의 어절(2자 이상) 과반을 담은 첫 줄.
        let tokens = cleaned.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard tokens.count >= 2 else { return nil }
        let needed = max(2, (tokens.count + 1) / 2)
        var best: (line: Substring, hits: Int)?
        for line in body.split(separator: "\n") {
            guard line.count >= 4 else { continue }
            let hits = tokens.reduce(0) { $0 + (line.contains($1) ? 1 : 0) }
            if hits >= needed, hits > (best?.hits ?? 0) {
                best = (line, hits)
            }
        }
        guard let best else { return nil }
        let snippet = best.line.trimmingCharacters(in: .whitespaces).prefix(40)
        return snippet.count >= 2 ? String(snippet) : nil
    }
    // MARK: - 스니펫 추출기 통합 (이슈 #61 PR1)

    /// 오프셋 자리에서 검색 가능한 스니펫 — 마크다운 마커·공백을 건너뛰고 산문
    /// 한 토막(≤40 UTF-16)을 취한다. NarrativeView.jumpSnippet의 본체였던 것.
    public static func jumpSnippet(in body: String, atUTF16 offset: Int) -> String? {
        let ns = body as NSString
        var start = min(max(0, offset), ns.length)
        while start < ns.length,
            "#>*- \t\n".unicodeScalars.map({ UInt16($0.value) })
                .contains(ns.character(at: start))
        {
            start += 1
        }
        guard start < ns.length else { return nil }
        let end = min(start + 40, ns.length)
        var snippet = ns.substring(with: NSRange(location: start, length: end - start))
        if let newline = snippet.firstIndex(of: "\n") {
            snippet = String(snippet[..<newline])
        }
        snippet = snippet.trimmingCharacters(in: .whitespaces)
        return snippet.count >= 2 ? snippet : nil
    }

    /// 매치 주변 발췌 — 앞뒤 24자에 줄임표. SidebarView 검색 결과용이었던 것.
    public static func searchSnippet(_ body: String, query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
            let range = body.range(of: q, options: .caseInsensitive)
        else { return nil }
        let start =
            body.index(range.lowerBound, offsetBy: -24, limitedBy: body.startIndex)
            ?? body.startIndex
        let end =
            body.index(range.upperBound, offsetBy: 24, limitedBy: body.endIndex)
            ?? body.endIndex
        var text = String(body[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if start != body.startIndex { text = "…" + text }
        if end != body.endIndex { text += "…" }
        return text
    }
}
