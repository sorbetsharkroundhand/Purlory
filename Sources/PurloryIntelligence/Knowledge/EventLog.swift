import Foundation

/// 사건 로그 (PLAN §6.3) — append-only. 설계 근거는 docs/m6-events.md.
///
/// **앵커는 Pos가 아니라 씬 콘텐츠 해시다.** PLAN §6.3 스키마의 `pos`를 그대로
/// 저장하지 않는 이유: 씬 배열 인덱스(Pos v1)는 씬이 하나 삽입되면 뒤가 전부
/// 밀려, append-only 로그가 삽입마다 전체 재기록을 요구하게 된다. 해시는 원문에
/// 매여 있어 삽입에 불변이고, Pos는 질의 시점에 아웃라인 순서에서 파생한다.
/// 덤으로 PLAN §8 "편집 무효화 규칙"의 톰스톤이 기존 GC(`save(pruningTo:)`)에
/// 그대로 얹힌다 — 블록이 바뀌면 해시가 고아가 되고 자동으로 청소된다.
public struct StoryEvent: Codable, Equatable, Sendable {
    /// 이 사건이 일어난 씬의 `DocumentOutline.Scene.contentHash`.
    public var sceneHash: String
    /// 참여 인물 — **등록된 `CharacterCard.id`만** 담는다. 미등록 이름은 링크하지
    /// 않는다 (자동 등록 금지, CLAUDE.md §3). 등록 시점에 이름 매칭으로 소급 연결.
    public var participants: [UUID]
    /// ≤80자 (PLAN §6.3).
    public var summary: String
    /// 1–5 — B 블록 예산이 모자랄 때 버리는 순서를 정한다 (PLAN §11).
    public var importance: Int
    /// 상태 효과 (PLAN §6.3 `상태 효과 [StateDelta 참조]`) — 사건 추출이 같은
    /// 줄의 `상태:` 필드에서 함께 채운다 (5b, docs/m6-events.md).
    public var deltas: [StateDelta]
    /// 근거 인용 (≤60자) — 이 사건 판단의 원문 앵커. 씬 원문에서 검증 실패한
    /// 인용은 저장하지 않는다 (nil = 추론 근거, EvidenceKind.inferred).
    public var quote: String?
    public var updatedAt: Date

    public init(
        sceneHash: String, participants: [UUID], summary: String,
        importance: Int, deltas: [StateDelta] = [], quote: String? = nil,
        updatedAt: Date = .now
    ) {
        self.sceneHash = sceneHash
        self.participants = participants
        self.summary = summary
        self.importance = importance
        self.deltas = deltas
        self.quote = quote
        self.updatedAt = updatedAt
    }

    /// 사용자 수정(중요도·요약 오버라이드)의 안정 키 — 요약문 해시라 씬이
    /// 재해시돼도 같은 요약이면 살아남는다. 요약이 바뀌면 오버라이드는 stale.
    public var stableKey: String { DocumentOutline.stableHash("evt|\(summary)") }

    public var evidenceKind: EvidenceKind { quote == nil ? .inferred : .direct }
}

/// 인물 상태 변화 한 조각 (PLAN §6.2) — 상태는 덮어쓰지 않고 append하며,
/// `state_at(pos)`(`KnowledgeSnapshot.stateAt`)가 pos 이하 델타를 접어
/// 그 시점 상태를 만든다.
public struct StateDelta: Codable, Equatable, Sendable {
    /// 닫힌 필드 집합 — 소형 모델의 자유 서술을 막는 장치 (docs/m6-events.md 5b).
    public enum Field: String, Codable, Equatable, Sendable, CaseIterable {
        case location = "위치"
        case emotion = "감정"
        case relation = "관계"
        case goal = "목표"
        case vitality = "생사"
    }

    public var characterID: UUID
    public var field: Field
    /// ≤40자.
    public var value: String
    /// 근거 앵커 — 이 델타를 만든 씬의 콘텐츠 해시.
    public var sceneHash: String

