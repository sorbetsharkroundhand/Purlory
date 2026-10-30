import Foundation

struct AskAnswerCitation: Equatable, Sendable {
    let sourceID: String
    let quote: String
    let evidence: EvidenceAnchor
}
struct AskAnswerBlock: Equatable, Sendable {
    let packetID: UUID
    let text: String
    let citations: [AskAnswerCitation]
}
struct AskAnswerDecoder {
    enum Failure: Error { case invalidResponse, limitReached, closed }
    private(set) var blocks: [AskAnswerBlock] = []
    private(set) var isInsufficient = false
    private let packet: AskEvidencePacket
    private var buffer = ""
    private var bufferedUnits = 0
    private var totalUnits = 0
    private var closed = false
    init(packet: AskEvidencePacket) { self.packet = packet }

    /// Only complete validated records publish. On error, blocks retains the valid prefix.
    mutating func append(_ chunk: String) throws -> [AskAnswerBlock] {
        guard !closed else { throw Failure.closed }
        let previous = blocks.count
        do {
            for scalar in chunk.unicodeScalars {
                let units = scalar.value > 0xffff ? 2 : 1
                guard totalUnits <= 65536 - units else { throw Failure.limitReached }
                totalUnits += units
                if scalar == "\n" {
                    try consumeLine(); buffer = ""; bufferedUnits = 0
                } else {
                    guard bufferedUnits <= 8192 - units else { throw Failure.limitReached }
                    buffer.unicodeScalars.append(scalar); bufferedUnits += units
                }
            }
            return Array(blocks.dropFirst(previous))
        } catch { closed = true; buffer = ""; throw error }
    }
    mutating func finish() throws -> [AskAnswerBlock] {
        guard !closed else { throw Failure.closed }
        let previous = blocks.count
        defer { closed = true; buffer = "" }
        try consumeLine()
        guard !blocks.isEmpty || isInsufficient else { throw Failure.invalidResponse }
        return Array(blocks.dropFirst(previous))
    }
    private struct Record: Decodable {
        struct Citation: Decodable { let source: String; let quote: String }
        let text: String
        let citations: [Citation]
    }
    private mutating func consumeLine() throws {
        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        guard !isInsufficient, let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        if Set(object.keys) == ["status"], object["status"] as? String == "insufficient" {
            isInsufficient = true; return
        }
        guard Set(object.keys) == ["text", "citations"], blocks.count < 20,
              let rawCitations = object["citations"] as? [[String: Any]],
              rawCitations.allSatisfy({ Set($0.keys) == ["source", "quote"] }) else { throw Failure.invalidResponse }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.text.utf16.count <= 2000,
              (1...4).contains(record.citations.count), Set(record.citations.map(\.source)).count == record.citations.count else { throw Failure.invalidResponse }
        var citations: [AskAnswerCitation] = []
        for citation in record.citations {
            guard !citation.quote.isEmpty, citation.quote.utf16.count <= 1024,
                  let source = packet.sources.first(where: { $0.id == citation.source }),
                  SourceAnchor.uniqueOriginalRange(for: citation.quote, in: source.hit.evidence.quote,
                    within: NSRange(location: 0, length: source.hit.evidence.quote.utf16.count)) != nil else { throw Failure.invalidResponse }
            citations.append(.init(sourceID: source.id, quote: citation.quote, evidence: source.hit.evidence))
        }
        let markers = try NSRegularExpression(pattern: #"\[\^?(S[0-9]+)\]"#)
        let text = record.text as NSString, ids = Set(citations.map(\.sourceID))
        guard markers.matches(in: record.text, range: NSRange(location: 0, length: text.length)).allSatisfy({
            ids.contains(text.substring(with: $0.range(at: 1)))
        }) else { throw Failure.invalidResponse }
        blocks.append(.init(packetID: packet.id, text: record.text, citations: citations))
    }
}
