@_spi(Benchmark) @testable import PurloryInference
@testable import PurloryStorage
import Combine
import AppKit
import Foundation
import XCTest
@testable import PurloryCore

@MainActor
final class ProjectSessionTests: XCTestCase {
    // Exercises the synchronous production paste entry before its enqueued task gets a turn.
    func testQueuedImagePasteKeepsInitiatingRuntimeWhenViewIsReusedBeforeTaskStarts() async throws {
        for fileBatch in [false, true] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (defaults, suite) = defaultsSuite()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProjectStore(root: root)
            let session = ProjectSession(store: store, defaults: defaults)
            let project = fictionProject()
            try await session.saveAndActivate(project)
            let view = BlockTextView(frame: .zero)
            view.textStorage?.delegate = view
            view.projectAssetCatalog = session.assetCatalog
            view.load(markdown: "A")
            let started = expectation(description: "Enqueued import starts")
            let finished = expectation(description: "Real import completes")
            let release = AsyncStream<Void>.makeStream()
            var reference: String?
            var invokedIdentity: ProjectRuntimeIdentity?
            func importer(_ identity: ProjectRuntimeIdentity) -> @MainActor (Data, String) async throws -> ProjectAssetCatalog {
                { data, path in
                    reference = path
                    invokedIdentity = identity
                    started.fulfill()
                    for await _ in release.stream { break }
                    defer { finished.fulfill() }
                    _ = try await session.importAsset(data: data, reference: path, for: identity)
                    return try XCTUnwrap(session.assetCatalog)
                }
            }
            let original = try XCTUnwrap(session.runtimeIdentity)
            view.projectAssetImporter = importer(original)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            if fileBatch {
                let image = root.appendingPathComponent("input.png")
                try Data([1, 2, 3]).write(to: image)
                pasteboard.writeObjects([image as NSURL])
            } else { pasteboard.setData(Data([1, 2, 3]), forType: .png) }

            XCTAssertTrue(view.insertImages(from: pasteboard))
            // No await: reuse the same view before the queued operation begins.
            session.selectDocument(project.documents[1].id)
            view.load(markdown: "B")
            view.projectAssetImporter = importer(try XCTUnwrap(session.runtimeIdentity))

            await fulfillment(of: [started], timeout: 2)
            release.continuation.yield(())
            release.continuation.finish()
            await fulfillment(of: [finished], timeout: 2)
            let path = try XCTUnwrap(reference)
            let bytes = try await store.assetData(reference: path, in: project.id)
            XCTAssertEqual(invokedIdentity, original)
            XCTAssertNil(bytes, "The queued paste wrote bytes under the newer runtime")
            XCTAssertEqual(view.serialize(), "B")
            XCTAssertEqual(session.selectedDocument?.body, "B")
        }
    }
    func testMultiImageImportPersistsEntireBatchBeforeInsertingMarkers() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults)
        let project = fictionProject()
        try await session.saveAndActivate(project)
        let identity = try XCTUnwrap(session.runtimeIdentity)
        let view = BlockTextView(frame: .zero)
        view.textStorage?.delegate = view
        view.projectAssetCatalog = session.assetCatalog
        view.projectAssetImporter = { data, reference in
            XCTAssertFalse(view.serialize().contains("images/"), "A partial batch inserted before all bytes were committed")
            _ = try await session.importAsset(data: data, reference: reference, for: identity)
            return try XCTUnwrap(session.assetCatalog)
        }
        try await view.insertProjectImages([
            (Data([1]), "images/a.png"), (Data([2]), "images/b.png")])
        XCTAssertTrue(view.serialize().contains("![](images/a.png)"), view.serialize())
        XCTAssertTrue(view.serialize().contains("![](images/b.png)"), view.serialize())
        let a = try await store.assetData(reference: "images/a.png", in: project.id)
        let b = try await store.assetData(reference: "images/b.png", in: project.id)
        XCTAssertEqual(a, Data([1]))
        XCTAssertEqual(b, Data([2]))
    }
    // Catches a switch while the actual asset manifest commit is suspended.
    func testInFlightAssetCommitCannotInsertIntoNewEditorDocument() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reliable = ProjectStore(root: root)
        let project = fictionProject()
        try await reliable.save(project)
        try await reliable.activate(id: project.id)
        let files = BlockingManifestProjectFiles()
        defer { files.releaseWrite() }
        let session = ProjectSession(store: ProjectStore(root: root, fileSystem: files), defaults: defaults)
        try await session.bootstrap()
        let view = BlockTextView(frame: .zero)
        view.projectAssetCatalog = session.assetCatalog
        let identity = try XCTUnwrap(session.runtimeIdentity)
        view.projectAssetImporter = { data, reference in
            _ = try await session.importAsset(data: data, reference: reference, for: identity)
            return try XCTUnwrap(session.assetCatalog)
        }
        view.load(markdown: "A")
        let insertion = Task { try await view.insertProjectImage(data: Data([1, 2, 3]), reference: "images/a.png") }
        let blocked = await Task.detached { files.waitUntilBlocked(timeout: 2) }.value
        guard blocked else { files.releaseWrite(); _ = try? await insertion.value; return XCTFail("No asset commit reached gate") }
        session.selectDocument(project.documents[1].id)
        view.load(markdown: "B")
        files.releaseWrite()
        do { try await insertion.value; XCTFail("Stale insertion accepted") }
        catch ProjectSessionError.staleRuntime {}
        XCTAssertEqual(view.serialize(), "B")
        XCTAssertEqual(session.selectedDocument?.body, "B")
        let committed = try await reliable.assetData(reference: "images/a.png", in: project.id)
        XCTAssertEqual(committed, Data([1, 2, 3]), "Committed bytes remain recoverable even after ownership is lost")
    }
    // Catches stale async image results retargeting another document or body generation.
    func testAssetResultForOldRuntimeDoesNotInsertMarkerIntoNewDocument() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults)
        let project = fictionProject()
        try await session.saveAndActivate(project)
        let identity = try XCTUnwrap(session.runtimeIdentity)
        session.selectDocument(project.documents[1].id)
        do {
            _ = try await session.importAsset(data: Data([1, 2, 3]), reference: "images/a.png", for: identity)
            XCTFail("Old runtime returned an insertable marker")
        } catch ProjectSessionError.staleRuntime {}
        XCTAssertEqual(session.selectedDocument?.body, "B")
        let current = try XCTUnwrap(session.runtimeIdentity)
        let marker = try await session.importAsset(data: Data([4]), reference: "images/b.png", for: current)
        XCTAssertEqual(marker, "images/b.png")
        let bytes = try await store.assetData(reference: marker, in: project.id)
        XCTAssertEqual(bytes, Data([4]))
        XCTAssertEqual(session.assetCatalog?.data(for: marker), Data([4]))
        session.updateSelectedDocumentBody("New revision")
        do {
            _ = try await session.importAsset(data: Data([5]), reference: "images/c.png", for: current)
            XCTFail("Old body generation returned an insertable marker")
        } catch ProjectSessionError.staleRuntime {}
        XCTAssertEqual(session.selectedDocument?.body, "New revision")
    }

    func testFailedFlushReconnectsReadersForActivateProject() async throws {
        try await assertFailedTransitionReconnectsReaders(failingFlush: true, savingCandidate: false)
    }

    func testFailedActivationReconnectsReadersForActivateProject() async throws {
        try await assertFailedTransitionReconnectsReaders(failingFlush: false, savingCandidate: false)
    }

    func testFailedFlushReconnectsReadersForSaveAndActivate() async throws {
        try await assertFailedTransitionReconnectsReaders(failingFlush: true, savingCandidate: true)
    }

    func testFailedActivationReconnectsReadersForSaveAndActivate() async throws {
        try await assertFailedTransitionReconnectsReaders(failingFlush: false, savingCandidate: true)
    }

    private func assertFailedTransitionReconnectsReaders(
        failingFlush: Bool, savingCandidate: Bool
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reliableStore = ProjectStore(root: root)
        let original = fictionProject()
        let other = generalProject()
        try await reliableStore.save(original)
        try await reliableStore.save(other)
        try await reliableStore.activate(id: original.id)
        let failurePath = failingFlush
            ? "/Documents/\(original.documents[0].id.rawValue.uuidString)/" : "active-project.json"
        let failingStore = ProjectStore(root: root, fileSystem: FailingProjectFiles(fragment: failurePath))
        let session = ProjectSession(store: failingStore, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        if failingFlush { session.updateSelectedDocumentBody("Surviving unsaved manuscript") }
        let surviving = try XCTUnwrap(session.selectedDocumentSnapshot)
        let settings = CompletionSettings(defaults: defaults)
        let completion = CompletionController(settings: settings)
        let reader = BackgroundIndexer(
            engine: CompletionEngine(), settings: settings,
            sidecarPersistence: KnowledgeSidecarRepository(projectStore: reliableStore))
        defer { reader.shutdown(); completion.shutdown() }
        reader.attach(documentProvider: { session.selectedDocumentSnapshot })
        completion.projectDocumentProvider = { session.selectedDocumentSnapshot }
        var attachedIdentity: ProjectRuntimeIdentity? = surviving.identity
        var publications: [ProjectDocumentSnapshot] = []
        session.willTransition = {
            attachedIdentity = nil
            reader.prepareForProjectTransition()
            completion.prepareForProjectTransition()
        }
        session.documentDidChange = { snapshot in
            XCTAssertEqual(session.phase, .ready)
            attachedIdentity = snapshot.identity
            publications.append(snapshot)
            reader.noteDocumentChange(snapshot)
            completion.noteDocumentChange(snapshot)
        }
        let restored = expectation(description: "Surviving project reader restored")
        let subscription = reader.$snapshotGeneration.dropFirst().prefix(1).sink { _ in restored.fulfill() }

        do {
            if savingCandidate { try await session.saveAndActivate(other) }
            else { try await session.activateProject(id: other.id) }
            XCTFail("Injected persistence failure did not fail the transition")
        } catch {}

        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(attachedIdentity, surviving.identity)
        XCTAssertEqual(publications, [surviving], "Only the surviving snapshot may be republished")
        XCTAssertEqual(reader.snapshotRuntimeIdentity, surviving.identity)
        XCTAssertEqual(session.selectedDocumentSnapshot, surviving)
        XCTAssertEqual(session.phase, .ready)
        let active = try await reliableStore.activeProject()
        XCTAssertEqual(active?.id, original.id)
        withExtendedLifetime(subscription) {}
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-ProjectSession-\(UUID().uuidString)", isDirectory: true)
    }

    private func defaultsSuite() -> (UserDefaults, String) {
        let name = "Purlory.ProjectSessionTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func fictionProject() -> WritingProject {
        WritingProject(
            id: WritingProjectID(),
            title: "Novel",
            mode: .fiction,
            documents: [
                WritingDocument(
                    id: WritingDocumentID(), title: "Chapter 1", body: "A", kind: .manuscript),
                WritingDocument(
                    id: WritingDocumentID(), title: "Chapter 2", body: "B", kind: .manuscript),
            ])
    }

    private func generalProject() -> WritingProject {
        WritingProject(
            id: WritingProjectID(),
            title: "Essay",
            mode: .general,
            documents: [
                WritingDocument(
                    id: WritingDocumentID(), title: "Draft", body: "C", kind: .manuscript)
            ])
    }

    /// Protected break: editor text routed anywhere except the selected project document,
    /// or dirty state cleared before verified persistence.
    func testBodyMutationUpdatesSelectedProjectDocumentAndFlushesToStore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(
            store: store,
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let initialIdentity = try XCTUnwrap(session.runtimeIdentity)
        var changedIdentity: ProjectRuntimeIdentity?
        session.documentDidChange = { changedIdentity = $0.identity }

        session.updateSelectedDocumentBody("edited")
        XCTAssertEqual(session.selectedDocument?.body, "edited")
        XCTAssertEqual(session.runtimeIdentity?.key, initialIdentity.key)
        XCTAssertEqual(session.runtimeIdentity?.generation, initialIdentity.generation + 1)
        XCTAssertEqual(changedIdentity, session.runtimeIdentity)
        XCTAssertEqual(session.savePhase, .dirty)
        try await session.flush()

        let reopened = try await store.load(id: project.id)
        XCTAssertEqual(reopened.documents[0].body, "edited")
        XCTAssertEqual(session.savePhase, .saved)
    }

    func testDocumentSelectionRunsBarrierBeforePublishingImmutableSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let original = try XCTUnwrap(session.selectedDocumentSnapshot)
        var barrierIdentity: ProjectRuntimeIdentity?
        var published: [ProjectDocumentSnapshot] = []
        session.willTransition = {
            barrierIdentity = session.runtimeIdentity
            session.updateSelectedDocumentBody("committed composition")
        }
        session.documentDidChange = { published.append($0) }

        session.selectDocument(project.documents[1].id)

        XCTAssertEqual(barrierIdentity, original.identity)
        XCTAssertEqual(original.body, "A", "Previously captured input must remain immutable")
        XCTAssertEqual(session.activeProject?.documents[0].body, "committed composition")
        XCTAssertEqual(published.last?.identity, session.runtimeIdentity)
        XCTAssertEqual(published.last?.title, "Chapter 2")
        XCTAssertEqual(published.last?.body, "B")
        XCTAssertEqual(published.last?.mode, .fiction)
        try await session.flush()
    }

    /// Protected break: a dirty project that receives no further edits must still reach
    /// durable storage after the configured debounce delay.
    func testBodyMutationAutosavesAfterDebounce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(
            store: store,
            defaults: defaults,
            autosaveDelay: .milliseconds(10))
        try await session.bootstrap()

        session.updateSelectedDocumentBody("autosaved")
        try await Task.sleep(for: .milliseconds(100))

        let reopened = try await store.load(id: project.id)
        XCTAssertEqual(reopened.documents[0].body, "autosaved")
        XCTAssertEqual(session.savePhase, .saved)
    }

    /// Protected break: treating selection as process-only state would reopen the first
    /// document instead of the user's last document for that project.
    func testSelectionPersistsAcrossNewSessionForSameProject() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)

        let first = ProjectSession(store: store, defaults: defaults)
        try await first.bootstrap()
        let initialIdentity = try XCTUnwrap(first.runtimeIdentity)
        first.selectDocument(project.documents[1].id)
        XCTAssertEqual(first.runtimeIdentity?.key, ProjectDocumentKey(
            projectID: project.id,
            documentID: project.documents[1].id))
        XCTAssertEqual(first.runtimeIdentity?.generation, initialIdentity.generation + 1)

        let second = ProjectSession(store: store, defaults: defaults)
        try await second.bootstrap()
        XCTAssertEqual(second.selectedDocumentID, project.documents[1].id)
    }

    /// Protected break: activating a destination before the current dirty project has
    /// persisted would split the in-memory owner from the durable active marker.
    func testFailedFlushDoesNotSwitchOrChangeDurableActiveProject() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = fictionProject()
        let other = generalProject()
        let reliableStore = ProjectStore(root: root)
        try await reliableStore.save(original)
        try await reliableStore.save(other)
        try await reliableStore.activate(id: original.id)

        let documentDirectory = "/Documents/\(original.documents[0].id.rawValue.uuidString)/"
        let failingStore = ProjectStore(
            root: root,
            fileSystem: FailingProjectFiles(fragment: documentDirectory))
        let session = ProjectSession(
            store: failingStore,
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        session.updateSelectedDocumentBody("dirty")

        do {
            try await session.activateProject(id: other.id)
            XCTFail("Switch unexpectedly succeeded after a failed flush")
        } catch {}

        let durable = try await reliableStore.activeProject()
        XCTAssertEqual(session.activeProject?.id, original.id)
        XCTAssertEqual(session.selectedDocument?.body, "dirty")
        XCTAssertEqual(session.savePhase, .failed)
        XCTAssertEqual(durable?.id, original.id)
        XCTAssertEqual(durable?.documents[0].body, "A")

        session.updateSelectedDocumentBody("retry after failed transition")
        XCTAssertEqual(session.selectedDocument?.body, "retry after failed transition")
        XCTAssertEqual(session.savePhase, .dirty)
    }

    /// Protected break: trashing must hide the selected document without removing its
    /// document record or immutable bytes from durable project storage.
    func testTrashingSelectedDocumentKeepsBytesAndSelectsVisibleReplacement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(
            store: store,
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let removed = try XCTUnwrap(session.selectedDocumentID)

        session.trashSelectedDocument()

        XCTAssertTrue(session.activeProject?.trashedDocumentIDs.contains(removed) == true)
        XCTAssertNotEqual(session.selectedDocumentID, removed)
        XCTAssertFalse(session.activeProject?.trashedDocumentIDs.contains(
            try XCTUnwrap(session.selectedDocumentID)) == true)
        try await session.flush()
        let reopened = try await store.load(id: project.id)
        XCTAssertTrue(reopened.documents.contains { $0.id == removed })
        XCTAssertTrue(reopened.trashedDocumentIDs.contains(removed))
    }

    /// Protected break: trashing the only visible document without creating a replacement
    /// would leave the editor without a safe mutable target.
    func testTrashingLastVisibleDocumentCreatesBlankReplacement() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = WritingDocument(
            id: WritingDocumentID(), title: "Only", body: "kept", kind: .manuscript)
        let project = WritingProject(
            id: WritingProjectID(), title: "Solo", mode: .general, documents: [document])
        let store = ProjectStore(root: root)
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()

        session.trashSelectedDocument()

        XCTAssertEqual(session.activeProject?.documents.count, 2)
        XCTAssertTrue(session.activeProject?.trashedDocumentIDs.contains(document.id) == true)
        XCTAssertEqual(session.selectedDocument?.title, "Untitled")
        XCTAssertEqual(session.selectedDocument?.body, "")
    }

    /// Protected break: renaming through UI state without updating the active project value
    /// would leave both the runtime generation and durable title stale.
    func testRenameSelectedDocumentAdvancesGenerationAndPersists() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let initial = try XCTUnwrap(session.runtimeIdentity)

        session.renameSelectedDocument(to: "Opening")

        XCTAssertEqual(session.selectedDocument?.title, "Opening")
        XCTAssertEqual(session.runtimeIdentity?.key, initial.key)
        XCTAssertEqual(session.runtimeIdentity?.generation, initial.generation + 1)
        try await session.flush()
        let reopened = try await store.load(id: project.id)
        XCTAssertEqual(reopened.documents[0].title, "Opening")
    }

    func testTargetedRenameKeepsNewerSelectionAndRenamesCapturedDocument() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let captured = ProjectDocumentKey(
            projectID: project.id,
            documentID: project.documents[0].id)
        session.selectDocument(project.documents[1].id)
        let selectedBeforeRename = session.selectedDocumentID
        let generationBeforeRename = try XCTUnwrap(session.runtimeIdentity?.generation)

        session.renameDocument(captured, to: "Captured chapter")

        XCTAssertEqual(
            session.activeProject?.documents.first(where: { $0.id == captured.documentID })?.title,
            "Captured chapter")
        XCTAssertEqual(session.selectedDocumentID, selectedBeforeRename)
        XCTAssertEqual(session.runtimeIdentity?.key.documentID, selectedBeforeRename)
        XCTAssertEqual(session.runtimeIdentity?.generation, generationBeforeRename + 1)
        try await session.flush()
        let reopened = try await store.load(id: project.id)
        XCTAssertEqual(reopened.documents[0].title, "Captured chapter")
    }

    func testTargetedRenameIgnoresTrashedMissingAndWrongProjectTargets() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let trashed = ProjectDocumentKey(
            projectID: project.id,
            documentID: project.documents[0].id)
        session.trashSelectedDocument()
        let selectedAfterTrash = session.selectedDocumentID
        let generationAfterTrash = try XCTUnwrap(session.runtimeIdentity?.generation)

        session.renameDocument(trashed, to: "Must stay unchanged")
        session.renameDocument(
            ProjectDocumentKey(projectID: project.id, documentID: WritingDocumentID()),
            to: "Missing")
        session.renameDocument(
            ProjectDocumentKey(
                projectID: WritingProjectID(), documentID: project.documents[1].id),
            to: "Wrong project")

        XCTAssertEqual(session.activeProject?.documents[0].title, project.documents[0].title)
        XCTAssertEqual(session.activeProject?.documents[1].title, project.documents[1].title)
        XCTAssertEqual(session.selectedDocumentID, selectedAfterTrash)
        XCTAssertEqual(session.runtimeIdentity?.generation, generationAfterTrash)
    }

    /// Protected break: creating a document without selecting and persisting it would make
    /// the editor and a relaunched session disagree about the active document.
    func testCreateDocumentSelectsAndPersistsNewDocument() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let initialGeneration = try XCTUnwrap(session.runtimeIdentity).generation

        let createdID = try XCTUnwrap(session.createDocument(title: "Research", kind: .note))

        XCTAssertEqual(session.selectedDocumentID, createdID)
        XCTAssertEqual(session.selectedDocument?.title, "Research")
        XCTAssertEqual(session.selectedDocument?.kind, .note)
        XCTAssertEqual(session.runtimeIdentity?.generation, initialGeneration + 1)
        try await session.flush()
        let relaunched = ProjectSession(store: store, defaults: defaults)
        try await relaunched.bootstrap()
        XCTAssertEqual(relaunched.selectedDocumentID, createdID)
    }

    /// Protected break: restoring only UI visibility without removing the durable trash ID
    /// would hide the document again after relaunch.
    func testRestoreDocumentAdvancesGenerationAndPersists() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let project = fictionProject()
        try await store.save(project)
        try await store.activate(id: project.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let restoredID = try XCTUnwrap(session.selectedDocumentID)
        session.trashSelectedDocument()
        let beforeRestore = try XCTUnwrap(session.runtimeIdentity).generation

        session.restoreDocument(restoredID)

        XCTAssertFalse(session.activeProject?.trashedDocumentIDs.contains(restoredID) == true)
        XCTAssertEqual(session.runtimeIdentity?.generation, beforeRestore + 1)
        try await session.flush()
        let reopened = try await store.load(id: project.id)
        XCTAssertFalse(reopened.trashedDocumentIDs.contains(restoredID))
    }

    /// Protected break: dropping an unreadable recent ID destroys its recovery handle,
    /// while adopting it would replace the currently verified owner with invalid data.
    func testInvalidRecentIDsStayRecoverableButAreOmittedWithoutReplacingActiveProject() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let current = fictionProject()
        try await store.save(current)
        try await store.activate(id: current.id)
        let missing = WritingProjectID()
        let malformed = "not-a-project-id"
        defaults.set(
            [missing.rawValue.uuidString, malformed],
            forKey: "purlory.recentProjects")

        let session = ProjectSession(store: store, defaults: defaults)
        try await session.bootstrap()

        XCTAssertEqual(session.activeProject?.id, current.id)
        XCTAssertEqual(session.recentProjects, [
            RecentProjectSummary(id: current.id, title: current.title, mode: current.mode)
        ])
        XCTAssertNotNil(session.lastErrorMessage)
        let stored = try XCTUnwrap(defaults.stringArray(forKey: "purlory.recentProjects"))
        XCTAssertTrue(stored.contains(missing.rawValue.uuidString))
        XCTAssertTrue(stored.contains(malformed))
    }

    /// Protected break: flushing before transition participants commit marked text would
    /// switch projects while the latest editor composition exists only in memory.
    func testTransitionCallbackCommitsBeforeFlushAndActivation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let original = fictionProject()
        let other = generalProject()
        try await store.save(original)
        try await store.save(other)
        try await store.activate(id: original.id)
        let session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(60))
        try await session.bootstrap()
        var didPrepareEditor = false
        session.willTransition = {
            didPrepareEditor = true
            session.updateSelectedDocumentBody("committed marked text")
        }

        try await session.activateProject(id: other.id)

        XCTAssertTrue(didPrepareEditor)
        XCTAssertEqual(session.activeProject?.id, other.id)
        let reopenedOriginal = try await store.load(id: original.id)
        XCTAssertEqual(reopenedOriginal.documents[0].body, "committed marked text")
    }

    /// Protected break: late editor callbacks arriving after the outgoing flush must not
    /// mutate the old owner or advance identity while activation is awaiting its commit.
    func testMutationsDuringBlockedActivationCannotAlterTransitionBoundary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = fictionProject()
        let destination = generalProject()
        let reliableStore = ProjectStore(root: root)
        try await reliableStore.save(original)
        try await reliableStore.save(destination)
        try await reliableStore.activate(id: original.id)
        let files = BlockingActiveMarkerProjectFiles()
        let sessionStore = ProjectStore(root: root, fileSystem: files)
        let session = ProjectSession(
            store: sessionStore,
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        session.selectWorkspaceMode(.map)
        let outgoingSnapshot = try XCTUnwrap(session.activeProject)
        let outgoingIdentity = try XCTUnwrap(session.runtimeIdentity)

        let transition = Task { try await session.activateProject(id: destination.id) }
        let didBlock = await Task.detached { files.waitUntilBlocked(timeout: 2) }.value
        guard didBlock else {
            files.releaseWrite()
            _ = try await transition.value
            return XCTFail("Activation did not reach the active-marker gate")
        }

        session.updateSelectedDocumentBody("late body")
        session.renameSelectedDocument(to: "Late title")
        let lateDocumentID = session.createDocument(title: "Late document", kind: .note)
        session.trashSelectedDocument()
        session.selectDocument(original.documents[1].id)
        session.selectWorkspaceMode(.review)
        session.restoreDocument(original.documents[0].id)
        let boundaryStayedFrozen = session.activeProject == outgoingSnapshot
            && session.runtimeIdentity == outgoingIdentity
            && session.workspaceMode == .map
            && lateDocumentID == nil

        files.releaseWrite()
        try await transition.value

        XCTAssertTrue(boundaryStayedFrozen)
        XCTAssertEqual(session.activeProject, destination)
        XCTAssertEqual(session.phase, .ready)
        let durableActive = try await reliableStore.activeProject()
        let durableOriginal = try await reliableStore.load(id: original.id)
        XCTAssertEqual(durableActive, destination)
        XCTAssertEqual(durableOriginal, outgoingSnapshot)

        session.updateSelectedDocumentBody("editable after transition")
        XCTAssertEqual(session.selectedDocument?.body, "editable after transition")
        XCTAssertEqual(session.savePhase, .dirty)
    }

    /// Protected break: save-and-activate has the same post-flush ownership boundary as
    /// ordinary activation and must not discard a late mutation while committing its marker.
    func testMutationDuringBlockedSaveAndActivateCannotAlterTransitionBoundary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = fictionProject()
        let candidate = generalProject()
        let reliableStore = ProjectStore(root: root)
        try await reliableStore.save(original)
        try await reliableStore.activate(id: original.id)
        let files = BlockingActiveMarkerProjectFiles()
        let session = ProjectSession(
            store: ProjectStore(root: root, fileSystem: files),
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        let outgoingSnapshot = try XCTUnwrap(session.activeProject)
        let outgoingIdentity = try XCTUnwrap(session.runtimeIdentity)

        let transition = Task { try await session.saveAndActivate(candidate) }
        let didBlock = await Task.detached { files.waitUntilBlocked(timeout: 2) }.value
        guard didBlock else {
            files.releaseWrite()
            _ = try await transition.value
            return XCTFail("Save-and-activate did not reach the active-marker gate")
        }

        session.updateSelectedDocumentBody("late body")
        let boundaryStayedFrozen = session.activeProject == outgoingSnapshot
            && session.runtimeIdentity == outgoingIdentity

        files.releaseWrite()
        try await transition.value

        XCTAssertTrue(boundaryStayedFrozen)
        XCTAssertEqual(session.activeProject, candidate)
        let durableOriginal = try await reliableStore.load(id: original.id)
        let durableActive = try await reliableStore.activeProject()
        XCTAssertEqual(durableOriginal, outgoingSnapshot)
        XCTAssertEqual(durableActive, candidate)
    }

    /// Protected break: a second activation entering the first transition's await window
    /// must be rejected before either durable or in-memory ownership can split.
    func testOverlappingActivationsAreRejectedBeforeFirstCommit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = fictionProject()
        let firstDestination = generalProject()
        var secondDestination = fictionProject()
        secondDestination.title = "Second destination"
        let reliableStore = ProjectStore(root: root)
        for project in [original, firstDestination, secondDestination] {
            try await reliableStore.save(project)
        }
        try await reliableStore.activate(id: original.id)
        let files = BlockingActiveMarkerProjectFiles()
        let session = ProjectSession(
            store: ProjectStore(root: root, fileSystem: files),
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        var transitionCallbackCount = 0
        session.willTransition = { transitionCallbackCount += 1 }

        let firstTransition = Task {
            try await session.activateProject(id: firstDestination.id)
        }
        let didBlock = await Task.detached { files.waitUntilBlocked(timeout: 2) }.value
        guard didBlock else {
            files.releaseWrite()
            _ = try await firstTransition.value
            return XCTFail("Activation did not reach the active-marker gate")
        }
        let phaseBeforeOverlap = session.phase
        let errorBeforeOverlap = session.lastErrorMessage

        var secondOutcome: TransitionAttemptOutcome?
        let secondTransition = Task {
            do {
                try await session.activateProject(id: secondDestination.id)
                secondOutcome = .succeeded
            } catch let error as ProjectSessionError {
                secondOutcome = .sessionFailure(error)
            } catch {
                secondOutcome = .otherFailure
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while secondOutcome == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let outcomeBeforeFirstCommit = secondOutcome
        let phaseAfterOverlap = session.phase
        let errorAfterOverlap = session.lastErrorMessage
        let callbackCountBeforeFirstCommit = transitionCallbackCount

        files.releaseWrite()
        try await firstTransition.value
        await secondTransition.value

        XCTAssertEqual(outcomeBeforeFirstCommit, .sessionFailure(.transitionInProgress))
        XCTAssertEqual(phaseAfterOverlap, phaseBeforeOverlap)
        XCTAssertEqual(errorAfterOverlap, errorBeforeOverlap)
        XCTAssertEqual(callbackCountBeforeFirstCommit, 1)
        XCTAssertEqual(session.activeProject, firstDestination)
        XCTAssertEqual(session.phase, .ready)
        let durableActive = try await reliableStore.activeProject()
        XCTAssertEqual(durableActive, firstDestination)
    }

    /// Protected break: clearing dirty state after an older snapshot saves while a newer
    /// edit arrives would report success and strand the latest body only in memory.
    func testFlushLoopsUntilEditArrivingDuringSaveIsDurable() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = fictionProject()
        let reliableStore = ProjectStore(root: root)
        try await reliableStore.save(project)
        try await reliableStore.activate(id: project.id)
        let files = BlockingManifestProjectFiles()
        let sessionStore = ProjectStore(root: root, fileSystem: files)
        let session = ProjectSession(
            store: sessionStore,
            defaults: defaults,
            autosaveDelay: .seconds(60))
        try await session.bootstrap()
        session.updateSelectedDocumentBody("first edit")

        let flushTask = Task { try await session.flush() }
        let didBlock = await Task.detached { files.waitUntilBlocked(timeout: 2) }.value
        guard didBlock else {
            files.releaseWrite()
            _ = try await flushTask.value
            return XCTFail("Save did not reach the manifest gate")
        }
        session.updateSelectedDocumentBody("latest edit")
        files.releaseWrite()
        try await flushTask.value

        let reopened = try await reliableStore.load(id: project.id)
        XCTAssertEqual(reopened.documents[0].body, "latest edit")
        XCTAssertEqual(session.savePhase, .saved)
    }

    /// Protected break: cancelling a superseded debounce while its write is in flight must
    /// neither strand the newer edit nor surface cancellation as a disk-save failure.
    func testSupersededAutosaveCancellationPersistsNewestEditWithoutFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = fictionProject()
        let reliableStore = ProjectStore(root: root)
        try await reliableStore.save(project)
        try await reliableStore.activate(id: project.id)
        let files = BlockingManifestProjectFiles()
        let sessionStore = ProjectStore(root: root, fileSystem: files)
        let session = ProjectSession(
            store: sessionStore,
            defaults: defaults,
            autosaveDelay: .milliseconds(1))
        try await session.bootstrap()

        session.updateSelectedDocumentBody("superseded")
        let didBlock = await Task.detached { files.waitUntilBlocked(timeout: 2) }.value
        guard didBlock else {
            files.releaseWrite()
            return XCTFail("Autosave did not reach the manifest gate")
        }
        session.updateSelectedDocumentBody("newest")
        files.releaseWrite()
        try await Task.sleep(for: .milliseconds(200))

        let reopened = try await reliableStore.load(id: project.id)
        XCTAssertEqual(reopened.documents[0].body, "newest")
        XCTAssertEqual(session.savePhase, .saved)
        XCTAssertNil(session.lastErrorMessage)
    }

    func testProjectSwitchIsolatesDocumentAndWorkspaceSelection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: root)
        let fiction = fictionProject()
        let general = generalProject()
        try await store.save(fiction)
        try await store.save(general)

        let session = ProjectSession(store: store, defaults: defaults)
        try await session.activateProject(id: fiction.id)
        session.selectDocument(fiction.documents[1].id)
        session.selectWorkspaceMode(.map)

        XCTAssertEqual(session.selectedDocumentID, fiction.documents[1].id)
        XCTAssertEqual(session.workspaceMode, .map)

        try await session.activateProject(id: general.id)

        XCTAssertEqual(session.activeProject?.id, general.id)
        XCTAssertEqual(session.selectedDocumentID, general.documents[0].id)
        XCTAssertNotEqual(session.selectedDocumentID, fiction.documents[1].id)
        XCTAssertEqual(session.workspaceMode, .write)
        XCTAssertEqual(session.availableWorkspaceModes, [.write, .outline, .review])

        try await session.activateProject(id: fiction.id)
        XCTAssertEqual(session.selectedDocumentID, fiction.documents[1].id)
        XCTAssertEqual(session.workspaceMode, .map)
    }

    /// Protected break: treating an empty durable store as ready (or a verified project as
    /// first-run) would route the app root to the wrong ownership surface.
    func testBootstrapPublishesNeedsProjectThenReadyPhases() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults)

        XCTAssertEqual(session.phase, .loading)
        try await session.bootstrap()
        XCTAssertEqual(session.phase, .needsProject)

        try await session.saveAndActivate(fictionProject())
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNotNil(session.runtimeIdentity)
    }

    func testStaleGeneralMapPreferenceNormalizesAndPersistsWrite() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: root)
        let general = generalProject()
        try await store.save(general)
        defaults.set(
            WorkspaceMode.map.rawValue,
            forKey: "purlory.workspaceMode.\(general.id.rawValue.uuidString)")

        let session = ProjectSession(store: store, defaults: defaults)
        try await session.activateProject(id: general.id)

        XCTAssertEqual(session.workspaceMode, .write)
        XCTAssertEqual(
            defaults.string(
                forKey: "purlory.workspaceMode.\(general.id.rawValue.uuidString)"),
            WorkspaceMode.write.rawValue)
    }

    func testSaveAndActivatePublishesOnlyVerifiedProject() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults)
        let project = fictionProject()

        try await session.saveAndActivate(project)

        XCTAssertEqual(session.activeProject, project)
        XCTAssertEqual(session.selectedDocumentID, project.documents.first?.id)
        let active = try await store.activeProject()
        XCTAssertEqual(active, project)
    }

    func testMemoryScopeIsUnknownUntilActiveProjectLookupCompletes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = defaultsSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(root: root)
        let session = ProjectSession(store: store, defaults: defaults)
        let legacyDocumentID = WritingDocumentID()

        XCTAssertNil(session.storyMemoryScope(for: legacyDocumentID.rawValue))

        try await session.loadActiveProject()
        XCTAssertEqual(
            session.storyMemoryScope(for: legacyDocumentID.rawValue),
            .legacy(documentID: legacyDocumentID))

        let project = fictionProject()
        try await session.saveAndActivate(project)
        XCTAssertEqual(
            session.storyMemoryScope(for: project.documents[0].id.rawValue),
            .project(projectID: project.id, documentID: project.documents[0].id))
        XCTAssertNil(session.storyMemoryScope(for: legacyDocumentID.rawValue))
    }
}