    public init(characterID: UUID, field: Field, value: String, sceneHash: String) {
        self.characterID = characterID
        self.field = field
        self.value = value
        self.sceneHash = sceneHash
    }
}

// MARK: - 추출 결과 파싱 (결정적 — CLAUDE.md §2-5)

/// LLM 사건 추출 출력의 파서·검증기.
///
/// 소형 모델의 JSON은 깨진다(중괄호 누락·트레일링 콤마) — 요약 경로가 평문 +
/// 결정적 clamp를 쓰는 것과 같은 규율로 줄 형식을 쓴다 (docs/m6-events.md 결정 4).
/// **파싱은 관대하게, 검증은 엄격하게**: 환각 인물은 등록 카드 매칭에서 탈락한다.
public enum EventParser {

    /// 사건 요약 상한 (PLAN §6.3).
    package static let maxSummaryCharacters = 80
    /// 씬 하나에서 받아들이는 사건 수 상한 — 모델이 문장마다 사건을 만들면
    /// B 블록 예산이 한 씬에 잠식된다 (품질 > 적극성, CLAUDE.md §1-2).
    package static let maxEventsPerScene = 3
    /// 델타 값 상한 (PLAN §6.2 `value ≤40자`).
    package static let maxDeltaValueCharacters = 40
    /// 사건 하나가 만드는 델타 수 상한 — 모델이 문장마다 상태를 갱신하면
    /// 진짜 변화가 소음에 묻힌다 (사건 상한과 같은 품질 > 적극성 규율).
    package static let maxDeltasPerEvent = 4

    /// 인물 이름·별칭 → 카드 id. 조립기와 같은 별칭 규격(쉼표 구분)을 쓴다.
    public static func nameIndex(_ cards: [CharacterCard]) -> [String: UUID] {
        var index: [String: UUID] = [:]
        for card in cards {
            let name = card.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            index[name] = card.id
            for alias in card.aliases.split(separator: ",") {
                let key = alias.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { index[key] = card.id }
            }
        }
        return index
    }

    /// 근거 인용 상한 — 짧아야 본문 검색 앵커로 안정적이다 (개행 없는 한 구절).
    package static let maxQuoteCharacters = 60

