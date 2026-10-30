@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ProjectFaultRecoveryTests: XCTestCase {
    func testInterruptedSavePreservesEveryDurableRecordAndActiveMarker() async throws {
        for phase in ProjectFaultFiles.Phase.allCases {
            for target in ["UserData/records/", "Documents/", "Notes/", "previous-project.json", "project.json"] {
                let root = try temporaryProjectRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let store = ProjectStore(root: root)
                var original = projectFixture()
                original.userData["decision"] = Data("Explicit durable decision".utf8)
                try await store.save(original)
                try await store.activate(id: original.id)
                let folder = root.appendingPathComponent(original.id.rawValue.uuidString)
                let manifest = try Data(contentsOf: folder.appendingPathComponent("project.json"))
                let marker = try Data(contentsOf: root.appendingPathComponent("active-project.json"))
                var updated = original
                updated.documents[0].body += " changed manuscript"
                updated.documents[1].body += " changed note"
                updated.userData["decision"] = Data("New explicit decision".utf8)
                let files = ProjectFaultFiles(phase: phase, target: target)
                let failing = ProjectStore(root: root, fileSystem: files)
                await expectInterruption { try await failing.save(updated) }
                XCTAssertEqual(files.hits.count, 1, "Injection was bypassed: \(target)")
                if phase == .stagedReplacement { XCTAssertGreaterThan(files.hits.first?.stagedBytes ?? 0, 0) }
                let active = try await store.activeProject()
                XCTAssertEqual(active, original)
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("project.json")), manifest)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("active-project.json")), marker)
                try await store.save(updated)
                let reopened = try await ProjectStore(root: root).activeProject()
                XCTAssertEqual(reopened, updated, "Verified retry must retain all new bytes")
            }
        }
    }

    func testInterruptedAssetCommitPreservesReferenceAndBackup() async throws {
        for phase in ProjectFaultFiles.Phase.allCases {
            for target in ["Assets/", "previous-project.json", "project.json"] {
                let root = try temporaryProjectRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let store = ProjectStore(root: root), project = projectFixture()
                try await store.save(project)
                try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
                let files = ProjectFaultFiles(phase: phase, target: target)
                let failing = ProjectStore(root: root, fileSystem: files)
                await expectInterruption { try await failing.addAsset(Data([4, 5, 6]), reference: "images/a.png", to: project.id) }
                XCTAssertEqual(files.hits.count, 1)
                let oldBytes = try await store.assetData(reference: "images/a.png", in: project.id)
                let oldProject = try await store.load(id: project.id)
                XCTAssertEqual(oldBytes, Data([1, 2, 3]))
                XCTAssertEqual(oldProject, project)
                try await store.addAsset(Data([4, 5, 6]), reference: "images/a.png", to: project.id)
                let previous = try await store.previousProject(id: project.id)
                XCTAssertEqual(previous, project)
            }
        }
    }

    func testActivationInterruptionRetainsTheAuthoritativeRuntimeAndVerifiedCandidate() async throws {
        for phase in ProjectFaultFiles.Phase.allCases {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProjectStore(root: root), original = projectFixture(), candidate = projectFixture()
            try await store.save(original); try await store.activate(id: original.id)
            let files = ProjectFaultFiles(phase: phase, target: "active-project.json")
            let defaults = isolatedDefaults()
            let session = ProjectSession(store: ProjectStore(root: root, fileSystem: files), defaults: defaults)
            try await session.bootstrap()
            let identity = session.runtimeIdentity
            await expectInterruption { try await session.saveAndActivate(candidate) }
            XCTAssertEqual(files.hits.count, 1)
            XCTAssertEqual(session.activeProject, original)
            XCTAssertEqual(session.runtimeIdentity, identity)
            let persisted = try await store.activeProject(), savedCandidate = try await store.load(id: candidate.id)
            XCTAssertEqual(persisted, original)
            XCTAssertEqual(savedCandidate, candidate)
            let restarted = ProjectSession(store: store, defaults: defaults)
            try await restarted.bootstrap()
            XCTAssertEqual(restarted.activeProject, original)
        }
    }

    func testCorruptManifestManuscriptUserDataAndAssetsNeverActivate() async throws {
        for damage in ["manifest", "manuscript", "decision", "asset"] {
            let root = try temporaryProjectRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ProjectStore(root: root), original = projectFixture()
            var candidate = projectFixture()
            candidate.userData["decision"] = Data("Durable decision".utf8)
            try await store.save(original); try await store.activate(id: original.id)
            try await store.save(candidate)
            try await store.addAsset(Data([1, 2]), reference: "images/a.png", to: candidate.id)
            let folder = root.appendingPathComponent(candidate.id.rawValue.uuidString)
            let manifestURL = folder.appendingPathComponent("project.json")
            let manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
            let path: String
            switch damage {
            case "manifest": path = "project.json"
            case "manuscript": path = try XCTUnwrap(manifest.documents.first).relativePath
            case "decision": path = try XCTUnwrap(manifest.userData["decision"]).relativePath
            default: path = try XCTUnwrap(manifest.assets.first).file.relativePath
            }
            let damaged = folder.appendingPathComponent(path), corrupt = Data("Corrupt fixture bytes".utf8)
            try corrupt.write(to: damaged)
            let session = ProjectSession(store: store, defaults: isolatedDefaults())
            try await session.bootstrap()
            let identity = session.runtimeIdentity
            do { try await session.activateProject(id: candidate.id); XCTFail("Unverified \(damage) activated") } catch {}
            XCTAssertEqual(session.activeProject, original)
            XCTAssertEqual(session.runtimeIdentity, identity)
            XCTAssertEqual(try Data(contentsOf: damaged), corrupt, "Preserve diagnostic source")
            if damage == "manifest" {
                let previous = try await store.previousProject(id: candidate.id)
                XCTAssertEqual(previous, candidate, "Verified backup retains explicit decisions")
            }
            let persisted = try await store.activeProject()
            XCTAssertEqual(persisted, original)
        }
    }

    func testMigrationInterruptionPreservesLegacyAndPreviousOwnerThenRetryVerifies() async throws {
        for phase in ProjectFaultFiles.Phase.allCases {
            for target in ["Documents/", "UserData/legacy-", "Assets/", "project.json", "Migrations/", "active-project.json"] {
                let root = try temporaryProjectRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let source = root.appendingPathComponent("entries.json")
                let archive = Data(#"{"entries":[{"id":"00000000-0000-0000-0000-000000000101","title":"초안","createdAt":"2026-09-01T00:00:00Z","body":"합성 원고\n![그림](images/a.png)","kind":"novel"}]}"#.utf8)
                try archive.write(to: source)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
                let asset = root.appendingPathComponent("images/a.png")
                try Data([7, 8]).write(to: asset)
                let projects = root.appendingPathComponent("Projects")
                let store = ProjectStore(root: projects), original = projectFixture()
                try await store.save(original); try await store.activate(id: original.id)
                let files = ProjectFaultFiles(phase: phase, target: target)
                let failing = ProjectStore(root: projects, fileSystem: files)
                await expectInterruption { _ = try await failing.migrateLegacy(from: source, mode: .general, title: "Synthetic import") }
                XCTAssertEqual(files.hits.count, 1)
                let active = try await store.activeProject()
                XCTAssertEqual(active, original)
                XCTAssertEqual(try Data(contentsOf: source), archive)
                XCTAssertEqual(try Data(contentsOf: asset), Data([7, 8]))
                let result = try await store.migrateLegacy(from: source, mode: .general, title: "Synthetic import")
                let recovered = try await store.activeProject(), retainedArchive = try await store.legacySource(id: result.projectID)
                XCTAssertEqual(recovered?.id, result.projectID)
                XCTAssertEqual(retainedArchive, archive)
            }
        }
    }

    func testCorruptDerivedCacheRebuildChangesNoManuscriptOrExplicitDecision() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture(); project.userData["decision"] = Data("Keep this decision".utf8)
        try await store.save(project); try await store.activate(id: project.id)
        let manifestURL = root.appendingPathComponent("\(project.id.rawValue.uuidString)/project.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        let documentID = project.documents[0].id
        try await store.writeIntelligence(Data("broken derived JSON".utf8), projectID: project.id, documentID: documentID)
        let repository = KnowledgeSidecarRepository(projectStore: store, legacyDirectory: root.appendingPathComponent("legacy"))
        let scope = StoryMemoryScope.project(projectID: project.id, documentID: documentID)
        let fresh = await repository.load(scope: scope)
        XCTAssertEqual(fresh.generation, 1)
        XCTAssertEqual(fresh.scope, scope)
        XCTAssertTrue(fresh.sceneSummaries.isEmpty)
        XCTAssertTrue(fresh.conversationMeta.isEmpty)
        XCTAssertNil(fresh.workSummary)
        _ = try await repository.replaceWithFresh(scope: scope, generation: 3)
        let rebuilt = await repository.load(scope: scope), durable = try await store.activeProject()
        XCTAssertEqual(rebuilt.generation, 3)
        XCTAssertEqual(durable, project)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
    }

    private func expectInterruption(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Interrupted operation reported success") }
        catch let error as ProjectFaultFiles.Failure { XCTAssertEqual(error, .interrupted) }
        catch { XCTFail("Unexpected failure: \(error)") }
    }
    private func isolatedDefaults() -> UserDefaults {
        // Each test session uses an empty domain; tests never persist arbitrary real settings.
        let suite = "ProjectFault-\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
}
