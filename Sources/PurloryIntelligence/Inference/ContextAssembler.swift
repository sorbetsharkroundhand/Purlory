import Foundation

/// 활성 문서의 메타·바이블 스냅샷 (PLAN §10) — MainActor(EntryStore)에서
/// 값 복사로 격리 경계를 넘긴다 (CompletionParameters와 같은 패턴).
public struct DocumentContext: Sendable, Equatable {
    public var title: String
    public var kind: EntryKind
    public var genre: String?
    public var characters: [CharacterCard]
    /// 이 스냅샷이 뜯어낸 문서 — 리포트·오버라이드가 어느 작품 소속인지 판정하는
    /// 기준 (이슈 #8). nil이면 구형 호출자(프리뷰 등).
    public var entryID: UUID?

    public init(
        title: String,
        kind: EntryKind,
        genre: String? = nil,
        characters: [CharacterCard] = [],
        entryID: UUID? = nil
    ) {
        self.title = title
        self.kind = kind
        self.genre = genre
        self.characters = characters
        self.entryID = entryID
    }
}

/// AI 컨텍스트 리포트 (요구사항 §17) — **실제로 프롬프트에 실린 것만** 담는다.
/// 조립이 항목을 넣는 바로 그 자리에서 리포트에도 넣으므로, 인스펙터가 보는
/// 것과 모델이 받은 것이 구조적으로 같다 (별도 프리뷰 데이터 금지).
public struct ContextReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case meta = "문서 정보"
            case card = "인물 카드"
            case state = "인물 상태"
            case knowledge = "인물 앎"
            case recentEvent = "최근 사건"
            case workSummary = "지난 줄거리"
            case chapterSummary = "장 요약"
            case sceneSummary = "앞선 장면"
            case currentScene = "지금 장면"
            case cohort = "장면 인물"
            case narrative = "서사 위치"
            case flowEvent = "흐름 사건"
            case dialogue = "대화 모드"
            case relation = "관계"
            case originalNameAnchor = "이전 원문"
        }

        public var kind: Kind
        /// 프롬프트에 실린 줄 그대로.
        public var text: String
        /// 원문 보기 — 본문 검색 질의(인용·스니펫). nil이면 원문 앵커 없음.
        public var jumpQuery: String?
        /// 원문 보기 — UTF-16 위치 (스니펫은 UI가 본문에서 만든다).
        public var jumpUTF16: Int?
        /// Pin/Exclude의 안정 키 (요구사항 §31) — 항목의 논리적 정체
        /// (종류 + 앵커). 인스펙터의 고정/제외 오버라이드가 이 키에 붙는다.
        public var stableKey: String
        /// 사용자가 고정(Pin)한 항목인가 — 인스펙터 표시용.
        public var pinned: Bool
        public var evidence: EvidenceAnchor?

        public init(
            kind: Kind, text: String, jumpQuery: String? = nil, jumpUTF16: Int? = nil,
            stableKey: String = "", pinned: Bool = false, evidence: EvidenceAnchor? = nil
        ) {
            self.kind = kind
            self.text = text
            self.jumpQuery = jumpQuery
            self.jumpUTF16 = jumpUTF16
            self.stableKey = stableKey
            self.pinned = pinned
            self.evidence = evidence
        }
    }

    public var items: [Item]
    /// Exact stable text before cursor-dependent scene/dialogue context.
    public var fixedPrefix: String? = nil
    /// 조립 시각 — 인스펙터의 "언제 것인지" 표시.
    public var assembledAt: Date
    /// 이 리포트가 조립된 문서 — 다른 작품의 화면에서 보여주거나, 그 작품의
    /// 오버라이드에 기록하는 일을 원천 차단한다 (이슈 #8). nil이면 구형 리포트.
    public var entryID: UUID?
    /// 조립 시점의 예측 세대 — 문서 전환·편집으로 무효화됐는지 판정용 (이슈 #8).
    public var generation: Int
    public var runtimeIdentity: ProjectRuntimeIdentity?
    public var contextMode: GhostContextMode
    /// Actual retained manuscript range, without added instructions or evidence.
    public var rawUTF16Range: Range<Int>?

    public init(
        items: [Item], assembledAt: Date = .now,
        entryID: UUID? = nil, generation: Int = 0,
        runtimeIdentity: ProjectRuntimeIdentity? = nil,
        contextMode: GhostContextMode = .current, rawUTF16Range: Range<Int>? = nil
    ) {
        self.items = items
        self.assembledAt = assembledAt
        self.entryID = entryID
        self.generation = generation
        self.runtimeIdentity = runtimeIdentity
        self.contextMode = contextMode
        self.rawUTF16Range = rawUTF16Range
    }

    public static let empty = ContextReport(items: [])
}

/// 예측 프롬프트 조립기 (PLAN §10–§11) — `[A 고정 헤더 | B 지식 | C 최근 원문]`.
///
/// 안정적인 것(A·B)이 앞, 매 키 입력마다 변하는 것(C)이 맨 뒤 — 이 순서라야
/// 직전 요청과의 공통 접두가 살아남아 KV 프리필 재사용이 가능하다 (PLAN §12).
/// 저널은 현행 그대로 C만(Fast 모드), 소설은 메타 헤더 + 인물 카드를 얹는다
/// (Smart/Story의 원형). 예측 시점엔 준비된 값의 조립만 한다 — LLM 호출·디스크
/// 접근 금지 (CLAUDE.md §2-2).
public enum ContextAssembler {

    /// A+B 문자 상한 — 소형 모델 프리필 예산 보호 (PLAN §11 초기값, 벤치로 조정).
    package static let maxHeaderCharacters = 700
    /// 주입 카드 수 상한 — 예산 초과 시 삭감 1순위가 카드다 (PLAN §11).
    package static let maxCards = 3
    /// 카드 한 장의 소개 글 상한 — 토큰당 품질 원칙 (CLAUDE.md §5-1).
    package static let maxCardNoteCharacters = 140
    /// B(요약 지식) 문자 상한 — 초과 시 커서에서 먼 것부터 버린다 (PLAN §10 삭감).
    package static let maxKnowledgeCharacters = 600
    /// 그라운딩(동석 인물) 이름 수 상한 — 군중 장면이 블록을 잠식하지 않게
    /// 한다 (토큰당 품질, CLAUDE.md §5-1).
    package static let maxCohortNames = 4

    /// 토큰 예산 경로의 상수 (#43) — 카운터 주입 시에만 쓴다. nil 경로는
    /// 위 문자 상수를 그대로 쓴다 (동작 불변).
    /// A+B 헤더 토큰 상한 — 문자 700자 상한과 같은 지점을 겨눈다.
    package static let maxHeaderTokens = 400
    /// B(요약 지식) 토큰 상한.
    package static let maxKnowledgeTokens = 400
    /// 전체 프롬프트 기본 토큰 예산 — 엔진 안전망(기본 3072)보다 여유를 남겨
    /// 조립 단계에서 먼저 맞춘다. 호출부가 `parameters.maxPromptTokens`로 덮는다.
    public static let defaultPromptTokenBudget = 2_560

