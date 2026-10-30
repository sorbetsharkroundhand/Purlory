@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ProjectConversationRecordingTests: XCTestCase {
    // Catches app composition leaving project recording disabled or ignoring persisted hashes.
    func testProjectCompositionRecordsAndRestoresHashesWithoutModel() async throws {
        let root = try temporaryProjectRoot(), suite = "purlory.project-recording.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root), session = ProjectSession(store: store, defaults: defaults)
        let project = projectFixture()
        try await session.saveAndActivate(project)
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let completion = CompletionController(settings: settings)
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings,
            sidecarPersistence: KnowledgeSidecarRepository(projectStore: store, legacyDirectory: root))
        defer { indexer.shutdown() }
        ContentView.connectProjectConsumers(session: session, completion: completion, indexer: indexer)
        XCTAssertNotNil(completion.onRecordConversation)
        guard let recordAction = completion.onRecordConversation else { return }
        let record = RecordedConversation(utf16Start: 0, utf16End: 2, firstLine: "첫말", lastLine: "끝말", contentHash: "recorded")
        recordAction(record)
        XCTAssertEqual(completion.recordedConversationHashesProvider?(), ["recorded"])
        try await session.flush()
        let durable = try await store.load(id: project.id), id = project.documents[0].id
        let writer = try WriterDocumentData.decode(durable.userData[WriterDocumentData.key(for: id)], documentID: id)
        XCTAssertEqual(writer.recordedConversations, [record])
        var other = project; other.id = WritingProjectID()
        try await session.saveAndActivate(other)
        XCTAssertEqual(completion.recordedConversationHashesProvider?(), [])
        try await session.activateProject(id: project.id)
        XCTAssertEqual(completion.recordedConversationHashesProvider?(), ["recorded"])
    }

    // Catches delayed detection publishing after the provider's project changes.
    func testDelayedDetectionCannotPublishIntoNewProject() async {
        let body = "\"안녕.\"\n\"그래.\"\n\"기다려.\""
        let id = WritingDocumentID()
        var document = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: WritingProjectID(), documentID: id), generation: 1),
            title: "A", body: body, kind: .manuscript, mode: .fiction)
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let completion = CompletionController(settings: settings)
        completion.projectDocumentProvider = { document }
        completion.onRecordConversation = { _ in XCTFail("No offer may be accepted") }
        let stale = expectation(description: "Old detection must stay quiet"); stale.isInverted = true
        completion.conversationSuggestionDidChange = { if $0 != nil { stale.fulfill() } }
        completion.noteEdit(prefix: body, caretLocation: (body as NSString).length, isComposing: false, caretAtParagraphEnd: true)
        document = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: WritingProjectID(), documentID: id), generation: 2),
            title: "B", body: body, kind: .manuscript, mode: .fiction)
        await fulfillment(of: [stale], timeout: 2.5)
        XCTAssertNil(completion.conversationSuggestion)
    }

    // Catches an old visible conversation approval being forwarded to a new project.
    func testStaleApprovalCannotRecordInNewProjectWithoutTransitionNotification() async {
        let body = "\"안녕.\"\n\"그래.\"\n\"기다려.\""
        let id = WritingDocumentID()
        var document = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: WritingProjectID(), documentID: id), generation: 1),
            title: "A", body: body, kind: .manuscript, mode: .fiction)
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let completion = CompletionController(settings: settings)
        completion.projectDocumentProvider = { document }
        var recorded = false
        completion.onRecordConversation = { _ in recorded = true }
        let published = expectation(description: "Conversation offered in A")
        completion.conversationSuggestionDidChange = { if $0 != nil { published.fulfill() } }
        completion.noteEdit(prefix: body, caretLocation: (body as NSString).length, isComposing: false, caretAtParagraphEnd: true)
        await fulfillment(of: [published], timeout: 5)
        document = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: WritingProjectID(), documentID: id), generation: 2),
            title: "B", body: body, kind: .manuscript, mode: .fiction)
        XCTAssertFalse(completion.acceptConversationSuggestion())
        XCTAssertFalse(recorded)
        XCTAssertNil(completion.conversationSuggestion)
    }
}
