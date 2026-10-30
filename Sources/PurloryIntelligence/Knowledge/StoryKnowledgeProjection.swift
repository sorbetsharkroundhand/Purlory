import Foundation
import CryptoKit

/// Adapts existing whole-scene inference without inventing time, confidence or writer authority.
public enum StoryKnowledgeProjection {
    public static func make(scope: StoryMemoryScope, body: String, outline: DocumentOutline,
                            sidecar: KnowledgeSidecar, characters: [CharacterCard], overrides: NarrativeOverrides = .empty) -> StoryKnowledgeSnapshot {
        let entities = StoryEntityResolver(characters: characters)
        var facts: [StoryFact] = []
        if sidecar.scope == scope, sidecar.schemaVersion == KnowledgeSidecar.currentSchemaVersion {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for scene in outline.scenes {
                if Task.isCancelled { facts.removeAll(); break }
                let range = NSRange(scene.utf16Range)
                guard let originalRange = Range(range, in: body),
                      DocumentOutline.stableHash(String(body[originalRange])) == scene.contentHash else { continue }
                func evidence(_ quote: String?) -> EvidenceAnchor? {
                    guard let quote, let match = SourceAnchor.uniqueOriginalRange(for: quote, in: body, within: range) else { return nil }
                    return .init(documentID: scope.documentID, sceneHash: scene.contentHash, quote: quote, utf16Hint: match.location)
                }
                func atom(_ content: StoryFact.Content, _ evidence: EvidenceAnchor, provider: String) -> StoryFact? {
                    let candidate = StoryFact(derivedID: "pending", scope: scope, content: content, evidence: evidence,
                        discourseRange: scene.utf16Range, origin: .model(providerID: provider))
                    guard candidate.isWellFormed, entities.accepts(content), let data = try? encoder.encode(candidate) else { return nil }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return .init(derivedID: "legacy:\(digest)", scope: scope, content: content, evidence: evidence,
                        discourseRange: scene.utf16Range, origin: candidate.origin)
                }
                for event in sidecar.events[scene.contentHash] ?? [] {
                    guard event.sceneHash == scene.contentHash,
                          overrides.value(.eventSummary, key: event.stableKey) == nil,
                          let anchor = evidence(event.quote),
                          let observation = atom(.event(summary: event.summary, participants: event.participants), anchor, provider: "legacy-scene-event") else { continue }
                    facts.append(observation)
                    for delta in event.deltas where delta.sceneHash == scene.contentHash {
                        if let value = atom(.characterState(.init(characterID: delta.characterID, field: delta.field, value: delta.value)),
                                            anchor, provider: "legacy-scene-event") { facts.append(value) }
                    }
                }
                if let insights = sidecar.insights[scene.contentHash] {
                    for delta in insights.knowledge where delta.sceneHash == scene.contentHash {
                        let stance: CharacterKnowledge.Stance
                        switch delta.stance {
                        case .knows: stance = .knows
                        case .suspects: stance = .suspects
                        case .misbelieves: stance = .misbelieves
                        case .hides: stance = .hides
                        }
                        if let anchor = evidence(delta.quote), let value = atom(
                            .characterKnowledge(.init(characterID: delta.characterID, fact: delta.fact, stance: stance)),
                            anchor, provider: "legacy-scene-insights") { facts.append(value) }
                    }
                    for delta in insights.relations where delta.sceneHash == scene.contentHash {
                        if let anchor = evidence(delta.quote), let value = atom(
                            .relationship(.init(fromID: delta.fromID, toID: delta.toID, value: delta.value)),
                            anchor, provider: "legacy-scene-insights") { facts.append(value) }
                    }
                }
            }
        }
        return .init(scope: scope, source: body, facts: facts, entities: entities)
    }
}
