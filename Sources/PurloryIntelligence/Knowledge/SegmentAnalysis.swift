import Foundation

// 서사 구간 분석 (요구사항 §7–§10) — 씬 내부 시간·관점 전환의 다단계 파이프라인.
//
// 단계 (요구사항 §10 — 단일 flashback=true 판정 금지):
// 1. **결정적 후보 감지** (`TemporalShiftDetector`) — 시간 이동 표지가 하나도
//    없는 씬은 LLM을 부르지 않고 "단일 현재 서사"로 메모한다 (토큰 절약 게이트).
// 2. **LLM 구간 추출** — 후보가 있는 씬만 structured 줄 형식 한 번의 호출로
//    구간 목록(층·시작/끝 인용·복귀·깊이·시점·출처)을 뽑는다.
// 3. **파서 검증** (`SegmentParser`) — 인용을 씬 원문과 대조해 위치를 확정한다.
//    시작 인용이 원문에 없으면 구간째 버린다 (환각 경계는 없느니만 못하다).
//    끝 인용이 없거나 못 찾으면 **uncertain** — 임의로 씬 끝까지 회상으로
//    확정하지 않는다 (요구사항 §9).
// 4. 중첩·복귀는 깊이 스택으로 계층화하고, Branch·Event 연결과 시간 정합성은
//    스냅샷 조립(KnowledgeSnapshot)이 담당한다.

// MARK: - 1단: 결정적 시간 이동 후보 감지

/// 씬에 시간 이동(회상·꿈·기록) 후보가 있는지의 빠른 판정 — LLM 호출 게이트.
/// 과거형 어미("~았다")는 표지가 아니다 — 한국어 소설 서술 자체가 과거형이다
/// (요구사항 §7 "과거형 문장이 있다는 이유만으로 회상 판단 금지").
public enum TemporalShiftDetector {

    /// 시간 이동을 시사하는 표지들 — 어휘·구문 신호만 (시제 아님).
    package static let markers: [String] = [
        // 회상 진입 동사
        "떠올렸", "떠올리", "회상", "기억이 났", "기억을 더듬", "기억 속",
        "생각이 났", "되짚었", "돌이켜",
        // 시점 이동 부사구
        "그날", "그때", "그 시절", "어린 시절", "학창 시절", "예전에", "오래전",
        "옛날", "년 전", "달 전", "주 전", "어렸을 때", "젊었을 때", "신혼",
        // 대과거 (과거 속 과거의 문법 신호 — 이것만으로는 부족하지만 후보는 된다)
        "았었", "었었",
        // 꿈·기록
        "꿈에", "꿈속", "꿈을 꾸", "편지에", "편지를", "일기에", "일기를",
        "기록에", "수첩에",
        // 구술 (인물이 설명하는 과거)
        "그러니까 그게", "말해 줄게", "이야기해 주",
    ]

    /// 씬 원문에 시간 이동 후보가 있는가.
    public static func hasCandidate(in sceneText: String) -> Bool {
        markers.contains { sceneText.contains($0) }
    }
}

// MARK: - 3단: LLM 출력 파서 (관대한 파싱 · 엄격한 검증)

/// 구간 추출 출력의 파서 — EventParser와 같은 규율.
///
/// 기대 형식 (한 줄에 구간 하나):
/// ```
/// 구간: 층=회상 | 시작="남편은 어린 시절을 떠올렸다" | 끝="다시 방 안이었다" | \
/// 복귀=확인 | 깊이=1 | 시점=남편 | 화자=3인칭 | 초점=남편 | 인물=남편 | \
/// 출처=기억 | 신뢰=유력
/// ```
public enum SegmentParser {

    /// 씬 하나에서 받는 구간 수 상한 — 문장마다 구간을 만들면 소음이다.
    package static let maxSegmentsPerScene = 6
    /// 인용 상한 — Source Evidence 규격과 동일.
    package static let maxQuoteCharacters = 40

