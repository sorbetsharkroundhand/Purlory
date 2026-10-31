import Foundation

/// 발화의 존대 수준 (PLAN §6.4) — 한국어 대화 예측의 핵심 축.
public enum Politeness: String, Equatable, Sendable {
    case honorific = "존댓말"
    case plain = "반말"
}

/// 귀속된 발화 하나 (PLAN §7 대화 귀속).
///
/// 사이드카에 저장하지 않는다 — 추출이 결정적(LLM 없음)이라 패스마다 원문에서
/// 재계산하는 비용이 저장·무효화 관리 비용보다 싸다 (CLAUDE.md §2-5).
/// 스냅샷에만 실려 예측 조립이 질의한다.
public struct Utterance: Equatable, Sendable {
    /// 화자 — 등록된 `CharacterCard.id`만 (자동 등록 금지, CLAUDE.md §3).
    public var speakerID: UUID
    /// 대사 원문 (따옴표 제외) — 말투 예문·존대 판정의 재료.
    public var text: String
    /// 발화 시작 위치 (UTF-16) — 시점 차단 질의의 축 (CLAUDE.md §2-4).
    public var utf16Start: Int
    /// 같은 런의 상대 화자 — **2인 대화 런에서만** 채워진다. 존대 매트릭스의
    /// 방향(A→B)이 여기서 나온다. 3인 이상은 v1에서 방향을 추정하지 않는다.
    public var listenerID: UUID?
    /// 존대 판정 — 종결어미가 닫힌 규칙에 없으면 nil (품질 > 적극성).
    public var politeness: Politeness?
    /// Present only when explicit adjacent narration proves the named speaker.
    public var attributionRange: Range<Int>? = nil
}

/// 대화 귀속 (PLAN §7·§6.4, m6-prep 6단계) — **결정적 우선** (CLAUDE.md §2-5).
///
/// 규칙 두 단: ① 인접 서술 — 발화가 있는 문단의 서술부에 등록 인물 이름이
/// (발화 동사와 함께, 또는 유일하게) 나오면 그 인물. ② 교대 규칙 — 화자 둘이
/// 확정된 대화 런에서 미귀속 발화는 교대로 채운다.
/// 둘 다 실패하면 **귀속하지 않는다** — 모호할 때의 LLM 판정(PLAN §7)은
/// v2 (docs/m6-dialogue.md 보류 근거).
public enum DialogueAttribution {

    /// 말투 예문으로 쓰는 대사 상한 — 카드·대화 블록 예산 보호 (PLAN §11).
    public static let maxExampleCharacters = 40

    /// 인접 서술에서 화자를 지목하는 발화 동사 어간 — 활용형을 접두로 매칭한다
    /// ("말했다"·"말하며"·"말했지만" 전부 "말하"/"말했"에 걸린다).
    package static let speechVerbStems = [
        "말했", "말하", "물었", "묻는", "대답했", "대답하", "답했", "답하",
        "외쳤", "외치", "소리쳤", "소리치", "중얼거렸", "중얼거리",
        "속삭였", "속삭이", "덧붙였", "덧붙이", "되물었", "되묻",
        "입을 열었", "말을 이었", "말을 꺼냈",
    ]

    /// 본문 전체 → 담화 순서의 귀속된 발화들. 등록 카드가 없으면 빈 배열.
    ///
    /// O(n) 한 번 훑기 + 문단 단위 처리 — 30만 자에서도 밀리초 단위라
    /// 패스마다 재계산한다 (`CharacterDetector.detect`와 같은 예산).
    public static func utterances(
        in body: String, cards: [CharacterCard]
    ) -> [Utterance] {
        let nameIndex = EventParser.nameIndex(cards)
        guard !nameIndex.isEmpty else { return [] }
        // 긴 이름 우선 매칭 — "서연희"가 등록돼 있으면 "서연"보다 먼저 잡는다.
        let names = nameIndex.keys.sorted { $0.count > $1.count }

        // ① 문단별 발화·서술 분해 + 인접 서술 귀속.
        var paragraphs: [Paragraph] = []
        var utf16Pos = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { utf16Pos += line.utf16.count + 1 }  // +1 = 개행
            let quotes = quotedSpans(in: line)
            guard !quotes.isEmpty else {
                paragraphs.append(Paragraph(quotes: [], speaker: nil))
                continue
            }
            let narration = narrationText(of: line)
            let speaker = attributeFromNarration(
                narration, names: names, nameIndex: nameIndex)
            paragraphs.append(
                Paragraph(
                    quotes: quotes.map { span in
                        (text: span.text, start: utf16Pos + span.utf16Offset)
                    },
                    speaker: speaker))
        }

