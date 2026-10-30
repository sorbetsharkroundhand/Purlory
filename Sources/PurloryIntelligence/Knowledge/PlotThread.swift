import Foundation

// Plot Thread (Narrative Graph의 branch 단위) — 하나의 지속적인 서사적 문제·
// 목표·갈등·미스터리·관계 변화를 추적하는 흐름.
//
// 핵심 원칙:
// - **Branch ≠ Character.** 같은 인물이 나온다고 같은 플롯이 아니고, 인물이
//   바뀌어도 같은 목표·갈등을 이으면 같은 플롯이다. 인물 흐름(NarrativeFlow)은
//   예측 컨텍스트용 파생물로 남고, 그래프의 레인은 PlotThread다.
// - **Branch ≠ 회상.** 회상·꿈·삽입 서사는 Narrative Traversal(서술 이동)이지
//   플롯이 아니다 — UI에서 별도 bracket으로 표현한다.
// - **LLM은 후보만, identity는 결정적으로.** 재분석마다 이름·ID가 흔들리면
//   오버라이드가 고아가 된다 — stableID는 여는 사건 키에서 파생하고, 재분석
//   결과는 멤버 겹침으로 이전 스레드에 잇는다 (reconcile).
// - 그래프 topology는 이 데이터에서만 나온다 — 레이아웃이 branch를 만들지
//   않는다 (요구사항 §11).

// MARK: - 역할·상태

/// 사건이 플롯에서 하는 역할 — LLM 추론 기본값 + 사용자 오버라이드.
public enum ThreadRole: String, Codable, Equatable, Sendable, CaseIterable {
    /// 플롯의 문제·목표·갈등이 처음 제시됨.
    case opens = "제시"
    case advances = "진행"
    /// 문제가 꼬이거나 심화됨.
    case complicates = "심화"
    /// 다른 플롯과 만나는 사건 (파생 계산도 하지만 명시 지정 가능).
    case intersects = "교차"
    /// 플롯의 핵심 질문·갈등이 해결됨.
    case resolves = "해결"
    /// 플롯이 언급만 됨 (진행 없음).
    case references = "언급"

    public static func normalize(_ raw: String) -> ThreadRole {
        if let exact = ThreadRole(rawValue: raw) { return exact }
        if raw.contains("제시") || raw.contains("시작") { return .opens }
        if raw.contains("해결") || raw.contains("종결") { return .resolves }
        if raw.contains("심화") || raw.contains("악화") { return .complicates }
        if raw.contains("교차") || raw.contains("합류") { return .intersects }
        if raw.contains("언급") { return .references }
        return .advances
    }
}

/// 플롯 생명주기 — RESOLVED만 저장 근거(해결 사건)가 있고, OPEN/ACTIVE/DORMANT는
/// 스냅샷 조립 때 담화 위치에서 결정적으로 파생한다 (저장하지 않는다).
public enum ThreadStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case open = "열림"
    case active = "진행"
    /// 한동안 다뤄지지 않지만 미해결 — **branch를 끝내지 않는다** (레인 유지).
    case dormant = "휴면"
    case resolved = "해결"
}

// MARK: - 저장 모델 (사이드카)

/// 사건 하나의 플롯 소속 — (사건 키, 역할).
public struct EventThreadMembership: Codable, Equatable, Sendable {
    /// `StoryEvent.stableKey` (저장 시점) — 스냅샷 조립이 정본 키로 정규화한다.
    public var eventKey: String
    public var role: ThreadRole

    public init(eventKey: String, role: ThreadRole = .advances) {
        self.eventKey = eventKey
        self.role = role
    }
}

/// 플롯 스레드 하나 (사이드카 저장) — LLM 추론 결과.
public struct PlotThread: Codable, Equatable, Sendable, Identifiable {
    /// persistent ID — 최초 추론 시 여는 사건 키에서 파생돼 **저장**된다.
    /// 재분석은 reconcile로 이전 ID를 물려받으므로, 문서가 길어져도 같은
    /// 플롯은 같은 ID를 유지한다 (오버라이드·색·레인의 앵커).
    public var stableID: String
    /// ≤20자 — "살인사건의 진실", "아버지와의 갈등".
    public var title: String
    /// ≤60자 — 이 플롯이 추적하는 문제.
    public var summary: String
    /// 멤버 사건들 (담화 순서) — 한 사건이 여러 스레드에 속할 수 있다.
    public var memberships: [EventThreadMembership]
    /// 해결 사건 키 — 있으면 RESOLVED (사용자가 오버라이드로 뒤집을 수 있다).
    public var resolvedAtKey: String?
    /// 추론 확신 0–1.
    public var confidence: Double

