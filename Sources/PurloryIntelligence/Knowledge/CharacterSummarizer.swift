import Foundation

/// 인물 카드의 자동 이해 프레젠테이션 (이슈 #61 PR4 — 지식 로직의 자리, AGENTS §4).
///
/// CharacterBibleView가 그리던 열람 줄(상태·연대기·앎·관계·대화)을 만드는 **순수
/// 함수**들이다 — 뷰에서 지식 조립을 떼어 온 것. 입력은 스냅샷 값뿐이라 캐시 빌더
/// (#48)와 단위 테스트 양쪽에서 결정적으로 재생된다.
public enum CharacterSummarizer {
    /// 카드 하나에 대한 자동 이해 요약 (열람 전용, CLAUDE.md §1-5) — 프롬프트
    /// 카드 줄과 같은 질의(`stateAt`·`lastAppearance`·`speechProfile`)를 문서 끝
    /// 기준으로 접는다. 사용자가 보는 것과 예측이 아는 것이 같은 소스다.
    /// 순수 함수로 분리 — 캐시 빌더가 카드당 한 번만 부른다 (#48).
    package static func understanding(
        of characterID: UUID, snapshot: KnowledgeSnapshot
    ) -> [String] {
        var lines: [String] = []
        let state = snapshot.stateAt(of: characterID, before: .max)
        if !state.isEmpty {
            let rendered = StateDelta.Field.allCases
                .compactMap { field in state[field].map { "\(field.rawValue) \($0)" } }
                .joined(separator: " · ")
            lines.append("상태: \(rendered)")
        }
        if let recent = snapshot.lastAppearance(of: characterID, before: .max) {
            lines.append("최근: \(recent.summary)")
        }
        if let profile = snapshot.speechProfile(of: characterID, before: .max) {
            var speech: [String] = []
            if let base = profile.defaultPoliteness { speech.append("\(base.rawValue) 기본") }
            if let example = profile.examples.last { speech.append("\"\(example)\"") }
            if !speech.isEmpty { lines.append("말투: \(speech.joined(separator: " · "))") }
        }
        return lines
    }
    /// 인물 연대기 (M7, PLAN §14) — 그 인물이 겪은 사건과 상태 변화를 담화
    /// 순서로 편다. StateDelta가 append-only인 덕에 이 UI가 "공짜로" 나온다
    /// (PLAN §7 — 상태를 덮어썼다면 역사가 없어 연대기도 없다).
    package static func chronicle(
        of characterID: UUID, snapshot: KnowledgeSnapshot
    ) -> [String] {
        guard let offsets = snapshot.eventIndexByCharacter[characterID] else { return [] }
        return offsets.map { offset in
            let event = snapshot.events[offset]
            var line = event.summary
            let changes = event.deltas
                .filter { $0.characterID == characterID }
                .map { "\($0.field.rawValue) \($0.value)" }
            if !changes.isEmpty {
                line += " → \(changes.joined(separator: " · "))"
            }
            return line
        }
    }
    /// 인물의 앎 (v4, 요구사항 §11) — 문서 끝 기준으로 접은 현재 앎.
    /// (text, 점프 질의) — 질의는 근거 인용, 없으면 nil (추론).
    package static func knowledgeLines(
        of characterID: UUID, snapshot: KnowledgeSnapshot
    ) -> [(text: String, jump: String?)] {
        snapshot.knowledge(of: characterID, before: .max).map { delta in
            ("\(delta.stance.rawValue): \(delta.fact)", delta.quote)
        }
    }
    /// 인물이 얽힌 관계들의 변화 이력 (v4, 요구사항 §12) — 방향 쌍별로
    /// "남편→아내: 사랑 → 의심 → 적대" 한 줄.
    package static func relationLines(
        of characterID: UUID, snapshot: KnowledgeSnapshot, names: [UUID: String]
    ) -> [(text: String, jump: String?)] {
        // 방향 쌍별 그룹 (담화 순서 유지).
        var order: [String] = []
        var grouped: [String: [RelationDelta]] = [:]
        for delta in snapshot.relationDeltas
        where delta.fromID == characterID || delta.toID == characterID {
            let key = "\(delta.fromID.uuidString)>\(delta.toID.uuidString)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(delta)
        }
        return order.compactMap { key in
            guard let deltas = grouped[key], let first = deltas.first,
                let from = names[first.fromID], let to = names[first.toID]
            else { return nil }
            let evolution = deltas.map(\.value).joined(separator: " → ")
            return ("\(from)→\(to): \(evolution)", deltas.last?.quote)
        }
    }
    /// 인물의 대화 인덱스 (v4, 요구사항 §13) — 원문 복제 없이 위치 참조.
    /// 점프 질의 = 첫 대사 (본문 부분 문자열이라 그대로 검색된다).
    package static func conversationLines(
        of card: CharacterCard, snapshot: KnowledgeSnapshot, names: [UUID: String]
    ) -> [(text: String, jump: String?)] {
        snapshot.conversations(involving: card.id).map { conversation in
            let others = conversation.participants
                .filter { $0 != card.id }
                .compactMap { names[$0] }
            let with = others.isEmpty ? "" : " ↔ \(others.joined(separator: "·"))"
            let scene = conversation.sceneHash
                .flatMap { snapshot.sceneMetaByHash[$0]?.title }
                .map { "[\($0)] " } ?? ""
            // 기록된 대화 표식 + 백그라운드 보완 주제 (요구사항 §21).
            let recorded = conversation.recordedID != nil ? "📌 " : ""
            let topic = conversation.topic.map { " · \($0)" } ?? ""
            let count = conversation.utteranceCount > 0 ? " · 발화 \(conversation.utteranceCount)" : ""
            return (
                "\(recorded)\(scene)\(card.name)\(with)\(count)\(topic) — “\(conversation.firstLine)”",
                conversation.firstLine
            )
        }
    }
}
