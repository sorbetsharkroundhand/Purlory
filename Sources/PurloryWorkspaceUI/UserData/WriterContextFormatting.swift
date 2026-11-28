import Foundation

/// Human-readable formatting for writer context-exclusion override keys.
enum WriterContextFormatting {
    static func readableExclusion(_ key: String) -> String {
        let parts = key.split(separator: "|").map(String.init)
        let kindLabel =
            parts.first.map { kind -> String in
                switch kind {
                case "scene": return "장면"
                case "chapter": return "장"
                case "card": return "인물"
                case "state": return "상태"
                case "knowledge": return "앎"
                case "recent": return "최근 사건"
                case "flow": return "흐름 사건"
                case "work": return "지난 줄거리"
                case "current": return "지금 장면"
                case "cohort": return "장면 인물"
                case "narrative": return "서사 위치"
                case "dialogue": return "대화"
                case "relation": return "관계"
                case "meta": return "문서 정보"
                default: return kind
                }
            } ?? "항목"
        let tail = parts.count >= 2 ? String(parts[1].prefix(6)) : ""
        return tail.isEmpty ? kindLabel : "\(kindLabel)(\(tail))"
    }
}