    public var id: String { stableID }

    public init(
        stableID: String? = nil, title: String, summary: String = "",
        memberships: [EventThreadMembership], resolvedAtKey: String? = nil,
        confidence: Double = 0.6
    ) {
        self.stableID =
            stableID
            ?? Self.makeStableID(openingKey: memberships.first?.eventKey ?? title)
        self.title = title
        self.summary = summary
        self.memberships = memberships
        self.resolvedAtKey = resolvedAtKey
        self.confidence = confidence
    }

    /// ID 파생 — 여는 사건의 stableKey가 근원. 사건 요약이 안 바뀌는 한
    /// 재분석에도 같은 ID가 나온다 (§27 persistent ID 규율).
    public static func makeStableID(openingKey: String) -> String {
        "thr-" + DocumentOutline.stableHash("thread|\(openingKey)")
    }

    /// 본줄기(잔여 사건 폴백) 스레드의 고정 ID.
    public static let mainID = "thread-main"
}

/// 플롯 추론 결과 (사이드카 저장 단위) — EventGraphAnalysis와 같은 메모 규율.
public struct PlotThreadAnalysis: Codable, Equatable, Sendable {
    public var threads: [PlotThread]
    /// 분석에 넣은 사건 키 집합의 결합 해시 — 같으면 재분석하지 않는다.
    public var memoHash: String
    public var updatedAt: Date

    public init(threads: [PlotThread] = [], memoHash: String = "", updatedAt: Date = .now) {
        self.threads = threads
        self.memoHash = memoHash
        self.updatedAt = updatedAt
    }
}

// MARK: - LLM 출력 파서 (관대한 파싱 · 엄격한 검증)

/// 플롯 추론 출력의 파서 — EventGraphParser와 같은 번호 참조 규율.
///
/// 기대 형식 (한 줄에 플롯 하나):
/// ```
/// 플롯: 1,3,5,8 | 제목: 살인사건의 진실 | 요약: 남편의 죽음을 파헤친다 | 해결: 8
/// ```
public enum PlotThreadParser {

    /// 스레드 수 상한 — 플롯이 사건마다 생기면 소음이다.
    package static let maxThreads = 6
    package static let maxTitleCharacters = 20
    package static let maxSummaryCharacters = 60
    /// 멤버 최소 수 — 사건 하나짜리 플롯은 근거 부족 (품질 > 적극성).
    package static let minMembers = 2