    /// 모델 출력 → 검증된 사건 배열.
    ///
    /// 기대 형식 (한 줄에 사건 하나):
    /// ```
    /// 서연이 병원에서 퇴원했다 | 참여: 서연, 민준 | 중요도: 3 | 근거: "…"
    /// ```
    /// 형식을 벗어난 줄은 조용히 버린다 — 한 줄도 못 건지면 빈 배열이고,
    /// 호출부는 "사건 없음"으로 기록한다 (다음 패스가 재시도하지 않도록).
    /// `sceneText`가 주어지면 근거 인용을 원문 대조로 검증한다 — 원문에 없는
    /// 인용(환각)은 버리고 추론 근거(nil)로 강등한다.
    public static func parse(
        _ output: String, sceneHash: String, nameIndex: [String: UUID],
        sceneText: String? = nil
    ) -> [StoryEvent] {
        var events: [StoryEvent] = []
        var seenKeys: Set<String> = []
        for rawLine in output.split(separator: "\n") {
            guard events.count < maxEventsPerScene else { break }
            let line = stripListMarker(rawLine.trimmingCharacters(in: .whitespaces))
            // **구분자 없는 줄은 버린다.** 모델의 머리말("다음은 사건입니다:")이
            // 사건으로 저장되면 B 블록에 지식인 척 주입된다 — 형식을 지킨 줄에는
            // 항상 `|`가 있으므로, 이 한 줄이 머리말을 구조적으로 막는다.
            // 형식을 벗어난 진짜 사건을 놓치는 비용은 받는다 (CLAUDE.md §1-2
            // 품질 > 적극성 — 확신이 없으면 침묵이 정답).
            guard line.contains("|") else { continue }
            let fields = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let head = fields.first, !head.isEmpty else { continue }

            let summary = String(head.prefix(maxSummaryCharacters))
            // 요약이라기엔 너무 짧은 토막은 사건이 아니다.
            guard summary.count >= 4 else { continue }

            var participants: [UUID] = []
            var importance = 3  // 표기가 없거나 깨졌으면 중간값
            var deltas: [StateDelta] = []
            var quote: String?
            for field in fields.dropFirst() {
                if let value = value(of: field, keys: ["참여", "인물"]) {
                    participants = resolve(value, nameIndex: nameIndex)
                } else if let value = value(of: field, keys: ["중요도", "중요"]) {
                    importance = min(5, max(1, Int(value.filter(\.isNumber)) ?? 3))
                } else if let value = value(of: field, keys: ["상태", "상태변화"]) {
                    deltas = parseDeltas(value, sceneHash: sceneHash, nameIndex: nameIndex)
                } else if let value = value(of: field, keys: ["근거", "인용"]) {
                    quote = validatedQuote(value, in: sceneText)
                }
            }
            // 상태가 바뀐 인물은 그 사건의 참여자다 — 델타만 있고 참여 표기가
            // 빠진 사건도 역색인(§6.3)에 걸려야 `state_at`이 그 인물을 찾는다.
            let holders = deltas.map(\.characterID).filter { !participants.contains($0) }
            let event = StoryEvent(
                sceneHash: sceneHash, participants: participants + holders,
                summary: summary, importance: importance, deltas: deltas,
                quote: quote)
            // 양자화 모델이 같은 사건 줄을 반복해도 정본 후보는 하나다
            // (PLAN §6.3·§6.6). 첫 출력만 남겨 순서와 근거를 안정화한다.
            guard seenKeys.insert(event.stableKey).inserted else { continue }
            events.append(event)
        }
        return events
    }

