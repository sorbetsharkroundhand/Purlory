@testable import PurloryStorage
import XCTest
@testable import PurloryCore

final class KnowledgeSidecarRepositoryTests: XCTestCase {
    func testProjectsWithSameDocumentAndContentRemainIsolated() async throws {
        let root = try temporaryProjectRoot()
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let documentID = WritingDocumentID()
        let projectA = project(id: WritingProjectID(), documentID: documentID, body: "Same")
        let projectB = project(id: WritingProjectID(), documentID: documentID, body: "Same")
        let store = ProjectStore(root: root)
        try await store.save(projectA)
        try await store.save(projectB)
        let repository = KnowledgeSidecarRepository(projectStore: store, legacyDirectory: legacy)
        let scopeA = StoryMemoryScope.project(projectID: projectA.id, documentID: documentID)
        let scopeB = StoryMemoryScope.project(projectID: projectB.id, documentID: documentID)
        var sidecarA = KnowledgeSidecar(scope: scopeA)
        var sidecarB = KnowledgeSidecar(scope: scopeB)
        sidecarA.generation = 3
        sidecarB.generation = 7

        try await repository.save(sidecarA, scope: scopeA)
        try await repository.save(sidecarB, scope: scopeB)

        let loadedA = await repository.load(scope: scopeA)
        let loadedB = await repository.load(scope: scopeB)
        XCTAssertEqual(loadedA.generation, 3)
        XCTAssertEqual(loadedB.generation, 7)
    }

    func testProjectLoadNeverFallsBackToLegacySidecar() async throws {
        let root = try temporaryProjectRoot()
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let documentID = WritingDocumentID()
        let project = project(id: WritingProjectID(), documentID: documentID, body: "Draft")
        let store = ProjectStore(root: root)
        try await store.save(project)
        let repository = KnowledgeSidecarRepository(projectStore: store, legacyDirectory: legacy)
        let legacyScope = StoryMemoryScope.legacy(documentID: documentID)
        var legacySidecar = KnowledgeSidecar(scope: legacyScope)
        legacySidecar.generation = 41
        try await repository.save(legacySidecar, scope: legacyScope)

        let projectScope = StoryMemoryScope.project(projectID: project.id, documentID: documentID)
        let loaded = await repository.load(scope: projectScope)

        XCTAssertEqual(loaded.scope, projectScope)
        XCTAssertEqual(loaded.generation, 0)
        let reloadedLegacy = await repository.load(scope: legacyScope)
        XCTAssertEqual(reloadedLegacy.generation, 41)
    }

    func testSchemaMismatchRebuildsOnlyDerivedProjectCache() async throws {
        let root = try temporaryProjectRoot()
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let documentID = WritingDocumentID()
        let project = project(id: WritingProjectID(), documentID: documentID, body: "User manuscript")
        let store = ProjectStore(root: root)
        try await store.save(project)
        let repository = KnowledgeSidecarRepository(projectStore: store, legacyDirectory: legacy)
        let scope = StoryMemoryScope.project(projectID: project.id, documentID: documentID)
        var old = KnowledgeSidecar(scope: scope)
        old.schemaVersion = KnowledgeSidecar.currentSchemaVersion - 1
        old.generation = 8
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await store.writeIntelligence(
            encoder.encode(old), projectID: project.id, documentID: documentID)

        let rebuilt = await repository.load(scope: scope)

        XCTAssertEqual(rebuilt.scope, scope)
        XCTAssertEqual(rebuilt.generation, 9)
        let reloadedProject = try await store.load(id: project.id)
        XCTAssertEqual(reloadedProject, project)
    }

    func testRepositoryRejectsCrossScopeWrite() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        let repository = KnowledgeSidecarRepository(
            projectStore: store, legacyDirectory: root.appendingPathComponent("legacy"))
        let a = StoryMemoryScope.legacy(documentID: WritingDocumentID())
        let b = StoryMemoryScope.legacy(documentID: WritingDocumentID())

        do {
            try await repository.save(KnowledgeSidecar(scope: a), scope: b)
            XCTFail("Cross-scope write was accepted")
        } catch let error as KnowledgeSidecarRepository.Error {
            XCTAssertEqual(error, .scopeMismatch)
        }
    }

    private func project(
        id: WritingProjectID,
        documentID: WritingDocumentID,
        body: String
    ) -> WritingProject {
        WritingProject(
            id: id, title: "Project", mode: .fiction,
            documents: [.init(id: documentID, title: "Draft", body: body, kind: .manuscript)])
    }
}
