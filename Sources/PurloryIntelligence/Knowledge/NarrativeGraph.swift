import Foundation

// Narrative Graph (v5, PLAN §6.6) — 씬 내부 서사 구간(Segment), 서사 흐름(Flow),
// 정본 사건(Canonical Event)과 관점(Perspective), 사건 인과(CausalLink),
// 시간 부분 순서(ChronoEdge)를 하나의 그래프로 묶는 공통 타입.
//
// 설계 원칙 (요구사항 §1–§6·§27):
// - **사건이 중심이다.** 브랜치가 사건을 소유하지 않는다 — 하나의 정본 사건을
//   여러 흐름(Main·인물·회상)이 참조한다. 분화·합류는 "같은 사건을 공유하는
//   흐름들"에서 결정적으로 파생되는 관계지, 별도 저장물이 아니다.
// - **파생 가능한 것은 저장하지 않는다** (CLAUDE.md §2-1). 흐름·합류점·레인은
//   스냅샷 조립 때 사건·참여자·구간에서 파생한다. 저장하는 것은 LLM 추출물
//   (구간·인과 후보·동일 사건 후보)과 사용자 수정뿐이다.
// - **persistent ID는 원문 앵커에서 나온다.** 재분석마다 UUID를 새로 만들지
//   않는다 — 구간은 시작 인용, 사건은 요약, 흐름은 인물 id·앵커 해시가 곧
//   식별자라, 원문이 유지되는 한 재분석 후에도 같은 ID가 나온다 (§27).

// MARK: - 서사 구간 (Narrative Segment, 요구사항 §8)

/// 씬 내부의 서사 구간 하나 — 씬 전체에 유형 하나를 붙이는 대신, 씬 안의
/// 현재→회상→회상 속 회상→복귀 구조를 구간 단위로 표현한다.
///
/// Scene과의 역할 구분 (요구사항 §32): Scene은 비교적 큰 장면 구조(헤딩·분할)
/// 이고, Segment는 그 안의 시간·관점 변화다. Segment는 항상 씬 하나에 속한다.
public struct NarrativeSegment: Codable, Equatable, Sendable, Identifiable {

    /// 서사 층 — 과거형 문장이 있다는 이유만으로 회상이 되지 않도록
    /// 회상의 결을 구분한다 (요구사항 §7). 닫힌 집합 — 소형 모델의 자유
    /// 서술을 막는다 (StateDelta.Field와 같은 규율).
    public enum Layer: String, Codable, Equatable, Sendable, CaseIterable {
        case present = "현재"
        /// 서술이 직접 과거로 이동한 회상 (짧든 길든 서술 주체가 과거에 있다).
        case flashback = "회상"
        /// 한두 문장의 짧은 기억 — 서술은 현재에 남아 있다.
        case briefMemory = "짧은기억"
        /// 인물이 다른 인물에게 말로 설명하는 과거 (구술 — 대사 안의 과거).
        case retelling = "구술"
        case dream = "꿈"
        /// 편지·일기·기록 속 과거.
        case document = "기록"
        /// 다른 POV에서 재구성된 과거, 같은 사건의 재서술.
        case renarration = "재서술"
        /// 과거 사건에 대한 단순 언급 — 회상이 아니다 (시간 이동 없음).
        case mention = "언급"
        case flashforward = "예상"
        /// 판단 불가 — 임의로 확정하지 않는다 (요구사항 §9).
        case uncertain = "불확실"