    /// 근거 인용 검증 — 따옴표를 벗기고 상한으로 자른 뒤, 씬 원문에 실제로
    /// 존재할 때만 받는다 (환각 인용은 점프 앵커로 쓸 수 없다 — 없느니만 못하다).
    /// `sceneText`가 nil이면(검증 불가 컨텍스트) 형식 정리만 하고 받아들인다.
    package static func validatedQuote(_ raw: String, in sceneText: String?) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespaces)
        let wrappers: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "「", "」", "『", "』"]
        while let first = cleaned.first, wrappers.contains(first) {
            cleaned.removeFirst()
        }
        while let last = cleaned.last, wrappers.contains(last) {
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard cleaned.count >= 4 else { return nil }
        // 상한 초과 인용은 앞부분만 — 접두가 원문에 있으면 앵커로 충분하다.
        cleaned = String(cleaned.prefix(maxQuoteCharacters))
        if let sceneText, !sceneText.contains(cleaned) {
            // 모델이 끝을 다듬었을 수 있다 — 앞 20자만으로 한 번 더.
            let head = String(cleaned.prefix(20))
            return sceneText.contains(head) ? head : nil
        }
        return cleaned
    }

    /// 모델이 붙이는 목록 기호만 벗긴다 — `- `·`* `·`• `·`1. `·`2) `.
    ///
    /// ⚠️ 선두 문자를 뭉뚱그려 버리면(`drop(while: "-*•0123456789. ")`) 숫자로
    /// 시작하는 **본문을 먹는다** — 실제 원고에서 "33번지 18가구…"가 "번지
    /// 18가구…"로 저장된 것을 확인했다 (이상 「날개」). 숫자 불릿은 뒤에
    /// `. `·`) `가 따라올 때만 불릿이다.
    package static func stripListMarker(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "-*•".contains(first) {
            return String(line.dropFirst().drop(while: { $0 == " " }))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return line }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return line }
        let after = rest.dropFirst()
        // "1." 뒤에 공백이 있어야 불릿 — "3.5초 만에"·"1930년"은 본문이다.
        guard after.first == " " else { return line }
        return String(after.drop(while: { $0 == " " }))
    }

    /// `상태:` 필드 원문 → 검증된 델타들 (5b, docs/m6-events.md).
    ///
    /// 기대 형식 — `;` 구분 조각들, 조각 하나가 델타 하나:
    /// ```
    /// 상태: 서연 위치=병원 앞; 민준 감정=불안
    /// ```
    /// 사건과 같은 규율(파싱은 관대, 검증은 엄격)로:
    /// - 이름은 등록 카드 매칭 실패 시 조각째 버린다 (환각 인물 차단).
    /// - 필드는 **닫힌 집합**(위치·감정·관계·목표·생사) 밖이면 버린다 —
    ///   소형 모델의 자유 서술("서연 기분=…")이 상태 스키마를 오염시키지 않는다.
    /// - 값은 40자 clamp. 못 읽는 조각은 조용히 버린다 — 한 조각의 실패가
    ///   사건 전체를 죽이지 않는다 (실패 격리, 결정 3과 같은 이유).
    package static func parseDeltas(
        _ raw: String, sceneHash: String, nameIndex: [String: UUID]
    ) -> [StateDelta] {
        var deltas: [StateDelta] = []
        // 모델이 `;` 대신 `,`를 쓰는 경우까지 받아준다 — 값에 쉼표가 든 델타는
        // 앞이 잘리지만, 값은 짧은 명사구(≤40자)라 비용이 작다.
        for fragment in raw.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            guard deltas.count < maxDeltasPerEvent else { break }
            let piece = fragment.trimmingCharacters(in: .whitespaces)
            guard let equals = piece.firstIndex(of: "=") else { continue }

            // `=` 왼쪽은 "이름 필드" — 마지막 공백 토큰이 필드, 앞이 이름이다.
            let head = piece[..<equals].trimmingCharacters(in: .whitespaces)
            guard let split = head.lastIndex(of: " ") else { continue }
            let name = head[..<split].trimmingCharacters(in: .whitespaces)
            let fieldName = head[head.index(after: split)...]
                .trimmingCharacters(in: .whitespaces)

            guard let field = StateDelta.Field(rawValue: fieldName) else { continue }
            guard let id = resolveOne(name, nameIndex: nameIndex) else { continue }
            let value = String(
                piece[piece.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(maxDeltaValueCharacters))
            guard !value.isEmpty else { continue }
            deltas.append(
                StateDelta(characterID: id, field: field, value: value, sceneHash: sceneHash))
        }
        return deltas
    }

    /// `키: 값` 조각에서 값만 — 키가 목록에 없으면 nil.
    private static func value(of field: String, keys: [String]) -> String? {
        guard let separator = field.firstIndex(of: ":") else { return nil }
        let key = field[..<separator].trimmingCharacters(in: .whitespaces)
        guard keys.contains(key) else { return nil }
        return field[field.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
    }

    /// 이름 목록 → 카드 id. **등록 카드에 없는 이름은 버린다** — 모델이 지어낸
    /// 인물이 사건에 들어오는 것을 막는 유일한 관문 (docs/m6-events.md 결정 2).
    private static func resolve(_ names: String, nameIndex: [String: UUID]) -> [UUID] {
        var ids: [UUID] = []
        for raw in names.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let id = resolveOne(name, nameIndex: nameIndex)
            else { continue }
            ids.append(id)
        }
        return Array(Set(ids))  // 같은 인물 중복 표기 제거
    }

    /// 이름 하나 → 카드 id. 모델이 조사를 붙여 오는 경우("서연이")까지 받아준다 —
    /// 등록 이름이 접두인 매칭. 감지기(CharacterLexicon)와 같은 교착어 대응.
    package static func resolveOne(
        _ name: any StringProtocol, nameIndex: [String: UUID]
    ) -> UUID? {
        let key = String(name)
        if let id = nameIndex[key] { return id }
        return nameIndex.first(where: { key.hasPrefix($0.key) })?.value
    }
}

