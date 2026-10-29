@testable import PurloryStorage
import XCTest
@testable import PurloryCore

final class WriterDataMigrationTests: XCTestCase {
    // Catches a newer valid manifest arriving after migration's initial verification.
    func testMigrationCommitRechecksOwnerSnapshotUnderStoreLock() async throws {
        let f = try await writerMigrationFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let manifest = f.projectsRoot.appendingPathComponent("\(f.project.id.rawValue.uuidString)/project.json")
        let original = try Data(contentsOf: manifest)
        var newest = f.project
        newest.userData["newer-decision"] = Data("commit during preparation".utf8)
        try await f.store.save(newest)
        let newerManifest = try Data(contentsOf: manifest)
        try original.write(to: manifest, options: .atomic)
        let files = WriterManifestArrivalFiles(manifest: manifest, incoming: newerManifest)
        let racing = ProjectStore(root: f.projectsRoot, fileSystem: files)
        do { _ = try await ProjectWriterDataMigration.prepare(f.project, store: racing); XCTFail("Newer commit was overwritten") } catch {}
        let preserved = try await f.store.load(id: newest.id)
        XCTAssertEqual(preserved.userData["newer-decision"], Data("commit during preparation".utf8))
    }

    // Catches migration clobbering decisions committed after its captured project snapshot.
    func testStaleMigrationSnapshotCannotDiscardNewerOpaqueDecision() async throws {
        let f = try await writerMigrationFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var latest = f.project
        latest.userData["future-decision"] = Data("newer author choice".utf8)
        try await f.store.save(latest)
        do { _ = try await ProjectWriterDataMigration.prepare(f.project, store: f.store); XCTFail("Stale migration overwrote newer state") } catch {}
        let preserved = try await f.store.load(id: latest.id)
        XCTAssertEqual(preserved.userData["future-decision"], Data("newer author choice".utf8))
    }

    // Catches duplicate IDs reaching consumers that require unique author record identities.
    func testDuplicateCardsConversationsAndDecisionsAreRefusedWithoutNormalization() throws {
        let documentID = WritingDocumentID()
        let card = CharacterCard(name: "동일 카드")
        let conversation = RecordedConversation(utf16Start: 0, utf16End: 1, firstLine: "첫말", lastLine: "끝말", contentHash: "same")
        let decision = WriterDecision(kind: .confirmed, targetID: "same", statement: "명시한 사실")
        for kind in ["card", "conversation", "decision"] {
            var writer = WriterDocumentData(documentID: documentID)
            if kind == "card" { writer.characters = [card, card] }
            if kind == "conversation" { writer.recordedConversations = [conversation, conversation] }
            if kind == "decision" { writer.decisions = [decision, decision] }
            XCTAssertThrowsError(try writer.encoded())
            let raw = try JSONEncoder().encode(writer)
            XCTAssertThrowsError(try WriterDocumentData.decode(raw, documentID: documentID))
        }
    }

    // Catches a damaged completion marker suppressing migration as though it were verified.
    func testInvalidMigrationMarkerIsAnErrorRatherThanEmptySuccess() async throws {
        let f = try await writerMigrationFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var project = f.project
        project.userData["writer-migration-v1"] = Data([0])
        try await f.store.save(project)
        do { _ = try await ProjectWriterDataMigration.prepare(project, store: f.store); XCTFail("Invalid migration marker accepted") } catch {}
        let preserved = try await f.store.load(id: project.id)
        XCTAssertEqual(preserved.userData["writer-migration-v1"], Data([0]))
    }

    // Catches body-only legacy migration dropping author fields or changing original bytes.
    func testArchivedWriterFieldsMigrateWithoutChangingSourceOrUnknownMetadata() async throws {
        let f = try await writerMigrationFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let migrated = try await ProjectWriterDataMigration.prepare(f.project, store: f.store)
        let state = try WriterDocumentData.decode(migrated.userData[WriterDocumentData.key(for: f.documentID)], documentID: f.documentID)
        XCTAssertEqual(state.genre, "판타지")
        XCTAssertEqual(state.characters, f.entry.characters)
        XCTAssertEqual(state.rejectedCharacterNames, ["제외한 이름"])
        XCTAssertEqual(state.narrativeOverrides, f.entry.narrativeOverrides)
        XCTAssertEqual(state.recordedConversations, f.entry.recordedConversations)
        XCTAssertEqual(migrated.documents[0].body, "옛 근거 문장\n")
        let archive = try await f.store.legacySource(id: migrated.id)
        XCTAssertEqual(archive, f.sourceData)
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
        let reopened = try await ProjectStore(root: f.projectsRoot).load(id: migrated.id)
        XCTAssertEqual(try WriterDocumentData.decode(reopened.userData[WriterDocumentData.key(for: f.documentID)], documentID: f.documentID), state)
    }