    /// `keys`: 프롬프트에 넣은 번호 순서의 사건 stableKey들.
    public static func parse(_ output: String, keys: [String]) -> [PlotThread] {
        var threads: [PlotThread] = []
        var claimedTitles: Set<String> = []

        func key(_ number: Int) -> String? {
            (1...keys.count).contains(number) ? keys[number - 1] : nil
        }

        for rawLine in output.split(separator: "\n") {
            guard threads.count < maxThreads else { break }
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard line.hasPrefix("플롯") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let fields = line[line.index(after: colon)...]
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = fields.first else { continue }

            // 멤버 번호 — 중복 제거, 담화 순서 정렬.
            let numbers = Array(
                Set(
                    first.split(whereSeparator: { !$0.isNumber })
                        .compactMap { Int($0) })
            ).sorted()
            let memberKeys = numbers.compactMap { key($0) }
            guard memberKeys.count >= minMembers else { continue }

            var title = ""
            var summary = ""
            var resolvedAt: String?
            for field in fields.dropFirst() {
                guard let c = field.firstIndex(of: ":") else { continue }
                let k = field[..<c].trimmingCharacters(in: .whitespaces)
                let v = field[field.index(after: c)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !v.isEmpty else { continue }
                switch k {
                case "제목", "이름": title = String(v.prefix(maxTitleCharacters))
                case "요약": summary = String(v.prefix(maxSummaryCharacters))
                case "해결", "종결":
                    resolvedAt = v.split(whereSeparator: { !$0.isNumber })
                        .compactMap { Int($0) }.first.flatMap { key($0) }
                default: break
                }
            }
            guard !title.isEmpty, claimedTitles.insert(title).inserted else { continue }
            // 해결 사건은 멤버여야 한다 (멤버 밖 해결은 근거 없음).
            if let resolved = resolvedAt, !memberKeys.contains(resolved) {
                resolvedAt = nil
            }

            let memberships = memberKeys.enumerated().map { offset, memberKey in
                EventThreadMembership(
                    eventKey: memberKey,
                    role: memberKey == resolvedAt
                        ? .resolves : offset == 0 ? .opens : .advances)
            }
            threads.append(
                PlotThread(
                    title: title, summary: summary,
                    memberships: memberships, resolvedAtKey: resolvedAt,
                    confidence: 0.6))
        }
        return threads
    }

    // MARK: - Stable identity reconciliation (요구사항 §10)

    /// 재분석 결과를 이전 스레드에 잇는다 — 멤버 겹침이 과반이면 같은 플롯으로
    /// 보고 이전 stableID(오버라이드·색의 앵커)를 물려받는다. 문서가 길어지며
    /// 여는 사건이 바뀌어도(앞에 새 사건 추가) identity가 유지되는 근거.
    /// 이전 ID 하나는 새 스레드 하나에만 붙는다 (겹침 큰 쪽 우선, 결정적).
    public static func reconcile(
        new: [PlotThread], previous: [PlotThread]
    ) -> [PlotThread] {
        guard !previous.isEmpty else { return new }
        // (새 인덱스, 이전 인덱스, 겹침 수) 전 쌍 — 겹침 내림차순, 동률은
        // (이전 ID, 새 인덱스) 순으로 결정적.
        var candidates: [(newIndex: Int, prevIndex: Int, overlap: Int)] = []
        for (newIndex, thread) in new.enumerated() {
            let members = Set(thread.memberships.map(\.eventKey))
            for (prevIndex, old) in previous.enumerated() {
                let overlap = members.intersection(old.memberships.map(\.eventKey)).count
                let smaller = min(members.count, old.memberships.count)
                // 과반 겹침만 동일 플롯 후보.
                guard overlap * 2 >= smaller, overlap >= 1 else { continue }
                candidates.append((newIndex, prevIndex, overlap))
            }
        }
        candidates.sort {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if previous[$0.prevIndex].stableID != previous[$1.prevIndex].stableID {
                return previous[$0.prevIndex].stableID < previous[$1.prevIndex].stableID
            }
            return $0.newIndex < $1.newIndex
        }

        var result = new
        var usedNew: Set<Int> = []
        var usedPrev: Set<Int> = []
        for candidate in candidates {
            guard !usedNew.contains(candidate.newIndex),
                !usedPrev.contains(candidate.prevIndex)
            else { continue }
            usedNew.insert(candidate.newIndex)
            usedPrev.insert(candidate.prevIndex)
            result[candidate.newIndex].stableID = previous[candidate.prevIndex].stableID
        }
        return result
    }
}

// MARK: - 파생 스레드 (스냅샷 조립 결과 — 저장하지 않는다)

/// 오버라이드·정본 정규화·상태 파생을 적용한 스레드 — 그래프 UI의 레인 단위.
public struct ResolvedPlotThread: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var status: ThreadStatus
    /// 정본 사건 키들 (담화 순서) — topology의 근원.
    public var memberKeys: [String]
    public var roleByKey: [String: ThreadRole]
    public var resolvedAtKey: String?
    /// 잔여 사건 폴백(본줄기)인가 — 레인 0 고정·액센트색.
    public var isMain: Bool
    public var userEdited: Bool
    public var confidence: Double