        /// LLM 출력·사용자 입력의 관대한 정규화 — 모르는 값은 uncertain.
        public static func normalize(_ raw: String) -> Layer {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = Layer(rawValue: cleaned) { return exact }
            if cleaned.contains("현재") { return .present }
            if cleaned.contains("꿈") { return .dream }
            if cleaned.contains("구술") || cleaned.contains("증언") || cleaned.contains("설명") {
                return .retelling
            }
            if cleaned.contains("기록") || cleaned.contains("편지") || cleaned.contains("일기") {
                return .document
            }
            if cleaned.contains("재서술") || cleaned.contains("재구성") { return .renarration }
            if cleaned.contains("언급") { return .mention }
            if cleaned.contains("짧은") { return .briefMemory }
            if cleaned.contains("회상") || cleaned.contains("과거") { return .flashback }
            if cleaned.contains("예상") || cleaned.contains("미래") { return .flashforward }
            return .uncertain
        }

        /// 이 층이 시간 이동(과거/미래 층)인가 — 언급·현재·불확실은 아니다.
        public var isTemporalShift: Bool {
            switch self {
            case .present, .mention, .uncertain: false
            case .flashback, .briefMemory, .retelling, .dream, .document,
                .renarration, .flashforward: true
            }
        }

        /// 작품 내 시간 관계 기본값.
        public var defaultChrono: ChronoRelation {
            switch self {
            case .present, .mention, .uncertain: .unknown
            case .flashback, .briefMemory, .retelling, .document, .renarration: .before
            case .dream: .approximate
            case .flashforward: .after
            }
        }
    }

    /// 회상 종료(복귀) 추적 상태 (요구사항 §9) — 종료를 못 찾았다고 임의로
    /// 씬 끝까지 회상으로 확정하지 않는다.
    public enum ReturnState: String, Codable, Equatable, Sendable {
        /// 복귀 지점이 원문에서 확인됨 (endQuote가 그 앵커).
        case found = "확인"
        /// 씬이 이 층인 채로 끝남 — 다음 씬에서 복귀 (씬 경계 = 자연 복귀).
        case sceneEnd = "씬끝"
        /// 판단 불가 — uncertain 유지 (요구사항 §9).
        case uncertain = "불확실"
    }

    /// 소속 씬 해시 — 씬이 재해시되면 인용 재앵커로 잇는다 (§27 reconciliation).
    public var sceneHash: String
    /// 씬-로컬 UTF-16 범위 — 씬 시작 기준 오프셋. 원문 이동·하이라이트용.
    public var localStart: Int
    public var localEnd: Int
    /// 구간 첫 문장 인용 (≤40자) — persistent ID·재앵커의 근원 (§27·§28).
    public var startQuote: String
    /// 복귀 직전(구간 끝) 인용 — ReturnState.found일 때만 신뢰.
    public var endQuote: String?
    public var layer: Layer
    /// 중첩 깊이 — 0 = 씬의 바탕 서사, 1 = 회상, 2 = 회상 속 회상 …
    public var depth: Int
    /// 부모 구간 ID (depth ≥ 1) — 회상 속 회상이 어느 회상에서 갈라졌는지.
    public var parentID: String?
    /// 복귀 대상 구간 ID — nil이면 부모(또는 씬 바탕)로 복귀.
    public var returnTargetID: String?
    public var returnState: ReturnState
    /// 작품 세계 시간 관계 (바탕 서사 기준).
    public var chrono: ChronoRelation
    /// 시점(POV) 인물 이름 — 등록 카드와 무관한 자유 문자열 (씬 메타와 동일 규격).
    public var pov: String?
    /// 서술자 — "1인칭 남편"·"3인칭 전지적" 등 (요구사항 §11).
    public var narrator: String?
    /// 초점 인물 (focal character) — 3인칭에서 카메라가 붙는 인물.
    public var focalCharacter: String?
    /// 이 구간이 어느 인물의 과거인가 — 인물 흐름(Flow) 연결의 재료.
    public var subjectCharacter: String?
    /// 과거 정보의 출처 (요구사항 §13).
    public var source: PerspectiveSource
    /// 신뢰 상태 (요구사항 §13).
    public var reliability: SourceReliability
    /// 분석 확신 0–1 — 낮으면 UI가 "불확실"로 표시한다.
    public var confidence: Double
    /// persistent ID (요구사항 §27) — 최초 분석 시 시작 인용에서 파생돼
    /// **저장**된다. 사용자가 경계(시작 인용)를 고쳐도 ID는 유지되므로 그 구간에
    /// 걸린 다른 오버라이드가 고아가 되지 않는다.
    public var persistentID: String

