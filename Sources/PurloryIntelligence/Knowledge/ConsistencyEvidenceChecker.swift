import Foundation

extension ConsistencyChecker {
    /// Production visibility gate. All work uses the captured original, outside prediction.
    public static func check(snapshot: KnowledgeSnapshot, characters: [CharacterCard], source: String) -> [ConsistencyWarning] {
        guard !Task.isCancelled, DocumentOutline.parse(source) == snapshot.outline else { return [] }
        let resolver = StoryEntityResolver(characters: characters)
        let names = Dictionary(grouping: characters, by: \.id).compactMapValues { copies -> String? in
            guard copies.count == 1, let card = copies.first, resolver.character(named: card.name) == card.id else { return nil }
            return card.name
        }
        let context = ConsistencyOriginal(snapshot: snapshot, source: source, names: names)
        var warnings: [ConsistencyWarning] = [], deadReported: Set<UUID> = []
        struct Pair: Hashable { let speaker: UUID; let listener: UUID }
        var streaks: [Pair: (Politeness, [EvidenceAnchor])] = [:], reported: Set<Pair> = []
        var seenSpeech: Set<Int> = []
        for utterance in snapshot.utterances.sorted(by: { $0.utf16Start < $1.utf16Start }) {
            guard !Task.isCancelled else { return [] }
            guard seenSpeech.insert(utterance.utf16Start).inserted else { continue }
            let speaker = utterance.speakerID
            guard let name = names[speaker],
                  let speech = context.speech(utterance) else {
                streaks = streaks.filter { $0.key.speaker != speaker }
                continue
            }
            if !deadReported.contains(speaker), let death = context.death(of: speaker, before: utterance.utf16Start) {
                deadReported.insert(speaker)
                warnings.append(.init(kind: .deadSpeaker, characterID: speaker, utf16Position: utterance.utf16Start,
                    message: "\(name)이(가) 사망 상태로 기록된 뒤에 대사가 있어요 — 의도한 장면인지 확인해 보세요",
                    evidence: [death, speech], sourceRevision: context.revision))
            }
            guard let listener = utterance.listenerID, listener != speaker, let target = names[listener],
                  let politeness = utterance.politeness, politeness == DialogueAttribution.politeness(of: utterance.text) else {
                streaks = streaks.filter { $0.key.speaker != speaker }
                continue
            }
            let pair = Pair(speaker: speaker, listener: listener)
            if let (previous, anchors) = streaks[pair], previous != politeness {
                if anchors.count == minEstablishedUtterances, reported.insert(pair).inserted {
                    warnings.append(.init(kind: .honorificBreak, characterID: speaker, utf16Position: utterance.utf16Start,
                        message: "\(name)이(가) \(target)에게 \(previous.rawValue)을 쓰다 \(politeness.rawValue)로 바뀌었어요 — 의도한 변화인지 확인해 보세요",
                        evidence: anchors + [speech], sourceRevision: context.revision))
                }
                streaks[pair] = (politeness, [speech])
            } else {
                streaks[pair] = (politeness, Array(((streaks[pair]?.1 ?? []) + [speech]).suffix(minEstablishedUtterances)))
            }
        }
        guard !Task.isCancelled else { return [] }
        return warnings.sorted {
            $0.utf16Position == $1.utf16Position ? $0.kind.rawValue < $1.kind.rawValue : $0.utf16Position < $1.utf16Position
        }
    }
}

