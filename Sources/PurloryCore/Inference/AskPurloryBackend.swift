import Foundation

extension AskAnswerGeneration {
    static func local(engine: CompletionEngine, packet: AskEvidencePacket, question: String, parameters: CompletionParameters) throws -> Self {
        let user = try packet.userMessage(question: question)
        return Self { emit in
            try await engine.streamInstructionIfReady(system: AskEvidencePacket.systemMessage, user: user, parameters: parameters, onChunk: emit)
        }
    }
}