    public var id: String { persistentID }

    public init(
        sceneHash: String, localStart: Int, localEnd: Int,
        startQuote: String, endQuote: String? = nil,
        layer: Layer, depth: Int = 0, parentID: String? = nil,
        returnTargetID: String? = nil, returnState: ReturnState = .uncertain,
        chrono: ChronoRelation? = nil,
        pov: String? = nil, narrator: String? = nil,
        focalCharacter: String? = nil, subjectCharacter: String? = nil,
        source: PerspectiveSource = .directlyNarrated,
        reliability: SourceReliability = .unknown,
        confidence: Double = 0.5,
        persistentID: String? = nil
    ) {
        self.sceneHash = sceneHash
        self.localStart = localStart
        self.localEnd = localEnd
        self.startQuote = startQuote
        self.endQuote = endQuote
        self.layer = layer
        self.depth = depth
        self.parentID = parentID
        self.returnTargetID = returnTargetID
        self.returnState = returnState
        self.chrono = chrono ?? layer.defaultChrono
        self.pov = pov
        self.narrator = narrator
        self.focalCharacter = focalCharacter
        self.subjectCharacter = subjectCharacter
        self.source = source
        self.reliability = reliability
        self.confidence = confidence
        self.persistentID =
            persistentID ?? DocumentOutline.stableHash("seg|\(startQuote)|\(depth)")
    }
}

/// 과거 정보의 출처 종류 (요구사항 §13) — 과거를 객관적 사실로 가정하지 않는다.
public enum PerspectiveSource: String, Codable, Equatable, Sendable, CaseIterable {
    case directlyNarrated = "직접서술"
    case memory = "기억"
    case testimony = "증언"
    case document = "기록물"
    case rumor = "소문"
    case dream = "꿈속"
    case inference = "추론"

    public static func normalize(_ raw: String) -> PerspectiveSource {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = PerspectiveSource(rawValue: cleaned) { return exact }
        if cleaned.contains("기억") { return .memory }
        if cleaned.contains("증언") || cleaned.contains("말") { return .testimony }
        if cleaned.contains("기록") || cleaned.contains("편지") || cleaned.contains("일기") {
            return .document
        }
        if cleaned.contains("소문") { return .rumor }
        if cleaned.contains("꿈") { return .dream }
        if cleaned.contains("추론") || cleaned.contains("추정") { return .inference }
        return .directlyNarrated
    }

    /// 출처의 기본 신뢰 상태 — 사용자가 오버라이드로 고칠 수 있다.
    public var defaultReliability: SourceReliability {
        switch self {
        case .directlyNarrated: .confirmed
        case .document: .probable
        case .memory, .testimony: .probable
        case .rumor, .dream, .inference: .unreliable
        }
    }
}

/// 신뢰 상태 (요구사항 §13) — 서로 다른 기억을 강제로 하나의 사실로 병합하지
/// 않기 위한 축. disputed는 "다른 관점과 모순됨"의 표시다.
public enum SourceReliability: String, Codable, Equatable, Sendable, CaseIterable {
    case confirmed = "확정"
    case probable = "유력"
    case disputed = "이견"
    case unreliable = "불신"
    case unknown = "미상"

    public static func normalize(_ raw: String) -> SourceReliability {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = SourceReliability(rawValue: cleaned) { return exact }
        if cleaned.contains("확") { return .confirmed }
        if cleaned.contains("유력") || cleaned.contains("높") { return .probable }
        if cleaned.contains("이견") || cleaned.contains("논란") { return .disputed }
        if cleaned.contains("불신") || cleaned.contains("낮") { return .unreliable }
        return .unknown
    }
}