    public static func parse(
        _ output: String, sceneHash: String, sceneText: String
    ) -> [NarrativeSegment] {
        let ns = sceneText as NSString
        var segments: [NarrativeSegment] = []
        // 깊이 스택 — parentID 연결용 (깊이 d의 부모 = 마지막 깊이 d-1 구간).
        var lastAtDepth: [Int: String] = [:]

        for rawLine in output.split(separator: "\n") {
            guard segments.count < maxSegmentsPerScene else { break }
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard line.hasPrefix("구간") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let fields = line[line.index(after: colon)...]
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            var layer: NarrativeSegment.Layer?
            var startQuote: String?
            var endQuote: String?
            var returnRaw: String?
            var depth = 1
            var pov: String?
            var narrator: String?
            var focal: String?
            var subject: String?
            var sourceRaw: String?
            var reliabilityRaw: String?

            for field in fields {
                guard let equals = field.firstIndex(of: "=") else { continue }
                let key = field[..<equals].trimmingCharacters(in: .whitespaces)
                let value = field[field.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                switch key {
                case "층", "종류": layer = NarrativeSegment.Layer.normalize(value)
                case "시작": startQuote = unquote(value)
                case "끝": endQuote = unquote(value)
                case "복귀": returnRaw = value
                case "깊이": depth = min(3, max(1, Int(value.filter(\.isNumber)) ?? 1))
                case "시점": pov = String(value.prefix(20))
                case "화자", "서술자": narrator = String(value.prefix(20))
                case "초점": focal = String(value.prefix(20))
                case "인물", "주체": subject = String(value.prefix(20))
                case "출처": sourceRaw = value
                case "신뢰": reliabilityRaw = value
                default: break
                }
            }

            // 검증 ① 층 — 시간 이동 층만 구간이 된다. "현재"·"언급"·판독 불가는
            // 구간을 만들지 않는다 (씬 바탕이 이미 현재다).
            guard let layer, layer.isTemporalShift else { continue }
            // 검증 ② 시작 인용 — 원문에 실제로 있어야 한다 (환각 경계 차단).
            guard let start = startQuote.flatMap({ locate($0, in: ns) }) else { continue }

            // 끝 인용 — 시작 이후에서 찾는다. 못 찾으면 uncertain으로 씬 끝까지
            // "잠정" 범위만 잡는다 (확정 아님 — returnState가 그 사실을 보존한다).
            var end = ns.length
            var returnState = NarrativeSegment.ReturnState.uncertain
            if let quote = endQuote,
                let found = locate(quote, in: ns, from: start.location + start.length)
            {
                end = found.location + found.length
                returnState = .found
            } else if returnRaw?.contains("씬끝") == true || returnRaw?.contains("끝") == true {
                returnState = .sceneEnd
            }

            let source = sourceRaw.map { PerspectiveSource.normalize($0) } ?? defaultSource(of: layer)
            let segment = NarrativeSegment(
                sceneHash: sceneHash,
                localStart: start.location,
                localEnd: max(end, start.location + start.length),
                startQuote: String(startQuote!.prefix(maxQuoteCharacters)),
                endQuote: returnState == .found
                    ? endQuote.map { String($0.prefix(maxQuoteCharacters)) } : nil,
                layer: layer,
                depth: depth,
                parentID: depth >= 2 ? lastAtDepth[depth - 1] : nil,
                returnTargetID: depth >= 2 ? lastAtDepth[depth - 1] : nil,
                returnState: returnState,
                pov: pov, narrator: narrator,
                focalCharacter: focal, subjectCharacter: subject ?? pov,
                source: source,
                reliability: reliabilityRaw.map { SourceReliability.normalize($0) }
                    ?? source.defaultReliability,
                confidence: returnState == .found ? 0.8 : 0.55)
            lastAtDepth[depth] = segment.id
            segments.append(segment)
        }
        return segments.sorted { ($0.localStart, $0.depth) < ($1.localStart, $1.depth) }
    }

    /// 사용자 경계 수정 적용 (요구사항 §15) — 시작/종료 인용 오버라이드를 씬
    /// 원문에서 되찾아 구간 범위를 다시 잡는다. persistentID가 저장돼 있어
    /// 경계를 고쳐도 다른 오버라이드(층·시점 등)가 그대로 붙어 있다.
    /// 인용을 원문에서 못 찾으면 기존 경계를 유지한다 (stale이 오적용보다 낫다).
    public static func applyingBoundaryOverrides(
        _ segments: [String: SceneSegmentation],
        overrides: NarrativeOverrides,
        outline: DocumentOutline,
        body: String
    ) -> [String: SceneSegmentation] {
        let starts = overrides.map(of: .segmentStart)
        let ends = overrides.map(of: .segmentEnd)
        guard !starts.isEmpty || !ends.isEmpty else { return segments }
        let text = body as NSString
        var result = segments
        for scene in outline.scenes {
            guard var stored = result[scene.contentHash] else { continue }
            var changed = false
            let sceneRange = NSRange(
                location: scene.utf16Range.lowerBound, length: scene.utf16Range.count)
            guard sceneRange.location + sceneRange.length <= text.length else { continue }
            let sceneText = text.substring(with: sceneRange) as NSString
            for index in stored.segments.indices {
                let id = stored.segments[index].persistentID
                if let raw = starts[id], let quote = unquote(raw),
                    let found = locate(quote, in: sceneText)
                {
                    stored.segments[index].localStart = found.location
                    stored.segments[index].startQuote = String(quote.prefix(maxQuoteCharacters))
                    stored.segments[index].confidence = 1
                    changed = true
                }
                if let raw = ends[id], let quote = unquote(raw),
                    let found = locate(
                        quote, in: sceneText,
                        from: stored.segments[index].localStart)
                {
                    stored.segments[index].localEnd = found.location + found.length
                    stored.segments[index].endQuote = String(quote.prefix(maxQuoteCharacters))
                    stored.segments[index].returnState = .found
                    stored.segments[index].confidence = 1
                    changed = true
                }
            }
            if changed { result[scene.contentHash] = stored }
        }
        return result
    }

    /// 층별 기본 출처 — 모델이 출처를 생략했을 때의 보수적 기본값.
    package static func defaultSource(of layer: NarrativeSegment.Layer) -> PerspectiveSource {
        switch layer {
        case .flashback, .briefMemory: .memory
        case .retelling: .testimony
        case .dream: .dream
        case .document: .document
        case .renarration: .memory
        case .present, .mention, .flashforward, .uncertain: .directlyNarrated
        }
    }

    /// 따옴표류 제거 (EventParser.validatedQuote와 같은 규격의 앞뒤 정리).
    package static func unquote(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespaces)
        let wrappers: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "「", "」", "『", "』"]
        while let first = cleaned.first, wrappers.contains(first) { cleaned.removeFirst() }
        while let last = cleaned.last, wrappers.contains(last) { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.count >= 4 ? cleaned : nil
    }