private final class BlockingManifestProjectFiles: ProjectFileSystem, @unchecked Sendable {
    private let real = LocalProjectFileSystem()
    private let condition = NSCondition()
    private var shouldBlock = true
    private var isBlocked = false
    private var isReleased = false

    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        condition.lock()
        let blockThisWrite = shouldBlock && url.lastPathComponent == "project.json"
        if blockThisWrite {
            shouldBlock = false
            isBlocked = true
            condition.broadcast()
            while !isReleased { condition.wait() }
        }
        condition.unlock()
        try real.writeAtomically(data, to: url)
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isBlocked {
            guard condition.wait(until: deadline) else { return isBlocked }
        }
        return true
    }

    func releaseWrite() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private enum TransitionAttemptOutcome: Equatable {
    case succeeded
    case sessionFailure(ProjectSessionError)
    case otherFailure
}

private final class BlockingActiveMarkerProjectFiles: ProjectFileSystem, @unchecked Sendable {
    private let real = LocalProjectFileSystem()
    private let condition = NSCondition()
    private var shouldBlock = true
    private var isBlocked = false
    private var isReleased = false

    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        condition.lock()
        let blockThisWrite = shouldBlock && url.lastPathComponent == "active-project.json"
        if blockThisWrite {
            shouldBlock = false
            isBlocked = true
            condition.broadcast()
            while !isReleased { condition.wait() }
        }
        condition.unlock()
        try real.writeAtomically(data, to: url)
    }

    func waitUntilBlocked(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isBlocked {
            guard condition.wait(until: deadline) else { return isBlocked }
        }
        return true
    }

    func releaseWrite() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
