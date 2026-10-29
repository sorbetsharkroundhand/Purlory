@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore

@MainActor
final class ProjectWriterReaderTests: XCTestCase {
    // Catches project completion dropping durable genre/cards or leaking A into B.
    func testCompletionUsesCurrentWriterValuesAcrossTypingAndABAReturn() throws {
        let id = WritingDocumentID(), a = WritingProjectID(), b = WritingProjectID()
        let completion = CompletionController()
        var writer = WriterDocumentData(documentID: id, genre: "판타지", characters: [CharacterCard(name: "유정")])
        var document = try snapshot(a, id, 1, writer)
        completion.projectDocumentProvider = { document }
        for generation in 1...4 {
            if generation == 2 { document = try snapshot(a, id, 2, writer, body: "본문 편집") }
            if generation == 3 {
                writer.genre = "추리"; writer.characters = [CharacterCard(name: "민준")]
                document = try snapshot(b, id, 3, writer)
            }
            if generation == 4 {
                writer.genre = "로맨스"; writer.characters = [CharacterCard(name: "서연")]
                document = try snapshot(a, id, 4, writer)
            }
            let context = try XCTUnwrap(completion.currentDocumentContext())
            XCTAssertEqual(context.genre, writer.genre)
            XCTAssertEqual(context.characters, writer.characters)
            XCTAssertEqual(context.entryID, id.rawValue)
        }
        document = ProjectDocumentSnapshot(identity: document.identity, title: "Draft", body: "", kind: .manuscript, mode: .fiction)
        XCTAssertEqual(completion.currentDocumentContext()?.characters, [])
        XCTAssertNil(completion.currentDocumentContext()?.genre)
    }

    // Catches metadata overlays/recorded decisions disappearing on prepared rehydration.
    func testIndexerUsesWriterOverlaysAndRecordsWithoutReloadingOnMetadataEdit() async throws {
        let id = WritingDocumentID(), projectID = WritingProjectID()
        let body = "# 장면\n\"안녕.\" 유정이 말했다.\n\"그래.\" 유정이 답했다.\n\"기다려.\"\n"
        let block = try XCTUnwrap(ConversationDetector.blockEnding(at: (body as NSString).length, in: body as NSString))
        let record = ConversationDetector.record(from: block, utterances: [])
        var writer = WriterDocumentData(documentID: id, characters: [CharacterCard(name: "유정")],
            narrativeOverrides: [NarrativeOverride(kind: .contextExclude, key: "card|choice", value: "제외")],
            recordedConversations: [record])
        var document = try snapshot(projectID, id, 1, writer, body: body)
        let persistence = WriterReaderPersistence()
        let settings = CompletionSettings(); settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings, sidecarPersistence: persistence)
        indexer.attach(documentProvider: { document })
        defer { indexer.shutdown() }
        for generation in 1...2 {
            if generation == 2 {
                writer.characters[0].note = "직접 수정"
                writer.narrativeOverrides.append(NarrativeOverride(kind: .contextPin, key: "card|other", value: "고정"))
                document = try snapshot(projectID, id, 2, writer, body: body)
            }
            let ready = expectation(description: "Prepared writer generation \(generation)")
            let subscription = indexer.$snapshotGeneration.dropFirst().prefix(1).sink { _ in ready.fulfill() }
            indexer.noteDocumentChange(document)
            await fulfillment(of: [ready], timeout: 2)
            subscription.cancel()
            let knowledge = try XCTUnwrap(indexer.snapshot)
            XCTAssertEqual(knowledge.characters, writer.characters)
            XCTAssertEqual(knowledge.overrides.all, writer.narrativeOverrides)
            XCTAssertTrue(knowledge.conversations.contains { $0.recordedID == record.id })
            XCTAssertEqual(indexer.snapshotRuntimeIdentity, document.identity)
        }
        let loads = await persistence.loads
        XCTAssertEqual(loads, 1, "Metadata edits reuse already-loaded derived values")
    }

    // Catches malformed typed metadata being silently replaced by empty writer state.
    func testCorruptWriterBytesDoNotProduceCompletionContext() {
        let id = WritingDocumentID(), completion = CompletionController()
        let document = ProjectDocumentSnapshot(
            identity: ProjectRuntimeIdentity(key: .init(projectID: WritingProjectID(), documentID: id), generation: 1),
            title: "Draft", body: "본문", kind: .manuscript, mode: .fiction,
            userData: [WriterDocumentData.key(for: id): Data("broken".utf8)])
        completion.projectDocumentProvider = { document }
        XCTAssertNil(completion.currentDocumentContext())
    }

    private func snapshot(_ project: WritingProjectID, _ id: WritingDocumentID, _ generation: UInt64,
                          _ writer: WriterDocumentData, body: String = "# 장면\n본문") throws -> ProjectDocumentSnapshot {
        ProjectDocumentSnapshot(identity: .init(key: .init(projectID: project, documentID: id), generation: generation),
            title: "Draft", body: body, kind: .manuscript, mode: .fiction,
            userData: [WriterDocumentData.key(for: id): try writer.encoded()])
    }
}

private actor WriterReaderPersistence: KnowledgeSidecarPersisting {
    private(set) var loads = 0
    func load(scope: StoryMemoryScope) async -> KnowledgeSidecar { loads += 1; return KnowledgeSidecar(scope: scope) }
    func save(_ sidecar: KnowledgeSidecar, pruningTo liveHashes: Set<String>?, scope: StoryMemoryScope) async throws {}
    func replaceWithFresh(scope: StoryMemoryScope, generation: Int) async throws -> KnowledgeSidecar { KnowledgeSidecar(scope: scope) }
    func pruneLegacyOrphans(keeping documentIDs: Set<WritingDocumentID>) async {}
}