    /// 인용 위치 찾기 — 전체 실패 시 앞 12자로 한 번 더 (모델의 꼬리 다듬기 대응).
    package static func locate(
        _ quote: String, in text: NSString, from location: Int = 0
    ) -> NSRange? {
        guard location < text.length else { return nil }
        let searchRange = NSRange(location: location, length: text.length - location)
        var range = text.range(of: quote, options: [], range: searchRange)
        if range.location == NSNotFound, quote.count > 12 {
            range = text.range(
                of: String(quote.prefix(12)), options: [], range: searchRange)
        }
        return range.location == NSNotFound ? nil : range
    }
}

// MARK: - 사건 그래프 분석 파서 (요구사항 §3·§6·§12·§29)

/// 사건 목록 전체를 한 번의 호출로 대조한 출력의 파서 — 인과·동일 사건·시간.
///
/// 기대 형식 (충돌 검사와 같은 번호 참조 방식):
/// ```
/// 인과: 3 -> 7 | 종류: 원인 | 이유: 과거의 실패가 범행 동기가 됐다
/// 동일: 2 & 9
/// 시간: 4 < 1
/// ```
public enum EventGraphParser {

    public struct Result: Equatable, Sendable {
        public var causalLinks: [CausalLink]
        public var identities: [EventIdentity]
        public var chronoEdges: [ChronoEdge]
        package init(causalLinks: [CausalLink], identities: [EventIdentity], chronoEdges: [ChronoEdge]) {
            self.causalLinks = causalLinks; self.identities = identities; self.chronoEdges = chronoEdges
        }
    }