// MARK: - 사건 인과 (Causal Link, 요구사항 §6)

/// 두 사건 사이의 인과·서사 관계 하나 — 시간 순서와 별도로 관리한다.
/// AI는 후보만 제안하고 확정·무시는 사용자 오버라이드가 한다 (CLAUDE.md §1-5).
public struct CausalLink: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case causes = "원인"
        case influences = "영향"
        case reveals = "폭로"
        case explains = "설명"
        case contradicts = "모순"
        case foreshadows = "복선"
    }

    /// 출발 사건의 `StoryEvent.stableKey`.
    public var fromKey: String
    public var toKey: String
    public var kind: Kind
    /// ≤60자 — 왜 이 관계인지.
    public var reason: String

    public init(fromKey: String, toKey: String, kind: Kind, reason: String = "") {
        self.fromKey = fromKey
        self.toKey = toKey
        self.kind = kind
        self.reason = reason
    }

    /// 안정 키 — 같은 (종류, 방향 쌍)이면 재추출 후에도 같다.
    public var id: String {
        DocumentOutline.stableHash("link|\(kind.rawValue)|\(fromKey)|\(toKey)")
    }
}

// MARK: - 동일 사건 (Canonical Event Identity, 요구사항 §3·§12)

/// "이 사건들은 같은 사건이다"라는 판단 하나 — 정본(canonical) 키 하나에
/// 멤버 사건 키들이 붙는다. 사건 자체를 복제하지 않는다: 각 씬의 StoryEvent는
/// 그대로 두고(그것이 곧 그 씬 관점의 서술이다), 이 묶음이 관점들을 잇는다.
public struct EventIdentity: Codable, Equatable, Sendable, Identifiable {
    /// 정본 키 — 담화 순서상 첫 멤버의 stableKey (첫 등장 = 정본 위치).
    public var canonicalKey: String
    /// 멤버 사건 키들 (정본 포함, 담화 순서).
    public var memberKeys: [String]

    public init(canonicalKey: String, memberKeys: [String]) {
        self.canonicalKey = canonicalKey
        self.memberKeys = memberKeys
    }

    public var id: String { canonicalKey }
}

/// 정본 사건 하나의 관점 뷰 (파생 — 저장하지 않는다). 멤버 사건 + 그 씬의
/// 서사 맥락(구간 층·POV·출처)에서 조립된다. 서로 모순될 수 있고, AI가 하나를
/// 객관적 진실로 확정하지 않는다 (요구사항 §12).
public struct EventPerspective: Equatable, Sendable, Identifiable {
    public var eventKey: String
    public var sceneHash: String
    /// 이 관점의 시점 인물 (구간 POV → 씬 POV 순 폴백).
    public var viewpoint: String?
    public var source: PerspectiveSource
    public var reliability: SourceReliability
    /// 이 관점에서의 서술 (그 씬 StoryEvent의 요약).
    public var summary: String
    public var quote: String?
    /// 이 관점의 맥락이 된 서사 구간 ID — 조립이 viewpoint·source를 파생할 때
    /// 쓴 구간을 기록해 정본 사건 → Segment 역추적을 가능하게 한다 (통합 UI의
    /// 사건 상세가 Scene/Segment를 보여주는 근거). 파생 전용이라 저장 안 함.
    public var segmentID: String?

    public var id: String { eventKey }
}

/// 정본 사건 (파생) — 여러 흐름·여러 관점이 만나는 그래프의 노드.
public struct CanonicalEvent: Equatable, Sendable, Identifiable {
    public var canonicalKey: String
    /// 담화 순서상 첫 등장 씬 해시 (그래프 배치의 기준 위치).
    public var sceneHash: String
    /// 대표 요약 (정본 멤버의 요약).
    public var summary: String
    public var importance: Int
    /// 전체 관점의 참여 인물 합집합.
    public var participants: [UUID]
    /// 관점들 (담화 순서) — 1개면 단일 서술, 2개 이상이면 다중 관점 사건.
    public var perspectives: [EventPerspective]
    public var quote: String?

