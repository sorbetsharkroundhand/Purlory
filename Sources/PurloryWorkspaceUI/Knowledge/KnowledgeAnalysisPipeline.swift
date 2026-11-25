import Foundation
import PurloryDocumentEngine
import PurloryFoundation
import PurloryInference
import PurloryIntelligence

/// Detached, nonisolated knowledge extraction and multi-stage pass execution pipeline.
enum KnowledgeAnalysisPipeline {
    static let fastPassCallBudget = BackgroundIndexer.fastPassCallBudget
    static let maxSceneCharacters = BackgroundIndexer.maxSceneCharacters

    /// Extracts a short character profile draft from excerpts mentioning `name`.
    static func profileCharacter(
        named name: String, in body: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        var snippets: [String] = []
        var total = 0
        for line in body.split(separator: "\n") where line.contains(name) {
            let sentence = line.trimmingCharacters(in: .whitespaces)
            snippets.append(sentence)
            total += sentence.count
            if snippets.count >= 8 || total > 1_000 { break }
        }
        guard !snippets.isEmpty else { return nil }
        let note =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.profileSystem,
                user: KnowledgePromptCatalog.profileUser(name: name, snippets: snippets),
                maxTokens: 96,
                parameters: parameters)) ?? ""
        let collapsed = note
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : String(collapsed.prefix(140))
    }

    /// 한 번의 이해 패스 — 값 입력만 받아 detached에서 돈다.
    static func runPass(
        deep: Bool,
        scope: StoryMemoryScope,
        entryID: UUID,
        body: String,
        parameters: CompletionParameters,
        engine: CompletionEngine,
        persistence: any KnowledgeSidecarPersisting,
        liveEntryIDs: Set<UUID>,
        characters: [CharacterCard],
        overrides: [NarrativeOverride],
        recordedConversations: [RecordedConversation] = [],
        caretUTF16: Int?,
        gateStateProvider: (@Sendable () -> (thermalState: ProcessInfo.ThermalState, lowPowerModeEnabled: Bool))? = nil,
        publish: @Sendable @escaping (KnowledgeSnapshot) async -> Void,
        publishMetrics: @Sendable @escaping (BackgroundIndexer.KnowledgeMetrics) -> Void = { _ in },
        /// 씬 단위 결정적 진행 (처리한 수, 전체 더티 수) — "지금 읽기" 표시용 (#35).
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        /// 게이트(열·저전력)로 보류될 때 사유 보고 (#35).
        onBlocked: (@Sendable (String) -> Void)? = nil,
        /// The only sidecar publication boundary. It revalidates pass ownership before
        /// and after the write, so cancelled or switched work cannot keep publishing.
        commit: @Sendable @escaping (KnowledgeSidecar, Set<String>?) async -> Bool
    ) async {
        // 게이트 차단은 조용히 return하지 않고 이유를 남긴다 (#35).
        func gateOrReport(_ deepFlag: Bool) -> Bool {
            let state = gateStateProvider?() ?? (
                thermalState: ProcessInfo.processInfo.thermalState,
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            if KnowledgeSnapshotAssembler.gateAllows(
                deep: deepFlag,
                thermalState: state.thermalState,
                lowPowerModeEnabled: state.lowPowerModeEnabled)
            {
                return true
            }
            if let reason = KnowledgeSnapshotAssembler.gateBlockReason(
                deep: deepFlag,
                thermalState: state.thermalState,
                lowPowerModeEnabled: state.lowPowerModeEnabled),
                let onBlocked
            {
                onBlocked(reason)
            }
            return false
        }
        guard gateOrReport(deep) else { return }

        let outline = DocumentOutline.parse(body)
        guard !outline.scenes.isEmpty else { return }
        // 커서 거리순 순회 — 씬 분할로 씬이 수십 개가 되면, 쓰고 있는 자리
        // 근처의 이해가 먼저 준비돼야 한다. 스냅샷·저장은 해시 키라 처리
        // 순서와 무관하고, 선점당해도 "가까운 것부터 남는" 성질이 생긴다.
        let orderedScenes: [DocumentOutline.Scene]
        if let caretUTF16 {
            orderedScenes = outline.scenes.sorted {
                KnowledgeSnapshotAssembler.distance(from: $0, to: caretUTF16) < KnowledgeSnapshotAssembler.distance(from: $1, to: caretUTF16)
            }
        } else {
            orderedScenes = outline.scenes
        }
        var sidecar = await persistence.load(scope: scope)
        guard sidecar.scope == scope else { return }
        let text = body as NSString

        let liveHashes = Set(outline.scenes.map(\.contentHash))
        var sidecarDirty = false
        func checkpointIfDirty() async -> Bool {
            guard sidecarDirty else { return true }
            guard !Task.isCancelled else { return false }
            let ok = await commit(sidecar, liveHashes)
            if ok { sidecarDirty = false }
            return ok
        }

        // Deterministic progress denominator counts each missing work unit across active phases.
        let dirtyTotal = orderedScenes.reduce(into: 0) { total, scene in
            if sidecar.sceneSummaries[scene.contentHash] == nil { total += 1 }
            if deep {
                if sidecar.events[scene.contentHash] == nil { total += 1 }
                if sidecar.insights[scene.contentHash] == nil { total += 1 }
                if sidecar.segments[scene.contentHash] == nil { total += 1 }
            }
        }
        var dirtyDone = 0
        func reportProgress() {
            guard let progress else { return }
            let denominator = max(dirtyTotal, 1)
            progress(min(dirtyDone, denominator), denominator)
        }
        reportProgress()
        // 대화 귀속 (PLAN §7·§6.4) — 결정적·LLM 없음이라 패스마다 재계산.
        // 사이드카에 저장하지 않는 파생 — 스냅샷에만 실린다.
        let utterances = DialogueAttribution.utterances(in: body, cards: characters)

        // ① 더티 씬 요약 — 해시 메모에 없는 씬만, 커서에서 가까운 순.
        var callBudget = deep ? Int.max : fastPassCallBudget
        for scene in orderedScenes {
            guard callBudget > 0 else { break }
            guard sidecar.sceneSummaries[scene.contentHash] == nil else { continue }
            guard !Task.isCancelled else { return }
            guard gateOrReport(deep) else {
                _ = await checkpointIfDirty()
                return
            }

            let sceneText = String(
                text.substring(
                    with: NSRange(
                        location: scene.utf16Range.lowerBound,
                        length: scene.utf16Range.count)
                ).prefix(maxSceneCharacters))
            guard sceneText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40
            else { continue }  // 요약할 내용이 없는 토막은 건너뛴다

            let analysis = await analyzeScene(
                sceneText, engine: engine, parameters: parameters)
            callBudget -= 1
            guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
            guard let analysis else { continue }  // 실패는 다음 패스가 재시도

            sidecar.sceneSummaries[scene.contentHash] = .init(
                contentHash: scene.contentHash,
                headingPath: scene.headingPath,
                summary: analysis.summary,
                title: analysis.title,
                narrativeType: analysis.narrativeType,
                pov: analysis.pov,
                location: analysis.location,
                updatedAt: .now)
            sidecarDirty = true
            dirtyDone += 1
            reportProgress()
        }
        guard await checkpointIfDirty() else { return }

        // ② 사건 추출 (깊은 패스 전용, PLAN §6.3) — 요약이 끝난 씬만.
        // 요약보다 뒤에 두는 이유: 빠른 패스의 LLM 예산은 요약이 먼저 쓴다
        // (docs/m6-events.md 결정 3).
        if deep, !Task.isCancelled {
            relinkParticipants(sidecar: &sidecar, characters: characters)
            for scene in orderedScenes {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else {
                    _ = await checkpointIfDirty()
                    return
                }
                // 키 존재 = 추출 완료(빈 배열이면 "사건 없음") — 메모 적중은 건너뛴다.
                guard sidecar.events[scene.contentHash] == nil else { continue }
                let sceneText = String(
                    text.substring(
                        with: NSRange(
                            location: scene.utf16Range.lowerBound,
                            length: scene.utf16Range.count)
                    ).prefix(maxSceneCharacters))
                let extracted = await extractEvents(
                    sceneText, sceneHash: scene.contentHash,
                    characters: characters, engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let extracted else { continue }  // 실패·인물 미등록 — 재시도 여지
                sidecar.events[scene.contentHash] = extracted
                sidecarDirty = true
                dirtyDone += 1
                reportProgress()
            }
            guard await checkpointIfDirty() else { return }
        }

        // ②b 심화 추출 (깊은 패스 전용, v4 — 앎·관계). 사건과 별도
        // 메모 키(insights) — 한쪽 실패가 다른 쪽을 지우지 않는다 (실패 격리).
        if deep, !Task.isCancelled {
            for scene in orderedScenes {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else {
                    _ = await checkpointIfDirty()
                    return
                }
                guard sidecar.insights[scene.contentHash] == nil else { continue }
                let sceneText = String(
                    text.substring(
                        with: NSRange(
                            location: scene.utf16Range.lowerBound,
                            length: scene.utf16Range.count)
                    ).prefix(maxSceneCharacters))
                let insights = await extractInsights(
                    sceneText, sceneHash: scene.contentHash,
                    characters: characters, engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let insights else { continue }  // 실패 — 다음 패스가 재시도
                sidecar.insights[scene.contentHash] = insights
                sidecarDirty = true
                dirtyDone += 1
                reportProgress()
            }
            guard await checkpointIfDirty() else { return }
        }

        // ②c 서사 구간 분석 (깊은 패스 전용, v5 — 요구사항 §7–§10).
        // 다단계: 결정적 후보 감지가 게이트다 — 시간 이동 표지가 전혀 없고 씬
        // 유형도 현재면 LLM 없이 "단일 현재 서사"로 메모한다 (토큰 절약).
        if deep, !Task.isCancelled {
            for scene in orderedScenes {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else {
                    _ = await checkpointIfDirty()
                    return
                }
                guard sidecar.segments[scene.contentHash] == nil else { continue }
                let sceneText = String(
                    text.substring(
                        with: NSRange(
                            location: scene.utf16Range.lowerBound,
                            length: scene.utf16Range.count)
                    ).prefix(maxSceneCharacters))
                let storedType = sidecar.sceneSummaries[scene.contentHash]?.narrativeType
                    .map { SceneNarrativeType.normalize($0) }
                let hasShiftHint =
                    (storedType ?? .present) != .present
                    || TemporalShiftDetector.hasCandidate(in: sceneText)
                guard hasShiftHint else {
                    sidecar.segments[scene.contentHash] = SceneSegmentation()  // 메모: 단일 서사
                    sidecarDirty = true
                    dirtyDone += 1
                    reportProgress()
                    continue
                }
                let segments = await analyzeSegments(
                    sceneText, sceneHash: scene.contentHash,
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let segments else { continue }  // 실패 — 다음 패스가 재시도
                sidecar.segments[scene.contentHash] = SceneSegmentation(segments: segments)
                sidecarDirty = true
                dirtyDone += 1
                reportProgress()
            }
            guard await checkpointIfDirty() else { return }
        }

        // ③ 상향 전파 (깊은 패스 전용) — 장 → 작품, 더티 경로만 (PLAN §6.1).
        if deep, !Task.isCancelled {
            await propagate(
                outline: outline, sidecar: &sidecar,
                parameters: parameters, engine: engine,
                gateAllows: { gateOrReport(true) })
            guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
            // 어떤 저널도 참조하지 않는 사이드카 정리 (삭제된 작품의 파생물).
            if case .legacy = scope {
                await persistence.pruneLegacyOrphans(
                    keeping: Set(liveEntryIDs.map(WritingDocumentID.init(rawValue:))))
            }
        }

        // ④ 사건 그래프 분석 (깊은 패스 전용, v5 — 요구사항 §3·§6·§12·§29).
        // 살아있는 씬의 사건 전체를 담화 순서로 모아 한 번의 호출로 인과·동일
        // 사건·시간 관계 후보를 뽑는다. 메모 키 = 사건 키 집합의 결합 해시.
        if deep, !Task.isCancelled, gateOrReport(true) {
            var orderedEvents: [StoryEvent] = []
            for scene in outline.scenes {
                orderedEvents.append(contentsOf: sidecar.events[scene.contentHash] ?? [])
            }
            let analysisEvents = uniqueEventsForAnalysis(orderedEvents)
            _ = clearAnalysesBelowThreshold(
                sidecar: &sidecar, uniqueEventCount: analysisEvents.count)
            let memoHash = KnowledgeSnapshotAssembler.combinedHash(analysisEvents.map(\.stableKey))
            if analysisEvents.count >= 2, sidecar.eventGraph?.memoHash != memoHash {
                let analysis = await analyzeEventGraph(
                    events: analysisEvents, characters: characters,
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                if let analysis = analysis {
                    sidecar.eventGraph = EventGraphAnalysis(
                        causalLinks: analysis.causalLinks,
                        identities: analysis.identities,
                        chronoEdges: analysis.chronoEdges,
                        memoHash: memoHash)
                    sidecarDirty = true
                }
            }
        }

        // ⑤b 플롯 스레드 추론 (깊은 패스 전용, v6). 사건 목록 + 인과 힌트를
        // 한 번의 호출로 플롯 라인으로 묶는다. 메모 키 = 사건 키 집합 해시.
        // 재분석 결과는 이전 스레드에 멤버 겹침으로 이어(reconcile) stableID가
        // 유지된다 — 오버라이드·색·레인의 앵커가 흔들리지 않는다 (요구사항 §10).
        if deep, !Task.isCancelled, gateOrReport(true) {
            var orderedEvents: [StoryEvent] = []
            for scene in outline.scenes {
                orderedEvents.append(contentsOf: sidecar.events[scene.contentHash] ?? [])
            }
            let analysisEvents = uniqueEventsForAnalysis(orderedEvents)
            let memoHash = KnowledgeSnapshotAssembler.combinedHash(analysisEvents.map(\.stableKey) + ["plot"])
            if analysisEvents.count >= 3, sidecar.plotThreads?.memoHash != memoHash {
                let threads = await analyzePlotThreads(
                    events: analysisEvents, characters: characters,
                    causalLinks: sidecar.eventGraph?.causalLinks ?? [],
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                if let threads = threads {
                    sidecar.plotThreads = PlotThreadAnalysis(
                        threads: PlotThreadParser.reconcile(
                            new: threads,
                            previous: sidecar.plotThreads?.threads ?? []),
                        memoHash: memoHash)
                    sidecarDirty = true
                }
            }
        }

        // ⑥ 기록된 대화 보완 (깊은 패스 전용, v5 — 요구사항 §19). 기록 시점에
        // 비어 있던 주제·어조를 채운다. 메모 = 기록의 contentHash (원문이
        // 바뀌면 재분석). 사용자 기록 자체(entries.json)는 건드리지 않는다.
        if deep, !Task.isCancelled {
            for record in recordedConversations {
                guard !Task.isCancelled else { return }
                guard gateOrReport(true) else {
                    _ = await checkpointIfDirty()
                    return
                }
                let key = record.id.uuidString
                if sidecar.conversationMeta[key]?.contentHash == record.contentHash { continue }
                let anchored = ConversationDetector.reanchor(record, in: text) ?? record
                let start = min(max(0, anchored.utf16Start), text.length)
                let end = min(max(start, anchored.utf16End), text.length)
                guard end > start else { continue }
                let conversationText = String(
                    text.substring(with: NSRange(location: start, length: end - start))
                        .prefix(maxSceneCharacters))
                let meta = await analyzeConversation(
                    conversationText, contentHash: record.contentHash,
                    engine: engine, parameters: parameters)
                guard !Task.isCancelled else { return }  // 취소 뒤 체크포인트 금지 (#82)
                guard let meta else { continue }
                sidecar.conversationMeta[key] = meta
                sidecarDirty = true
            }
            // 기록이 삭제된 보완 데이터 정리.
            let liveIDs = Set(recordedConversations.map { $0.id.uuidString })
            sidecar.conversationMeta = sidecar.conversationMeta.filter {
                liveIDs.contains($0.key)
            }
        }

        guard !Task.isCancelled else { return }
        let saveStart = CFAbsoluteTimeGetCurrent()
        guard await commit(sidecar, liveHashes) else { return }
        let saveMs = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
        let deriveStart = CFAbsoluteTimeGetCurrent()
        let snapshot = KnowledgeSnapshotAssembler.makeSnapshot(
            entryID: entryID, scope: scope, outline: outline, sidecar: sidecar,
            utterances: utterances, overrides: overrides, body: body,
            characters: characters,
            recordedConversations: recordedConversations)
        let deriveMs = (CFAbsoluteTimeGetCurrent() - deriveStart) * 1000
        await publish(snapshot)
        // 성능 지표 (요구사항 §33) — 깊은 패스 끝에서 한 번 갱신.
        publishMetrics(
            KnowledgeSnapshotAssembler.measure(
                sidecar: sidecar, sceneCount: outline.scenes.count,
                loadMs: 0, deriveMs: deriveMs, saveMs: saveMs))
    }

    /// 장·작품 요약 상향 전파 — 하위 요약이 전부 준비된 노드만, 결합 해시가
    /// 바뀐(더티) 노드만 다시 만든다.
    private static func propagate(
        outline: DocumentOutline,
        sidecar: inout KnowledgeSidecar,
        parameters: CompletionParameters,
        engine: CompletionEngine,
        gateAllows: () -> Bool = { KnowledgeSnapshotAssembler.gateAllows(deep: true) }
    ) async {
        let changes = HierarchicalMemory.changes(previous: sidecar, outline: outline)
        let chapters = HierarchicalMemory.chapterGroups(in: outline)

        // 이번 패스에서 확보한 롤업 — 경로별 기록 후 아래에서 문서 순서로 조립한다.
        var madeByPath: [[String]: KnowledgeSidecar.ChapterSummary] = [:]
        for chapter in chapters {
            guard !Task.isCancelled, gateAllows() else { return }
            let childSummaries = chapter.scenes.compactMap {
                sidecar.sceneSummaries[$0.contentHash]?.summary
            }
            // 하위가 다 준비되지 않았거나, 씬 하나뿐이면(씬 요약으로 충분) 건너뛴다.
            guard childSummaries.count == chapter.scenes.count,
                chapter.scenes.count >= 2
            else { continue }
            if !changes.dirtyChapters.contains(chapter.nodeID),
                let existing = sidecar.chapterSummaries.first(where: {
                    $0.headingPath == chapter.path && $0.childrenHash == chapter.childrenHash
                })
            {
                madeByPath[chapter.path] = existing  // 메모 적중 — 재요약 금지
                continue
            }
            let summary = await rollup(
                childSummaries, level: .chapter, engine: engine, parameters: parameters)
            guard let summary else { continue }
            madeByPath[chapter.path] =
                .init(
                    headingPath: chapter.path, childrenHash: chapter.childrenHash,
                    summary: summary, updatedAt: .now)
        }
        // 문서 순서 조립 — 갱신된 장은 새 값, 아니면 기존 롤업을 물려받는다.
        // 완전 교체하면 더티 윈도우(씬 재요약 중·롤업 실패)에 유효한 장 요약이
        // 통째로 사라졌다 다음 패스에 되살아난다 — 요약 피라미드의 증분 규율(§6.1) 위반.
        sidecar.chapterSummaries = chapters.compactMap { chapter in
            madeByPath[chapter.path]
                ?? sidecar.chapterSummaries.first { $0.headingPath == chapter.path }
        }

        // 작품 요약 — 장 요약(없으면 씬 요약)에서. 씬 3개 미만이면 만들지 않는다
        // (C 창이 이미 전부를 본다 — 토큰당 품질, CLAUDE.md §5-1).
        guard outline.scenes.count >= 3, !Task.isCancelled else { return }
        let sources =
            sidecar.chapterSummaries.count >= 2
            ? sidecar.chapterSummaries.map(\.summary)
            : outline.scenes.compactMap { sidecar.sceneSummaries[$0.contentHash]?.summary }
        guard sources.count >= 2 else { return }
        guard changes.workIsDirty else { return }
        let childrenHash = HierarchicalMemory.workChildrenHash(for: outline)
        let summary = await rollup(
            sources, level: .work, engine: engine, parameters: parameters)
        guard let summary else { return }
        sidecar.workSummary = .init(
            childrenHash: childrenHash, summary: summary, updatedAt: .now)
    }

    // MARK: - 씬 분석 호출 (공용 — 인덱서 본 경로 + PurloryBench 리플레이 측정)


    /// 씬 하나를 분석한다 (제목·요약·유형·시점·장소 — 한 번의 호출).
    /// 실패·빈 결과는 nil — 호출부가 무시한다 (PLAN §9).
    /// public인 이유: 벤치가 **완전히 같은 프롬프트·규격**으로 지식을 만들어야
    /// 측정이 본 경로를 대표한다 (CLAUDE.md §2-7).
    static func analyzeScene(
        _ text: String, engine: CompletionEngine, parameters: CompletionParameters
    ) async -> BackgroundIndexer.SceneAnalysis? {
        // 헤딩 한 줄뿐인 초미니 씬은 요약할 내용이 없다 — 모델에 넣으면 환각
        // 요약이 생긴다 (벤치에서 확인). 인덱서·벤치 공용 가드.
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return nil
        }
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.sceneSystem,
                user: KnowledgePromptCatalog.sceneUser(text),
                // 다섯 줄 형식 — 빈 줄 조기 종료를 끄고 토큰 예산으로만 제한한다.
                // 64토큰이 한국어 120자를 못 채워 요약이 중간에서 잘리던 원인.
                maxTokens: 192,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        return parseSceneAnalysis(output)
    }

    /// 벤치 호환 래퍼 — 분석에서 요약만 취한다 (같은 프롬프트·같은 경로).
    static func summarizeScene(
        _ text: String, engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        await analyzeScene(text, engine: engine, parameters: parameters)?.summary
    }

    /// 씬 분석 출력 파싱 — `키: 값` 줄 형식 (EventParser와 같은 관대한 파싱).
    /// 요약 줄이 없으면 nil — 제목만으로는 지식이 아니다.
    static func parseSceneAnalysis(_ output: String) -> BackgroundIndexer.SceneAnalysis? {
        var title: String?
        var summary: String?
        var type: String?
        var pov: String?
        var location: String?
        for rawLine in output.split(separator: "\n") {
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard let colon = line.firstIndex(of: ":") else {
                // 키 없는 첫 산문 줄 — 구형 응답(요약만 출력)의 폴백.
                if summary == nil, line.count >= 10 { summary = line }
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "제목": title = SentenceClamp.clamp(value, to: 24)
            case "요약": summary = SentenceClamp.clamp(value, to: BackgroundIndexer.maxSummaryCharacters)
            case "유형", "종류": type = value
            case "시점", "시점인물": pov = String(value.prefix(20))
            case "장소": location = String(value.prefix(30))
            default: break
            }
        }
        guard let summary, !summary.isEmpty else { return nil }
        return BackgroundIndexer.SceneAnalysis(
            title: title, summary: summary, narrativeType: type,
            pov: pov, location: location)
    }

    /// 심화 추출 (v4, PLAN §6.5) — 앎·관계. 깊은 패스 전용.
    /// 사건 추출과 별도 호출인 이유: 여러 필드를 한 프롬프트에 욱여넣으면 소형
    /// 모델의 형식 준수가 무너진다 (요약/사건 분리와 같은 실패 격리).
    static func extractInsights(
        _ text: String, sceneHash: String, characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> SceneInsights? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return SceneInsights()  // 초미니 씬 — 뽑을 것이 없다 (환각 방지)
        }
        let nameIndex = EventParser.nameIndex(characters)
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.insightSystem,
                user: KnowledgePromptCatalog.insightUser(text, names: nameIndex.keys.sorted()),
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }  // 실패 — 다음 패스가 재시도
        return InsightParser.parse(
            output, sceneHash: sceneHash, nameIndex: nameIndex, sceneText: text)
    }

    /// 서사 구간 분석 (v5, 요구사항 §7–§10) — 씬 안의 시간·관점 전환 구간을
    /// 한 번의 structured 호출로 뽑는다. 파서가 인용을 원문 대조로 검증하므로
    /// 환각 경계는 구조적으로 걸러진다. 실패는 nil — 다음 패스가 재시도.
    /// public인 이유: 벤치가 같은 프롬프트·규격으로 측정해야 한다 (CLAUDE.md §2-7).
    static func analyzeSegments(
        _ text: String, sceneHash: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [NarrativeSegment]? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return []  // 초미니 씬 — 구간이 있을 수 없다 (환각 방지)
        }
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.segmentSystem,
                user: KnowledgePromptCatalog.segmentUser(text),
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        // "없음"만 출력 = 씬 전체가 단일 서사 (유효한 완료).
        if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("없음") {
            return []
        }
        return SegmentParser.parse(output, sceneHash: sceneHash, sceneText: text)
    }

    /// 사건 그래프 분석 (v5, 요구사항 §3·§6·§12·§29) — 사건 목록 전체를 번호로
    /// 제시하고 인과·동일 사건·시간 관계 후보를 한 번의 호출로 받는다.
    /// 사건은 짧은 요약(≤80자)이라 수십 개여도 프롬프트가 작다. 실패는 nil.
    static func analyzeEventGraph(
        events: [StoryEvent], characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> EventGraphParser.Result? {
        let capped = uniqueEventsForAnalysis(events)
        guard capped.count >= 2 else {
            return EventGraphParser.Result(causalLinks: [], identities: [], chronoEdges: [])
        }
        let names = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.name) })
        let listing = capped.enumerated()
            .map { offset, event in
                let who = event.participants.compactMap { names[$0] }.joined(separator: "·")
                return "\(offset + 1). \(event.summary)\(who.isEmpty ? "" : " [\(who)]")"
            }
            .joined(separator: "\n")
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.eventGraphSystem,
                user: "사건 목록 (본문 등장 순서):\n\(listing)",
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        return EventGraphParser.parse(output, keys: capped.map(\.stableKey))
    }

    /// 플롯 스레드 추론 (v6) — 사건 목록을 플롯 라인으로 묶는다. 인물 겹침이
    /// 아니라 목표·갈등·질문의 연속성으로 묶으라는 규칙이 프롬프트의 핵심이다
    /// (Branch ≠ Character). 인과 후보를 힌트로 함께 준다 — 인과 사슬은 같은
    /// 플롯일 강한 신호다. 실패는 nil (기존 분석 유지).
    static func analyzePlotThreads(
        events: [StoryEvent], characters: [CharacterCard],
        causalLinks: [CausalLink],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [PlotThread]? {
        let capped = uniqueEventsForAnalysis(events)
        guard capped.count >= 3 else { return [] }
        let names = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.name) })
        let listing = capped.enumerated()
            .map { offset, event in
                let who = event.participants.compactMap { names[$0] }.joined(separator: "·")
                return "\(offset + 1). \(event.summary)\(who.isEmpty ? "" : " [\(who)]")"
            }
            .joined(separator: "\n")
        // 인과 힌트 — 번호로 환산 가능한 것만 (같은 40개 상한 안).
        let numberByKey = Dictionary(
            uniqueKeysWithValues: capped.enumerated().map { ($0.element.stableKey, $0.offset + 1) })
        let hints = causalLinks.compactMap { link -> String? in
            guard let from = numberByKey[link.fromKey], let to = numberByKey[link.toKey]
            else { return nil }
            return "\(from) → \(to) (\(link.kind.rawValue))"
        }
        let hintBlock = hints.isEmpty ? "" : "\n\n인과 관계 힌트:\n\(hints.joined(separator: "\n"))"
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.plotThreadSystem,
                user: "사건 목록 (본문 등장 순서):\n\(listing)\(hintBlock)",
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("없음") {
            return []
        }
        return PlotThreadParser.parse(output, keys: capped.map(\.stableKey))
    }

    /// 같은 사건의 재서술은 stableKey가 겹친다. 번호 목록과 key→번호 인덱스를
    /// 1:1로 유지하도록 첫 등장만 남긴 뒤 분석 상한을 적용한다 (PLAN §6.6).
    static func uniqueEventsForAnalysis(
        _ events: [StoryEvent], limit: Int = 40
    ) -> [StoryEvent] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var result: [StoryEvent] = []
        result.reserveCapacity(min(limit, events.count))
        for event in events where seen.insert(event.stableKey).inserted {
            result.append(event)
            if result.count == limit { break }
        }
        return result
    }

    /// 중복 정규화 뒤 분석 최소 개수를 못 채우면 과거 결과도 더는 유효하지 않다.
    /// raw 사건 수만 보고 건너뛰면 삭제된 사건을 가리키는 그래프가 남는다 (PLAN §6.6).
    @discardableResult
    static func clearAnalysesBelowThreshold(
        sidecar: inout KnowledgeSidecar, uniqueEventCount: Int
    ) -> Bool {
        var changed = false
        if uniqueEventCount < 2, sidecar.eventGraph != nil {
            sidecar.eventGraph = nil
            changed = true
        }
        if uniqueEventCount < 3, sidecar.plotThreads != nil {
            sidecar.plotThreads = nil
            changed = true
        }
        return changed
    }

    /// 기록된 대화 보완 (v5, 요구사항 §19) — 주제·어조·핵심 발언을 뽑는다.
    static func analyzeConversation(
        _ text: String, contentHash: String,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> ConversationMeta? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
            return ConversationMeta(contentHash: contentHash)
        }
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.conversationSystem,
                user: "다음 대화를 분석하라.\n\n\(text)",
                maxTokens: 128,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }
        var topic: String?
        var tone: String?
        var statements: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = EventParser.stripListMarker(
                rawLine.trimmingCharacters(in: .whitespaces))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "주제": topic = String(value.prefix(30))
            case "어조", "분위기": tone = String(value.prefix(20))
            case "핵심":
                if statements.count < 2,
                    let quote = EventParser.validatedQuote(value, in: text)
                {
                    statements.append(String(quote.prefix(40)))
                }
            default: break
            }
        }
        return ConversationMeta(
            contentHash: contentHash, topic: topic, tone: tone, keyStatements: statements)
    }

    /// 등록 인물 ↔ 과거 사건 참여자 소급 연결 (결정적·LLM 없음, CLAUDE.md §2-5).
    ///
    /// 왜 필요한가: 추출은 **그 시점에 등록된 카드만** 참여자로 링크한다
    /// (CLAUDE.md §3). 그래서 나중에 등록된 인물은 이미 메모된 과거 사건에
    /// 영영 연결되지 못하고, 역색인이 빈 채로 남아 카드의 "최근" 줄이 나오지
    /// 않는다. 등록 때마다 전 씬을 재추출하면 LLM 비용이 등록 횟수만큼 곱해지므로,
    /// 사건 요약문의 이름 매칭으로 잇는다.
    ///
    /// 트레이드오프: 요약에 이름이 있지만 실제 참여자가 아닌 경우("서연이 민준의
    /// 편지를 읽었다"의 민준)까지 링크된다. 이름이 언급된 사건은 그 인물의
    /// 맥락으로서 여전히 유효하다고 보고 받아들인다 — 역색인에 구멍이 남는 쪽이
    /// 더 나쁘다. 기존 참여자는 지우지 않는다(추출 당시의 판단을 신뢰).
    private static func relinkParticipants(
        sidecar: inout KnowledgeSidecar, characters: [CharacterCard]
    ) {
        guard !characters.isEmpty else { return }
        let nameIndex = EventParser.nameIndex(characters)
        for (hash, events) in sidecar.events {
            var updated = events
            for offset in updated.indices {
                let summary = updated[offset].summary
                var participants = Set(updated[offset].participants)
                for (name, id) in nameIndex where summary.contains(name) {
                    participants.insert(id)
                }
                guard participants.count != updated[offset].participants.count else { continue }
                updated[offset].participants = Array(participants)
            }
            if updated != events { sidecar.events[hash] = updated }
        }
    }

    /// 씬 하나에서 사건을 뽑는다 (PLAN §6.3, M6-5) — 깊은 패스 전용.
    ///
    /// 요약과 **별도 호출**인 이유: 요약 경로는 이미 측정·출시됐고, 사건 파싱
    /// 실패가 요약까지 죽이면 회귀다 (docs/m6-events.md 결정 3).
    /// 등록 카드가 없으면 호출 자체를 건너뛴다 — 참여자를 링크할 수 없는 사건은
    /// 역색인에 들어가지 못해 토큰만 태운다 (CLAUDE.md §5-1).
    /// 벤치가 같은 프롬프트를 쓰도록 public (요약 경로와 같은 이유).
    static func extractEvents(
        _ text: String, sceneHash: String, characters: [CharacterCard],
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> [StoryEvent]? {
        let nameIndex = EventParser.nameIndex(characters)
        guard !nameIndex.isEmpty else { return nil }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            return []  // 요약과 같은 초미니 씬 가드 — 뽑을 사건이 없다(환각 방지)
        }
        let output =
            (try? await engine.generateOneShot(
                system: KnowledgePromptCatalog.eventSystem,
                user: KnowledgePromptCatalog.eventUser(text, names: nameIndex.keys.sorted()),
                // 5b에서 줄마다 `상태:` 필드가, v4에서 `근거:`가 붙어 길어졌다 —
                // 마지막 줄이 중간에서 잘리면 그 사건·델타를 통째로 잃는다.
                maxTokens: 384,
                parameters: parameters,
                stopAtBlankLine: false)) ?? ""
        guard !output.isEmpty else { return nil }  // 실패 — 다음 패스가 재시도
        return EventParser.parse(
            output, sceneHash: sceneHash, nameIndex: nameIndex, sceneText: text)
    }


    static func rollup(
        _ summaries: [String], level: BackgroundIndexer.RollupLevel,
        engine: CompletionEngine, parameters: CompletionParameters
    ) async -> String? {
        let summary =
            (try? await engine.generateOneShot(
                system: level == .chapter ? KnowledgePromptCatalog.chapterSystem : KnowledgePromptCatalog.workSystem,
                user: KnowledgePromptCatalog.rollupUser(summaries),
                maxTokens: level == .chapter ? 128 : 160,
                parameters: parameters)) ?? ""
        return summary.isEmpty ? nil : KnowledgeSnapshotAssembler.clamp(summary, to: level == .chapter ? 300 : 500)
    }
}
