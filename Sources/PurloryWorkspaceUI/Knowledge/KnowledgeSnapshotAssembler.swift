import Foundation
import PurloryDocumentEngine
import PurloryFoundation
import PurloryIntelligence

/// Pure, nonisolated snapshot assembly, thermal/low-power gating, and sidecar metric helpers for `BackgroundIndexer`.
enum KnowledgeSnapshotAssembler {
    static func measure(
        sidecar: KnowledgeSidecar,
        sceneCount: Int,
        loadMs: Double,
        deriveMs: Double,
        saveMs: Double = 0
    ) -> BackgroundIndexer.KnowledgeMetrics {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = (try? encoder.encode(sidecar))?.count ?? 0
        return BackgroundIndexer.KnowledgeMetrics(
            sidecarBytes: bytes,
            sceneCount: sceneCount,
            bytesPerScene: sceneCount > 0 ? bytes / sceneCount : 0,
            loadMs: loadMs,
            saveMs: saveMs,
            deriveMs: deriveMs
        )
    }

    static func distance(from scene: DocumentOutline.Scene, to caret: Int) -> Int {
        if scene.utf16Range.contains(caret) { return 0 }
        return caret < scene.utf16Range.lowerBound
            ? scene.utf16Range.lowerBound - caret
            : caret - scene.utf16Range.upperBound
    }

    static func gateAllows(
        deep: Bool,
        thermalState: ProcessInfo.ThermalState,
        lowPowerModeEnabled: Bool
    ) -> Bool {
        switch thermalState {
        case .serious, .critical: return false
        default: break
        }
        if deep, lowPowerModeEnabled { return false }
        return true
    }

    static func gateAllows(deep: Bool) -> Bool {
        let process = ProcessInfo.processInfo
        return gateAllows(
            deep: deep,
            thermalState: process.thermalState,
            lowPowerModeEnabled: process.isLowPowerModeEnabled
        )
    }

    static func gateBlockReason(
        deep: Bool,
        thermalState: ProcessInfo.ThermalState,
        lowPowerModeEnabled: Bool
    ) -> String? {
        switch thermalState {
        case .serious, .critical:
            return "기기가 뜨거워요(열 상태) — 식으면 자동으로 다시 시작할 수 있어요"
        default:
            break
        }
        if deep, lowPowerModeEnabled {
            return "저전력 모드예요 — 저전력을 끄거나 나중에 다시 시도해 주세요"
        }
        return nil
    }

    static func makeSnapshot(
        entryID: UUID,
        scope: StoryMemoryScope? = nil,
        outline: DocumentOutline,
        sidecar: KnowledgeSidecar,
        utterances: [Utterance],
        overrides: [NarrativeOverride] = [],
        body: String = "",
        characters: [CharacterCard] = [],
        recordedConversations: [RecordedConversation] = []
    ) -> KnowledgeSnapshot {
        let (rekeyed, stale) = NarrativeOverrides(overrides)
            .rekeyedForScenes(outline: outline, body: body)
        let text = body as NSString
        let anchoredRecords = recordedConversations.map {
            ConversationDetector.reanchor($0, in: text) ?? $0
        }
        let boundedSegments = SegmentParser.applyingBoundaryOverrides(
            sidecar.segments, overrides: rekeyed, outline: outline, body: body
        )
        let memoryScope = scope ?? .legacy(
            documentID: WritingDocumentID(rawValue: entryID)
        )
        let storyMemory = StoryMemorySnapshot.make(
            scope: memoryScope, outline: outline, sidecar: sidecar, body: body
        )
        let storyKnowledge = StoryKnowledgeProjection.make(
            scope: memoryScope, body: body, outline: outline, sidecar: sidecar,
            characters: characters, overrides: rekeyed
        )
        let freshSceneSummaries = Dictionary(
            uniqueKeysWithValues: storyMemory.sceneSummaries.map {
                ($0.key.rawValue, $0.value)
            }
        )
        let freshChapterSummaries = Dictionary(
            uniqueKeysWithValues: storyMemory.chapterSummaries.values.map {
                ($0.headingPath.joined(separator: " > "), $0.summary)
            }
        )
        return KnowledgeSnapshot(
            entryID: entryID,
            outline: outline,
            summariesByHash: freshSceneSummaries.mapValues(\.summary),
            chapterSummariesByPath: freshChapterSummaries,
            workSummary: storyMemory.workSummary?.summary,
            storyMemory: storyMemory,
            storyKnowledge: storyKnowledge,
            events: sidecar.events,
            utterances: utterances,
            sceneSummaries: freshSceneSummaries,
            insights: sidecar.insights,
            segments: boundedSegments,
            eventGraph: sidecar.eventGraph,
            plotThreadAnalysis: sidecar.plotThreads,
            recordedConversations: anchoredRecords,
            conversationMeta: sidecar.conversationMeta,
            characters: characters,
            overrides: rekeyed,
            staleOverrides: stale
        )
    }

    static func combinedHash(_ hashes: [String]) -> String {
        DocumentOutline.stableHash(hashes.joined(separator: "|"))
    }

    static func clamp(_ text: String, to limit: Int) -> String {
        SentenceClamp.clamp(text, to: limit)
    }
}
