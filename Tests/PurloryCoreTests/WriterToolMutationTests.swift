@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WriterToolMutationTests: XCTestCase {
    // Catches successive field callbacks losing characters before SwiftUI refreshes.
    func testSuccessiveFieldCallbacksAdvanceOnlyTheirOwnAcceptedIdentity() async throws {
        let root = try temporaryProjectRoot(), suite = "purlory.writer-bindings.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root), session = ProjectSession(store: store, defaults: defaults)
        let a = projectFixture(); var b = a; b.id = WritingProjectID()
        try await session.saveAndActivate(a)
        let field = WriterToolMutation(identity: try XCTUnwrap(session.runtimeIdentity))
        for value in ["F", "Fi", "Fixture"] { try field.perform(.genre(value), in: session) }
        let id = a.documents[0].id
        var writer = try WriterDocumentData.decode(session.selectedDocumentSnapshot?.userData[WriterDocumentData.key(for: id)], documentID: id)
        XCTAssertEqual(writer.genre, "Fixture")
        let external = WriterToolMutation(identity: try XCTUnwrap(session.runtimeIdentity))
        session.updateSelectedDocumentBody("External body edit")
        XCTAssertThrowsError(try external.perform(.genre("stale body"), in: session))
        XCTAssertThrowsError(try field.perform(.genre("stale field"), in: session))
        let oldA = WriterToolMutation(identity: try XCTUnwrap(session.runtimeIdentity))
        try await session.saveAndActivate(b)
        XCTAssertThrowsError(try oldA.perform(.genre("wrong B"), in: session))
        try await session.activateProject(id: a.id)
        XCTAssertThrowsError(try oldA.perform(.genre("old A"), in: session))
        writer = try WriterDocumentData.decode(session.selectedDocumentSnapshot?.userData[WriterDocumentData.key(for: id)], documentID: id)
        XCTAssertEqual(writer.genre, "Fixture")
        XCTAssertEqual(session.selectedDocument?.body, "External body edit")
    }
}