    /// 삭감 사다리 손잡이 (#43) — 사건 → 카드 3→2장 → 요약 축소 → (최후) C 축소.
    /// A(고정 헤더)는 어떤 단계에서도 버리지 않는다 (PLAN §11).
    package struct BudgetKnobs {
        var maxCardsOverride: Int?
        var knowledgeTokenOverride: Int?
        var includeFlowEvents: Bool = true

        static let defaults = BudgetKnobs()
        /// 사다리 — 앞에서부터 시도하고 처음 맞는 단계로 확정한다.
        static let ladder: [BudgetKnobs] = [
            .defaults,
            BudgetKnobs(includeFlowEvents: false),
            BudgetKnobs(maxCardsOverride: 2, includeFlowEvents: false),
            BudgetKnobs(
                maxCardsOverride: 2, knowledgeTokenOverride: maxKnowledgeTokens / 2,
                includeFlowEvents: false),
            BudgetKnobs(
                maxCardsOverride: 1, knowledgeTokenOverride: maxKnowledgeTokens / 4,
                includeFlowEvents: false),
        ]
    }

    /// C(최근 원문 창)에 A·B를 얹어 최종 프롬프트를 만든다.
    ///
    /// `knowledge`/`prefixStartUTF16`은 M6 — 인덱서가 발행한 스냅샷에서 C 창
    /// **밖**(이전) 씬의 요약만 골라 넣는다. 시점 차단(커서 이후 지식 미주입,
    /// CLAUDE.md §2-4)은 씬 위치 비교라 여기서 결정적으로 성립한다.
    public static func assemble(
        prefix: String,
        document: DocumentContext?,
        knowledge: KnowledgeSnapshot? = nil,
        prefixStartUTF16: Int = 0,
        style: PromptStyle,
        contextMode: GhostContextMode = .current,
        originalNameAnchors: OriginalNameAnchorIndex? = nil
    ) -> AssembledPrompt {
        assembleWithReport(
            prefix: prefix, document: document, knowledge: knowledge,
            prefixStartUTF16: prefixStartUTF16, style: style, contextMode: contextMode,
            originalNameAnchors: originalNameAnchors
        ).prompt
    }

    /// 조립 + 컨텍스트 리포트 (요구사항 §16·§17) — 리포트는 프롬프트에 실제로
    /// 들어간 줄들의 기록이다. 인스펙터가 이걸 그대로 보여준다.
    /// Pin/Exclude 판독 (요구사항 §31) — 오버라이드(entries.json)가 스냅샷에
    /// 실려 오므로, 인스펙터가 보는 것과 조립이 쓰는 것이 같은 파이프라인이다
    /// (UI 전용 프리뷰 금지). 컨텍스트가 바뀌면 프롬프트 접두가 달라져 KV
    /// 프리픽스 재사용(LCP 매칭)이 자연히 무효화된다 — 별도 처리 불필요.
    package struct Controls {
        var pins: Set<String>
        var excludes: Set<String>

        init(_ knowledge: KnowledgeSnapshot?) {
            let overrides = knowledge?.overrides ?? .empty
            pins = Set(overrides.map(of: .contextPin).keys)
            excludes = Set(overrides.map(of: .contextExclude).keys)
        }

        /// 테스트·내부 조립용 — 오버라이드 집합을 직접 지정한다.
        init(pins: Set<String> = [], excludes: Set<String> = []) {
            self.pins = pins
            self.excludes = excludes
        }

        func allows(_ key: String) -> Bool { !excludes.contains(key) }
        func pinned(_ key: String) -> Bool { pins.contains(key) }
    }

    public static func assembleWithReport(
        prefix: String,
        document: DocumentContext?,
        knowledge: KnowledgeSnapshot? = nil,
        prefixStartUTF16: Int = 0,
        style: PromptStyle,
        tokenCounter: TokenCounter? = nil,
        tokenBudget: Int? = nil,
        contextMode: GhostContextMode = .current,
        originalNameAnchors: OriginalNameAnchorIndex? = nil
    ) -> (prompt: AssembledPrompt, report: ContextReport) {
        if contextMode != .current {
            return assembleRaw(prefix: prefix, prefixStartUTF16: prefixStartUTF16,
                style: style, mode: contextMode, counter: tokenCounter, budget: tokenBudget,
                document: document, knowledge: knowledge, originalNameAnchors: originalNameAnchors)
        }
        guard let counter = tokenCounter else {
            // 현행 문자 예산 경로 — 동작 불변 (#43).
            return assembleCore(
                prefix: prefix, document: document, knowledge: knowledge,
                prefixStartUTF16: prefixStartUTF16, style: style,
                knobs: .defaults, counter: nil).result
        }
        // 토큰 예산 경로 (#43, PLAN §11) — 삭감 사다리를 순서대로 시도하고 처음
        // 맞는 단계로 확정한다. 순서: 사건 → 카드 3→2장 → 요약 축소 → 최후 C 축소.
        let budget = tokenBudget ?? defaultPromptTokenBudget
        var window = prefix
        var outcome = assembleCore(
            prefix: window, document: document, knowledge: knowledge,
            prefixStartUTF16: prefixStartUTF16, style: style,
            knobs: BudgetKnobs.ladder[0], counter: counter, tokenBudget: budget)
        for index in BudgetKnobs.ladder.indices.dropFirst() {
            if (outcome.totalTokens ?? .max) <= budget { break }
            // 다음 단계로 넘어가기 전에 C 창을 어절 경계에서 한 단계 줄인다 —
            // 단어 중간 절단은 KV 재사용 모델의 LCP와 문장 품질을 함께 깬다.
            let trimmed = Self.wordBoundaryTrimmed(window, keepingFraction: 0.8)
            if trimmed != window { window = trimmed }
            let windowStartUTF16 =
                max(0, prefixStartUTF16) + max(0, prefix.utf16.count - window.utf16.count)
            outcome = assembleCore(
                prefix: window, document: document, knowledge: knowledge,
                prefixStartUTF16: windowStartUTF16,
                style: style,
                knobs: BudgetKnobs.ladder[index], counter: counter, tokenBudget: budget)
        }
        // 사다리를 다 타고도 넘치면 — C 창만 계속 줄인다 (최후 수단). 지식·카드는
        // 이미 최소라 A 헤더와 남은 C 중에서는 C가 늘 희생이다. 무한 루프 가드.
        var safety = 0
        while (outcome.totalTokens ?? .max) > budget, !window.isEmpty, safety < 48 {
            var trimmed = Self.wordBoundaryTrimmed(window, keepingFraction: 0.7)
            if trimmed == window {
                trimmed = Self.rawSuffixTrimmed(window)
            }
            if trimmed == window { break }  // 더는 못 자른다 — 안전망(엔진 클램프)으로.
            window = trimmed
            let windowStartUTF16 =
                max(0, prefixStartUTF16) + max(0, prefix.utf16.count - window.utf16.count)
            outcome = assembleCore(
                prefix: window, document: document, knowledge: knowledge,
                prefixStartUTF16: windowStartUTF16,
                style: style,
                knobs: BudgetKnobs.ladder.last!, counter: counter, tokenBudget: budget)
            safety += 1
        }
        return outcome.result
    }