    // Catches reseeding edits/deletions from a legacy archive on migration retry/relaunch.
    func testExistingWriterRecordsWinAndDeletedRecordNeverReseeds() async throws {
        let f = try await writerMigrationFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var project = f.project
        var edited = WriterDocumentData(documentID: f.documentID)
        edited.genre = "사용자 수정"
        project.userData[WriterDocumentData.key(for: f.documentID)] = try edited.encoded()
        project.userData["future-record"] = Data([0, 255])
        try await f.store.save(project)
        var migrated = try await ProjectWriterDataMigration.prepare(project, store: f.store)
        let key = WriterDocumentData.key(for: f.documentID)
        XCTAssertEqual(try WriterDocumentData.decode(migrated.userData[key], documentID: f.documentID).genre, "사용자 수정")
        migrated.userData.removeValue(forKey: key)
        try await f.store.save(migrated)
        let retry = try await ProjectWriterDataMigration.prepare(migrated, store: f.store)
        XCTAssertNil(retry.userData[key])
        XCTAssertEqual(retry.userData["future-record"], Data([0, 255]))
        let reloaded = try await f.store.load(id: migrated.id)
        let afterRelaunch = try await ProjectWriterDataMigration.prepare(reloaded, store: f.store)
        XCTAssertNil(afterRelaunch.userData[key])
        XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
    }

    // Catches intentional being flattened into dismiss, or stale evidence deleting a decision.
    func testDistinctDecisionsAndStaleEvidenceSurviveIntelligenceReplacement() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        let documentID = project.documents[0].id
        var writer = WriterDocumentData(documentID: documentID)
        let stale = EvidenceAnchor(documentID: documentID, sceneHash: "old-hash", quote: "사라진 원문", utf16Hint: 0)
        writer.decisions = [
            WriterDecision(kind: .intentional, targetID: "same-item", statement: "의도한 설정", evidence: [stale]),
            WriterDecision(kind: .dismissed, targetID: "same-item", statement: "안내 숨김", evidence: [stale])
        ]
        project.userData[WriterDocumentData.key(for: documentID)] = try writer.encoded()
        try await store.save(project)
        let repository = KnowledgeSidecarRepository(projectStore: store)
        _ = try await repository.replaceWithFresh(scope: .project(projectID: project.id, documentID: documentID), generation: 9)
        let loaded = try await store.load(id: project.id)
        let restored = try WriterDocumentData.decode(loaded.userData[WriterDocumentData.key(for: documentID)], documentID: documentID)
        XCTAssertEqual(restored.decisions.map(\.kind), [.intentional, .dismissed])
        XCTAssertEqual(restored.decisions[0].statement, "의도한 설정")
        XCTAssertEqual(restored.decisions[0].evidence[0].quote, "사라진 원문")
        XCTAssertNil(restored.decisions[0].evidence[0].resolvedQuery(in: loaded.documents[0].body))
    }

    // Catches corrupt/future/foreign typed records being treated as empty or overwriting the owner.
    func testBadWriterRecordsAndFailedOrCancelledMigrationPreserveValidOwner() async throws {
        let f = try await writerMigrationFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = projectFixture()
        try await f.store.save(owner); try await f.store.activate(id: owner.id)
        let key = WriterDocumentData.key(for: f.documentID)
        for corruption in ["malformed", "future", "foreign"] {
            var candidate = f.project
            if corruption == "malformed" { candidate.userData[key] = Data("broken".utf8) }
            else if corruption == "foreign" {
                candidate.userData[key] = try WriterDocumentData(documentID: WritingDocumentID()).encoded()
            } else {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: WriterDocumentData(documentID: f.documentID).encoded()) as? [String: Any])
                json["schemaVersion"] = 99
                candidate.userData[key] = try JSONSerialization.data(withJSONObject: json)
            }
            try await f.store.save(candidate)
            do { _ = try await ProjectWriterDataMigration.prepare(candidate, store: f.store); XCTFail("Bad record accepted: \(corruption)") } catch {}
            let active = try await f.store.activeProject()
            XCTAssertEqual(active, owner)
        }
        try await f.store.save(f.project)
        let manifestURL = f.projectsRoot.appendingPathComponent("\(f.project.id.rawValue.uuidString)/project.json")
        let before = try Data(contentsOf: manifestURL)
        for cancel in [false, true] {
            let failing = ProjectStore(root: f.projectsRoot, fileSystem: WriterMigrationFaultFiles(cancel: cancel))
            let task = Task { try await ProjectWriterDataMigration.prepare(f.project, store: failing) }
            do { _ = try await task.value; XCTFail("Failed migration accepted") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } }
            XCTAssertEqual(try Data(contentsOf: manifestURL), before)
            XCTAssertEqual(try Data(contentsOf: f.source), f.sourceData)
            let active = try await f.store.activeProject()
            XCTAssertEqual(active, owner)
        }
    }
}

