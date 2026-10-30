import Foundation

extension ContextAssembler {
    package static func assembleRaw(
        prefix: String, prefixStartUTF16: Int, style: PromptStyle,
        mode: GhostContextMode, counter: TokenCounter?, budget: Int?,
        document: DocumentContext?, knowledge: KnowledgeSnapshot?,
        originalNameAnchors: OriginalNameAnchorIndex?
    ) -> (prompt: AssembledPrompt, report: ContextReport) {
        var window = String(prefix.suffix(12_000))
        func prompt(_ text: String, quote: String? = nil) -> AssembledPrompt {
            let evidence = quote.map { "[이전 원문]\n" + $0 + "\n\n" } ?? ""
            switch style {
            case .continuation: return .continuation(evidence + text)
            case .instruct: return .instruct(system: instructSystem, user: evidence + instructUser(prefix: text))
            }
        }
        func cost(_ text: String, counter: TokenCounter, quote: String? = nil) -> Int {
            counter.count(prompt(text, quote: quote))
        }
        if let counter {
            let limit = max(0, budget ?? defaultPromptTokenBudget)
            while !window.isEmpty, cost(window, counter: counter) > limit {
                window = rawSuffixTrimmed(window)
            }
        }
        let end = max(0, prefixStartUTF16) + prefix.utf16.count
        var report = ContextReport(items: [], contextMode: mode,
            rawUTF16Range: (end - window.utf16.count)..<end)
        let controls = Controls(knowledge)
        if mode == .rawWithNameAnchor, document?.kind == .novel,
            let index = originalNameAnchors, index.documentID == document?.entryID,
            let anchor = index.latest(in: window, startingAt: end - window.utf16.count),
            controls.allows(anchor.stableKey),
            counter.map({ cost(window, counter: $0, quote: anchor.evidence.quote)
                <= max(0, budget ?? defaultPromptTokenBudget) }) ?? true {
            report.items.append(.init(kind: .originalNameAnchor, text: anchor.evidence.quote,
                jumpQuery: anchor.evidence.quote, jumpUTF16: anchor.evidence.utf16Hint,
                stableKey: anchor.stableKey, pinned: controls.pinned(anchor.stableKey),
                evidence: anchor.evidence))
            return (prompt(window, quote: anchor.evidence.quote), report)
        }
        return (prompt(window), report)
    }

    /// Prefer a word boundary, but always make progress for unbroken input.
    /// String indices preserve grapheme clusters; source ranges use UTF-16.
    package static func rawSuffixTrimmed(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let keep = Int(Double(text.count) * 0.8)
        guard keep > 0 else { return "" }
        let cut = text.index(text.endIndex, offsetBy: -keep)
        if let boundary = text[cut...].firstIndex(where: { $0.isWhitespace }) {
            let next = text.index(after: boundary)
            if next < text.endIndex { return String(text[next...]) }
        }
        return String(text[cut...])
    }
}