    /// 어절(공백·줄바꿈) 경계에서 **앞부분**을 잘라낸다 — 단어 중간 절단 금지 (#43).
    /// 한 번에 keepingFraction만큼 남긴다. 자를 게 없으면 원문을 돌려준다.
    package static func wordBoundaryTrimmed(_ text: String, keepingFraction: Double) -> String {
        guard keepingFraction < 1, !text.isEmpty else { return text }
        var starts: [String.Index] = []
        var previousWasBoundary = true
        for index in text.indices {
            let isSpace = text[index].isWhitespace
            if previousWasBoundary, !isSpace { starts.append(index) }
            previousWasBoundary = isSpace
        }
        let keepCount = max(1, Int(Double(starts.count) * keepingFraction))
        guard keepCount < starts.count else { return text }
        let cutIndex = starts[starts.count - keepCount]
        guard cutIndex > text.startIndex, cutIndex < text.endIndex else { return text }
        return String(text[cutIndex...])
    }

    /// 조립 본체 — 문자/토큰 두 예산 단위를 knobs·counter로 갈라 낸다.
    /// counter가 nil이면 기존 산술과 결과가 동일하다 (회귀 그물: nil 경로 불변, #43).
    package static func assembleCore(
        prefix: String,
        document: DocumentContext?,
        knowledge: KnowledgeSnapshot?,
        prefixStartUTF16: Int,
        style: PromptStyle,
        knobs: BudgetKnobs,
        counter: TokenCounter?,
        tokenBudget: Int? = nil
    ) -> (result: (prompt: AssembledPrompt, report: ContextReport), totalTokens: Int?) {
        var items: [ContextReport.Item] = []
        let controls = Controls(knowledge)
        let cursor = prefixStartUTF16 + (prefix as NSString).length
        // 현재 서사 좌표 (요구사항 §30) — 회상을 쓰는 중이면 Retrieval의 축이
        // 담화 위치에서 작품 내 시간 위치로 바뀐다.
        let position: KnowledgeSnapshot.NarrativePosition? =
            document?.kind == .novel ? knowledge?.position(at: cursor) : nil
        var header = headerText(
            document: document, window: prefix,
            knowledge: knowledge, windowStart: prefixStartUTF16,
            position: position, controls: controls, report: &items,
            knobs: knobs, counter: counter)
        if document?.kind == .novel,
            let knowledge,
            case let block = knowledgeText(
                knowledge, before: prefixStartUTF16, cursor: cursor, window: prefix,
                position: position, controls: controls, report: &items,
                knobs: knobs, counter: counter),
            !block.isEmpty
        {
            header = header.isEmpty ? block : header + "\n" + block
        }
        let fixedPrefix = header
        // 지금 장면·서사 위치·그라운딩 (v4·v5) — 커서가 속한 씬의 제목·유형·
        // 시점·장소·동석 인물·흐름·층. 커서가 씬을 넘을 때만 변하므로 대화
        // 블록과 같은 "맨 뒤" 자리다 (KV 프리픽스 보호).
        if document?.kind == .novel, let knowledge {
            let block = currentSceneText(
                knowledge, document: document, cursor: cursor, window: prefix,
                position: position, controls: controls, report: &items)
            if !block.isEmpty {
                header = header.isEmpty ? block : header + "\n" + block
            }
        }
        // 대화 모드 (PLAN §10, 모드와 직교) — 커서가 열린 따옴표 안이면 다음
        // 화자의 말투·예문·존대쌍을 승격한다. 헤더 맨 뒤에 붙는 이유: 이 블록은
        // 커서 위치에 따라 변하므로, 앞에 두면 A+B의 KV 프리픽스까지 식힌다.
        if document?.kind == .novel, let knowledge, let document,
            isInsideUtterance(prefix)
        {
            let block = dialogueText(
                knowledge, document: document, cursor: cursor, report: &items)
            if !block.isEmpty {
                header = header.isEmpty ? block : header + "\n" + block
            }
        }
        let startUTF16 = max(0, prefixStartUTF16)
        var report = ContextReport(
            items: items,
            rawUTF16Range: startUTF16..<max(startUTF16, cursor))
        let assembled: AssembledPrompt
        switch style {
        case .continuation:
            report.fixedPrefix = fixedPrefix.isEmpty ? nil : fixedPrefix
            // 헤더와 본문은 빈 줄 하나로만 구분 — 이어쓰기 흐름을 깨지 않는 최소 구조.
            assembled =
                header.isEmpty ? .continuation(prefix) : .continuation(header + "\n\n" + prefix)
        case .instruct:
            let system =
                header.isEmpty
                ? instructSystem
                : instructSystem + "\n\n[작품 정보]\n" + header
            assembled = .instruct(system: system, user: instructUser(prefix: prefix))
        }
        // 총량 보고 — 토큰 경로에서만 (사다리 판정용, #43).
        if let counter {
            return ((assembled, report), counter.count(assembled))
        }
        return (((assembled, report)), nil)
    }