struct WriterMigrationFixture {
    let root: URL, projectsRoot: URL, source: URL
    let store: ProjectStore
    let project: WritingProject
    let entry: JournalEntry
    let sourceData: Data
    var documentID: WritingDocumentID { WritingDocumentID(rawValue: entry.id) }
}
func writerMigrationFixture() async throws -> WriterMigrationFixture {
    let root = try temporaryProjectRoot()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = JournalEntry(title: "이관", createdAt: date, body: "옛 근거 문장\n", kind: .novel,
        genre: "판타지", characters: [CharacterCard(name: "유정", aliases: "정", note: "작가 설정", locked: true)],
        rejectedCharacterNames: ["제외한 이름"], narrativeOverrides: [
            NarrativeOverride(kind: .contextPin, key: "card|known", value: "고정", updatedAt: date),
            NarrativeOverride(kind: .contextExclude, key: "scene|old", value: "제외", updatedAt: date),
            NarrativeOverride(kind: .sceneTitle, key: "old-hash", value: "의도한 제목", anchor: "옛 근거 문장", updatedAt: date)
        ], recordedConversations: [RecordedConversation(utf16Start: 0, utf16End: 5, firstLine: "첫말", lastLine: "끝말", contentHash: "old-conversation", recordedAt: date)])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(entry)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json["futureWriterField"] = ["keep": true]
    let sourceData = try JSONSerialization.data(withJSONObject: ["entries": [json]])
    let source = root.appendingPathComponent("entries.json")
    try sourceData.write(to: source)
    let projectsRoot = root.appendingPathComponent("Projects"), store = ProjectStore(root: root.appendingPathComponent("Projects"))
    let result = try await store.prepareLegacyMigration(from: source, mode: .fiction, title: "Imported")
    let project = try await store.load(id: result.projectID)
    return WriterMigrationFixture(root: root, projectsRoot: projectsRoot, source: source, store: store, project: project, entry: entry, sourceData: sourceData)
}
private struct WriterMigrationFaultFiles: ProjectFileSystem {
    let cancel: Bool
    private let real = LocalProjectFileSystem()
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        if url.path.contains("UserData/records/") {
            if cancel { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try real.writeAtomically(data, to: url)
    }
}

/// Controlled arrival of a complete valid manifest at the real archive-read boundary.
private final class WriterManifestArrivalFiles: ProjectFileSystem, @unchecked Sendable {
    let manifest: URL, incoming: Data
    private let real = LocalProjectFileSystem(), lock = NSLock()
    private var delivered = false
    init(manifest: URL, incoming: Data) { self.manifest = manifest; self.incoming = incoming }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws { try real.writeAtomically(data, to: url) }
    func read(_ url: URL) throws -> Data {
        let value = try real.read(url)
        if url.lastPathComponent.hasPrefix("legacy-") {
            let deliver = lock.withLock { let next = !delivered; delivered = true; return next }
            if deliver { try real.writeAtomically(incoming, to: manifest) }
        }
        return value
    }
}
