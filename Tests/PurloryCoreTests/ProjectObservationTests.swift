import Observation
import XCTest
@testable import PurloryFoundation
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

@MainActor
final class ProjectObservationTests: XCTestCase {
    func testBodyEditsDoNotInvalidateNavigationTitlesOrEditability() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let session = fixture.session
        let metadata = ObservationFlag(), editable = ObservationFlag()
        withObservationTracking {
            _ = session.projectPresentation?.title
            _ = session.projectPresentation?.documents.map(\.id)
            _ = session.selectedDocumentPresentation?.title
        } onChange: { metadata.mark() }
        withObservationTracking { _ = session.isEditorEditable } onChange: { editable.mark() }
        session.updateSelectedDocumentBody("Changed manuscript")
        XCTAssertFalse(metadata.changed)
        XCTAssertFalse(editable.changed)
        XCTAssertEqual(session.selectedDocument?.body, "Changed manuscript")
        let key = try XCTUnwrap(session.runtimeIdentity?.key)
        session.renameDocument(key, to: "Renamed")
        XCTAssertTrue(metadata.changed)
        XCTAssertEqual(session.selectedDocumentPresentation?.title, "Renamed")
    }

    func testSourceAndRuntimeReadersObserveAcceptedEditsWithoutMaterializing() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let session = fixture.session
        let sourceChanged = ObservationFlag(), identityChanged = ObservationFlag()
        withObservationTracking { _ = session.selectedDocument?.source } onChange: { sourceChanged.mark() }
        withObservationTracking { _ = session.runtimeIdentity } onChange: { identityChanged.mark() }
        let source = DocumentSource(chunks: ["Changed ", "원고"])
        session.updateDocumentSource(source, for: try XCTUnwrap(session.runtimeIdentity?.key), activationEpoch: session.activationEpoch)
        XCTAssertTrue(sourceChanged.changed)
        XCTAssertTrue(identityChanged.changed)
        XCTAssertEqual(source.materializationCount, 0)
    }

    func testSavePhaseOnlyInvalidatesWhenItsValueChanges() async throws {
        let fixture = try await fixture()
        defer { fixture.clean() }
        let session = fixture.session, first = ObservationFlag()
        withObservationTracking { _ = session.savePhase } onChange: { first.mark() }
        session.updateSelectedDocumentBody("First edit")
        XCTAssertTrue(first.changed)
        let repeated = ObservationFlag()
        withObservationTracking { _ = session.savePhase } onChange: { repeated.mark() }
        session.updateSelectedDocumentBody("Second edit")
        XCTAssertFalse(repeated.changed)
    }

    private struct Fixture {
        let session: ProjectSession
        let root: URL
        let defaults: UserDefaults
        let suite: String
        func clean() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Purlory-observation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults, autosaveDelay: .seconds(3600))
        let document = WritingDocument(id: WritingDocumentID(), title: "Draft", body: "Original", kind: .manuscript)
        try await session.saveAndActivate(WritingProject(id: WritingProjectID(), title: "Project", mode: .general, documents: [document]))
        return Fixture(session: session, root: root, defaults: defaults, suite: suite)
    }
}
