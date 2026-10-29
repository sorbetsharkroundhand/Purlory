@testable import PurloryStorage
import XCTest
@testable import PurloryCore

@MainActor
final class ProjectWriterEditingTests: XCTestCase {
    // Catches writer edits losing existing ownership rules or durable relaunch/delete state.
    func testWriterAddEditDeleteRelaunchKeepsBodyAndUnknownDataWithoutModel() async throws {
        try await withWriterSession { session, store, defaults in
            var project = projectFixture(); project.userData["future-choice"] = Data([7])
            try await session.saveAndActivate(project)
            @MainActor func edit(_ action: ProjectWriterEdit) throws {
                try ProjectWriterEditing.perform(action, in: session, identity: XCTUnwrap(session.runtimeIdentity))
            }
            try edit(.genre("  판타지  "))
            var card = CharacterCard(name: "유정", autoRegistered: true)
            try edit(.character(card)); card.note = "작가 설정"; try edit(.character(card))
            let pin = NarrativeOverride(kind: .contextPin, key: "card|known", value: "고정")
            try edit(.override(pin)); try edit(.override(pin))
            try edit(.rejectName("제외할 이름")); try edit(.rejectName("제외할 이름"))
            let record = RecordedConversation(utf16Start: 0, utf16End: 2, firstLine: "첫말", lastLine: "끝말", contentHash: "conversation")
            try edit(.record(record))
            let beforeNoOp = session.runtimeIdentity
            try edit(.record(record))
            XCTAssertEqual(session.runtimeIdentity, beforeNoOp)
            let decisions = [WriterDecision(kind: .intentional, targetID: "x", statement: "의도한 설정"),
                             WriterDecision(kind: .dismissed, targetID: "x", statement: "제안 숨기기"),
                             WriterDecision(kind: .confirmed, targetID: "y", statement: "확인한 설정")]
            for decision in decisions { try edit(.decision(decision)) }
            let writer = try read(session)
            XCTAssertEqual(writer.genre, "판타지")
            XCTAssertEqual(writer.characters.first?.locked, true)
            XCTAssertNil(writer.characters.first?.autoRegistered)
            XCTAssertEqual(writer.narrativeOverrides, [pin])
            XCTAssertEqual(writer.rejectedCharacterNames, ["제외할 이름"])
            XCTAssertEqual(writer.decisions, decisions)
            try await session.flush()
            let reopened = ProjectSession(store: store, defaults: defaults)
            try await reopened.bootstrap()
            XCTAssertEqual(try read(reopened), writer)
            XCTAssertEqual(reopened.selectedDocument?.body, project.documents[0].body)
            XCTAssertEqual(reopened.activeProject?.userData["future-choice"], Data([7]))
            try edit(.removeCharacter(card.id)); try edit(.removeOverride(.contextPin, pin.key))
            try edit(.restoreName("제외할 이름")); try edit(.removeRecord(record.id))
            for decision in decisions { try edit(.removeDecision(decision.id)) }
            try edit(.genre("  "))
            try await session.flush()
            let durable = try await store.load(id: project.id)
            let empty = try WriterDocumentData.decode(durable.userData[WriterDocumentData.key(for: project.documents[0].id)], documentID: project.documents[0].id)
            XCTAssertEqual(empty, WriterDocumentData(documentID: project.documents[0].id))
            XCTAssertEqual(durable.userData["future-choice"], Data([7]))
        }
    }

    // Catches a stale tool/report callback mutating B or a later return to A.
    func testCapturedWriterActionsCannotCrossABARuntime() async throws {
        try await withWriterSession { session, _, _ in
            let a = projectFixture(); var b = a; b.id = WritingProjectID()
            try await session.saveAndActivate(a)
            let captured = try XCTUnwrap(session.runtimeIdentity)
            try await session.saveAndActivate(b)
            for returnToA in [false, true] {
                if returnToA { try await session.activateProject(id: a.id) }
                let actions: [ProjectWriterEdit] = [.genre("wrong"), .character(CharacterCard(name: "wrong")),
                    .override(NarrativeOverride(kind: .contextExclude, key: "wrong", value: "wrong")),
                    .decision(WriterDecision(kind: .intentional, targetID: "wrong", statement: "wrong"))]
                for action in actions {
                    XCTAssertThrowsError(try ProjectWriterEditing.perform(action, in: session, identity: captured))
                }
                XCTAssertTrue(session.activeProject?.userData.isEmpty == true)
                XCTAssertEqual(session.savePhase, .saved)
            }
        }
    }

    // Catches edit fallback replacing an unreadable writer record with an empty one.
    func testBadRecordIsPreservedOnEditFailure() async throws {
        try await withWriterSession { session, _, _ in
            var project = projectFixture()
            let key = WriterDocumentData.key(for: project.documents[0].id), bad = Data("broken".utf8)
            project.userData[key] = bad
            try await session.saveAndActivate(project)
            let identity = try XCTUnwrap(session.runtimeIdentity)
            XCTAssertThrowsError(try ProjectWriterEditing.perform(.genre("새 설정"), in: session, identity: identity))
            XCTAssertEqual(session.activeProject?.userData[key], bad)
            XCTAssertEqual(session.runtimeIdentity, identity)
            XCTAssertEqual(session.savePhase, .saved)
        }
    }

    private func read(_ session: ProjectSession) throws -> WriterDocumentData {
        let snapshot = try XCTUnwrap(session.selectedDocumentSnapshot), id = snapshot.identity.key.documentID
        return try WriterDocumentData.decode(snapshot.userData[WriterDocumentData.key(for: id)], documentID: id)
    }
}

@MainActor
private func withWriterSession(_ body: @MainActor (ProjectSession, ProjectStore, UserDefaults) async throws -> Void) async throws {
    let root = try temporaryProjectRoot(), suite = "purlory.writer-editing.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let store = ProjectStore(root: root), session = ProjectSession(store: ProjectStore(root: root), defaults: defaults, autosaveDelay: .seconds(3600))
    try await body(session, store, defaults)
}
