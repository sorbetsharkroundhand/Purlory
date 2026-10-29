@testable import PurloryStorage
import XCTest
@testable import PurloryCore

@MainActor
final class WritingStyleRepositoryTests: XCTestCase {
    func testExplicitReanchorStillRequiresByteExactOriginalEvidence() throws {
        let original = styleSnapshot(body: "한")
        let occurrence = try WritingStyleRepository.captureIntentional(ruleID: "repeat", range: .init(location: 0, length: 1), in: original)
        let decomposed = styleSnapshot(body: "한", identity: original.identity)
        XCTAssertNil(WritingStyleRepository.reanchor(occurrence, in: decomposed))
        XCTAssertThrowsError(try WritingStyleRepository.captureIntentional(ruleID: "repeat", range: .init(location: 0, length: 1), in: decomposed))
    }

    func testUnknownVersionOneFieldsAndNullChoicesRemainUnreadable() throws {
        let encoded = try JSONEncoder().encode(WritingStyleRecord())
        let known = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var future = known; future["newDecision"] = ["retain": true]
        var nested = known
        var profile = try XCTUnwrap(nested["profile"] as? [String: Any]); profile["futurePreference"] = true
        nested["profile"] = profile
        var corrupt = known
        profile = try XCTUnwrap(known["profile"] as? [String: Any]); profile["learnedWords"] = NSNull()
        corrupt["profile"] = profile
        for object in [future, nested, corrupt] {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            guard case let .unreadable(original, _) = WritingStyleRepository.read(styleSnapshot(bytes)) else {
                XCTFail("Unrecognized decisions became writable"); continue
            }
            XCTAssertEqual(original, bytes)
        }
    }

