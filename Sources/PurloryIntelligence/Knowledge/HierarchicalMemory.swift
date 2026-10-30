import Foundation

/// The persistence and publication boundary for one document's derived story memory.
/// Project and legacy scopes are separate cases so project data can never silently fall
/// back to the process-wide legacy cache.
public enum StoryMemoryScope: Hashable, Codable, Sendable {
    case project(projectID: WritingProjectID, documentID: WritingDocumentID)
    case legacy(documentID: WritingDocumentID)

    public var projectID: WritingProjectID? {
        guard case .project(let projectID, _) = self else { return nil }
        return projectID
    }

    public var documentID: WritingDocumentID {
        switch self {
        case .project(_, let documentID), .legacy(let documentID): documentID
        }
    }
}

/// Resolves persistence scope without crossing the project/legacy boundary. An active
/// project that does not own the document returns `nil`; it never falls back to legacy.
public enum StoryMemoryScopeResolver {
    public static func resolve(
        activeProject: WritingProject?,
        entryID: UUID
    ) -> StoryMemoryScope? {
        let documentID = WritingDocumentID(rawValue: entryID)
        guard let activeProject else { return .legacy(documentID: documentID) }
        guard activeProject.documents.contains(where: { $0.id == documentID }) else {
            return nil
        }
        return .project(projectID: activeProject.id, documentID: documentID)
    }
}

/// Stable routing-node identity for hierarchy levels that have a structural identity.
/// Scene revisions intentionally use `SceneContentVersion` instead of this type.
public struct StoryMemoryNodeID: Hashable, Codable, Sendable {
    public enum Level: String, Codable, Sendable {
        case chapter
        case work
    }

    public let level: Level
    public let key: String

    public init(level: Level, key: String) {
        self.level = level
        self.key = key
    }

    public static func chapter(path: [String]) -> Self {
        let key = path.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return Self(level: .chapter, key: key)
    }

    public static let work = Self(level: .work, key: "work")
}

public struct HierarchicalMemoryChanges: Equatable, Sendable {
    public let dirtyScenes: Set<SceneContentVersion>
    public let dirtyChapters: Set<StoryMemoryNodeID>
    public let workIsDirty: Bool

    public init(
        dirtyScenes: Set<SceneContentVersion>,
        dirtyChapters: Set<StoryMemoryNodeID>,
        workIsDirty: Bool
    ) {
        self.dirtyScenes = dirtyScenes
        self.dirtyChapters = dirtyChapters
        self.workIsDirty = workIsDirty
    }
}

public enum HierarchicalMemory {
    public struct ChapterGroup: Equatable, Sendable {
        public let path: [String]
        public let scenes: [DocumentOutline.Scene]
        public let childrenHash: String
        public let nodeID: StoryMemoryNodeID
    }

    public static func chapterGroups(in outline: DocumentOutline) -> [ChapterGroup] {
        var groups: [(path: [String], scenes: [DocumentOutline.Scene])] = []
        for scene in outline.scenes {
            let path = Array(scene.headingPath.prefix(2))
            if let last = groups.indices.last, groups[last].path == path {
                groups[last].scenes.append(scene)
            } else {
                groups.append((path, [scene]))
            }
        }
        return groups.map { group in
            ChapterGroup(
                path: group.path,
                scenes: group.scenes,
                childrenHash: combinedHash(group.scenes.map(\.contentHash)),
                nodeID: .chapter(path: group.path))
        }
    }

    public static func workChildrenHash(for outline: DocumentOutline) -> String {
        combinedHash(outline.scenes.map(\.contentHash))
    }

    public static func changes(
        previous: KnowledgeSidecar,
        outline: DocumentOutline
    ) -> HierarchicalMemoryChanges {
        let dirtyScenes = Set(outline.scenes.compactMap { scene -> SceneContentVersion? in
            guard let summary = previous.sceneSummaries[scene.contentHash],
                summary.contentHash == scene.contentHash
            else { return scene.contentVersion }
            return nil
        })
        let dirtyChapters = Set<StoryMemoryNodeID>(chapterGroups(in: outline).compactMap { chapter in
            guard chapter.scenes.count >= 2 else { return nil }
            let existing = previous.chapterSummaries.first {
                $0.headingPath == chapter.path && $0.childrenHash == chapter.childrenHash
            }
            return existing == nil ? chapter.nodeID : nil
        })
        let workIsDirty = outline.scenes.count >= 3
            && (previous.workSummary?.childrenHash != workChildrenHash(for: outline)
                || !dirtyScenes.isEmpty)
        return HierarchicalMemoryChanges(
            dirtyScenes: dirtyScenes,
            dirtyChapters: dirtyChapters,
            workIsDirty: workIsDirty)
    }