    /// 안정 색 시드 — stableID 해시 (NarrativeFlow.colorSeed와 같은 규칙).
    public var colorSeed: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int(hash % 997)
    }

    /// 사건이 이 스레드를 여는가/해결하는가.
    public func role(of key: String) -> ThreadRole? { roleByKey[key] }

    /// DORMANT 판정 간격 — 마지막 멤버 이후 이만큼의 사건이 지나면 휴면.
    public static let dormantGap = 6

    /// 스냅샷 조립: 저장 스레드 + 오버라이드 → 파생 스레드 목록.
    ///
    /// - 멤버 키를 정본 키로 정규화하고 죽은 참조를 버린다.
    /// - 멤버십 오버라이드(키 "threadID|정본키", 값 = 역할 or "제외")를 얹는다.
    /// - 상태를 파생한다: 해결 사건 있음 → resolved, 멤버 1개 → open,
    ///   마지막 멤버 뒤로 dormantGap 이상 지남 → dormant, 그 외 active.
    ///   상태 오버라이드가 항상 이긴다.
    /// - 어느 스레드에도 안 속한 사건은 **본줄기**(mainID)로 접는다 — 분석이
    ///   없는 직선 소설은 자연히 레인 하나짜리 그래프가 된다.
    public static func derive(
        analysis: PlotThreadAnalysis?,
        canonicalOrder: [String],
        memberMap: [String: String],
        overrides: NarrativeOverrides
    ) -> [ResolvedPlotThread] {
        let index = Dictionary(
            uniqueKeysWithValues: canonicalOrder.enumerated().map { ($0.element, $0.offset) })
        let titleOverrides = overrides.map(of: .threadTitle)
        let statusOverrides = overrides.map(of: .threadStatus)
        let membershipOverrides = overrides.map(of: .threadMembership)

        var threads: [ResolvedPlotThread] = []
        var claimed: Set<String> = []

        for stored in analysis?.threads ?? [] {
            // 정본 정규화 — 같은 정본에 접힌 멤버는 하나로.
            var ordered: [String] = []
            var roles: [String: ThreadRole] = [:]
            for membership in stored.memberships {
                let canonical = memberMap[membership.eventKey] ?? membership.eventKey
                guard index[canonical] != nil else { continue }
                if roles[canonical] == nil { ordered.append(canonical) }
                roles[canonical] = membership.role
            }
            var resolvedAt = stored.resolvedAtKey.flatMap { raw -> String? in
                let canonical = memberMap[raw] ?? raw
                return index[canonical] != nil ? canonical : nil
            }

            // 멤버십 오버라이드 — 사용자가 사건을 넣고 빼고 역할을 고친다.
            var userEdited = false
            for (key, value) in membershipOverrides {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == stored.stableID,
                    index[parts[1]] != nil
                else { continue }
                userEdited = true
                if value == "제외" {
                    ordered.removeAll { $0 == parts[1] }
                    roles[parts[1]] = nil
                    if resolvedAt == parts[1] { resolvedAt = nil }
                } else {
                    let role = ThreadRole.normalize(value)
                    if roles[parts[1]] == nil { ordered.append(parts[1]) }
                    roles[parts[1]] = role
                    if role == .resolves { resolvedAt = parts[1] }
                }
            }
            ordered.sort { (index[$0] ?? 0) < (index[$1] ?? 0) }
            guard !ordered.isEmpty else { continue }
            claimed.formUnion(ordered)

            let title = titleOverrides[stored.stableID] ?? stored.title
            let status = deriveStatus(
                statusOverride: statusOverrides[stored.stableID],
                resolvedAt: resolvedAt, members: ordered,
                index: index, total: canonicalOrder.count)
            threads.append(
                ResolvedPlotThread(
                    id: stored.stableID,
                    title: title,
                    summary: stored.summary,
                    status: status,
                    memberKeys: ordered,
                    roleByKey: roles,
                    resolvedAtKey: status == .resolved ? resolvedAt : nil,
                    isMain: false,
                    userEdited: userEdited
                        || titleOverrides[stored.stableID] != nil
                        || statusOverrides[stored.stableID] != nil,
                    confidence: stored.confidence))
        }

        // 본줄기 — 어느 스레드에도 안 속한 사건들. 분석 전이면 전부 = 직선 그래프.
        let unclaimed = canonicalOrder.filter { !claimed.contains($0) }
        if !unclaimed.isEmpty {
            threads.append(
                ResolvedPlotThread(
                    id: PlotThread.mainID,
                    title: overrides.value(.threadTitle, key: PlotThread.mainID) ?? "본줄기",
                    summary: "",
                    status: .active,
                    memberKeys: unclaimed,
                    roleByKey: [:],
                    resolvedAtKey: nil,
                    isMain: true,
                    userEdited: overrides.value(.threadTitle, key: PlotThread.mainID) != nil,
                    confidence: 1))
        }

        // 정렬 — 본줄기 먼저, 나머지는 (첫 멤버 담화 위치, ID) — 결정적.
        threads.sort { a, b in
            if a.isMain != b.isMain { return a.isMain }
            let ai = a.memberKeys.first.flatMap { index[$0] } ?? .max
            let bi = b.memberKeys.first.flatMap { index[$0] } ?? .max
            if ai != bi { return ai < bi }
            return a.id < b.id
        }
        return threads
    }

    package static func deriveStatus(
        statusOverride: String?,
        resolvedAt: String?,
        members: [String],
        index: [String: Int],
        total: Int
    ) -> ThreadStatus {
        if let raw = statusOverride, let status = ThreadStatus(rawValue: raw) {
            return status
        }
        if resolvedAt != nil { return .resolved }
        if members.count == 1 { return .open }
        let last = members.compactMap { index[$0] }.max() ?? 0
        // 마지막 멤버 이후 지난 사건 수 — dormantGap 이상이면 휴면 (레인은 유지).
        return (total - 1 - last) >= dormantGap ? .dormant : .active
    }
}
