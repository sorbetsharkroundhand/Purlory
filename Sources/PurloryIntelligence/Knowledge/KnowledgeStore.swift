import Foundation

/// 작품별 지식 사이드카 (PLAN §6 저장 형식) — 요약 피라미드의 디스크 형태.
///
/// `~/Documents/Purlory/knowledge/<entryID>.json`. **전체가 파생 캐시다** —
/// 스키마가 바뀌면 `schemaVersion`을 올리고, 버전이 다른 파일은 버리고
/// 재구축한다. 마이그레이션 코드를 쌓지 않는다 (CLAUDE.md §2-1).
///
/// 소유자는 `BackgroundIndexer` 하나뿐이다 — 읽기·쓰기가 인덱서의 단일
/// 태스크 안에서만 일어나므로 actor 격리가 필요 없다. 예측 경로는 이 파일을
/// 절대 읽지 않는다 — 인덱서가 발행한 인메모리 `KnowledgeSnapshot`만 쓴다
/// (예측 시점 디스크 접근 금지, CLAUDE.md §2-2).
public struct KnowledgeSidecar: Codable, Equatable, Sendable {

    /// 지식 스키마 버전 — 구조가 바뀌면 올린다. 다른 버전 파일은 로드 시 폐기.
    /// v2 (M6-5a): 사건 로그 추가. v3 (M6-5b): 사건 추출이 StateDelta까지 뽑는다 —
    /// 디코딩 모양은 같지만 `events` 메모의 **의미**가 바뀌었다 (키 존재 = 델타
    /// 포함 추출 완료). v2 파일을 살리면 5a 시절 사건들이 델타 없이 영영 남아
    /// `상태@커서`에 구멍이 뚫린다 — 폐기·재구축이 정답이다 (CLAUDE.md §2-1,
    /// 마이그레이션 코드를 쌓지 않는 값. 결정 5가 피하려던 두 번째 비용이지만,
    /// 추출 형식 자체가 바뀌어 피할 수 없었다 — docs/m6-events.md 5b).
    /// v4 (Narrative Intelligence): 씬 분석이 제목·유형·시점·장소를 함께 뽑고
    /// (`SceneSummary` 확장), 심화 추출(`insights`)이 붙었다. **사용자 수정은
    /// 여기 없다** — entries.json의 NarrativeOverride에 살므로 이 폐기·재구축이
    /// 사용자 데이터를 건드리지 않는다.
    /// v5 (Narrative Graph): 씬 내부 구간 분석(`segments`)·사건 그래프(인과·
    /// 동일 사건·시간 간선, `eventGraph`)·기록 대화 보완(`conversationMeta`)이
    /// 붙었다. v4 파일은 폐기·재구축 (마이그레이션 코드를 쌓지 않는다, §2-1).
    /// v6 (Plot Thread): 플롯 스레드 추론(`plotThreads`)이 붙었다 — 그래프의
    /// branch 단위가 인물이 아니라 플롯이 됐다 (PLAN §6.6).
    /// v7: 설정 충돌·복선 기능을 제거했다 — `insights`에서 사실·복선 필드,
    /// 사이드카의 `factConflicts`가 빠졌다. v6 파일은 폐기·재구축.
    /// v8: stable project/document scope를 저장해 프로젝트 sidecar 혼입을 막는다.
    public static let currentSchemaVersion = 8

    /// 씬 요약 노드 (PLAN §6.1) — 앵커는 씬 원문의 콘텐츠 해시.
    /// 해시가 같으면 재요약 금지 (백그라운드 3요건의 메모이제이션, CLAUDE.md §4).
    public struct SceneSummary: Codable, Equatable, Sendable {
        /// `DocumentOutline.Scene.contentHash` — 씬 원문 SHA-256 앞 16자.
        public var contentHash: String
        /// 요약 당시의 헤딩 경로 — B 블록 렌더링용 (해시가 키, 경로는 표시용).
        public var headingPath: [String]
        /// 1–2문장, ≤120자 (PLAN §6.1).
        public var summary: String
        /// 내용 기반 씬 제목 (≤24자, v4) — "날개 (1/22)" 대신 "아내의 외출과
        /// 남편의 불안". 없으면(구 분석) UI가 헤딩 경로로 폴백.
        public var title: String?
        /// 서사 유형 원문 (v4) — SceneNarrativeType.normalize로 해석한다.
        public var narrativeType: String?
        /// 시점(POV) 인물 이름 (v4) — 등록 카드와 무관한 자유 문자열.
        public var pov: String?
        /// 장소 (v4).
        public var location: String?
        public var updatedAt: Date

        public init(
            contentHash: String, headingPath: [String], summary: String,
            title: String? = nil, narrativeType: String? = nil,
            pov: String? = nil, location: String? = nil, updatedAt: Date = .now
        ) {
            self.contentHash = contentHash
            self.headingPath = headingPath
            self.summary = summary
            self.title = title
            self.narrativeType = narrativeType
            self.pov = pov
            self.location = location
            self.updatedAt = updatedAt
        }
    }

    /// 장 요약 노드 — 앵커는 하위 씬 해시들의 결합 해시.
    /// 하위 씬이 하나라도 바뀌면 키가 바뀌어 자연히 더티가 된다 (상향 전파).
    public struct ChapterSummary: Codable, Equatable, Sendable {
        /// 장을 여는 레벨 1–2 헤딩 경로 (예: ["1부", "3장"]).
        public var headingPath: [String]
        /// 하위 씬 contentHash들을 이어 붙인 문자열의 해시 — 더티 판정 키.
        public var childrenHash: String
        /// ≤300자 (PLAN §6.1).
        public var summary: String
        public var updatedAt: Date
        package init(headingPath: [String], childrenHash: String, summary: String, updatedAt: Date) {
            self.headingPath = headingPath; self.childrenHash = childrenHash
            self.summary = summary; self.updatedAt = updatedAt
        }
    }

    /// 작품 요약 — 앵커는 장(또는 씬 전체) 해시들의 결합 해시. ≤500자.
    public struct WorkSummary: Codable, Equatable, Sendable {
        public var childrenHash: String
        public var summary: String
        public var updatedAt: Date
        package init(childrenHash: String, summary: String, updatedAt: Date) {
            self.childrenHash = childrenHash; self.summary = summary; self.updatedAt = updatedAt
        }
    }