    /// 커서가 속한 씬의 메타 + 서사 위치 + 그라운딩 — "지금 장면: 아내의 외출 (회상)" +
    /// "지금 흐름: 남편의 과거 (회상 · 깊이 1)" + "이 장면의 사람들: …". 흐름·층은
    /// Narrative Graph의 position 질의에서, 사람들은 씬 발화·사건 질의에서 온다
    /// (요구사항 §30 "지금 어떤 이야기 흐름에 있는가" + 그라운딩 계층).
    package static func currentSceneText(
        _ knowledge: KnowledgeSnapshot, document: DocumentContext?, cursor: Int,
        window: String? = nil,
        position: KnowledgeSnapshot.NarrativePosition? = nil,
        controls: Controls = Controls(nil),
        report: inout [ContextReport.Item]
    ) -> String {
        guard let index = knowledge.outline.sceneIndex(at: cursor) else { return "" }
        let scene = knowledge.outline.scenes[index]
        let isAtOrAfterSceneEnd = cursor >= scene.utf16Range.upperBound
        let headingContext = scene.headingPath.joined(separator: " ")
        func isGroundedBeforeCursor(_ candidate: String) -> Bool {
            if isAtOrAfterSceneEnd || controls.pinned("current") { return true }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let sources = [window, headingContext.isEmpty ? nil : headingContext].compactMap { $0 }
            guard !sources.isEmpty else { return false }
            if sources.contains(where: { $0.contains(trimmed) }) { return true }
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "·" || $0 == "," })
            for token in tokens {
                let stem = String(token.prefix(2))
                if stem.count >= 2, sources.contains(where: { $0.contains(stem) }) {
                    return true
                }
            }
            return false
        }
        var lines: [String] = []
        if let meta = knowledge.sceneMetaByHash[scene.contentHash],
            controls.allows("current")
        {
            var pieces: [String] = []
            if let title = meta.title, !title.isEmpty,
                meta.titleUserEdited || isGroundedBeforeCursor(title)
            {
                pieces.append(title)
            }
            if meta.type != .present,
                meta.typeUserEdited || isAtOrAfterSceneEnd || position?.layer.isTemporalShift == true
            {
                pieces.append("(\(meta.type.rawValue) 장면)")
            }
            if let location = meta.location, !location.isEmpty,
                isGroundedBeforeCursor(location)
            {
                pieces.append("· 장소: \(location)")
            }
            // 시점 명시 — 1인칭/제한 삼인칭은 서술 어투와 앎 범위를 결정하는
            // 소설의 핵심 신호다. 구간 시점(회상 속 시점)이 씬 시점보다 이긴다.
            let pov: String?
            if let segmentID = position?.segmentID, !segmentID.isEmpty, let segPOV = position?.pov {
                pov = segPOV
            } else if let rawPOV = position?.pov ?? meta.pov, isGroundedBeforeCursor(rawPOV) {
                pov = rawPOV
            } else {
                pov = nil
            }
            if let pov, !pov.isEmpty { pieces.append("· 시점: \(pov)") }
            if !pieces.isEmpty {
                let line = "지금 장면: " + pieces.joined(separator: " ")
                lines.append(line)
                report.append(
                    ContextReport.Item(
                        kind: .currentScene, text: line,
                        jumpUTF16: scene.utf16Range.lowerBound,
                        stableKey: "current", pinned: controls.pinned("current")))
            }
        }
        // 그라운딩 — 지금 공간에 함께 있는 등장인물. 다음 문장 예측의 탄약은
        // 작품 요약이 아니라 "지금 이 방에 누가 있는가"다 (ConStory-Bench:
        // 오류 최다 분포가 factual — 로컬 사실 그라운딩이 실탄).
        // 대화 모드에서는 화자·청자를 이미 지목하므로 중복 없이 서술용으로만.
        if controls.allows("cohort") {
            let names = knowledge.sceneCohabitants(at: cursor, in: window).compactMap { id in
                document?.characters.first(where: { $0.id == id })?.name
            }
            if !names.isEmpty {
                let line = "이 장면의 사람들: \(names.prefix(maxCohortNames).joined(separator: ", "))"
                lines.append(line)
                report.append(
                    ContextReport.Item(
                        kind: .cohort, text: line, stableKey: "cohort",
                        pinned: controls.pinned("cohort")))
            }
        }
        // 서사 위치 (v5) — 회상·구술·꿈 등 시간 이동 층 안일 때만 한 줄 더.
        // 현재 층·시점·소속 인물이 곧 "그 시점의 문체·지식"의 신호다.
        if let position, position.layer.isTemporalShift, controls.allows("narrative") {
            var pieces = ["\(position.layer.rawValue)"]
            if position.depth >= 2 { pieces.append("깊이 \(position.depth)") }
            if let subject = position.subjectCharacter { pieces.append("\(subject)의 과거") }
            if let pov = position.pov { pieces.append("시점: \(pov)") }
            let flowName = knowledge.flows.first { $0.id == position.flowID }?.name
            let line =
                "지금 흐름: \(flowName ?? "본줄기") (\(pieces.joined(separator: " · "))) — 이 시점 이후의 일은 아직 일어나지 않았다"
            lines.append(line)
            report.append(
                ContextReport.Item(
                    kind: .narrative, text: line,
                    stableKey: "narrative", pinned: controls.pinned("narrative")))
        }
        return lines.joined(separator: "\n")
    }

    /// B 블록 — C 창이 시작되기 **전에 끝난** 씬들의 요약 (PLAN §11).
    ///
    /// 구성: 작품 요약 → 이전 장 요약 → (커서와 같은 장의) 이전 씬 요약.
    /// 예산 초과 시 커서에서 먼 것부터 버린다 — 가까운 맥락이 더 예측에 기여한다.
    /// 창 시작이 512 격자에 스냅되므로(에디터·PLAN §12) 결과 문자열은 키 입력에
    /// 안정적 — KV 프리픽스가 식지 않는다.
    package static func knowledgeText(_ knowledge: KnowledgeSnapshot, before windowStart: Int) -> String {
        var report: [ContextReport.Item] = []
        return knowledgeText(knowledge, before: windowStart, report: &report)
    }

    package static func knowledgeText(
        _ knowledge: KnowledgeSnapshot, before windowStart: Int,
        cursor: Int? = nil, window: String? = nil,
        position: KnowledgeSnapshot.NarrativePosition? = nil,
        controls: Controls = Controls(nil),
        report: inout [ContextReport.Item],
        knobs: BudgetKnobs = .defaults,
        counter: TokenCounter? = nil
    ) -> String {
        let scenes = knowledge.outline.scenes
        let effectiveCursor = max(windowStart, cursor ?? windowStart)
        // C 창 이전에 완전히 끝난 씬들 — 창과 겹치는 씬은 원문이 이미 C에 있다.
        var outside = scenes.enumerated().filter { $0.element.utf16Range.upperBound <= windowStart }
        guard !outside.isEmpty else { return "" }

        // 과거 층 집필 중의 시간 차단 (요구사항 §30) — 회상을 쓰는 중에는 그
        // 시점보다 **작품 내 시간상 뒤**인 씬의 요약을 주입하지 않는다. Main의
        // 미래 사건이 회상 안으로 새는 것을 막는다. 사용자가 Pin한 씬은 예외
        // (고정은 명시적 사용자 결정, §31).
        let writingInPast = position?.chrono == .before && position?.layer.isTemporalShift == true
        var allowedChronoIndices: Set<Int>?
        if writingInPast,
            let currentScene = position?.sceneIndex
                ?? knowledge.outline.sceneIndex(at: max(windowStart, 0))
        {
            let chronoOrder = knowledge.chronologicalSceneOrder()
            if let currentRank = chronoOrder.firstIndex(of: currentScene) {
                let allowed = Set(chronoOrder.prefix(currentRank + 1))
                allowedChronoIndices = allowed
                outside = outside.filter { index, scene in
                    allowed.contains(index)
                        || controls.pinned("scene|\(scene.contentHash)")
                }
            }
        }

        // 커서(창)가 속한 장 — 같은 장의 씬은 요약으로, 이전 장은 장 요약으로.
        let cursorChapter = scenes.last(where: { $0.utf16Range.lowerBound <= windowStart })
            .map { Array($0.headingPath.prefix(2)) }

        // 예산 단위 (#43) — 카운터가 있으면 토큰으로 접는다. nil이면 문자(불변).
        func cost(_ text: String) -> Int { counter?.count(text) ?? text.count }
        var budget =
            knobs.knowledgeTokenOverride
            ?? (counter != nil ? maxKnowledgeTokens : maxKnowledgeCharacters)
        var lines: [String] = []
        var reported: [ContextReport.Item] = []

        // 흐름 사건 (v5, 요구사항 §30) — 회상 집필 중이면 그 인물 흐름의 이전
        // 사건을 우선 주입한다: "이 회상의 주인이 겪어온 일"이 가장 진한 신호다.
        // 삭감 사다리 1단 — 예산 초과 시 이 블록부터 빠진다 (#43).
        if knobs.includeFlowEvents, writingInPast, let flowID = position?.flowID {
            let outsideHashes = Set(outside.map(\.element.contentHash))
            let currentSceneHashes = Set(
                scenes.enumerated().compactMap { index, scene -> String? in
                    guard scene.utf16Range.lowerBound <= effectiveCursor,
                        scene.utf16Range.upperBound > windowStart,
                        allowedChronoIndices?.contains(index) ?? true
                    else { return nil }
                    return scene.contentHash
                })
            let flowEvents = knowledge.flowEvents(of: flowID).filter { event in
                let key = "flow|\(event.canonicalKey)"
                if controls.pinned(key) { return true }
                if outsideHashes.contains(event.sceneHash) { return true }
                guard currentSceneHashes.contains(event.sceneHash) else { return false }
                if let quote = event.quote?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !quote.isEmpty
                {
                    return window?.contains(quote) == true
                }
                return window == nil
            }
            for event in flowEvents.suffix(2) {
                // stableKey에 정본 사건 키를 넣는다 — 두 사건이 "flow" 하나를
                // 같이 쓰면 Pin/Exclude 오버라이드가 서로를 덮어 인스펙터(거울)와
                // 조립이 어긋난다.
                let key = "flow|\(event.canonicalKey)"
                guard controls.allows(key) else { continue }
                let line = "이 흐름의 사건: \(event.summary)"
                guard cost(line) <= budget else { break }
                lines.append(line)
                reported.append(
                    ContextReport.Item(
                        kind: .flowEvent, text: line, jumpQuery: event.quote,
                        stableKey: key, pinned: controls.pinned(key)))
                budget -= cost(line)
            }
        }

        // 선별 순서 (살라이언스, PLAN §11 개편) — Pin된 씬이 항상 먼저(§31 —
        // 관련성이 낮아져도 유지·예산을 이긴다), 나머지는 인덱스 공유 점수순:
        // 인과 선행·같은 장소·동석 인물이 담화 거리보다 이긴다. 같은 점수면
        // 담화상 가까운 쪽 — 결정적 타이브레이크라 출력이 요동치지 않는다.
        // 실제 줄 순서는 아래에서 문서 순서로 복원한다 (KV 프리픽스 보호).
        let scores = knowledge.sceneSalienceScores(
            at: windowStart, candidates: outside.map(\.element))
        let pinnedScenes = outside
            .filter { controls.pinned("scene|\($0.element.contentHash)") }
            .sorted { $0.offset < $1.offset }
        let rankedScenes = outside
            .filter { !controls.pinned("scene|\($0.element.contentHash)") }
            .sorted { lhs, rhs in
                let ls = scores[lhs.element.contentHash] ?? 0
                let rs = scores[rhs.element.contentHash] ?? 0
                if ls != rs { return ls > rs }
                return lhs.offset > rhs.offset
            }

        let outsideIndices = Set(outside.map(\.offset))
        // 담고 나서(예산 소진 시 밀린 것이 자연히 빠진다) 문서 순서로 뒤집는다.
        var picked: [(line: String, item: ContextReport.Item)] = []
        var coveredChapters: Set<String> = []
        var coveredScenes: Set<Int> = []
        for (sceneIndex, scene) in pinnedScenes + rankedScenes {
            let sceneKey = "scene|\(scene.contentHash)"
            guard controls.allows(sceneKey), coveredScenes.insert(sceneIndex).inserted
            else { continue }
            let chapter = Array(scene.headingPath.prefix(2))
            let chapterKey = chapter.joined(separator: " > ")
            let chapterFullyBeforeCursor = scenes.enumerated().allSatisfy { idx, candidate in
                Array(candidate.headingPath.prefix(2)) != chapter || outsideIndices.contains(idx)
            }
            let line: String
            let kind: ContextReport.Item.Kind
            var stableKey = sceneKey
            if chapter == cursorChapter || knowledge.chapterSummariesByPath[chapterKey] == nil
                || (!chapterFullyBeforeCursor && !controls.pinned("chapter|\(chapterKey)"))
                || controls.pinned(sceneKey)
            {
                // 같은 장(또는 장 요약이 아직 없는 장, 또는 Pin)은 씬 해상도로.
                guard let summary = knowledge.summariesByHash[scene.contentHash] else { continue }
                // 씬 제목(내용 기반, v4)이 있으면 헤딩보다 그쪽이 신호가 진하다.
                let label = knowledge.sceneMetaByHash[scene.contentHash]?.title
                    ?? scene.headingPath.last.flatMap { $0.isEmpty ? nil : $0 }
                line = label.map { "앞선 장면(\($0)): \(summary)" } ?? "앞선 장면: \(summary)"
                kind = .sceneSummary
            } else {
                // 이전 장은 장 해상도 한 줄로 — 장 하나당 한 번만.
                guard coveredChapters.insert(chapterKey).inserted,
                    controls.allows("chapter|\(chapterKey)")
                else { continue }
                line = "\(chapterKey): \(knowledge.chapterSummariesByPath[chapterKey]!)"
                kind = .chapterSummary
                stableKey = "chapter|\(chapterKey)"
            }
            guard cost(line) <= budget else {
                if controls.pinned(stableKey) { continue } else { break }
            }
            picked.append(
                (line,
                 ContextReport.Item(
                    kind: kind, text: line,
                    jumpUTF16: scene.utf16Range.lowerBound,
                    stableKey: stableKey, pinned: controls.pinned(stableKey))))
            budget -= cost(line)
        }
        // 문서 순서 복원 — 씬 시작 위치로 정렬 (Pin 우선 수집과 무관하게 안정 출력).
        let ordered = picked.sorted {
            ($0.item.jumpUTF16 ?? 0) < ($1.item.jumpUTF16 ?? 0)
        }
        lines.append(contentsOf: ordered.map(\.line))
        reported.append(contentsOf: ordered.map(\.item))

        // 지난 줄거리 (작품 요약) — 맨 앞에서 **맨 뒤·남는 예산**으로 강등했다.
        // 다음 문장 예측의 실탄은 장면 해상도 지식이고, 작품 요약은 일관성
        // 보험이다 (ConStory-Bench 2026: 오류 최다 분포가 factual·temporal —
        // state·장면 지식이 요약보다 먼저다). 회상 집필 중엔 여전히 아예
        // 빠진다 — 미래가 새는 것을 막는다 (Pin이 있으면 사용자 결정).
        let workEvidenceComplete =
            !scenes.isEmpty && scenes.allSatisfy { $0.utf16Range.upperBound <= effectiveCursor }
        if let work = knowledge.workSummary, controls.allows("work"),
            (workEvidenceComplete && !writingInPast) || controls.pinned("work")
        {
            let line = "지난 줄거리: \(work)"
            if cost(line) + 1 <= budget {
                lines.append(line)
                reported.append(
                    ContextReport.Item(
                        kind: .workSummary, text: line,
                        stableKey: "work", pinned: controls.pinned("work")))
            }
        }
        report.append(contentsOf: reported)
        return lines.joined(separator: "\n")
    }

    // MARK: - 대화 모드 (PLAN §10 — 화자 추정·말투 승격·발화 끝 정지)

    /// 커서(프리픽스 끝)가 열린 따옴표 안인가 — 대화 모드 게이트 (결정적).
    /// 마지막 문단만 본다: 대사는 문단을 넘지 않는 것이 한국어 소설의 관례고,
    /// 앞 문단의 짝 안 맞는 따옴표(오탈자)가 온 문서를 대화 모드로 만들면 안 된다.
    public static func isInsideUtterance(_ prefix: String) -> Bool {
        let paragraph = prefix.suffix(from: prefix.lastIndex(of: "\n").map {
            prefix.index(after: $0)
        } ?? prefix.startIndex)
        var asciiOpen = false
        var depth = 0
        for char in paragraph {
            switch char {
            case "“", "「", "『": depth += 1
            case "”", "」", "』": depth = max(0, depth - 1)
            case "\"": asciiOpen.toggle()
            default: break
            }
        }
        return depth > 0 || asciiOpen
    }

    /// 대화 블록 — 다음 화자 추정(§10 ①) + 그 인물의 말투 카드 승격(②).
    /// 추정이 안 서면 빈 문자열 — 틀린 화자 지목은 대사를 통째로 망친다
    /// (품질 > 적극성, CLAUDE.md §1-2).
    package static func dialogueText(
        _ knowledge: KnowledgeSnapshot, document: DocumentContext, cursor: Int
    ) -> String {
        var report: [ContextReport.Item] = []
        return dialogueText(knowledge, document: document, cursor: cursor, report: &report)
    }

    package static func dialogueText(
        _ knowledge: KnowledgeSnapshot, document: DocumentContext, cursor: Int,
        report: inout [ContextReport.Item]
    ) -> String {
        guard let (speakerID, addresseeID) = knowledge.expectedSpeaker(before: cursor)
        else { return "" }
        let name = { (id: UUID) in document.characters.first(where: { $0.id == id })?.name }
        guard let speaker = name(speakerID) else { return "" }

        var line = "지금 대화 중 — 다음 발화: \(speaker)"
        if let addressee = name(addresseeID),
            let usage = knowledge.honorific(from: speakerID, to: addresseeID, before: cursor)
        {
            line += " (\(addressee)에게 \(usage.rawValue))"
        } else if let profile = knowledge.speechProfile(of: speakerID, before: cursor),
            let base = profile.defaultPoliteness
        {
            line += " (\(base.rawValue) 기본)"
        }
        if let profile = knowledge.speechProfile(of: speakerID, before: cursor),
            !profile.examples.isEmpty
        {
            let examples = profile.examples.map { "\"\($0)\"" }.joined(separator: " ")
            line += " · \(speaker) 말투 예: \(examples)"
        }
        report.append(ContextReport.Item(kind: .dialogue, text: line, stableKey: "dialogue"))
        // 화자→청자 관계 (v4) — 대사 어조의 핵심 신호. 커서 이전 마지막 관계.
        if let addressee = name(addresseeID),
            let relation = knowledge.relation(from: speakerID, to: addresseeID, before: cursor)
        {
            let relationLine = "\(speaker)→\(addressee) 관계: \(relation.value)"
            report.append(
                ContextReport.Item(
                    kind: .relation, text: relationLine, jumpQuery: relation.quote,
                    stableKey: "relation|\(speakerID.uuidString)|\(addresseeID.uuidString)"))
            line += "\n" + relationLine
        }
        return line
    }

    /// 인물 한 명의 "최근" 줄 상한 — 사건 요약(≤80자)을 그대로 쓴다.
    package static let maxRecentEventCharacters = 80
    /// 인물 한 명의 상태 산문 절 상한 — 필드 5개 × 값 40자를 다 붙이면
    /// 카드 하나가 헤더 예산(700자)을 잠식한다 (토큰당 품질, CLAUDE.md §5-1).
    package static let maxStateCharacters = 100

    /// A 고정 헤더 + 인물 카드(산문형). 소설 전용 — 저널은 빈 문자열(Fast = C만).
    ///
    /// `knowledge`/`windowStart`(M6-5): 카드마다 **커서 이전 마지막 등장 사건**을
    /// 한 문장 붙인다 (PLAN §8 `lastAppearance`). 사건을 B 블록에 따로 나열하지
    /// 않는 이유: 같은 씬을 씬 요약이 이미 말하고 있어 지식이 겹치고 예산만
    /// 태운다. 사건이 요약 대비 더 가진 것은 **참여자 링크**뿐이므로, 그 값은
    /// "인물 → 그 인물의 사건"이라는 질의에서만 나온다 (PLAN §11 엔티티 앵커
    /// 검색). 이 줄이 M6 완료 기준의 "1200자 창 밖 인물을 쓰는 제안"을 겨눈다.
    /// 인물 한 명의 "앎" 조각 상한 — 최근 앎 2개까지 (토큰당 품질).
    package static let maxKnowledgeFactsPerCard = 2

    package static func headerText(
        document: DocumentContext?,
        window: String,
        knowledge: KnowledgeSnapshot? = nil,
        windowStart: Int = 0
    ) -> String {
        var report: [ContextReport.Item] = []
        return headerText(
            document: document, window: window, knowledge: knowledge,
            windowStart: windowStart, report: &report)
    }

    /// 헤더 예산 단위 — 카운터가 있으면 토큰 상한, 없으면 문자 상한 (#43).
    package static func headerCost(_ text: String, counter: TokenCounter?) -> Int {
        counter?.count(text) ?? text.count
    }

    package static func headerText(
        document: DocumentContext?,
        window: String,
        knowledge: KnowledgeSnapshot? = nil,
        windowStart: Int = 0,
        position: KnowledgeSnapshot.NarrativePosition? = nil,
        controls: Controls = Controls(nil),
        report: inout [ContextReport.Item],
        knobs: BudgetKnobs = .defaults,
        counter: TokenCounter? = nil
    ) -> String {
        guard let document, document.kind == .novel else { return "" }
        // 줄 + 그 줄이 만든 리포트 항목들 — 예산에서 줄이 떨어지면 항목도
        // 함께 떨어진다 (리포트 = 실제 주입의 거울, 요구사항 §17).
        var lines: [(text: String, items: [ContextReport.Item])] = []

        var meta: [String] = []
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { meta.append("제목: \(title)") }
        if let genre = document.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
            !genre.isEmpty
        {
            meta.append("장르: \(genre)")
        }
        // "소설"이라는 신호 자체가 몇 토큰으로 톤을 바꾼다
        // (docs/autocomplete-context.md 개선 1).
        meta.append("종류: 소설")
        let metaLine = meta.joined(separator: " · ")
        lines.append(
            (metaLine, [ContextReport.Item(kind: .meta, text: metaLine, stableKey: "meta")]))

        // 회상 집필 중의 인물 앎은 담화 위치가 아니라 **작품 내 시간**으로 접는다
        // (요구사항 §14·§30) — 그 시점의 인물이 모르는 것은 카드에도 없어야 한다.
        let writingInPast =
            position?.chrono == .before && position?.layer.isTemporalShift == true

        for card in selectCards(
            from: document.characters, window: window, controls: controls,
            maxCards: knobs.maxCardsOverride ?? Self.maxCards)
        {
            guard controls.allows("card|\(card.id.uuidString)") else { continue }
            let aliases = aliasList(card)
            let name =
                aliases.isEmpty
                ? card.name : "\(card.name)(\(aliases.joined(separator: "·")))"
            var rawNoteParts: [String] = []
            let trimmedNote = card.note
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNote.isEmpty {
                rawNoteParts.append(trimmedNote)
            }
            let arcParts: [(String, String?)] = [
                ("동기", card.motivation),
                ("목표", card.goal),
                ("갈등", card.conflict),
                ("변화", card.epiphany),
            ]
            for (label, raw) in arcParts {
                guard let value = raw?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else { continue }
                rawNoteParts.append("\(label): \(value)")
            }
            let note = String(rawNoteParts.joined(separator: " · ").prefix(maxCardNoteCharacters))
            // 산문형 카드 — "등장인물 N: 소개 · 필드=값" 레코드 대신 이름으로
            // 시작하는 짧은 문장들. 소설 코퍼스에 맞춰진 모델(Qwen3 계열 포함)은
            // 서술형을 레코드보다 어투 누수 없이 흡수한다 (NovelAI lorebook
            // 실측·CHIRON EMNLP 2024). 줄 단위 예산 규율은 그대로 유지한다.
            var pieces: [String] = [
                note.isEmpty ? name : "\(name) — \(KoreanProse.terminated(note))"
            ]
            let cardKey = "card|\(card.id.uuidString)"
            var cardItems: [ContextReport.Item] = [
                ContextReport.Item(
                    kind: .card, text: pieces[0],
                    stableKey: cardKey, pinned: controls.pinned(cardKey))
            ]
            // 상태@커서 (PLAN §7 카드 스키마, §8 `state_at`) — 창 시작 시점까지의
            // 델타를 접은 결과를 **산문 절**로 편다. 일관성 > 유창성(CLAUDE.md §3)
            // 의 실탄: "이미 죽어 있다" 한 문장이 죽은 인물의 등장을 프롬프트
            // 수준에서 막는다.
            if let knowledge {
                let state = knowledge.stateAt(of: card.id, before: windowStart)
                if !state.isEmpty, controls.allows("state|\(card.id.uuidString)") {
                    let clauses = stateProse(name: card.name, state: state)
                    if !clauses.isEmpty {
                        let rendered = clauses.joined(separator: " ").prefix(maxStateCharacters)
                        pieces.append(String(rendered))
                        cardItems.append(
                            ContextReport.Item(
                                kind: .state, text: "\(card.name) \(rendered)",
                                stableKey: "state|\(card.id.uuidString)"))
                    }
                }
                // 앎@커서 (v4, 요구사항 §11·§16) — 그 시점까지 이 인물이 가진
                // 앎의 최근 조각을 태도 문장으로. "아직 모르는 비밀을 대사로
                // 말하는" 제안을 프롬프트 수준에서 막는 재료다. **회상 집필 중에는
                // 시간 기준** (요구사항 §14·§30) — 그때의 인물은 미래의 앎이 없다.
                let known =
                    writingInPast
                    ? position?.sceneIndex.map {
                        knowledge.knowledgeChrono(of: card.id, atSceneIndex: $0)
                    } ?? knowledge.knowledgeChrono(of: card.id, atSceneContaining: windowStart)
                    : knowledge.knowledge(of: card.id, before: windowStart)
                if !known.isEmpty, controls.allows("knowledge|\(card.id.uuidString)") {
                    let facts = known.suffix(maxKnowledgeFactsPerCard)
                        .map { knowledgeProse(name: card.name, delta: $0) }
                    pieces.append(contentsOf: facts)
                    // 태도 문장은 이미 이름으로 시작하므로 리포트 접두 없이 그대로.
                    cardItems.append(
                        ContextReport.Item(
                            kind: .knowledge,
                            text: facts.joined(separator: " "),
                            jumpQuery: known.last?.quote,
                            stableKey: "knowledge|\(card.id.uuidString)"))
                }
            }
            // 커서가 이미 보고 있는 사건은 붙이지 않는다 — C 창에 원문이 그대로
            // 있는데 요약을 겹쳐 넣으면 토큰만 쓴다 (`lastAppearance`가 창 밖
            // 사건만 돌려주므로 이 조건은 질의에서 이미 성립).
            if let recent = knowledge?.lastAppearance(of: card.id, before: windowStart),
                controls.allows("recent|\(card.id.uuidString)")
            {
                let summary = String(recent.summary.prefix(maxRecentEventCharacters))
                let piece = "최근에 \(KoreanProse.terminated(summary))"
                pieces.append(piece)
                cardItems.append(
                    ContextReport.Item(
                        kind: .recentEvent, text: "\(card.name): \(piece)",
                        jumpQuery: recent.quote,
                        stableKey: "recent|\(card.id.uuidString)"))
            }
            lines.append((pieces.joined(separator: " "), cardItems))
        }
        // 줄 단위 예산 — 통짜 prefix는 마지막 줄을 중간에서 잘라 리포트와
        // 프롬프트가 어긋난다. 예산을 넘는 줄부터 통째로 버린다.
        // 줄 단위 예산 — 통짜 prefix는 마지막 줄을 중간에서 잘라 리포트와
        // 프롬프트가 어긋난다. 예산을 넘는 줄부터 통째로 버린다. 단위(#43):
        // 카운터 주입 시 토큰, 미주입 시 문자 (동작 불변).
        let headerLimit =
            counter != nil ? maxHeaderTokens : maxHeaderCharacters
        var total = 0
        var kept: [String] = []
        for (text, items) in lines {
            guard total + headerCost(text, counter: counter) + 1 <= headerLimit else { break }
            kept.append(text)
            total += headerCost(text, counter: counter) + 1
            report.append(contentsOf: items)
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - 산문 렌더링 (PLAN §11 형식 개편 — 레코드 덤프 폐지)

    /// 상태 델타 → 산문 절들 — `필드=값` 대신 짧은 자연 문장. 값은 자유 서술
    /// (≤40자)이라 완벽한 굴절은 불가능하다: 템플릿이 가장 무해한 문형을 고르고,
    /// 정보가 없는 기본값(생존)은 침묵한다 (품질 > 적극성, CLAUDE.md §1-2).
    /// CaseIterable 순서로 고정 렌더링 — 같은 상태가 패스마다 다른 순서로 찍히면
    /// KV 프리픽스가 식는다 (PLAN §12).
    package static func stateProse(
        name: String, state: [StateDelta.Field: String]
    ) -> [String] {
        StateDelta.Field.allCases.compactMap { field -> String? in
            guard let value = state[field]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { return nil }
            switch field {
            case .vitality:
                if isDeathValue(value) {
                    return "\(KoreanProse.topic(name)) 이미 죽어 있다."
                }
                // 생존·건강 같은 기본값은 말할 가치가 없다 — 토큰당 품질.
                guard !value.contains("생존"), !value.contains("건강"),
                    !value.contains("무사")
                else { return nil }
                return "몸은 \(KoreanProse.copula(value))."
            case .location:
                return "지금 \(value)에 있다."
            case .emotion:
                return "마음은 \(KoreanProse.copula(value))."
            case .relation:
                return "관계는 \(KoreanProse.copula(value))."
            case .goal:
                return "목표는 \(KoreanProse.terminated(value))"
            }
        }
    }

    /// 사망을 뜻하는 값 판정 — 닫힌 키워드 집합 (소형 모델의 서술 변주를 흡수).
    private static func isDeathValue(_ value: String) -> Bool {
        ["사망", "죽음", "죽었", "숨졌", "없어졌", "부고"].contains { value.contains($0) }
    }

    /// 앎 델타 → 태도 문장 — `사실(태도)` 튜플 대신 "누구는 …다 — 사실." 꼴.
    /// 오해(misbelieves)는 "잘못 믿고 있다"로 렌더링해 모델이 그 사실을 진실로
    /// 흡수하는 것을 막는다 (일관성 > 유창성, CLAUDE.md §3).
    package static func knowledgeProse(name: String, delta: KnowledgeDelta) -> String {
        let attitude: String
        switch delta.stance {
        case .knows: attitude = "알고 있다"
        case .suspects: attitude = "의심한다"
        case .misbelieves: attitude = "잘못 믿고 있다"
        case .hides: attitude = "숨기고 있다"
        }
        return "\(KoreanProse.topic(name)) \(attitude) — \(KoreanProse.terminated(delta.fact))"
    }

    /// 카드 선택 — 최근 창에 이름·별칭이 언급된 카드 우선, 남는 자리는 목록
    /// 앞(주인공일 확률이 높다)에서 채운다. 결과는 항상 문서의 카드 순서 —
    /// 언급 최신순 정렬은 창이 밀릴 때마다 순서를 흔들어 KV 프리픽스를 식힌다.
    /// 세대 단위 랭킹은 M6 (PLAN §11).
    package static func selectCards(
        from cards: [CharacterCard], window: String, controls: Controls = Controls(nil),
        maxCards overrideMax: Int? = nil
    ) -> [CharacterCard] {
        let limit = overrideMax ?? maxCards
        let valid = cards.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard valid.count > limit else { return valid }

        // Pin된 카드는 상한과 무관하게 **전부** 실린다 — 사용자 지정(§31)이 휴리스틱
        // 예산을 이긴다 (CLAUDE.md §1-5). prefix로 자르면 초과분이 말없이 탈락해
        // "고정했는데 빠졌다"는 신뢰 붕괴가 된다. 토큰 안전망은 엔진의 3072 클램프가 담당.
        var picked = valid.filter { controls.pinned("card|\($0.id.uuidString)") }
        if picked.count < limit {
            for card in valid where !picked.contains(where: { $0.id == card.id }) {
                if window.contains(card.name)
                    || aliasList(card).contains(where: { window.contains($0) })
                {
                    picked.append(card)
                    if picked.count >= limit { break }
                }
            }
        }
        if picked.count < limit {
            for card in valid where !picked.contains(where: { $0.id == card.id }) {
                picked.append(card)
                if picked.count >= limit { break }
            }
        }
        let chosen = Set(picked.map(\.id))
        return valid.filter { chosen.contains($0.id) }
    }

    /// 쉼표 구분 별칭 원문 → 빈 항목을 뺀 배열.
    private static func aliasList(_ card: CharacterCard) -> [String] {
        card.aliases.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - instruct 프롬프트 (엔진에서 이관 — 프롬프트의 단일 소유자는 조립기)

    package static let instructSystem = """
        너는 글쓰기 자동완성 엔진이다. 사용자가 쓰던 글의 마지막 부분을 받아, \
        그 마지막 글자 바로 뒤에 자연스럽게 이어질 짧은 다음 구절(최대 한 문장)을 \
        출력한다. 설명·인사·따옴표·머리말 없이 이어질 본문만 출력한다.
        """

    package static func instructUser(prefix: String) -> String {
        """
        다음 글에 바로 이어질 내용을 짧게 이어써라.

        \(prefix)
        """
    }
}