    package static let maxLinks = 12
    package static let maxIdentities = 8
    package static let maxChronoEdges = 12

    /// `keys`: 프롬프트에 넣은 번호 순서의 사건 stableKey들.
    public static func parse(_ output: String, keys: [String]) -> Result {
        var links: [CausalLink] = []
        var identityPairs: [(Int, Int)] = []
        var chrono: [ChronoEdge] = []

        func key(_ number: Int) -> String? {
            (1...keys.count).contains(number) ? keys[number - 1] : nil
        }

        for rawLine in output.split(separator: "\n") {
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...]
            let fields = rest.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = fields.first else { continue }
            let numbers = first.split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }

            switch head {
            case "인과":
                guard links.count < maxLinks, numbers.count >= 2,
                    let from = key(numbers[0]), let to = key(numbers[1]), from != to
                else { continue }
                var kind = CausalLink.Kind.causes
                var reason = ""
                for field in fields.dropFirst() {
                    guard let c = field.firstIndex(of: ":") else { continue }
                    let k = field[..<c].trimmingCharacters(in: .whitespaces)
                    let v = field[field.index(after: c)...]
                        .trimmingCharacters(in: .whitespaces)
                    if k == "종류" { kind = normalizeKind(v) }
                    if k == "이유" { reason = String(v.prefix(60)) }
                }
                links.append(CausalLink(fromKey: from, toKey: to, kind: kind, reason: reason))
            case "동일":
                guard identityPairs.count < maxIdentities, numbers.count >= 2,
                    numbers[0] != numbers[1],
                    key(numbers[0]) != nil, key(numbers[1]) != nil
                else { continue }
                identityPairs.append((numbers[0], numbers[1]))
            case "시간":
                guard chrono.count < maxChronoEdges, numbers.count >= 2,
                    let a = key(numbers[0]), let b = key(numbers[1]), a != b
                else { continue }
                let relation: ChronoRelation =
                    first.contains("<") ? .before
                    : first.contains(">") ? .after
                    : first.contains("~") || first.contains("=") ? .simultaneous
                    : .unknown
                guard relation != .unknown else { continue }
                chrono.append(ChronoEdge(aKey: a, bKey: b, relation: relation))
            default:
                continue
            }
        }

        // 동일 쌍 → 연결 성분으로 접는다 (2 & 9, 9 & 12 → {2, 9, 12}).
        // 정본은 담화 순서상 첫 번째(가장 작은 번호) 멤버다.
        var groups: [Set<Int>] = []
        for (a, b) in identityPairs {
            let touching = groups.enumerated().filter {
                $0.element.contains(a) || $0.element.contains(b)
            }
            var mergedGroup: Set<Int> = [a, b]
            for (offset, group) in touching.reversed() {
                mergedGroup.formUnion(group)
                groups.remove(at: offset)
            }
            groups.append(mergedGroup)
        }
        let identities = groups.compactMap { group -> EventIdentity? in
            let ordered = group.sorted()
            let memberKeys = ordered.compactMap { key($0) }
            guard memberKeys.count >= 2, let canonical = memberKeys.first else { return nil }
            return EventIdentity(canonicalKey: canonical, memberKeys: memberKeys)
        }
        .sorted { $0.canonicalKey < $1.canonicalKey }

        // 같은 (방향, 쌍) 중복 제거.
        var seen: Set<String> = []
        let dedupedLinks = links.filter { seen.insert($0.id).inserted }
        var seenChrono: Set<String> = []
        let dedupedChrono = chrono.filter { seenChrono.insert($0.id).inserted }

        return Result(
            causalLinks: dedupedLinks, identities: identities, chronoEdges: dedupedChrono)
    }

    package static func normalizeKind(_ raw: String) -> CausalLink.Kind {
        if let exact = CausalLink.Kind(rawValue: raw) { return exact }
        if raw.contains("원인") || raw.contains("cause") { return .causes }
        if raw.contains("영향") { return .influences }
        if raw.contains("폭로") || raw.contains("드러") { return .reveals }
        if raw.contains("설명") { return .explains }
        if raw.contains("모순") { return .contradicts }
        if raw.contains("복선") || raw.contains("암시") { return .foreshadows }
        return .causes
    }
}
