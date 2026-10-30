import Foundation

/// 인물 감지의 언어 지식 (M6, PLAN §7) — 조사·어미·품사 부류를 데이터로 담는다.
///
/// **왜 별도 타입인가.** 한국어는 Apple `NLTagger`가 품사(`lexicalClass`)·개체명
/// (`nameType`)을 지원하지 않는다(2026-07 실측: 한국어 가용 스킴은 Language·
/// Script·TokenType뿐, "한도경은"을 조사 분리조차 못 함). 그래서 형태소 분석기
/// 대신 교착어 구조 지식(격조사는 체언에만 붙는다 등)을 우리가 데이터로 들고
/// 판별한다. 그 지식이 곧 이 렉시콘이다.
///
/// **확장성** (요구: "코드 수정 없이 불용어 확장"): 불용어는 컴파일된 기본값 +
/// 런타임 사용자 파일 `~/Documents/Purlory/character-stopwords.txt`의 병합이다.
/// 사용자가 그 파일에 한 줄씩 추가하면 재빌드 없이 즉시 반영된다(mtime 캐시).
/// 격조사·유정 신호 같은 언어 구조는 사용자 튜닝 대상이 아니라 내부 인프라다.
public struct CharacterLexicon: Sendable {

    /// 격조사·보조사의 문법 역할 — 표면형이 아니라 역할로 다양성을 센다
    /// (은/는은 같은 보조사 = 한 역할, 이/가는 같은 주격 = 한 역할). 체언이
    /// 여러 역할로 격변화하는가가 "고정된 낱말이 아니라 명사"라는 구조적 증거다.
    public enum Role: Sendable, Hashable {
        case subject  // 주격 이/가
        case object  // 목적격 을/를
        case topic  // 보조사 은/는/도/만…
        case genitive  // 속격 의
        case comitative  // 공동격 과/와/(이)랑/하고
        case dative  // 여격 에게/한테/께 — **유정물 전용** (사람 신호)
        case vocative  // 호격 아/야 — **부름 = 사람 신호**
        case locative  // 처격 에/에서 — 장소·시간이 흔히 취함(사람 신호 아님)
        case directional  // (으)로
    }

    /// (표면형, 역할) — 긴 조사 우선 매칭을 위해 길이 내림차순으로 정렬해 보관.
    public let particles: [(suffix: String, role: Role)]

    /// 대화 귀속 판정용 주어 표지 — 이 표지가 붙은 이름 뒤에 발화 동사가 오면
    /// 그 이름은 화자(사람)다 ("소리가 말했다"). PLAN §7의 대화 인접 가중.
    public let subjectMarkers: [String]

    /// 발화·서술 동사의 접두 — 뒤 토큰이 이 중 하나로 시작하면 발화 귀속.
    /// 사물은 이 자리에 오지 않는다("등불이 말했다"는 없다) → 강한 사람 신호.
    public let speechVerbPrefixes: [String]

    /// 대명사 — 닫힌 부류. 명사처럼 조사를 취하므로 구조 신호로는 못 거른다.
    public let pronouns: Set<String>

    /// 호칭 — 사람을 가리키는 명사지만 **고유명사가 아니다**(아버지·소장님).
    /// 발화 주어가 되므로("소장님이 말했다") 유정 신호를 통과한다 → 명시적으로 제외.
    /// 사용자가 특정 호칭을 인물로 쓰고 싶으면 바이블에 직접 등록한다(사용자가 이김).
    public let honorifics: Set<String>

    /// 일반명사·부사·접속사 안전망 + **사용자 확장분**. 구조 필터가 대부분을
    /// 걸러내므로 이 목록은 작다 — 유정 신호를 우연히 통과하는 소수만 담는다.
    public let stopwords: Set<String>

    /// 동음이의 주의: "소리"(소리=sound / 인물명 윤소리)처럼 문맥에 따라 갈리는
    /// 낱말은 **불용어에 넣지 않는다** — 발화 귀속 같은 구조 신호가 실제 인물일
    /// 때만 통과시키기 때문이다(불용어는 이 판단을 뭉갠다).

    // MARK: - 기본값 (컴파일 데이터 — 언어 구조 인프라)