    public var id: String { canonicalKey }
}

// MARK: - 시간 부분 순서 (Chrono Partial Order, 요구사항 §29)

/// 두 앵커(씬 해시·사건 키·구간 ID) 사이의 상대 시간 관계 하나.
/// "a가 b보다 relation" — before면 a가 시간상 먼저다.
public struct ChronoEdge: Codable, Equatable, Sendable, Identifiable {
    public var aKey: String
    public var bKey: String
    public var relation: ChronoRelation

    public init(aKey: String, bKey: String, relation: ChronoRelation) {
        self.aKey = aKey
        self.bKey = bKey
        self.relation = relation
    }

    public var id: String { DocumentOutline.stableHash("chrono|\(aKey)|\(bKey)") }
}

/// 부분 순서 해석기 — 확실한 간선만으로 위상 정렬하고, 모순(사이클)은 Conflict로
/// 보고한다. 정보가 부족한 항목은 담화 순서를 유지한다 — 임의로 확정 연표를
/// 만들지 않는다 (요구사항 §29).
public enum ChronoOrder {

    /// 결과 — 정렬된 키 배열 + 모순 간선 쌍.
    public struct Resolution: Equatable, Sendable {
        /// 시간 순서 (부분 순서를 담화 순서로 보완한 안정 정렬).
        public var ordered: [String]
        /// 모순으로 판정된 간선들 (사이클에 참여) — UI가 Conflict로 표시.
        public var conflicts: [ChronoEdge]
    }

    /// `items`: 담화 순서의 키들 (안정 tie-break). `edges`: before/after만
    /// 순서 제약으로 쓰고, simultaneous는 같은 자리로, unknown·approximate는
    /// 제약 없음으로 둔다.
    public static func resolve(items: [String], edges: [ChronoEdge]) -> Resolution {
        let index = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { ($0.element, $0.offset) })
        // 방향 간선 정규화 — after(a,b)는 before(b,a)와 같다.
        var directed: [(from: String, to: String, edge: ChronoEdge)] = []
        for edge in edges {
            guard index[edge.aKey] != nil, index[edge.bKey] != nil else { continue }
            switch edge.relation {
            case .before: directed.append((edge.aKey, edge.bKey, edge))
            case .after: directed.append((edge.bKey, edge.aKey, edge))
            case .simultaneous, .unknown, .approximate: break
            }
        }

        // 사이클 감지 — 모순 간선을 골라내 제약에서 뺀다. 간선 하나씩 더하며
        // 사이클을 만드는 간선을 conflict로 분류한다 (결정적: 입력 순서).
        var successors: [String: Set<String>] = [:]
        var conflicts: [ChronoEdge] = []
        func reaches(_ from: String, _ target: String) -> Bool {
            var seen: Set<String> = []
            var queue = [from]
            while let current = queue.popLast() {
                guard seen.insert(current).inserted else { continue }
                if current == target { return true }
                queue.append(contentsOf: successors[current] ?? [])
            }
            return false
        }
        var accepted: [(from: String, to: String)] = []
        for (from, to, edge) in directed {
            if reaches(to, from) {
                conflicts.append(edge)
            } else {
                successors[from, default: []].insert(to)
                accepted.append((from, to))
            }
        }

