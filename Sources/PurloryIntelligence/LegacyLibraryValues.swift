import Foundation

/// 저널 종류 — 일반 글쓰기와 소설 쓰기를 구분한다.
/// 본문은 같은 마크다운이지만, 사이드바 아이콘·에디터 크롬이 다르고
/// 이후 기능(자동완성 프롬프트·통계 등)이 여기서 갈라진다.
public enum EntryKind: String, Codable, Sendable {
    case journal
    case novel

    public var label: String {
        switch self {
        case .journal: "저널"
        case .novel: "소설"
        }
    }
}

/// 스토리 바이블 v0 — 사용자가 직접 쓰는 인물 카드 (PLAN §6.2·§7).
///
/// 사용자 저작 데이터이므로 파생 캐시(지식 사이드카)가 아니라 원문 스토어에
/// 산다 — 원문이 유일한 진실(CLAUDE.md §2-1). M6 자동 추출이 도입돼도 이
/// 카드는 잠금 취급이라 자동이 덮지 않는다 (CLAUDE.md §1-5).
public struct CharacterCard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// 정식 이름 — 최근 창 언급 감지(카드 선택)의 키 (PLAN §11).
    public var name: String
    /// 별칭·호칭, 쉼표 구분 원문 그대로 보관 — 배열로 쪼개 저장하면 입력 중
    /// 쉼표·공백이 바인딩 왕복에서 먹혀 타이핑을 방해한다. 파싱은 조립기가 한다.
    public var aliases: String
    /// 성격·말투·관계 자유 기술 — 프롬프트 A 헤더에 그대로 실린다 (짧을수록 좋다).
    public var note: String
    public var role: String?
    public var traits: [String]?
    /// 사용자 편집 잠금 (PLAN §6.2, CLAUDE.md §1-5 "사용자 수정이 자동 추출을
    /// 이긴다") — true면 백그라운드 프로파일링이 소개를 채우지 않는다.
    /// 소개를 직접 고치면 UI가 자동으로 잠근다. 옵셔널인 이유: 이전 저장
    /// 파일엔 키가 없어 nil(잠기지 않음)로 로드된다 (`folderID`와 같은 패턴).
    public var locked: Bool?
    /// HIGH 신뢰 감지로 자동 등록된 카드 (요구사항 §16) — UI가 표식을 달아
    /// 사용자가 알아보고 지울 수 있게 한다. 사용자가 카드를 편집하면 해제된다.
    public var autoRegistered: Bool?

    public init(
        id: UUID = UUID(),
        name: String = "",
        aliases: String = "",
        note: String = "",
        locked: Bool? = nil,
        autoRegistered: Bool? = nil,
        role: String? = nil,
        traits: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.note = note
        self.role = role; self.traits = traits
        self.locked = locked
        self.autoRegistered = autoRegistered
    }
}