    public static let base = CharacterLexicon(
        particles: sortedParticles([
            // 여격 (유정 전용 — 사람 신호). 긴 것 먼저.
            ("이에게서", .dative), ("에게서", .dative), ("한테서", .dative),
            ("에게", .dative), ("한테", .dative), ("께서", .dative), ("께", .dative),
            // 공동격
            ("이랑", .comitative), ("하고", .comitative), ("랑", .comitative),
            ("과", .comitative), ("와", .comitative),
            // 처격·방향 (장소·시간이 흔히 취함 — 사람 신호 아님, 어간 추출용)
            ("에서", .locative), ("에게로", .directional), ("에는", .locative),
            ("에도", .locative), ("에", .locative), ("으로", .directional),
            ("로", .directional),
            // 주격·목적격·속격·보조사
            ("이", .subject), ("가", .subject), ("을", .object), ("를", .object),
            ("의", .genitive), ("은", .topic), ("는", .topic), ("도", .topic),
            ("만", .topic), ("조차", .topic), ("마저", .topic), ("까지", .topic),
            ("부터", .topic),
            // 호격 (부름 — 사람 신호). 아/야는 감탄사와 겹칠 수 있어 어간 길이로 방어.
            ("아", .vocative), ("야", .vocative), ("이여", .vocative),
        ]),
        subjectMarkers: ["이", "가", "은", "는"],
        speechVerbPrefixes: [
            "말했", "말하", "말한", "말을", "물었", "물으", "묻", "되물었",
            "답했", "답하", "대답", "외쳤", "외치", "중얼", "속삭", "덧붙",
            "내뱉", "소리쳤", "소리치", "읊", "뇌까", "되뇌", "웃으며", "웃었",
            "울먹", "다그", "타일", "털어놓", "부르짖", "중얼거",
        ],
        pronouns: [
            "그녀", "그들", "그이", "그대", "당신", "우리", "저희", "자신",
            "자기", "누구", "무엇", "여기", "저기", "거기", "이것", "그것",
            "저것", "이곳", "그곳", "저곳", "네가", "내가",
        ],
        honorifics: [
            "아버지", "어머니", "아버님", "어머님", "할아버지", "할머니",
            "아저씨", "아주머니", "선생님", "소장님", "사장님", "부장님",
            "과장님", "형님", "누님", "오빠", "언니", "누나", "동생", "아들",
            "딸", "부인", "영감", "마님", "나리", "도련님", "아가씨",
        ],
        stopwords: [
            // 사람 관련 일반명사 — 발화 주어가 될 수 있어 구조로 안 걸리는 소수.
            "사람", "남자", "여자", "아이", "노인", "청년", "소년", "소녀",
            "목소리", "모두", "누군가", "아무", "여럿", "사내", "여인",
            // 부사·접속사 안전망 (대부분 구조로 이미 걸림 — 이중 방어).
            "그러나", "그리고", "그런데", "하지만", "그래서", "그러면",
            "그러자", "그리하여", "다시", "천천히", "이제", "아직", "이미",
            "함께", "정말", "그냥", "가장", "물론", "역시", "결국", "마침내",
        ]
    )

    /// 사용자 확장 불용어를 병합한 현재 렉시콘. 파일이 없으면 기본값 그대로.
    /// 감지 패스마다 호출되므로 mtime으로 캐시한다(파일 안 바뀌면 재파싱 안 함).
    public static func current() -> CharacterLexicon {
        base.mergingUserStopwords(UserStopwords.load())
    }

    package func mergingUserStopwords(_ extra: Set<String>) -> CharacterLexicon {
        guard !extra.isEmpty else { return self }
        return CharacterLexicon(
            particles: particles, subjectMarkers: subjectMarkers,
            speechVerbPrefixes: speechVerbPrefixes, pronouns: pronouns,
            honorifics: honorifics, stopwords: stopwords.union(extra))
    }

    /// 제외 집합 — 대명사·호칭·불용어 통합 (어간이 이 안에 있으면 후보 아님).
    public var excluded: Set<String> {
        pronouns.union(honorifics).union(stopwords)
    }

    private static func sortedParticles(
        _ list: [(String, Role)]
    ) -> [(suffix: String, role: Role)] {
        list.map { (suffix: $0.0, role: $0.1) }
            .sorted { $0.suffix.count > $1.suffix.count }
    }
}

/// 사용자 확장 불용어 파일 로더 — `~/Documents/Purlory/character-stopwords.txt`.
/// 한 줄에 한 낱말, `#` 이후는 주석. mtime 캐시로 편집을 재빌드 없이 반영한다.
package enum UserStopwords {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (url: URL, mtime: Date, words: Set<String>)?

    package static func load(storageLocation: PurloryStorageLocation = .standard) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let url = storageLocation.stopwordsFileURL
        guard
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .modificationDate] as? Date
        else {
            cached = nil
            return []
        }
        if let cached, cached.url == url, cached.mtime == mtime { return cached.words }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let words = Set(
            text.split(separator: "\n")
                .map { line -> String in
                    let noComment = line.split(separator: "#", maxSplits: 1).first ?? ""
                    return noComment.trimmingCharacters(in: .whitespaces)
                }
                .filter { !$0.isEmpty })
        cached = (url, mtime, words)
        return words
    }
}
