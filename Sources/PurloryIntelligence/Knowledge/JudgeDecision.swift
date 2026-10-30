import Foundation

/// A complete validated response; explanation prose cannot create evidence actions.
package struct JudgeDecision: Equatable, Sendable {
    package enum Verdict: String, Codable, Sendable { case conflict, intentionalPossible, insufficientEvidence, noConflict }
    package enum Failure: Error { case invalidResponse }
    package let packetID: UUID
    package let candidateID: String
    package let verdict: Verdict
    package let confidence: Double
    package let explanation: String
    package let evidence: [EvidenceAnchor]
    package var visibleConflict: Bool { verdict == .conflict && confidence >= 0.8 }
    private struct Wire: Decodable {
        let packet: String
        let verdict: Verdict
        let confidence: Double
        let explanation: String
        let citations: [Int]
    }
    private init(packet: JudgeEvidencePacket, wire: Wire) {
        packetID = packet.id; candidateID = packet.candidateID; verdict = wire.verdict; confidence = wire.confidence
        explanation = wire.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        evidence = wire.citations.map { packet.evidence[$0 - 1] }
    }
    package static func decode(_ raw: String, packet: JudgeEvidencePacket) throws -> Self {
        guard raw.utf16.count <= 4096 else { throw Failure.invalidResponse }
        let bytes = Array(raw.utf8)
        guard try rootKeys(bytes) == Set(["packet", "verdict", "confidence", "explanation", "citations"]) else { throw Failure.invalidResponse }
        let wire = try JSONDecoder().decode(Wire.self, from: Data(bytes))
        guard wire.packet == packet.id.uuidString, wire.confidence.isFinite, (0...1).contains(wire.confidence),
              !wire.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, wire.explanation.utf16.count <= 500,
              wire.explanation.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }),
              Set(wire.citations).count == wire.citations.count,
              wire.citations.allSatisfy({ (1...packet.evidence.count).contains($0) }),
              wire.verdict != .conflict || wire.citations.count == packet.evidence.count else { throw Failure.invalidResponse }
        return .init(packet: packet, wire: wire)
    }

    /// Foundation collapses duplicate JSON keys. Inspect root key tokens before typed decoding,
    /// decoding escaped key spellings too; the typed decoder validates the entire JSON grammar.
    private static func rootKeys(_ bytes: [UInt8]) throws -> Set<String> {
        var depth = 0, inString = false, escaped = false, expectsKey = false
        var keyStart: Int?, keys: Set<String> = []
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 {
                    inString = false
                    if let start = keyStart {
                        let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                        guard keys.insert(key).inserted else { throw Failure.invalidResponse }
                        keyStart = nil; expectsKey = false
                    }
                }
            } else {
                switch byte {
                case 34:
                    inString = true
                    keyStart = depth == 1 && expectsKey ? index : nil
                case 123, 91:
                    depth += 1
                    if depth == 1 { expectsKey = true }
                case 125, 93: depth -= 1
                case 44: if depth == 1 { expectsKey = true }
                default: break
                }
            }
        }
        guard !inString, depth == 0 else { throw Failure.invalidResponse }
        return keys
    }
}