        // ② 대화 런으로 묶어 교대 규칙 적용 + 청자 방향 부여.
        var result: [Utterance] = []
        for run in dialogueRuns(paragraphs) {
            let attributed = fillByAlternation(run)
            let speakers = Set(attributed.compactMap(\.speaker))
            for paragraph in attributed {
                guard let speaker = paragraph.speaker else { continue }
                // 2인 런에서만 상대를 청자로 확정 — 3인 이상의 방향 추정은
                // 틀린 매트릭스를 만든다 (품질 > 적극성).
                let listener =
                    speakers.count == 2 ? speakers.first(where: { $0 != speaker }) : nil
                for quote in paragraph.quotes {
                    result.append(
                        Utterance(
                            speakerID: speaker,
                            text: quote.text,
                            utf16Start: quote.start,
                            listenerID: listener,
                            politeness: politeness(of: quote.text)))
                }
            }
        }
        return result.sorted { $0.utf16Start < $1.utf16Start }
    }

    /// Conservative attribution for style evidence, without discourse alternation.
    public static func explicitUtterances(in body: String, cards: [CharacterCard], beforeUTF16: Int? = nil) throws -> [Utterance] {
        guard !cards.isEmpty, cards.count <= 128 else { return [] }
        let source = body as NSString, end = beforeUTF16 ?? source.length
        guard end >= 0, end <= source.length,
              end == source.length || source.rangeOfComposedCharacterSequence(at: end).location == end else { return [] }
        var owners: [String: Set<UUID>] = [:]
        for card in cards {
            for raw in [card.name] + card.aliases.split(separator: ",").map(String.init) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name.utf16.count <= 64 { owners[name, default: []].insert(card.id) }
            }
        }
        guard owners.count <= 512 else { return [] }
        let verbs = speechVerbStems.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let patterns = try owners.map { name, ids in
            (ids, try NSRegularExpression(pattern: "(?:^|[\\s\\p{P}])" + NSRegularExpression.escapedPattern(for: name)
                + "(?:이|가|은|는|께서)\\s+(?:" + verbs + ")"))
        }
        var result: [Utterance] = [], offset = 0
        for line in source.substring(to: end).split(separator: "\n", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            defer { offset += line.utf16.count + 1 }
            guard line.utf16.count <= 2048 else { continue }
            let quotes = quotedSpans(in: line)
            guard quotes.count == 1, let quote = quotes.first, quote.text.utf16.count <= 768 else { continue }
            let narration = narrationText(of: line), range = NSRange(location: 0, length: narration.utf16.count)
            // Multiple declared names or a shared alias cannot prove a speaker.
            let mentioned = owners.filter { narration.contains($0.key) }.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
            guard mentioned.count == 1, let speaker = mentioned.first,
                  patterns.contains(where: { $0.0 == [speaker] && $0.1.firstMatch(in: narration, range: range) != nil }) else { continue }
            result.append(.init(speakerID: speaker, text: quote.text, utf16Start: offset + quote.utf16Offset,
                listenerID: nil, politeness: politeness(of: quote.text), attributionRange: offset..<(offset + line.utf16.count)))
        }
        return result
    }

    // MARK: - 존대 판정 (결정적 — 닫힌 종결어미 규칙)

    /// 발화 → 존대/반말. 문장별로 판정해 다수결, 갈리거나 못 읽으면 nil.
    ///
    /// 규칙이 **닫힌 집합**인 이유: 종결어미는 유한하고, 규칙 밖을 추정으로
    /// 채우면 틀린 존대 신호가 프롬프트에 실린다 — 침묵이 낫다 (CLAUDE.md §1-2).
    public static func politeness(of utterance: String) -> Politeness? {
        var honorific = 0
        var plain = 0
        for sentence in utterance.split(whereSeparator: { ".!?…。！？".contains($0) }) {
            switch sentencePoliteness(sentence) {
            case .honorific: honorific += 1
            case .plain: plain += 1
            case nil: break
            }
        }
        if honorific > 0, plain == 0 { return .honorific }
        if plain > 0, honorific == 0 { return .plain }
        return nil  // 혼재·판정 불가 — 발화 단위에선 침묵
    }

    /// 존대 종결 — "요"로 끝나거나 격식체(-니다/-니까/-십시오 등).
    private static let honorificSuffixes = [
        "요", "니다", "니까", "십시오", "십시다", "시죠", "소서",
    ]
    /// 반말 종결 — 해체·해라체의 흔한 꼬리. 모호한 음절은 넣지 않는다:
    /// "마" 단독은 "설마"·"엄마"를 먹는다 → 금지 명령은 "지 마"/"지마"로만.
    private static let plainSuffixes = [
        "야", "어", "아", "지", "자", "니", "냐", "래", "라", "지 마", "지마",
        "걸", "게", "군", "네", "든", "잖아", "거든", "다고", "다니까", "달라고",
    ]
    /// 반말로 오판하기 쉬운 평서형 — "~했다"·"~이다"는 서술이지 반말 대사체가
    /// 아닐 수 있으나, 대사 안에서는 해라체(반말)로 본다. 단 "니다"가 먼저다.
    private static let plainDeclarative = ["다"]

    private static func sentencePoliteness(_ sentence: Substring) -> Politeness? {
        // 꼬리 정리 — 공백·물결·반복 부호는 판정에서 뺀다 ("알겠어요~~" → "알겠어요").
        let trimmed = sentence.trimmingCharacters(
            in: CharacterSet(charactersIn: " \t~ㅋㅎㅠㅜ,"))
        guard !trimmed.isEmpty else { return nil }
        for suffix in honorificSuffixes where trimmed.hasSuffix(suffix) {
            return .honorific
        }
        for suffix in plainSuffixes where trimmed.hasSuffix(suffix) {
            return .plain
        }
        for suffix in plainDeclarative where trimmed.hasSuffix(suffix) {
            return .plain
        }
        return nil
    }

    // MARK: - 내부: 문단 분해

    private struct Paragraph {
        var quotes: [(text: String, start: Int)]
        var speaker: UUID?
        var hasQuotes: Bool { !quotes.isEmpty }
    }

    /// 여닫는 따옴표 쌍 — 큰따옴표 계열만 대사로 본다 (작은따옴표는 속마음·강조).
    private static let quotePairs: [(open: Character, close: Character)] = [
        ("“", "”"), ("\"", "\""), ("「", "」"), ("『", "』"),
    ]

    /// 한 문단에서 따옴표 안 대사들을 뽑는다 (UTF-16 상대 오프셋 포함).
    package static func quotedSpans(in line: Substring) -> [(text: String, utf16Offset: Int)] {
        var spans: [(String, Int)] = []
        var index = line.startIndex
        var utf16Offset = 0
        while index < line.endIndex {
            let char = line[index]
            if let pair = quotePairs.first(where: { $0.open == char }) {
                let contentStart = line.index(after: index)
                if let closeIndex = line[contentStart...].firstIndex(of: pair.close) {
                    let raw = line[contentStart..<closeIndex]
                    let leading = raw.unicodeScalars.prefix { CharacterSet.whitespaces.contains($0) }
                        .reduce(0) { $0 + String($1).utf16.count }
                    let text = String(raw).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        spans.append((text, utf16Offset + String(char).utf16.count + leading))
                    }
                    utf16Offset += line[index..<line.index(after: closeIndex)].utf16.count
                    index = line.index(after: closeIndex)
                    continue
                }
            }
            utf16Offset += String(char).utf16.count
            index = line.index(after: index)
        }
        return spans
    }

    /// 문단에서 대사를 걷어낸 서술부.
    private static func narrationText(of line: Substring) -> String {
        var text = String(line)
        for span in quotedSpans(in: line) {
            text = text.replacingOccurrences(of: span.text, with: "")
        }
        return text
    }

    /// 인접 서술 귀속 — 발화 동사 옆 이름이 최우선, 없으면 서술부의 유일한 이름.
    private static func attributeFromNarration(
        _ narration: String, names: [String], nameIndex: [String: UUID]
    ) -> UUID? {
        let mentioned = names.filter { narration.contains($0) }
        // 별칭이 본명의 부분 문자열인 경우("서연"/"연이") 같은 인물이면 하나로 본다.
        let ids = Set(mentioned.compactMap { nameIndex[$0] })
        guard !ids.isEmpty else { return nil }
        if ids.count == 1 { return ids.first }
        // 이름이 여럿이면 발화 동사에 가장 가까운 이름 — "서연이 민준을 보며
        // 말했다"에서 화자는 서연이다 (v1: 동사 앞에서 가장 가까운 이름).
        guard let verbRange = speechVerbRange(in: narration) else { return nil }
        var best: (id: UUID, distance: Int)?
        for name in mentioned {
            guard let id = nameIndex[name] else { continue }
            var searchStart = narration.startIndex
            while let range = narration.range(of: name, range: searchStart..<narration.endIndex) {
                if range.upperBound <= verbRange.lowerBound {
                    let distance = narration.distance(
                        from: range.upperBound, to: verbRange.lowerBound)
                    if best == nil || distance < best!.distance {
                        best = (id, distance)
                    }
                }
                searchStart = range.upperBound
            }
        }
        return best?.id
    }

    private static func speechVerbRange(in narration: String) -> Range<String.Index>? {
        var earliest: Range<String.Index>?
        for stem in speechVerbStems {
            if let range = narration.range(of: stem) {
                if earliest == nil || range.lowerBound < earliest!.lowerBound {
                    earliest = range
                }
            }
        }
        return earliest
    }

    // MARK: - 내부: 대화 런·교대 규칙

    /// 발화 문단들의 연속 구간(런) — 사이의 서술 문단은 1개까지 허용한다
    /// ("대사, 서술 한 줄, 대사"는 같은 대화다). 빈 줄 2연속·헤딩은 런을 끊는다.
    private static func dialogueRuns(_ paragraphs: [Paragraph]) -> [[Paragraph]] {
        var runs: [[Paragraph]] = []
        var current: [Paragraph] = []
        var gap = 0
        for paragraph in paragraphs {
            if paragraph.hasQuotes {
                current.append(paragraph)
                gap = 0
            } else if !current.isEmpty {
                gap += 1
                if gap > 1 {
                    runs.append(current)
                    current = []
                    gap = 0
                }
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// 교대 규칙 — 화자 둘이 확정된 런에서, 미귀속 문단을 이웃의 반대 화자로
    /// 채운다. 확정 화자가 0·1·3+명이면 채우지 않는다 (모호 — 침묵이 정답).
    private static func fillByAlternation(_ run: [Paragraph]) -> [Paragraph] {
        let known = run.compactMap(\.speaker)
        let speakers = Array(Set(known))
        guard speakers.count == 2 else { return run }

        var filled = run
        // 앞→뒤: 직전 확정 화자의 반대로 채운다. 연속 미귀속도 교대로 이어진다.
        var previous: UUID?
        for index in filled.indices {
            if let speaker = filled[index].speaker {
                previous = speaker
            } else if let last = previous {
                let next = speakers.first(where: { $0 != last })
                filled[index].speaker = next
                previous = next
            }
        }
        // 런 머리의 미귀속(직전 화자가 없던 구간)은 뒤에서 앞으로 한 번 더.
        var following: UUID?
        for index in filled.indices.reversed() {
            if let speaker = filled[index].speaker {
                following = speaker
            } else if let next = following {
                let previous = speakers.first(where: { $0 != next })
                filled[index].speaker = previous
                following = previous
            }
        }
        return filled
    }
}