    public var schemaVersion: Int
    /// 지식 세대 — 전체 재구축(캐시 비우기)마다 증가. 디버깅·벤치 대조용.
    public var generation: Int
    public var scope: StoryMemoryScope
    /// Compatibility bridge for legacy consumers while #118 moves editor ownership to projects.
    public var entryID: UUID { scope.documentID.rawValue }
    /// 씬 해시 → 요약. 현재 아웃라인에 없는 해시도 다음 저장까지는 남겨 둔다 —
    /// 타이핑 중 해시가 요동칠 때(문장 하나 지웠다 복원) 재요약을 아낀다.
    public var sceneSummaries: [String: SceneSummary]
    public var chapterSummaries: [ChapterSummary]
    public var workSummary: WorkSummary?
    /// 씬 해시 → 그 씬의 사건들 (PLAN §6.3, M6-5).
    ///
    /// **키 존재 자체가 메모다** — 빈 배열은 "추출했고 사건이 없었다"이고 키
    /// 부재는 "아직 안 뽑았다"다. 이 구분이 없으면 사건 없는 씬을 깊은 패스마다
    /// 다시 뽑는다 (CLAUDE.md §4 메모이제이션).
    public var events: [String: [StoryEvent]]
    /// 씬 해시 → 심화 추출 (앎·관계, v4) — events와 같은 메모 규약.
    public var insights: [String: SceneInsights]
    /// 씬 해시 → 서사 구간 분석 (v5, 요구사항 §8) — events와 같은 메모 규약
    /// (키 존재 = 분석 완료, 빈 배열 = 단일 현재 서사).
    public var segments: [String: SceneSegmentation]
    /// 사건 그래프 분석 (v5, 요구사항 §3·§6·§12·§29) — 인과·동일 사건·시간 간선.
    public var eventGraph: EventGraphAnalysis?
    /// 플롯 스레드 추론 (v6) — Narrative Graph의 branch 단위.
    public var plotThreads: PlotThreadAnalysis?
    /// 기록된 대화 보완 (v5, 요구사항 §19) — 키 = RecordedConversation.id.
    public var conversationMeta: [String: ConversationMeta]