/// 저널 한 편 (에디터 v3 — 다중 저널).
public struct JournalEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var body: String
    /// 소속 폴더. nil이면 루트 (파일시스템 v1 — 이전 파일엔 키가 없어 nil로 로드).
    public var folderID: UUID?
    /// 사용자가 직접 제목을 바꿨는가 — true면 본문에서 자동 파생하지 않는다.
    /// 레거시 파일엔 없는 키(옵셔널) — nil이면 "기본 제목일 때만" 자동 파생을 허용해
    /// 예전에 붙여 둔 이름은 보존한다.
    public var titleIsCustom: Bool?
    /// 저널 종류. 레거시 파일엔 없는 키 — nil이면 일반 글쓰기(journal).
    public var kind: EntryKind?
    /// 작품 장르 (소설 메타, PLAN §5) — 예측 프롬프트 A 헤더에 실린다.
    /// 사용자 저작 데이터라 파생 캐시가 아닌 여기 산다. 레거시 파일엔 없는 키.
    public var genre: String?
    /// 스토리 바이블 v0 — 인물 카드 (PLAN §7). 레거시 파일엔 없는 키.
    public var characters: [CharacterCard]?
    /// 인물 감지에서 사용자가 "무시"한 이름들 (M6, PLAN §7 거부 목록) —
    /// 같은 후보를 다시 묻지 않는다. 사용자 결정이므로 파생 캐시가 아니라 여기 산다.
    public var rejectedCharacterNames: [String]?
    /// 폴더 안 표시 순서 (사이드바 DnD 재정렬). 레거시 파일엔 없는 키 —
    /// nil이면 로드 시 기존 표시 순서(작성일 내림차순)로 시드된다.
    public var sortOrder: Double?
    /// AI 분석 결과에 대한 사용자 수정 (Narrative Intelligence, PLAN §6.5).
    /// **사용자 결정이라 파생 캐시(사이드카)가 아니라 여기 산다** — 사이드카는
    /// 스키마 변경 시 통째로 버려지지만 이 목록은 살아남아, 재분석·재구축이
    /// 사용자 수정을 절대 덮지 못한다 (CLAUDE.md §1-5). 레거시 파일엔 없는 키.
    public var narrativeOverrides: [NarrativeOverride]?
    /// 사용자가 기록한 대화 (요구사항 §20–§21) — 오버라이드와 같은 이유로
    /// 여기 산다. 재분석이 지우지 못한다. 레거시 파일엔 없는 키.
    public var recordedConversations: [RecordedConversation]?

    public init(
        id: UUID = UUID(),
        title: String = "새 저널",
        createdAt: Date = .now,
        body: String = "",
        folderID: UUID? = nil,
        titleIsCustom: Bool? = nil,
        kind: EntryKind? = nil,
        genre: String? = nil,
        characters: [CharacterCard]? = nil,
        rejectedCharacterNames: [String]? = nil,
        sortOrder: Double? = nil,
        narrativeOverrides: [NarrativeOverride]? = nil,
        recordedConversations: [RecordedConversation]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.body = body
        self.folderID = folderID
        self.titleIsCustom = titleIsCustom
        self.kind = kind
        self.genre = genre
        self.characters = characters
        self.rejectedCharacterNames = rejectedCharacterNames
        self.sortOrder = sortOrder
        self.narrativeOverrides = narrativeOverrides
        self.recordedConversations = recordedConversations
    }

    /// 옵셔널 kind의 확정값 — 레거시(nil)는 전부 일반 글쓰기.
    public var resolvedKind: EntryKind { kind ?? .journal }

    /// 자동으로 붙는 기본 제목들 — 이 이름이면 본문에서 파생해도 사용자 의도를 해치지 않는다.
    package static let placeholderTitles: Set<String> = ["새 저널", "새 소설", "저널", "제목 없음", ""]

    /// 본문에서 제목을 자동 파생해도 되는가.
    package var allowsAutoTitle: Bool {
        if let titleIsCustom { return !titleIsCustom }
        // 레거시 파일: 기본 제목일 때만 자동 파생 — 직접 붙인 이름은 그대로 둔다.
        return Self.placeholderTitles.contains(title)
    }
}

/// 저널을 프로젝트처럼 묶는 폴더 (파일시스템 v1). parentID로 중첩된다.
public struct JournalFolder: Identifiable, Codable, Equatable, Sendable {
    /// 자동 생성 폴더의 기본 이름 — AI 명명(renameFolderIfPlaceholder)은 이름이
    /// 아직 이 값일 때만 덮어쓴다 (사용자가 먼저 바꾸면 그쪽이 이긴다).
    public static let placeholderName = "새 폴더"

    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var createdAt: Date
    /// 형제 폴더 사이 표시 순서 (사이드바 DnD 재정렬). 레거시 파일엔 없는 키 —
    /// nil이면 로드 시 기존 배열 순서로 시드된다.
    public var sortOrder: Double?

    public init(
        id: UUID = UUID(),
        name: String = JournalFolder.placeholderName,
        parentID: UUID? = nil,
        createdAt: Date = .now,
        sortOrder: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }
}