        // Kahn 위상 정렬 — 후보가 여럿이면 담화 순서가 이긴다 (안정성).
        var indegree: [String: Int] = [:]
        for item in items { indegree[item] = 0 }
        for (_, to) in accepted { indegree[to, default: 0] += 1 }
        var ready = items.filter { indegree[$0] == 0 }  // 담화 순서 유지
        var ordered: [String] = []
        var remaining = accepted
        while let next = ready.first {
            ready.removeFirst()
            ordered.append(next)
            let outgoing = remaining.filter { $0.from == next }
            remaining.removeAll { $0.from == next }
            for (_, to) in outgoing {
                indegree[to]! -= 1
                if indegree[to] == 0 {
                    // 담화 순서 위치에 맞게 삽입 (안정 tie-break).
                    let position = ready.firstIndex { (index[$0] ?? 0) > (index[to] ?? 0) }
                    ready.insert(to, at: position ?? ready.count)
                }
            }
        }
        // 사이클로 남은 항목(이론상 conflict 분류로 없어야 함)은 담화 순서로 꼬리에.
        if ordered.count < items.count {
            let placed = Set(ordered)
            ordered.append(contentsOf: items.filter { !placed.contains($0) })
        }
        return Resolution(ordered: ordered, conflicts: conflicts)
    }
}

// MARK: - 서사 흐름 (Narrative Flow, 요구사항 §1·§2·§4·§5)

/// 서사 흐름 하나 — Main(독자가 따라가는 중심 흐름)·인물 흐름·시간(회상) 흐름.
/// **파생이다**: 사건 참여자·구간·씬 유형에서 스냅샷 조립 때 결정적으로 만든다.
/// 흐름이 사건을 소유하지 않는다 — eventKeys는 정본 사건 키의 참조 목록이고,
/// 같은 키가 여러 흐름에 나타나는 것이 곧 합류(공유 사건)다.
public struct NarrativeFlow: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// 독자가 따라가는 중심 흐름 — 주인공의 개인 타임라인이 아니다 (요구사항 §2).
        case main
        /// 등장인물 하나의 독립적인 사건 흐름.
        case character
        /// 회상·꿈 등 시간 이동 구간의 흐름 (씬/구간에서 파생).
        case temporal
    }

    /// persistent ID — main은 고정 문자열, 인물은 카드 UUID, 시간 흐름은
    /// 앵커 해시. 재분석 후에도 같은 값 → 색·레인이 안정된다 (요구사항 §24·§25).
    public var id: String
    public var kind: Kind
    public var name: String
    public var characterID: UUID?
    /// 이 흐름이 참조하는 정본 사건 키들 (담화 순서).
    public var eventKeys: [String]
    /// 시간 흐름일 때의 씬 구간 (아웃라인 인덱스).
    public var sceneRange: Range<Int>?
    public var chrono: ChronoRelation
    public var userEdited: Bool

    /// 안정 색 인덱스 — persistent ID의 해시. 팔레트 크기는 UI가 정한다.
    public var colorSeed: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int(hash % 997)
    }

    public init(
        id: String, kind: Kind, name: String, characterID: UUID? = nil,
        eventKeys: [String] = [], sceneRange: Range<Int>? = nil,
        chrono: ChronoRelation = .unknown, userEdited: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.characterID = characterID
        self.eventKeys = eventKeys
        self.sceneRange = sceneRange
        self.chrono = chrono
        self.userEdited = userEdited
    }

    public static let mainID = "flow-main"

    /// 흐름들 파생 — main + 인물 흐름 + 시간 흐름.
    ///
    /// - main: 정본 사건 전부 (담화 순서) — 독자가 따라가는 중심 흐름.
    /// - 인물: 그 인물이 참여한 정본 사건 2개 이상일 때만 (외톨이 사건 하나로
    ///   흐름을 만들면 그래프가 소음이 된다 — 품질 > 적극성).
    /// - 시간: 기존 NarrativeBranch(연속 비현재 씬 묶음)를 흐름으로 승격.
    ///
    /// 분화·합류·교차·공유는 별도 데이터가 아니라 **eventKeys의 교집합**이다:
    /// 두 흐름이 같은 키를 담으면 그 사건에서 만나고, 다음 키가 갈리면 분화한다.
    public static func derive(
        canonicalEvents: [CanonicalEvent],
        characters: [CharacterCard],
        branches: [NarrativeBranch],
        branchCharacterOverrides: [String: String] = [:],
        flowNameOverrides: [String: String] = [:]
    ) -> [NarrativeFlow] {
        var flows: [NarrativeFlow] = []
        let allKeys = canonicalEvents.map(\.canonicalKey)
        flows.append(
            NarrativeFlow(
                id: mainID, kind: .main,
                name: flowNameOverrides[mainID] ?? "본줄기",
                eventKeys: allKeys,
                chrono: .unknown,
                userEdited: flowNameOverrides[mainID] != nil))

        for card in characters {
            let keys = canonicalEvents
                .filter { $0.participants.contains(card.id) }
                .map(\.canonicalKey)
            guard keys.count >= 2 else { continue }
            let flowID = "flow-chr-\(card.id.uuidString)"
            flows.append(
                NarrativeFlow(
                    id: flowID, kind: .character,
                    name: flowNameOverrides[flowID] ?? card.name,
                    characterID: card.id,
                    eventKeys: keys,
                    chrono: .unknown,
                    userEdited: flowNameOverrides[flowID] != nil))
        }

        for branch in branches {
            let flowID = "flow-tmp-\(branch.anchorHash)"
            // 브랜치를 인물에 연결하는 오버라이드 — "남편의 과거" 같은 소속 표시.
            let linkedCharacter = branchCharacterOverrides[branch.anchorHash]
                .flatMap { raw in characters.first { $0.id.uuidString == raw }?.id }
            flows.append(
                NarrativeFlow(
                    id: flowID, kind: .temporal,
                    name: flowNameOverrides[flowID] ?? branch.name,
                    characterID: linkedCharacter,
                    sceneRange: branch.sceneRange,
                    chrono: branch.chrono,
                    userEdited: branch.userEdited || flowNameOverrides[flowID] != nil))
        }
        return flows
    }

    /// 두 흐름이 공유하는 사건 키들 (담화 순서) — 합류/교차점.
    public static func sharedEvents(_ a: NarrativeFlow, _ b: NarrativeFlow) -> [String] {
        let bKeys = Set(b.eventKeys)
        return a.eventKeys.filter { bKeys.contains($0) }
    }
}