    public init(scope: StoryMemoryScope) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generation = 0
        self.scope = scope
        self.sceneSummaries = [:]
        self.chapterSummaries = []
        self.workSummary = nil
        self.events = [:]
        self.insights = [:]
        self.segments = [:]
        self.eventGraph = nil
        self.plotThreads = nil
        self.conversationMeta = [:]
    }

    public init(entryID: UUID) {
        self.init(scope: .legacy(documentID: WritingDocumentID(rawValue: entryID)))
    }

    // MARK: - 디스크 IO (인덱서 전용)

    /// `~/Documents/Purlory/knowledge/` — 없으면 만든다.
    package static func directory(storageLocation: PurloryStorageLocation = .standard) -> URL {
        let dir = storageLocation.knowledgeDirectory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    package static func fileURL(for entryID: UUID, storageLocation: PurloryStorageLocation = .standard) -> URL {
        directory(storageLocation: storageLocation).appendingPathComponent("\(entryID.uuidString).json")
    }

    /// 로드 — 파일이 없거나, 못 읽거나, **스키마 버전이 다르면** 빈 사이드카.
    /// 파생 캐시라 버리는 것이 곧 복구다 (CLAUDE.md §5-5).
    public static func load(entryID: UUID, storageLocation: PurloryStorageLocation = .standard) -> KnowledgeSidecar {
        let scope = StoryMemoryScope.legacy(documentID: WritingDocumentID(rawValue: entryID))
        let url = fileURL(for: entryID, storageLocation: storageLocation)
        guard let data = try? Data(contentsOf: url) else {
            return KnowledgeSidecar(scope: scope)
        }
        return decoded(data, for: scope)
    }

    /// 버전 불일치 파일에서 세대 카운터만 건져 재구축 이력을 잇는다.
    package struct GenerationPeek: Codable { var generation: Int }

    package static func decoded(_ data: Data, for scope: StoryMemoryScope) -> KnowledgeSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sidecar = try? decoder.decode(KnowledgeSidecar.self, from: data),
            sidecar.schemaVersion == currentSchemaVersion,
            sidecar.scope == scope
        else {
            var fresh = KnowledgeSidecar(scope: scope)
            fresh.generation =
                ((try? decoder.decode(GenerationPeek.self, from: data))?.generation ?? 0) + 1
            return fresh
        }
        return sidecar
    }

    /// 저장 (원자적 쓰기). 현재 아웃라인에 없는 씬 요약·사건은 여기서 정리한다 —
    /// 저장 시점이 곧 가비지 컬렉션이라 별도 청소 경로가 없다.
    ///
    /// 사건에는 이 정리가 곧 PLAN §8의 **톰스톤**이다: 블록이 수정되면 씬 해시가
    /// 바뀌어 그 씬의 사건이 고아가 되고, 여기서 사라진 뒤 다음 깊은 패스가
    /// 새 해시로 재추출한다. 무효화 전용 코드가 따로 없는 이유다.
    public func save(pruningTo liveHashes: Set<String>? = nil, storageLocation: PurloryStorageLocation = .standard) {
        guard case .legacy = scope, let data = try? encoded(pruningTo: liveHashes) else { return }
        try? data.write(to: Self.fileURL(for: entryID, storageLocation: storageLocation), options: .atomic)
    }

    package func encoded(pruningTo liveHashes: Set<String>? = nil) throws -> Data {
        var snapshot = self
        if let liveHashes {
            snapshot.sceneSummaries = snapshot.sceneSummaries.filter {
                liveHashes.contains($0.key)
            }
            snapshot.events = snapshot.events.filter { liveHashes.contains($0.key) }
            snapshot.insights = snapshot.insights.filter { liveHashes.contains($0.key) }
            snapshot.segments = snapshot.segments.filter { liveHashes.contains($0.key) }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// 저널 삭제 시 사이드카도 지운다 (원문이 사라지면 파생물도 무의미).
    public static func remove(entryID: UUID, storageLocation: PurloryStorageLocation = .standard) {
        try? FileManager.default.removeItem(at: fileURL(for: entryID, storageLocation: storageLocation))
    }
}

/// 예측 조립이 읽는 인메모리 지식 스냅샷 (PLAN §11) — 인덱서가 패스를 마칠
/// 때마다 발행하는 **값 복사본**. MainActor(컨트롤러)가 pull해 격리 경계를
/// 넘긴다 (`DocumentContext`와 같은 패턴). 예측 경로에서 디스크·LLM을 건드리지
/// 않기 위한 유일한 통로다 (CLAUDE.md §2-2).
public struct KnowledgeSnapshot: Sendable, Equatable {
    public let entryID: UUID
    /// 스냅샷을 만든 시점의 아웃라인 — 씬 위치(utf16Range)로 시점 차단 질의를 한다.
    /// 이후의 타이핑으로 실제 본문과 어긋날 수 있다 — 오차는 다음 패스(유휴 ~5s)가
    /// 잡고, B 블록은 창 밖(커서에서 먼) 씬만 쓰므로 어긋남의 영향이 작다.
    public let outline: DocumentOutline
    /// 씬 콘텐츠 해시 → 요약문.
    public let summariesByHash: [String: String]
    /// 헤딩 경로("1부 > 3장" 조인 키) → 장 요약문.
    public let chapterSummariesByPath: [String: String]
    public let workSummary: String?
    /// Fresh, scope-bound hierarchy used for retrieval routing and evidence drill-down.
    /// Event/state arrays remain on this snapshot and are not duplicated here.
    public let storyMemory: StoryMemorySnapshot?
    /// Source-verified atomic observations prepared by the existing background reader.
    public let storyKnowledge: StoryKnowledgeSnapshot?
    /// 담화 순서(Pos = 씬 배열 인덱스)로 정렬된 사건들 (PLAN §6.3).
    /// 아웃라인에 없는 해시(톰스톤)는 여기서 이미 빠져 있다.
    public let events: [StoryEvent]
    /// 인물 id → `events` 인덱스 목록 — PLAN §6.3의 역색인.
    /// §11 엔티티 앵커 검색의 기반이자 `lastAppearance` 질의의 실체다.
    public let eventIndexByCharacter: [UUID: [Int]]
    /// 귀속된 발화들 (담화 순서, PLAN §6.4·§7 대화 귀속) — 결정적 추출이라
    /// 사이드카에 저장하지 않고 패스마다 재계산해 스냅샷에만 싣는다.
    public let utterances: [Utterance]
    /// 씬 해시 → 그 씬이 끝나는 UTF-16 위치. 시점 차단 질의를 예측 경로에서
    /// O(1)로 하기 위해 미리 접어 둔다 (조립은 조립만 — CLAUDE.md §2-2).
    private let sceneEndByHash: [String: Int]

    // MARK: Narrative Intelligence (v4, PLAN §6.5)

    /// 씬 해시 → 씬 메타 (제목·유형·시점·장소) — **오버라이드 적용 후** 값.
    public let sceneMetaByHash: [String: SceneMeta]
    /// 서사 브랜치 (담화 순서) — 씬 유형에서 결정적으로 파생.
    public let branches: [NarrativeBranch]
    /// 대화 인덱스 (담화 순서) — 발화에서 결정적으로 파생.
    public let conversations: [Conversation]
    /// 앎 델타 (담화 순서) — `knowledge(of:before:)`가 접는다.
    public let knowledgeDeltas: [KnowledgeDelta]
    /// 관계 델타 (담화 순서).
    public let relationDeltas: [RelationDelta]
    /// 재앵커에 실패한 사용자 수정 — UI가 "근거를 잃은 수정"으로 보여준다.
    public let staleOverrides: [NarrativeOverride]
    /// 스냅샷에 적용된 오버라이드 — UI의 userEdited 표시가 이걸 본다.
    public let overrides: NarrativeOverrides

    // MARK: Narrative Graph (v5, PLAN §6.6)

    /// 씬 해시 → 서사 구간들 (오버라이드 적용 후, 구간 시작 위치 순).
    public let segmentsByScene: [String: [NarrativeSegment]]
    /// 정본 사건들 (담화 순서) — 동일 사건 묶음 적용 후. 그래프의 노드.
    public let canonicalEvents: [CanonicalEvent]
    /// 사건 키(멤버) → 정본 키.
    public let canonicalKeyByMember: [String: String]
    /// 인과 관계 (사용자 추가/삭제 적용 후).
    public let causalLinks: [CausalLink]
    /// 서사 흐름들 — main + 인물 + 시간 (담화 순서 파생). **그래프 레인이
    /// 아니다** — 예측 컨텍스트(ContextAssembler의 위치 판정)용 파생물이다.
    public let flows: [NarrativeFlow]
    /// 플롯 스레드들 (v6) — Narrative Graph의 branch 단위 (본줄기 포함,
    /// 오버라이드·상태 파생 적용 후).
    public let plotThreads: [ResolvedPlotThread]
    /// 정본 사건 키 → 속한 스레드 ID들 (plotThreads 순서).
    public let threadIDsByEvent: [String: [String]]
    /// 정본 사건의 시간 순서 (부분 순서 해석 결과).
    public let eventChronoOrder: [String]
    /// 시간 관계 모순 간선들 — UI가 Conflict로 표시한다 (요구사항 §29).
    public let chronoConflicts: [ChronoEdge]
    /// 스냅샷 조립 시점의 등록 인물 (이름 질의용 값 복사).
    public let characters: [CharacterCard]
    /// 씬 해시 → 씬 시작 UTF-16 (구간 절대 좌표 환산용).
    private let sceneStartByHash: [String: Int]

    /// 씬 메타 한 장 — 사이드카 SceneSummary의 파생 + 오버라이드 적용 결과.
    public struct SceneMeta: Equatable, Sendable {
        public var title: String?
        public var type: SceneNarrativeType
        public var pov: String?
        public var location: String?
        /// 제목이 사용자 수정인가 (오버라이드 존재).
        public var titleUserEdited: Bool
        /// 유형이 사용자 수정인가.
        public var typeUserEdited: Bool
    }

    public init(
        entryID: UUID,
        outline: DocumentOutline,
        summariesByHash: [String: String],
        chapterSummariesByPath: [String: String] = [:],
        workSummary: String? = nil,
        storyMemory: StoryMemorySnapshot? = nil,
        storyKnowledge: StoryKnowledgeSnapshot? = nil,
        events: [String: [StoryEvent]] = [:],
        utterances: [Utterance] = [],
        sceneSummaries: [String: KnowledgeSidecar.SceneSummary] = [:],
        insights: [String: SceneInsights] = [:],
        segments: [String: SceneSegmentation] = [:],
        eventGraph: EventGraphAnalysis? = nil,
        plotThreadAnalysis: PlotThreadAnalysis? = nil,
        recordedConversations: [RecordedConversation] = [],
        conversationMeta: [String: ConversationMeta] = [:],
        characters: [CharacterCard] = [],
        overrides: NarrativeOverrides = .empty,
        staleOverrides: [NarrativeOverride] = []
    ) {
        self.entryID = entryID
        self.outline = outline
        self.summariesByHash = summariesByHash
        self.chapterSummariesByPath = chapterSummariesByPath
        self.workSummary = workSummary
        self.storyMemory = storyMemory
        if let prepared = storyKnowledge, prepared.scope.documentID.rawValue == entryID,
           storyMemory.map({ $0.scope == prepared.scope }) ?? true {
            self.storyKnowledge = prepared
        } else { self.storyKnowledge = nil }
        self.utterances = utterances
        self.overrides = overrides
        self.staleOverrides = staleOverrides
        self.characters = characters

        // 사건을 담화 순서로 편다 — 저장은 해시 키(삽입에 불변), 순서는 여기서
        // 아웃라인으로부터 파생한다 (docs/m6-events.md 결정 1).
        // 사용자 수정(요약·중요도)은 여기서 얹는다 — 재분석이 원본 캐시를
        // 갱신해도 오버라이드는 entries.json에 있어 항상 다시 이긴다 (§1-5).
        var ends: [String: Int] = [:]
        var ordered: [StoryEvent] = []
        for scene in outline.scenes {
            ends[scene.contentHash] = scene.utf16Range.upperBound
            // 같은 씬 안에서는 중요도 높은 사건이 먼저 — 예산 삭감이 뒤에서
            // 잘리므로 중요한 것이 살아남는다 (PLAN §11).
            let sceneEvents = (events[scene.contentHash] ?? [])
                .map { event in
                    var event = event
                    let key = event.stableKey
                    if let importance = overrides.value(.eventImportance, key: key),
                        let value = Int(importance)
                    {
                        event.importance = min(5, max(1, value))
                    }
                    if let summary = overrides.value(.eventSummary, key: key) {
                        event.summary = summary
                    }
                    return event
                }
                .sorted { $0.importance > $1.importance }
            ordered.append(contentsOf: sceneEvents)
        }
        self.events = ordered
        self.sceneEndByHash = ends

        var index: [UUID: [Int]] = [:]
        for (offset, event) in ordered.enumerated() {
            for participant in event.participants {
                index[participant, default: []].append(offset)
            }
        }
        self.eventIndexByCharacter = index

        // 씬 메타 — 사이드카 값 위에 오버라이드를 얹는다.
        var metaByHash: [String: SceneMeta] = [:]
        var types: [SceneNarrativeType] = []
        var anchorHashes: [String] = []
        for scene in outline.scenes {
            let hash = scene.contentHash
            let stored = sceneSummaries[hash]
            let titleOverride = overrides.value(.sceneTitle, key: hash)
            let typeOverride = overrides.value(.sceneType, key: hash)
            let type =
                typeOverride.map { SceneNarrativeType.normalize($0) }
                ?? stored?.narrativeType.map { SceneNarrativeType.normalize($0) }
                ?? .present
            metaByHash[hash] = SceneMeta(
                title: titleOverride ?? stored?.title,
                type: type,
                pov: stored?.pov,
                location: stored?.location,
                titleUserEdited: titleOverride != nil,
                typeUserEdited: typeOverride != nil)
            types.append(type)
            anchorHashes.append(hash)
        }
        self.sceneMetaByHash = metaByHash

        // 브랜치 — 씬 유형에서 파생, 이름·시간 관계 오버라이드 적용.
        var chronoOverrides: [String: ChronoRelation] = [:]
        for (key, raw) in overrides.map(of: .branchChrono) {
            if let relation = ChronoRelation(rawValue: raw) { chronoOverrides[key] = relation }
        }
        self.branches = NarrativeBranch.derive(
            types: types, anchorHashes: anchorHashes,
            nameOverrides: overrides.map(of: .branchName),
            chronoOverrides: chronoOverrides)

        // 씬 시작 위치 맵 — 구간(씬-로컬 좌표)의 절대 좌표 환산용.
        var starts: [String: Int] = [:]
        for scene in outline.scenes { starts[scene.contentHash] = scene.utf16Range.lowerBound }
        self.sceneStartByHash = starts

        // 서사 구간 — 사이드카 값 위에 사용자 오버라이드를 얹는다 (요구사항 §15).
        var segmentsApplied: [String: [NarrativeSegment]] = [:]
        for scene in outline.scenes {
            guard let stored = segments[scene.contentHash] else { continue }
            let applied = stored.segments.map { segment -> NarrativeSegment in
                var segment = segment
                let key = segment.id
                if let raw = overrides.value(.segmentLayer, key: key) {
                    segment.layer = NarrativeSegment.Layer.normalize(raw)
                    segment.chrono = segment.layer.defaultChrono
                    segment.confidence = 1  // 사용자 판정 = 확정
                }
                if let raw = overrides.value(.segmentChrono, key: key),
                    let relation = ChronoRelation(rawValue: raw)
                {
                    segment.chrono = relation
                }
                if let pov = overrides.value(.segmentPOV, key: key) { segment.pov = pov }
                if let narrator = overrides.value(.segmentNarrator, key: key) {
                    segment.narrator = narrator
                }
                if let focal = overrides.value(.segmentFocal, key: key) {
                    segment.focalCharacter = focal
                }
                if let subject = overrides.value(.segmentSubject, key: key) {
                    segment.subjectCharacter = subject
                }
                if let raw = overrides.value(.segmentReliability, key: key) {
                    segment.reliability = SourceReliability.normalize(raw)
                }
                return segment
            }
            .sorted { ($0.localStart, $0.depth) < ($1.localStart, $1.depth) }
            segmentsApplied[scene.contentHash] = applied
        }
        self.segmentsByScene = segmentsApplied

        // 동일 사건 묶음 — AI 후보(eventGraph.identities) 위에 사용자 판정
        // (.eventIdentity — 값 = 정본 키, 빈 값 = 분리)을 얹는다 (요구사항 §12).
        var memberToCanonical: [String: String] = [:]
        for identity in eventGraph?.identities ?? [] {
            for member in identity.memberKeys {
                memberToCanonical[member] = identity.canonicalKey
            }
        }
        for (member, canonical) in overrides.map(of: .eventIdentity) {
            if canonical.isEmpty {
                memberToCanonical[member] = nil  // 사용자 분리
            } else {
                memberToCanonical[member] = canonical
            }
        }

        // 정본 사건 조립 — 담화 순서로 접되, 같은 정본 키의 뒷 등장은 관점으로만
        // 붙는다 (사건 복제 금지, 요구사항 §3·§12).
        let liveKeys = Set(ordered.map(\.stableKey))
        var canonicalOrder: [String] = []
        var canonicalByKey: [String: CanonicalEvent] = [:]
        var memberMap: [String: String] = [:]
        for event in ordered {
            let member = event.stableKey
            // 정본 키가 살아있는 사건을 가리킬 때만 묶는다 (죽은 참조 무시).
            let canonical =
                memberToCanonical[member].flatMap { liveKeys.contains($0) ? $0 : nil } ?? member
            memberMap[member] = canonical
            // 이 멤버의 관점 — 씬 구간의 층·출처가 관점의 맥락이다.
            let sceneSegments = segmentsApplied[event.sceneHash] ?? []
            let context = sceneSegments.first { $0.depth >= 1 && $0.layer.isTemporalShift }
            let viewpoint = context?.pov ?? metaByHash[event.sceneHash]?.pov
            let source = context?.source ?? .directlyNarrated
            let reliability =
                context.map { $0.reliability == .unknown ? $0.source.defaultReliability : $0.reliability }
                ?? .confirmed
            let perspective = EventPerspective(
                eventKey: member, sceneHash: event.sceneHash,
                viewpoint: viewpoint, source: source, reliability: reliability,
                summary: event.summary, quote: event.quote,
                segmentID: context?.persistentID)
            if var existing = canonicalByKey[canonical] {
                existing.perspectives.append(perspective)
                existing.participants = Array(Set(existing.participants + event.participants))
                canonicalByKey[canonical] = existing
            } else {
                canonicalOrder.append(canonical)
                canonicalByKey[canonical] = CanonicalEvent(
                    canonicalKey: canonical,
                    sceneHash: event.sceneHash,
                    summary: event.summary,
                    importance: event.importance,
                    participants: event.participants,
                    perspectives: [perspective],
                    quote: event.quote)
            }
        }
        // 관점이 여럿이고 내용이 갈리면 이견(disputed) 표시 — 하나를 진실로
        // 확정하지 않는다 (요구사항 §12·§13).
        for key in canonicalOrder {
            guard var event = canonicalByKey[key], event.perspectives.count >= 2 else { continue }
            let summaries = Set(event.perspectives.map(\.summary))
            if summaries.count >= 2 {
                event.perspectives = event.perspectives.map { perspective in
                    var perspective = perspective
                    if perspective.reliability == .confirmed { perspective.reliability = .probable }
                    return perspective
                }
                canonicalByKey[key] = event
            }
        }
        let canonicals = canonicalOrder.compactMap { canonicalByKey[$0] }
        self.canonicalEvents = canonicals
        self.canonicalKeyByMember = memberMap

        // 인과 관계 — AI 후보 + 사용자 추가 − 사용자 삭제. 끝점은 정본 키로
        // 정규화하고, 죽은 사건 참조는 버린다.
        var links: [CausalLink] = []
        var linkIDs: Set<String> = []
        func normalizedLink(_ link: CausalLink) -> CausalLink? {
            guard let from = memberMap[link.fromKey] ?? (liveKeys.contains(link.fromKey) ? link.fromKey : nil),
                let to = memberMap[link.toKey] ?? (liveKeys.contains(link.toKey) ? link.toKey : nil),
                from != to
            else { return nil }
            return CausalLink(fromKey: from, toKey: to, kind: link.kind, reason: link.reason)
        }
        let causalOverrides = overrides.map(of: .causalLink)
        func userDecision(_ link: CausalLink) -> String? {
            causalOverrides["\(link.kind.rawValue)|\(link.fromKey)|\(link.toKey)"]
        }
        for raw in eventGraph?.causalLinks ?? [] {
            guard let link = normalizedLink(raw), userDecision(link) != "삭제",
                linkIDs.insert(link.id).inserted
            else { continue }
            links.append(link)
        }
        for (key, decision) in causalOverrides where decision == "추가" {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 3, let kind = CausalLink.Kind(rawValue: parts[0]),
                let link = normalizedLink(
                    CausalLink(fromKey: parts[1], toKey: parts[2], kind: kind, reason: "직접 연결")),
                linkIDs.insert(link.id).inserted
            else { continue }
            links.append(link)
        }
        self.causalLinks = links

        // 시간 부분 순서 — AI 간선 + 사용자 간선 + 층 파생 간선을 해석한다.
        // 정보가 부족하면 담화 순서를 유지하고, 모순은 Conflict로 남긴다 (§29).
        var chronoEdges: [ChronoEdge] = []
        for raw in eventGraph?.chronoEdges ?? [] {
            guard let a = memberMap[raw.aKey], let b = memberMap[raw.bKey], a != b else { continue }
            chronoEdges.append(ChronoEdge(aKey: a, bKey: b, relation: raw.relation))
        }
        for (key, raw) in overrides.map(of: .chronoEdge) {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2, let relation = ChronoRelation(rawValue: raw) else { continue }
            let a = memberMap[parts[0]] ?? parts[0]
            let b = memberMap[parts[1]] ?? parts[1]
            guard a != b else { continue }
            // 사용자 간선이 같은 쌍의 AI 간선을 대체한다.
            chronoEdges.removeAll { ($0.aKey == a && $0.bKey == b) || ($0.aKey == b && $0.bKey == a) }
            chronoEdges.append(ChronoEdge(aKey: a, bKey: b, relation: relation))
        }
        // 층 파생 간선 — '과거' 브랜치 씬의 사건은 그 다음 '현재' 씬 첫 사건보다
        // 앞이다 (회상은 그 자리에서 이야기되는 과거다). 근사가 아니라 층 정의에서
        // 나오는 확실한 제약만 넣는다.
        var branchChrono: [Int: ChronoRelation] = [:]
        for branch in self.branches {
            for index in branch.sceneRange { branchChrono[index] = branch.chrono }
        }
        let sceneIndexByHash = outline.unambiguousSceneIndicesByHash
        for canonical in canonicals {
            guard let sceneIndex = sceneIndexByHash[canonical.sceneHash],
                branchChrono[sceneIndex] == .before
            else { continue }
            // 이 회상 사건 → 브랜치 다음의 첫 현재 사건.
            if let anchor = canonicals.first(where: { other in
                guard let otherIndex = sceneIndexByHash[other.sceneHash] else { return false }
                return otherIndex > sceneIndex && branchChrono[otherIndex] == nil
            }) {
                let edge = ChronoEdge(
                    aKey: canonical.canonicalKey, bKey: anchor.canonicalKey, relation: .before)
                if !chronoEdges.contains(where: { $0.id == edge.id }) {
                    chronoEdges.append(edge)
                }
            }
        }
        let resolution = ChronoOrder.resolve(
            items: canonicalOrder, edges: chronoEdges)
        self.eventChronoOrder = resolution.ordered
        self.chronoConflicts = resolution.conflicts

        // 서사 흐름 — main + 인물 + 시간 (요구사항 §1·§2·§4·§5).
        var branchCharacterOverrides: [String: String] = [:]
        for (key, value) in overrides.map(of: .branchCharacter) {
            branchCharacterOverrides[key] = value
        }
        self.flows = NarrativeFlow.derive(
            canonicalEvents: canonicals,
            characters: characters,
            branches: self.branches,
            branchCharacterOverrides: branchCharacterOverrides,
            flowNameOverrides: overrides.map(of: .flowName))

        // 플롯 스레드 (v6) — 저장된 추론 + 오버라이드 → 그래프의 branch.
        // 분석이 아직 없으면 전 사건이 본줄기 하나 = 직선 그래프 (그것이 정답이다).
        let resolvedThreads = ResolvedPlotThread.derive(
            analysis: plotThreadAnalysis,
            canonicalOrder: canonicalOrder,
            memberMap: memberMap,
            overrides: overrides)
        self.plotThreads = resolvedThreads
        var threadIndex: [String: [String]] = [:]
        for thread in resolvedThreads {
            for key in thread.memberKeys {
                threadIndex[key, default: []].append(thread.id)
            }
        }
        self.threadIDsByEvent = threadIndex

        // 대화 인덱스 — 발화에서 결정적으로 + 기록된 대화 겹침 (요구사항 §21).
        // 기록은 자동 감지보다 높은 신뢰: 겹치는 자동 감지 대화에 기록 표식을
        // 달고, 겹치는 것이 없으면 기록 자체가 대화 항목이 된다.
        var merged = Conversation.index(utterances: utterances, outline: outline)
        for record in recordedConversations.sorted(by: { $0.utf16Start < $1.utf16Start }) {
            let meta = conversationMeta[record.id.uuidString]
            let enriched = meta?.contentHash == record.contentHash ? meta : nil
            if let index = merged.firstIndex(where: {
                $0.utf16Start < record.utf16End && record.utf16Start < $0.utf16End
            }) {
                merged[index].recordedID = record.id
                merged[index].topic = enriched?.topic
                merged[index].tone = enriched?.tone
                if merged[index].participants.isEmpty {
                    merged[index].participants = record.participants
                }
            } else {
                let sceneHash = outline.sceneIndex(at: record.utf16Start)
                    .map { outline.scenes[$0].contentHash }
                merged.append(
                    Conversation(
                        participants: record.participants,
                        sceneHash: sceneHash,
                        utf16Start: record.utf16Start,
                        utf16End: record.utf16End,
                        utteranceCount: 0,
                        firstLine: String(record.firstLine.prefix(40)),
                        recordedID: record.id,
                        topic: enriched?.topic,
                        tone: enriched?.tone))
            }
        }
        self.conversations = merged.sorted { $0.utf16Start < $1.utf16Start }

        // 심화 추출을 담화 순서로 편다 (사건과 같은 파생).
        var knowledge: [KnowledgeDelta] = []
        var relations: [RelationDelta] = []
        for scene in outline.scenes {
            guard let insight = insights[scene.contentHash] else { continue }
            knowledge.append(contentsOf: insight.knowledge)
            relations.append(contentsOf: insight.relations)
        }
        self.knowledgeDeltas = knowledge
        self.relationDeltas = relations
    }

    // MARK: - 표준 질의 (PLAN §8) — ContextAssembler는 이것만 쓴다

    /// 주어진 위치 **이전에 완전히 끝난** 씬의 사건들 (담화 순서).
    /// 커서 이후 지식 누출 차단(CLAUDE.md §2-4)이 여기서 결정적으로 성립한다 —
    /// 3장을 고치는 중에 9장의 사건이 새어 들어가지 않는다.
    public func events(before utf16Offset: Int) -> [StoryEvent] {
        events.filter { (sceneEndByHash[$0.sceneHash] ?? .max) <= utf16Offset }
    }

    /// 인물이 마지막으로 등장한 사건 (그 위치 이전) — PLAN §8 `lastAppearance`.
    /// 역색인을 뒤에서부터 훑으므로 사건이 많아도 첫 적중에서 끝난다.
    public func lastAppearance(of characterID: UUID, before utf16Offset: Int) -> StoryEvent? {
        guard let offsets = eventIndexByCharacter[characterID] else { return nil }
        for offset in offsets.reversed() {
            let event = events[offset]
            if (sceneEndByHash[event.sceneHash] ?? .max) <= utf16Offset { return event }
        }
        return nil
    }

    /// 커서가 속한 씬에 함께 있는 등록 인물 — PLAN §11 장면 앵커(그라운딩).
    ///
    /// 다음 문장 예측에는 "지난 줄거리"보다 "지금 이 공간에 누가 있는가"가
    /// 정보량이 크다 (ConStory-Bench 2026의 실패 분포 — factual 최다 — 와
    /// 같은 방향). 발화는 커서 이전 것만(위치가 있는 유일 신호), 씬 사건은
    /// 씬 해시 단위로 합친다 — 사건은 씬 내 세부 위치가 없어 그렇게밖에 안 된다.
    /// 순서는 첫 등장 순(발화 → 사건)으로 고정 — KV 프리픽스 보호 (PLAN §12).
    public func sceneCohabitants(at utf16Offset: Int) -> [UUID] {
        guard let index = outline.sceneIndex(at: utf16Offset) else { return [] }
        let hash = outline.scenes[index].contentHash
        var order: [UUID] = []
        var seen: Set<UUID> = []
        func add(_ ids: [UUID]) {
            for id in ids where seen.insert(id).inserted { order.append(id) }
        }
        for conversation in conversations
        where conversation.sceneHash == hash && conversation.utf16Start < utf16Offset {
            add(conversation.participants)
        }
        for event in events where event.sceneHash == hash { add(event.participants) }
        return order
    }

    /// 그 위치 시점의 인물 상태 — PLAN §8 `state_at`, §6.2의 fold.
    ///
    /// 커서 이전에 끝난 씬의 델타를 **담화 순서로 접는다**: 같은 필드는 나중
    /// 델타가 이긴다 (상태는 덮어쓰지 않고 append, 질의가 최신을 뽑는다).
    /// 시점 차단·톰스톤 제외는 `events(before:)`와 같은 씬 위치 비교라 여기서도
    /// 결정적으로 성립한다 — 9장에서 죽은 인물이 3장 수정 중에 "사망"으로
    /// 주입되지 않는다 (CLAUDE.md §2-4).
    ///
    /// 역색인이 담화 순서 오름차순이므로 앞에서부터 그대로 접으면 된다 —
    /// 인물 하나의 사건 수는 작아 예측 경로 예산 안이다 (조립은 조립만).
    public func stateAt(
        of characterID: UUID, before utf16Offset: Int
    ) -> [StateDelta.Field: String] {
        guard let offsets = eventIndexByCharacter[characterID] else { return [:] }
        var state: [StateDelta.Field: String] = [:]
        for offset in offsets {
            let event = events[offset]
            guard (sceneEndByHash[event.sceneHash] ?? .max) <= utf16Offset else { continue }
            for delta in event.deltas where delta.characterID == characterID {
                state[delta.field] = delta.value
            }
        }
        return state
    }

    // MARK: - 대화 질의 (PLAN §6.4·§10 대화 모드)

    /// 인물 말투 프로필 — 기본 존대 수준 + 최근 대사 예문 (PLAN §6.4).
    public struct SpeechProfile: Equatable, Sendable {
        /// 그 인물 발화 다수결 — 갈리면 nil (섣부른 신호보다 침묵).
        public let defaultPoliteness: Politeness?
        /// 최근 우선 예문, 문서 순서 (PLAN §6.4 "최근 우선, 결정적 수집").
        public let examples: [String]
    }

    /// (A→B) 방향 존대 사용 — 한국어 대화 예측의 핵심 신호 (PLAN §6.4 매트릭스).
    public enum HonorificUsage: String, Equatable, Sendable {
        case honorific = "존댓말"
        case plain = "반말"
        case mixed = "혼재"
    }

    /// 커서 이전 발화로 만드는 말투 프로필. 발화가 없으면 nil.
    public func speechProfile(
        of characterID: UUID, before utf16Offset: Int, maxExamples: Int = 2
    ) -> SpeechProfile? {
        let mine = utterances.filter {
            $0.speakerID == characterID && $0.utf16Start < utf16Offset
        }
        guard !mine.isEmpty else { return nil }
        var honorific = 0
        var plain = 0
        for utterance in mine {
            switch utterance.politeness {
            case .honorific: honorific += 1
            case .plain: plain += 1
            case nil: break
            }
        }
        let base: Politeness? =
            honorific > plain ? .honorific : plain > honorific ? .plain : nil
        let examples = mine.suffix(maxExamples).map {
            String($0.text.prefix(DialogueAttribution.maxExampleCharacters))
        }
        return SpeechProfile(defaultPoliteness: base, examples: examples)
    }

    /// (from → to) 방향의 존대 사용 — 커서 이전 발화만 fold (시점 차단).
    /// 어색한 존대가 반말로 무너지는 시점이 있다면 커서 위치가 그걸 반영한다.
    public func honorific(
        from speakerID: UUID, to listenerID: UUID, before utf16Offset: Int
    ) -> HonorificUsage? {
        var honorific = 0
        var plain = 0
        for utterance in utterances {
            guard utterance.utf16Start < utf16Offset,
                utterance.speakerID == speakerID,
                utterance.listenerID == listenerID
            else { continue }
            switch utterance.politeness {
            case .honorific: honorific += 1
            case .plain: plain += 1
            case nil: break
            }
        }
        if honorific == 0, plain == 0 { return nil }
        if plain == 0 { return .honorific }
        if honorific == 0 { return .plain }
        return .mixed
    }

    // MARK: - Narrative Intelligence 질의 (v4, PLAN §6.5·§8)

    /// 그 위치 시점에 인물이 가진 앎 — 커서 이전 씬의 앎 델타를 접는다.
    /// 같은 사실(fact)에 대한 나중 델타(태도 변화: 의심 → 안다)가 이긴다.
    /// 시점 차단은 사건 질의와 같은 씬 위치 비교 — 9장의 비밀이 3장 수정 중에
    /// 새지 않는다 (CLAUDE.md §2-4). 요구사항 §11 "그 시점에 아는 것만"의 실체.
    public func knowledge(
        of characterID: UUID, before utf16Offset: Int
    ) -> [KnowledgeDelta] {
        var order: [String] = []
        var latest: [String: KnowledgeDelta] = [:]
        for delta in knowledgeDeltas {
            guard delta.characterID == characterID,
                (sceneEndByHash[delta.sceneHash] ?? .max) <= utf16Offset
            else { continue }
            if latest[delta.fact] == nil { order.append(delta.fact) }
            latest[delta.fact] = delta
        }
        return order.compactMap { latest[$0] }
    }

    /// (from → to) 방향의 현재 관계 — 커서 이전 마지막 관계 델타.
    public func relation(
        from fromID: UUID, to toID: UUID, before utf16Offset: Int
    ) -> RelationDelta? {
        relationDeltas.last {
            $0.fromID == fromID && $0.toID == toID
                && (sceneEndByHash[$0.sceneHash] ?? .max) <= utf16Offset
        }
    }

    /// (from → to) 관계의 전체 변화 이력 (담화 순서) — 바이블 관계 화면용.
    public func relationHistory(from fromID: UUID, to toID: UUID) -> [RelationDelta] {
        relationDeltas.filter { $0.fromID == fromID && $0.toID == toID }
    }

    /// 인물이 참여한 대화들 (담화 순서) — 바이블 대화 인덱스용.
    public func conversations(involving characterID: UUID) -> [Conversation] {
        conversations.filter { $0.participants.contains(characterID) }
    }

    /// 씬의 대표 중요도 — 그 씬 사건들의 최대 중요도 (사건 없으면 nil).
    /// 타임라인의 시각적 계층(노드 크기·요약 밀도)이 이 값을 쓴다.
    public func sceneImportance(of sceneHash: String) -> Int? {
        events.filter { $0.sceneHash == sceneHash }.map(\.importance).max()
    }

    /// 작품 세계 시간 순서의 씬 인덱스 배열 (근사) — `과거` 브랜치 블록을 맨
    /// 앞으로(브랜치 등장 순서 유지), `미래` 블록을 맨 뒤로 옮기고, 나머지는
    /// 담화 순서를 유지한다. 절대 시각이 없는 한 완전한 정렬은 불가능하다 —
    /// 상대 관계(ChronoRelation)의 표시가 목적이지 정밀 연표가 아니다
    /// (요구사항 §7의 상대 시간 표현: before/after/simultaneous/unknown).
    public func chronologicalSceneOrder() -> [Int] {
        var past: [Int] = []
        var future: [Int] = []
        for branch in branches {
            switch branch.chrono {
            case .before: past.append(contentsOf: branch.sceneRange)
            case .after: future.append(contentsOf: branch.sceneRange)
            case .simultaneous, .approximate, .unknown: break
            }
        }
        let moved = Set(past + future)
        let middle = outline.scenes.indices.filter { !moved.contains($0) }
        return past + middle + future
    }

    // MARK: - Narrative Graph 질의 (v5, PLAN §6.6)

    /// 현재 작성 위치의 서사 좌표 — "지금 어떤 이야기 흐름에 있는가"의 답
    /// (요구사항 §30). 조립기가 Retrieval 축으로 쓴다.
    public struct NarrativePosition: Equatable, Sendable {
        /// 현재 흐름 (main / 인물 / 시간).
        public var flowID: String
        /// 현재 서사 층 (씬 바탕이면 씬 유형에서, 구간 안이면 구간에서).
        public var layer: NarrativeSegment.Layer
        /// 중첩 깊이 (0 = 바탕).
        public var depth: Int
        /// 작품 내 시간 관계.
        public var chrono: ChronoRelation
        /// 현재 구간 (씬 바탕이면 nil).
        public var segmentID: String?
        /// 현재 시점 인물 이름.
        public var pov: String?
        /// 현재 구간의 소속 인물 (회상의 주인).
        public var subjectCharacter: String?
        /// 커서가 속한 씬 인덱스 — 시간 차단(§30)의 기준 좌표.
        public var sceneIndex: Int?
    }

    /// 커서 위치의 구간 — 그 위치를 덮는 **가장 깊은** 구간 (중첩 회상 대응).
    public func segment(at utf16Offset: Int) -> NarrativeSegment? {
        guard let index = outline.sceneIndex(at: utf16Offset) else { return nil }
        let scene = outline.scenes[index]
        let local = utf16Offset - scene.utf16Range.lowerBound
        return (segmentsByScene[scene.contentHash] ?? [])
            .filter { $0.localStart <= local && local < max($0.localEnd, $0.localStart + 1) }
            .max { $0.depth < $1.depth }
    }

    /// 커서 위치의 서사 좌표 (요구사항 §30) — 구간 → 씬 브랜치 → main 순 판정.
    public func position(at utf16Offset: Int) -> NarrativePosition {
        guard let sceneIndex = outline.sceneIndex(at: utf16Offset) else {
            return NarrativePosition(
                flowID: NarrativeFlow.mainID, layer: .present, depth: 0,
                chrono: .unknown, segmentID: nil, pov: nil, subjectCharacter: nil,
                sceneIndex: nil)
        }
        let scene = outline.scenes[sceneIndex]
        let meta = sceneMetaByHash[scene.contentHash]
        // 씬이 속한 시간 브랜치 (씬 전체 유형이 비현재).
        let branch = branches.first { $0.sceneRange.contains(sceneIndex) }

        if let segment = segment(at: utf16Offset), segment.layer.isTemporalShift {
            // 구간의 소속 인물이 등록 카드와 이어지면 인물 흐름이 현재 흐름이다.
            let flowID: String
            if let subject = segment.subjectCharacter,
                let card = characters.first(where: {
                    $0.name == subject || subject.hasPrefix($0.name)
                }),
                flows.contains(where: { $0.id == "flow-chr-\(card.id.uuidString)" })
            {
                flowID = "flow-chr-\(card.id.uuidString)"
            } else if let branch {
                flowID = "flow-tmp-\(branch.anchorHash)"
            } else {
                flowID = NarrativeFlow.mainID
            }
            return NarrativePosition(
                flowID: flowID, layer: segment.layer, depth: segment.depth,
                chrono: segment.chrono, segmentID: segment.id,
                pov: segment.pov ?? meta?.pov,
                subjectCharacter: segment.subjectCharacter,
                sceneIndex: sceneIndex)
        }
        if let branch {
            return NarrativePosition(
                flowID: "flow-tmp-\(branch.anchorHash)",
                layer: NarrativeSegment.Layer.normalize(branch.type.rawValue),
                depth: 1, chrono: branch.chrono, segmentID: nil,
                pov: meta?.pov, subjectCharacter: nil, sceneIndex: sceneIndex)
        }
        return NarrativePosition(
            flowID: NarrativeFlow.mainID, layer: .present, depth: 0,
            chrono: .unknown, segmentID: nil, pov: meta?.pov, subjectCharacter: nil,
            sceneIndex: sceneIndex)
    }

    /// 사건 키(멤버·정본 모두) → 정본 사건.
    public func canonicalEvent(for key: String) -> CanonicalEvent? {
        let canonical = canonicalKeyByMember[key] ?? key
        return canonicalEvents.first { $0.canonicalKey == canonical }
    }

    /// 멤버 키 → 원래 StoryEvent — 정본 사건에서 상태 델타 등 원본 필드로의
    /// 역추적 통로 (통합 서사 UI). 사건 수는 수백 규모라 선형 탐색로 충분하다.
    public func storyEvent(forMember key: String) -> StoryEvent? {
        events.first { $0.stableKey == key }
    }

    /// 정본 사건이 속한 플롯 스레드들 (plotThreads 순서).
    public func threads(of canonicalKey: String) -> [ResolvedPlotThread] {
        (threadIDsByEvent[canonicalKey] ?? []).compactMap { id in
            plotThreads.first { $0.id == id }
        }
    }

    /// 구간 persistent ID → 구간 — EventPerspective.segmentID의 역참조.
    public func segment(withID id: String) -> NarrativeSegment? {
        for segments in segmentsByScene.values {
            if let match = segments.first(where: { $0.persistentID == id }) { return match }
        }
        return nil
    }

    /// 이 사건의 원인들 — (kind = 원인/영향/설명 …) 방향이 이 사건으로 들어오는
    /// 링크 (요구사항 §6 "이 사건의 원인").
    public func causes(of canonicalKey: String) -> [CausalLink] {
        causalLinks.filter { $0.toKey == canonicalKey }
    }

    /// 이 사건이 영향을 준 사건들.
    public func effects(of canonicalKey: String) -> [CausalLink] {
        causalLinks.filter { $0.fromKey == canonicalKey }
    }

    /// 정본 사건의 시간 순위 — eventChronoOrder에서의 위치 (없으면 nil).
    public func chronoRank(of canonicalKey: String) -> Int? {
        eventChronoOrder.firstIndex(of: canonicalKey)
    }

    /// **독자의 앎** (요구사항 §14) — 담화 순서상 커서 이전에 본문에 공개된
    /// 모든 앎 델타. 인물 구분 없음: 독자는 회상으로 공개된 범인의 비밀도 안다.
    public func readerKnowledge(before utf16Offset: Int) -> [KnowledgeDelta] {
        knowledgeDeltas.filter { delta in
            (sceneEndByHash[delta.sceneHash] ?? .max) <= utf16Offset
        }
    }

    /// **작품 내 시간 기준의 인물 앎** (요구사항 §14·§30) — 회상을 쓰는 중에는
    /// "그 시점의 인물"이 알던 것만 유효하다. 담화 위치가 아니라 씬의 시간
    /// 순위(chronologicalSceneOrder)로 접는다: 현재 씬보다 시간상 뒤인 씬의
    /// 앎은 아직 생기지 않았다 — 미래 지식 누출 차단.
    public func knowledgeChrono(
        of characterID: UUID, atSceneContaining utf16Offset: Int
    ) -> [KnowledgeDelta] {
        guard let currentScene = outline.sceneIndex(at: utf16Offset) else { return [] }
        return knowledgeChrono(of: characterID, atSceneIndex: currentScene)
    }

    /// 씬 인덱스 기준 변형 — 조립기가 커서 씬(NarrativePosition.sceneIndex)으로
    /// 직접 부른다 (창 시작과 커서가 다른 씬일 수 있다).
    public func knowledgeChrono(
        of characterID: UUID, atSceneIndex currentScene: Int
    ) -> [KnowledgeDelta] {
        let chronoOrder = chronologicalSceneOrder()
        guard let currentRank = chronoOrder.firstIndex(of: currentScene) else { return [] }
        let allowed = Set(chronoOrder.prefix(currentRank + 1).map { outline.scenes[$0].contentHash })
        var order: [String] = []
        var latest: [String: KnowledgeDelta] = [:]
        // 시간 순서로 접는다 — 같은 사실의 시간상 나중 태도가 이긴다.
        for sceneIndex in chronoOrder.prefix(currentRank + 1) {
            let hash = outline.scenes[sceneIndex].contentHash
            for delta in knowledgeDeltas
            where delta.characterID == characterID && delta.sceneHash == hash && allowed.contains(hash) {
                if latest[delta.fact] == nil { order.append(delta.fact) }
                latest[delta.fact] = delta
            }
        }
        return order.compactMap { latest[$0] }
    }

    /// 인물 흐름의 사건들 (담화 순서) — "이 사건은 누구의 이야기인가"의 역질의.
    public func flowEvents(of flowID: String) -> [CanonicalEvent] {
        guard let flow = flows.first(where: { $0.id == flowID }) else { return [] }
        let keys = Set(flow.eventKeys)
        return canonicalEvents.filter { keys.contains($0.canonicalKey) }
    }

    // MARK: - 씬 살라이언스 (B블록 선별, PLAN §11)

    /// B블록 후보 씬들의 살라이언스 점수 — 인덱스 공유(Indexter pairwise event
    /// salience: 시간·공간·주인공·인과 중 그래프가 답할 수 있는 셋)와 담화 거리
    /// 감쇠의 합. 순수 거리순("커서에서 가까운 것부터")을 대체한다 — 같은 장소
    /// 재방문·동석 인물·인과 선행 사건은 멀어도 다음 장면 예측에 더 진한 신호다.
    ///
    /// 결정적 파생이라 예측 경로에서 매번 계산해도 O(사건+간선+후보)로 저렴하다
    /// (조립은 조립만, CLAUDE.md §2-2 — LLM 호출 없음).
    public func sceneSalienceScores(
        at utf16Offset: Int, candidates: [DocumentOutline.Scene]
    ) -> [String: Double] {
        let offset = max(utf16Offset, 0)
        guard let currentIndex = outline.sceneIndex(at: offset) else { return [:] }
        let currentHash = outline.scenes[currentIndex].contentHash
        let currentMeta = sceneMetaByHash[currentHash]
        let currentLocation = Self.normalizedLocation(currentMeta?.location)
        let currentCast = Set(sceneCohabitants(at: offset))

        // 정본 사건 키 → 씬 해시 — 인과 간선 끝점을 씬 단위로 환산한다.
        var hashByKey: [String: String] = [:]
        for event in canonicalEvents { hashByKey[event.canonicalKey] = event.sceneHash }
        let currentKeys = Set(
            canonicalEvents.filter { $0.sceneHash == currentHash }.map(\.canonicalKey))
        // 지금 씬의 사건으로 **들어오는** 인과 간선의 원인 씬 — "지금 일이 왜
        // 일어났나"의 근거가 놓인 과거 장면이다 (Indexter causality).
        var ancestorHashes: Set<String> = []
        for link in causalLinks where currentKeys.contains(link.toKey) {
            if let hash = hashByKey[link.fromKey], hash != currentHash {
                ancestorHashes.insert(hash)
            }
        }

        let indexByHash = outline.unambiguousSceneIndicesByHash
        var castByHash: [String: Set<UUID>] = [:]
        for event in events {
            castByHash[event.sceneHash, default: []].formUnion(event.participants)
        }

        var scores: [String: Double] = [:]
        for scene in candidates {
            let hash = scene.contentHash
            var score = 5.0
            if ancestorHashes.contains(hash) { score += 30 }
            if let currentLocation,
                let location = Self.normalizedLocation(sceneMetaByHash[hash]?.location),
                location == currentLocation
            {
                score += 20
            }
            let shared = (castByHash[hash] ?? []).intersection(currentCast).count
            score += Double(min(shared, 2)) * 10
            if let index = indexByHash[hash] {
                score -= 0.25 * Double(max(0, currentIndex - index))
            }
            scores[hash] = score
        }
        return scores
    }

    /// 장소 문자열 정규화 — 공백 제거, 빈 값은 nil. 살라이언스의 공간 비교용.
    private static func normalizedLocation(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// 다음 화자 추정 (PLAN §10 대화 모드 ①) — 직전 발화의 청자가 1순위,
    /// 없으면 직전 두 발화의 교대. 추정 불가면 nil (침묵이 정답).
    /// 반환: (다음 화자, 그 상대 = 직전 화자).
    public func expectedSpeaker(
        before utf16Offset: Int
    ) -> (speakerID: UUID, addresseeID: UUID)? {
        let prior = utterances.filter { $0.utf16Start < utf16Offset }
        guard let last = prior.last else { return nil }
        if let listener = last.listenerID {
            return (listener, last.speakerID)
        }
        // 청자 미상(3인 런 등) — 마지막과 다른 직전 화자로 교대 추정.
        if let previous = prior.last(where: { $0.speakerID != last.speakerID }) {
            return (previous.speakerID, last.speakerID)
        }
        return nil
    }
}