    func testNewLegacyUnknownAndCorruptProfiles() throws {
        let snapshot = styleSnapshot()
        let fresh = try ready(WritingStyleRepository.read(snapshot))
        XCTAssertEqual(fresh.profile.repetitionSensitivity, .standard)
        XCTAssertEqual(fresh.profile.dialogueSensitivity, .low)
        let legacy = WritingStyleProfile(ignoredRuleIDs: ["repeat"], learnedWords: ["민트"], dialogueSensitivity: .standard)
        let bytes = try JSONEncoder().encode(legacy)
        let old = try ready(WritingStyleRepository.read(styleSnapshot(bytes)))
        XCTAssertEqual(old.profile, legacy)
        XCTAssertEqual(old.profile.dialogueSensitivity, .standard)
        let sparse = try ready(WritingStyleRepository.read(styleSnapshot(Data(#"{"learnedWords":["민트"]}"#.utf8))))
        XCTAssertEqual(sparse.profile.learnedWords, ["민트"])
        XCTAssertEqual(sparse.profile.dialogueSensitivity, .standard)
        for original in [Data("broken".utf8), Data(#"{"version":99,"profile":{}}"#.utf8),
                         Data(#"{"profile":{}}"#.utf8), Data(#"{"futureChoice":true}"#.utf8)] {
            guard case let .unreadable(retained, reason) = WritingStyleRepository.read(styleSnapshot(original)) else {
                XCTFail("Unknown/corrupt data became writable defaults"); continue
            }
            XCTAssertEqual(retained, original)
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertTrue(snapshot.userData.isEmpty, "Reading missing choices must never write defaults")
    }

    func testChoicesSurviveFlushReopenReindexAndRestore() async throws {
        let fixture = try await StyleFixture(body: "같은 말 같은 말")
        defer { fixture.close() }
        let snapshot = try XCTUnwrap(fixture.session.selectedDocumentSnapshot)
        var record = try ready(WritingStyleRepository.read(snapshot))
        record.profile.ignoredRuleIDs.insert("ko.repeated-ending")
        record.profile.learnedWords.insert("민트")
        record.languageTag = "ko"
        record.intentionalOccurrences = [try WritingStyleRepository.captureIntentional(
            ruleID: "ko.repeated-word", range: .init(location: 5, length: 4), in: snapshot)]
        try WritingStyleRepository.update(record, in: fixture.session, identity: snapshot.identity)
        XCTAssertEqual(fixture.session.selectedDocument?.body, snapshot.body)
        try await fixture.session.flush()
        let bytes = try XCTUnwrap(fixture.session.activeProject?.userData[WritingStyleRepository.key])
        try await fixture.store.writeIntelligence(Data("derived".utf8), projectID: fixture.project.id,
                                                 documentID: snapshot.identity.key.documentID)
        try await fixture.store.removeIntelligence(projectID: fixture.project.id, documentID: snapshot.identity.key.documentID)
        let reopened = ProjectSession(store: fixture.store, defaults: fixture.defaults, autosaveDelay: .seconds(3600))
        try await reopened.bootstrap()
        XCTAssertEqual(try ready(WritingStyleRepository.read(XCTUnwrap(reopened.selectedDocumentSnapshot))), record)
        var changed = record; changed.profile.repetitionSensitivity = .high
        try WritingStyleRepository.update(changed, in: reopened, identity: XCTUnwrap(reopened.runtimeIdentity))
        try await reopened.flush()
        let backup = try await fixture.store.previousBackup(id: fixture.project.id)
        let recovered = try await fixture.store.prepareBackupRestore(backup)
        XCTAssertNotEqual(recovered.id, fixture.project.id)
        XCTAssertEqual(recovered.userData[WritingStyleRepository.key], bytes)
        let recoveredSnapshot = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: recovered.id,
            documentID: snapshot.identity.key.documentID), generation: 1), title: "Recovered",
            body: snapshot.body, kind: .manuscript, mode: .general, userData: recovered.userData)
        XCTAssertEqual(try ready(WritingStyleRepository.read(recoveredSnapshot)), record)
    }

    func testStaleAtoBtoAActionCannotWrite() async throws {
        let fixture = try await StyleFixture()
        defer { fixture.close() }
        let oldA = try XCTUnwrap(fixture.session.runtimeIdentity)
        var record = WritingStyleRecord(); record.profile.ignoredRuleIDs.insert("ko.repeated-ending")
        var b = projectFixture(); b.title = "Synthetic B"
        try await fixture.session.saveAndActivate(b)
        let before = fixture.session.activeProject?.userData
        XCTAssertThrowsError(try WritingStyleRepository.update(record, in: fixture.session, identity: oldA))
        XCTAssertEqual(fixture.session.activeProject?.userData, before)
        try await fixture.session.activateProject(id: fixture.project.id)
        XCTAssertThrowsError(try WritingStyleRepository.update(record, in: fixture.session, identity: oldA))
        XCTAssertNil(fixture.session.activeProject?.userData[WritingStyleRepository.key])
        XCTAssertEqual(fixture.session.savePhase, .saved)
    }

    func testUnreadableBytesCannotBeOverwrittenAndSemanticNoOpDoesNotWrite() async throws {
        for bytes in [Data("not JSON".utf8), Data(#"{"version":42,"profile":{}}"#.utf8)] {
            let fixture = try await StyleFixture(bytes: bytes)
            defer { fixture.close() }
            let snapshot = try XCTUnwrap(fixture.session.selectedDocumentSnapshot)
            XCTAssertThrowsError(try WritingStyleRepository.update(WritingStyleRecord(), in: fixture.session, identity: snapshot.identity))
            XCTAssertEqual(fixture.session.activeProject?.userData[WritingStyleRepository.key], bytes)
            XCTAssertEqual(fixture.session.runtimeIdentity, snapshot.identity)
            XCTAssertEqual(fixture.session.savePhase, .saved)
        }
        let legacy = try JSONEncoder().encode(WritingStyleProfile())
        let fixture = try await StyleFixture(bytes: legacy)
        defer { fixture.close() }
        let snapshot = try XCTUnwrap(fixture.session.selectedDocumentSnapshot)
        let record = try ready(WritingStyleRepository.read(snapshot))
        try WritingStyleRepository.update(record, in: fixture.session, identity: snapshot.identity)
        XCTAssertEqual(fixture.session.activeProject?.userData[WritingStyleRepository.key], legacy)
        XCTAssertEqual(fixture.session.runtimeIdentity, snapshot.identity)
        XCTAssertEqual(fixture.session.savePhase, .saved)
    }

    func testFailedSaveKeepsPendingAuthorChoicesAndPreviousValidData() async throws {
        let fixture = try await StyleFixture()
        defer { fixture.close() }
        let failing = ProjectStore(root: fixture.root, fileSystem: FailingProjectFiles(fragment: "UserData/records/"))
        let session = ProjectSession(store: failing, defaults: fixture.defaults, autosaveDelay: .seconds(3600))
        try await session.bootstrap()
        var record = WritingStyleRecord(); record.profile.learnedWords = ["민트"]
        try WritingStyleRepository.update(record, in: session, identity: XCTUnwrap(session.runtimeIdentity))
        do { try await session.flush(); XCTFail("Injected save succeeded") } catch {}
        XCTAssertEqual(session.savePhase, .failed)
        XCTAssertEqual(try ready(WritingStyleRepository.read(XCTUnwrap(session.selectedDocumentSnapshot))), record)
        let durable = try await fixture.store.load(id: fixture.project.id)
        XCTAssertNil(durable.userData[WritingStyleRepository.key])
        XCTAssertEqual(durable.documents, fixture.project.documents)
    }

    func testIntentionalChoicesRequireSameRevisionAndExactOccurrence() throws {
        let original = styleSnapshot(body: "같은 말 같은 말")
        let occurrence = try WritingStyleRepository.captureIntentional(ruleID: "repeat", range: .init(location: 5, length: 4), in: original)
        let first = EvidenceAnchor(documentID: original.identity.key.documentID, quote: "같은 말", utf16Hint: 0)
        let second = EvidenceAnchor(documentID: first.documentID, quote: "같은 말", utf16Hint: 5)
        XCTAssertFalse(occurrence.suppresses(ruleID: "repeat", evidence: first, sourceRevision: occurrence.sourceRevision))
        XCTAssertTrue(occurrence.suppresses(ruleID: "repeat", evidence: second, sourceRevision: occurrence.sourceRevision))
        XCTAssertFalse(occurrence.suppresses(ruleID: "other", evidence: second, sourceRevision: occurrence.sourceRevision))
        XCTAssertFalse(occurrence.suppresses(ruleID: "repeat", evidence: second, sourceRevision: nil))
        let changed = styleSnapshot(body: "앞 같은 말 같은 말", identity: original.identity)
        XCTAssertNil(WritingStyleRepository.reanchor(occurrence, in: changed), "Changed duplicates must remain ambiguous")
        let unique = styleSnapshot(body: "유일한 말", identity: original.identity)
        let anchored = try WritingStyleRepository.captureIntentional(ruleID: "repeat", range: .init(location: 0, length: 5), in: unique)
        let moved = styleSnapshot(body: "앞 유일한 말", identity: original.identity)
        let reanchored = try XCTUnwrap(WritingStyleRepository.reanchor(anchored, in: moved))
        XCTAssertEqual(reanchored.evidence.utf16Hint, 2)
        XCTAssertFalse(anchored.suppresses(ruleID: "repeat", evidence: reanchored.evidence, sourceRevision: reanchored.sourceRevision))
        XCTAssertNil(WritingStyleRepository.reanchor(anchored, in: styleSnapshot(body: "앞 유일한 말")))
    }

    func testLearnedWordsUseCanonicalCompositionAndExactCase() throws {
        var record = WritingStyleRecord()
        record.profile.learnedWords = ["민트", "Purlory", "Straße", "İ"]
        XCTAssertTrue(record.isLearned("민트"))
        XCTAssertTrue(record.isLearned("Purlory"))
        XCTAssertFalse(record.isLearned("purlory"))
        XCTAssertFalse(record.isLearned("Strasse"))
        XCTAssertFalse(record.isLearned("i"))
        XCTAssertFalse(record.isLearned(" 민트"))
    }

    private func ready(_ load: WritingStyleLoad, file: StaticString = #filePath, line: UInt = #line) throws -> WritingStyleRecord {
        guard case let .ready(record) = load else { XCTFail("Expected readable style record", file: file, line: line); throw CocoaError(.fileReadCorruptFile) }
        return record
    }
    private func styleSnapshot(_ bytes: Data? = nil, body: String = "Synthetic", identity: ProjectRuntimeIdentity? = nil) -> ProjectDocumentSnapshot {
        .init(identity: identity ?? .init(key: .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: 1),
              title: "Synthetic", body: body, kind: .manuscript, mode: .general,
              userData: bytes.map { [WritingStyleRepository.key: $0] } ?? [:])
    }
}

@MainActor
private final class StyleFixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "purlory.writing-style.\(UUID())"
    let project: WritingProject
    let store: ProjectStore
    let session: ProjectSession
    init(body: String = "Synthetic", bytes: Data? = nil) async throws {
        root = try temporaryProjectRoot(); defaults = UserDefaults(suiteName: suite)!
        var project = projectFixture(); project.documents[0].body = body
        if let bytes { project.userData["writing-style-profile"] = bytes }
        self.project = project; store = ProjectStore(root: root)
        session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        try await session.saveAndActivate(project)
    }
    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