// MARK: - 심화 추출 파싱 (앎·관계 — PLAN §6.5)

/// 심화 추출 출력의 파서 — EventParser와 같은 규율 (파싱은 관대, 검증은 엄격).
///
/// 기대 형식 (한 줄에 항목 하나, 머리 키워드가 종류를 정한다):
/// ```
/// 앎: 아내 의심=남편이 약을 바꿨다 | 근거: "…"
/// 관계: 남편→아내=의심과 통제 | 근거: "…"
/// ```
public enum InsightParser {

    package static let maxFactCharacters = 60
    /// 씬 하나에서 받는 항목 수 상한 (종류별) — 소음 방지 (품질 > 적극성).
    package static let maxItemsPerKind = 4

    public static func parse(
        _ output: String, sceneHash: String, nameIndex: [String: UUID],
        sceneText: String? = nil
    ) -> SceneInsights {
        var insights = SceneInsights()
        for rawLine in output.split(separator: "\n") {
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyword = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...]
            // `| 근거:` 분리 — 본문에 `|`가 들어간 항목은 앞이 잘리지만 값이
            // 짧은 명사구라 비용이 작다 (parseDeltas의 쉼표와 같은 트레이드오프).
            let fields = rest.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let head = fields.first, let equals = head.firstIndex(of: "=") else {
                continue
            }
            let lhs = head[..<equals].trimmingCharacters(in: .whitespaces)
            let rhs = head[head.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !lhs.isEmpty, !rhs.isEmpty else { continue }
            var quote: String?
            for field in fields.dropFirst() {
                if let colon2 = field.firstIndex(of: ":"),
                    ["근거", "인용"].contains(
                        field[..<colon2].trimmingCharacters(in: .whitespaces))
                {
                    quote = EventParser.validatedQuote(
                        String(field[field.index(after: colon2)...]), in: sceneText)
                }
            }

            switch keyword {
            case "앎", "지식", "인지":
                guard insights.knowledge.count < maxItemsPerKind else { continue }
                // lhs = "이름 태도" — 마지막 공백 토큰이 태도 (parseDeltas와 동형).
                guard let split = lhs.lastIndex(of: " ") else { continue }
                let name = lhs[..<split].trimmingCharacters(in: .whitespaces)
                let stanceName = lhs[lhs.index(after: split)...]
                    .trimmingCharacters(in: .whitespaces)
                guard let stance = KnowledgeDelta.Stance(rawValue: stanceName),
                    let id = EventParser.resolveOne(name, nameIndex: nameIndex)
                else { continue }
                insights.knowledge.append(
                    KnowledgeDelta(
                        characterID: id, stance: stance,
                        fact: String(rhs.prefix(maxFactCharacters)),
                        sceneHash: sceneHash, quote: quote))
            case "관계":
                guard insights.relations.count < maxItemsPerKind else { continue }
                // lhs = "A→B" (→·->·> 허용).
                let pair = lhs
                    .replacingOccurrences(of: "->", with: "→")
                    .replacingOccurrences(of: ">", with: "→")
                    .split(separator: "→")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2,
                    let from = EventParser.resolveOne(pair[0], nameIndex: nameIndex),
                    let to = EventParser.resolveOne(pair[1], nameIndex: nameIndex),
                    from != to
                else { continue }
                insights.relations.append(
                    RelationDelta(
                        fromID: from, toID: to,
                        value: String(rhs.prefix(EventParser.maxDeltaValueCharacters)),
                        sceneHash: sceneHash, quote: quote))
            default:
                continue
            }
        }
        return insights
    }
}