    package static func combinedHash(_ hashes: [String]) -> String {
        DocumentOutline.stableHash(hashes.joined(separator: "|"))
    }
}

/// A freshness-filtered routing view over the existing derived sidecar.
public struct StoryMemorySnapshot: Equatable, Sendable {
    public let scope: StoryMemoryScope
    public let outline: DocumentOutline
    public let sceneSummaries: [SceneContentVersion: KnowledgeSidecar.SceneSummary]
    public let chapterSummaries: [StoryMemoryNodeID: KnowledgeSidecar.ChapterSummary]
    public let workSummary: KnowledgeSidecar.WorkSummary?
    private let evidenceByScene: [SceneContentVersion: EvidenceAnchor]
    private let sceneVersionsByNode: [StoryMemoryNodeID: [SceneContentVersion]]

    public static func make(
        scope: StoryMemoryScope,
        outline: DocumentOutline,
        sidecar: KnowledgeSidecar,
        body: String
    ) -> Self {
        guard sidecar.scope == scope else {
            return Self(
                scope: scope,
                outline: outline,
                sceneSummaries: [:],
                chapterSummaries: [:],
                workSummary: nil,
                evidenceByScene: [:],
                sceneVersionsByNode: [:])
        }
        var freshScenes: [SceneContentVersion: KnowledgeSidecar.SceneSummary] = [:]
        var evidenceByScene: [SceneContentVersion: EvidenceAnchor] = [:]
        let text = body as NSString

        for scene in outline.scenes {
            guard let summary = sidecar.sceneSummaries[scene.contentHash],
                summary.contentHash == scene.contentHash
            else { continue }
            freshScenes[scene.contentVersion] = summary
            guard scene.utf16Range.lowerBound >= 0,
                scene.utf16Range.upperBound <= text.length
            else { continue }
            let original = text.substring(
                with: NSRange(
                    location: scene.utf16Range.lowerBound,
                    length: scene.utf16Range.count))
            let quote = String(
                original.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            let anchor = EvidenceAnchor(
                documentID: scope.documentID,
                sceneHash: scene.contentHash,
                quote: quote,
                utf16Hint: scene.utf16Range.lowerBound)
            if anchor.resolvedQuery(in: body) != nil {
                evidenceByScene[scene.contentVersion] = anchor
            }
        }

        var freshChapters: [StoryMemoryNodeID: KnowledgeSidecar.ChapterSummary] = [:]
        var sceneVersionsByNode: [StoryMemoryNodeID: [SceneContentVersion]] = [:]
        let chapters = HierarchicalMemory.chapterGroups(in: outline)
        for chapter in chapters where chapter.scenes.count >= 2 {
            let versions = chapter.scenes.map(\.contentVersion)
            guard versions.allSatisfy({ freshScenes[$0] != nil }),
                let summary = sidecar.chapterSummaries.first(where: {
                    $0.headingPath == chapter.path && $0.childrenHash == chapter.childrenHash
                })
            else { continue }
            freshChapters[chapter.nodeID] = summary
            sceneVersionsByNode[chapter.nodeID] = versions
        }

        let allVersions = outline.scenes.map(\.contentVersion)
        let allScenesFresh = allVersions.allSatisfy { freshScenes[$0] != nil }
        let freshWork: KnowledgeSidecar.WorkSummary?
        if allScenesFresh,
            sidecar.workSummary?.childrenHash == HierarchicalMemory.workChildrenHash(for: outline)
        {
            freshWork = sidecar.workSummary
            sceneVersionsByNode[.work] = allVersions
        } else {
            freshWork = nil
        }

        return Self(
            scope: scope,
            outline: outline,
            sceneSummaries: freshScenes,
            chapterSummaries: freshChapters,
            workSummary: freshWork,
            evidenceByScene: evidenceByScene,
            sceneVersionsByNode: sceneVersionsByNode)
    }

    public func evidence(for sceneVersion: SceneContentVersion) -> EvidenceAnchor? {
        evidenceByScene[sceneVersion]
    }

    public func evidence(for nodeID: StoryMemoryNodeID) -> [EvidenceAnchor] {
        (sceneVersionsByNode[nodeID] ?? []).compactMap { evidenceByScene[$0] }
    }
}
