import Foundation

/// A derived candidate; production visibility requires verified original evidence.
public struct ConsistencyWarning: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case deadSpeaker = "죽은 인물 발화"
        case honorificBreak = "말투 붕괴"
    }

    public var kind: Kind
    public var characterID: UUID
    /// 문제가 감지된 본문 위치 (UTF-16).
    public var utf16Position: Int
    /// 사용자에게 보여줄 한 줄 설명 — 단정이 아니라 확인 요청의 어조.
    public var message: String
    public var evidence: [EvidenceAnchor] = []
    public var sourceRevision: String? = nil

    public var id: String { "\(kind.rawValue)-\(characterID.uuidString)-\(utf16Position)" }
}

/// Deterministic, non-mutating consistency checks. Production uses the captured-source
/// overload so only original-backed, non-shifted candidates can reach presentation.
/// Legacy detection remains for compatibility; it never grants visibility by itself.
public enum ConsistencyChecker {

    /// 존대 붕괴 판정에 필요한 최소 선행 발화 수 — 두어 번의 우연으로
    /// "확립됐다"고 단정하지 않는다.
    package static let minEstablishedUtterances = 3

    /// 생사 델타 값에서 사망을 읽는 닫힌 규칙 — "죽을 뻔했다" 같은 서술을
    /// 사망으로 오판하지 않게 보수적으로 잡는다.
    package static func isDead(_ vitality: String) -> Bool {
        ["사망", "사고로 사망", "죽음", "죽었다", "죽었음"].contains(vitality.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Legacy unverified detector; production must use the captured-source overload.
    /// 스냅샷 전체 검사 — 발화 수에 선형. 스냅샷 발행 시 백그라운드에서 한 번
    /// 돌고 결과만 UI로 간다 (키 입력·렌더 경로에서 재계산 금지).
    public static func check(
        snapshot: KnowledgeSnapshot, characters: [CharacterCard]
    ) -> [ConsistencyWarning] {
        let names = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.name) })
        var warnings: [ConsistencyWarning] = []

        // ① 죽은 인물 발화 — 발화 시점 이전의 생사 fold가 사망이면 경고.
        // 시점 차단(fold가 커서 이전만 접는 것)이 그대로 "죽기 전 발화는 정상,
        // 죽은 뒤 발화만 경고"를 만든다. 인물당 첫 건만 — 같은 문제의 반복
        // 경고는 소음이다.
        var deadReported: Set<UUID> = []
        for utterance in snapshot.utterances {
            guard !deadReported.contains(utterance.speakerID) else { continue }
            let state = snapshot.stateAt(of: utterance.speakerID, before: utterance.utf16Start)
            guard let vitality = state[.vitality], isDead(vitality) else { continue }
            deadReported.insert(utterance.speakerID)
            let name = names[utterance.speakerID] ?? "등장인물"
            warnings.append(
                ConsistencyWarning(
                    kind: .deadSpeaker,
                    characterID: utterance.speakerID,
                    utf16Position: utterance.utf16Start,
                    message: "\(name)이(가) '\(vitality)' 상태로 기록된 뒤에 대사가 있어요 — 회상이 아니라면 확인해 보세요"))
        }

        // ② 존대 붕괴 — (화자→청자) 쌍에서 같은 존대가 3회 이상 이어진 뒤
        // 반대 존대가 나오면 경고. 쌍당 첫 건만 — 반말 트기(의도적 전환)면
        // 그 뒤는 새 관계다.
        struct PairKey: Hashable { let speaker: UUID; let listener: UUID }
        var streak: [PairKey: (politeness: Politeness, count: Int)] = [:]
        var breakReported: Set<PairKey> = []
        for utterance in snapshot.utterances {
            guard let listener = utterance.listenerID,
                let politeness = utterance.politeness
            else { continue }
            let key = PairKey(speaker: utterance.speakerID, listener: listener)
            if let current = streak[key] {
                if current.politeness == politeness {
                    streak[key] = (politeness, current.count + 1)
                } else {
                    if current.count >= minEstablishedUtterances,
                        !breakReported.contains(key)
                    {
                        breakReported.insert(key)
                        let speaker = names[utterance.speakerID] ?? "등장인물"
                        let target = names[listener] ?? "상대"
                        warnings.append(
                            ConsistencyWarning(
                                kind: .honorificBreak,
                                characterID: utterance.speakerID,
                                utf16Position: utterance.utf16Start,
                                message: "\(speaker)이(가) \(target)에게 \(current.politeness.rawValue)을 쓰다 \(politeness.rawValue)로 바뀌었어요 — 의도한 변화가 아니라면 확인해 보세요"))
                    }
                    streak[key] = (politeness, 1)  // 전환 후는 새 확립의 시작
                }
            } else {
                streak[key] = (politeness, 1)
            }
        }

        return warnings.sorted { $0.utf16Position < $1.utf16Position }
    }
}