// MARK: - 씬 구간 묶음 (사이드카 저장 단위)

/// 씬 하나의 구간 분석 결과 — 키 존재 = 분석 완료 메모 (events와 같은 규약).
/// 빈 배열 = "분석했고 씬 전체가 단일 현재 서사"다.
public struct SceneSegmentation: Codable, Equatable, Sendable {
    public var segments: [NarrativeSegment]
    public var updatedAt: Date

    public init(segments: [NarrativeSegment] = [], updatedAt: Date = .now) {
        self.segments = segments
        self.updatedAt = updatedAt
    }
}

// MARK: - 사건 그래프 분석 결과 (사이드카 저장 단위)

/// 깊은 패스의 사건 그래프 분석 결과 — 인과 후보·동일 사건 후보·시간 간선.
/// 메모 키 = 분석에 넣은 사건 집합의 결합 해시 (충돌 검사와 같은 규율).
public struct EventGraphAnalysis: Codable, Equatable, Sendable {
    public var causalLinks: [CausalLink]
    public var identities: [EventIdentity]
    public var chronoEdges: [ChronoEdge]
    /// 분석에 넣은 사건 키 결합 해시 — 같으면 재분석하지 않는다.
    public var memoHash: String
    public var updatedAt: Date

    public init(
        causalLinks: [CausalLink] = [], identities: [EventIdentity] = [],
        chronoEdges: [ChronoEdge] = [], memoHash: String = "", updatedAt: Date = .now
    ) {
        self.causalLinks = causalLinks
        self.identities = identities
        self.chronoEdges = chronoEdges
        self.memoHash = memoHash
        self.updatedAt = updatedAt
    }
}