private struct ConsistencyOriginal {
    package let snapshot: KnowledgeSnapshot
    package let source: String
    package let revision: String
    package let length: Int
    private var vitality: [UUID: [(end: Int, proof: EvidenceAnchor?)]] = [:]
    package init(snapshot: KnowledgeSnapshot, source: String, names: [UUID: String]) {
        self.snapshot = snapshot; self.source = source; revision = DocumentOutline.stableHash(source); length = source.utf16.count
        let events = Dictionary(grouping: snapshot.events, by: \.sceneHash)
        for scene in snapshot.outline.scenes {
            if Task.isCancelled { return }
            guard snapshot.sceneMetaByHash[scene.contentHash]?.type == .present else { continue }
            var assertions: [UUID: [(String, EvidenceAnchor?)]] = [:]
            for event in events[scene.contentHash] ?? [] {
                let quote = event.quote.flatMap { SourceAnchor.uniqueOriginalRange(for: $0, in: source, within: NSRange(scene.utf16Range)) }
                if let quote, !eligible(quote, scene: scene) { continue }
                let proof = event.quote.flatMap { anchor($0, range: NSRange(scene.utf16Range), scene: scene) }
                for delta in event.deltas where delta.field == .vitality && delta.sceneHash == scene.contentHash {
                    guard let name = names[delta.characterID] else { continue }
                    let affirmed = proof.map { Self.affirmativeDeath($0.quote, name: name) } == true
                    assertions[delta.characterID, default: []].append((delta.value, affirmed ? proof : nil))
                }
            }
            for (character, values) in assertions {
                // A newer unproven/competing assertion retires old authority; absence proves nothing.
                let proof = values.allSatisfy { ConsistencyChecker.isDead($0.0) && $0.1 != nil } ? values.first?.1 : nil
                vitality[character, default: []].append((scene.utf16Range.upperBound, proof))
            }
        }
    }
    private static func affirmativeDeath(_ quote: String, name: String) -> Bool {
        let original = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["은 ", "는 ", "이 ", "가 "].contains { particle in
            ["사망했다", "사고로 사망했다", "죽었다"].contains { verb in
                original == name + particle + verb || original == name + particle + verb + "."
            }
        }
    }
    private func eligible(_ range: NSRange, scene: DocumentOutline.Scene) -> Bool {
        guard snapshot.sceneMetaByHash[scene.contentHash]?.type == .present else { return false }
        let length = scene.utf16Range.count
        for segment in snapshot.segmentsByScene[scene.contentHash] ?? [] {
            guard segment.localStart >= 0, segment.localEnd >= segment.localStart, segment.localEnd <= length else { return false }
            let bounds = NSRange(location: scene.utf16Range.lowerBound + segment.localStart, length: segment.localEnd - segment.localStart)
            if NSIntersectionRange(bounds, range).length > 0, segment.layer != .present { return false }
        }
        return true
    }
    private func anchor(_ quote: String, range: NSRange, scene: DocumentOutline.Scene) -> EvidenceAnchor? {
        guard let match = SourceAnchor.uniqueOriginalRange(for: quote, in: source, within: range),
              eligible(match, scene: scene) else { return nil }
        return .init(documentID: .init(rawValue: snapshot.entryID), sceneHash: scene.contentHash, quote: quote, utf16Hint: match.location)
    }
    package func speech(_ utterance: Utterance) -> EvidenceAnchor? {
        let start = utterance.utf16Start, count = utterance.text.utf16.count
        guard start >= 0, start <= length, count > 0, count <= length - start,
              let scene = snapshot.outline.scenes.first(where: { $0.utf16Range.lowerBound <= start && start + count <= $0.utf16Range.upperBound }) else { return nil }
        return anchor(utterance.text, range: .init(location: start, length: count), scene: scene)
    }
    package func death(of character: UUID, before: Int) -> EvidenceAnchor? {
        let records = vitality[character] ?? []
        var low = 0, high = records.count
        while low < high {
            let mid = low + (high - low) / 2
            if records[mid].end <= before { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? records[low - 1].proof : nil
    }
}

extension ConsistencyWarning {
    /// Exact originals only. Legacy unverified candidates cannot grant navigation.
    public func sourcePosition(in source: String, documentID: WritingDocumentID) -> Int? {
        guard let sourceRevision, !evidence.isEmpty else { return nil }
        let current = DocumentOutline.stableHash(source), length = source.utf16.count
        for anchor in evidence {
            guard anchor.documentID == documentID else { return nil }
            let range: NSRange
            if current == sourceRevision, let hint = anchor.utf16Hint, hint >= 0, hint <= length,
               anchor.quote.utf16.count <= length - hint {
                range = .init(location: hint, length: anchor.quote.utf16.count)
            } else { range = .init(location: 0, length: length) }
            guard SourceAnchor.uniqueOriginalRange(for: anchor.quote, in: source, within: range) != nil else { return nil }
        }
        guard let target = evidence.last,
              let match = SourceAnchor.uniqueOriginalRange(for: target.quote, in: source, within: .init(location: 0, length: length)) else { return nil }
        // The legacy editor query uses a case-insensitive first match; never grant a different target.
        let first = (source as NSString).range(of: target.quote, options: .caseInsensitive)
        guard first == match else { return nil }
        return match.location
    }
}
