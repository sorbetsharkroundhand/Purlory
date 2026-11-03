import Observation
import Combine
import Foundation

/// Sole mutable in-memory owner for the active writing project.
///
/// ProjectStore owns durable serialization and verification. Consumers edit only through this
/// session and receive generation-bearing identities for stale-safe asynchronous work.
@Observable
@MainActor
public final class ProjectSession {
    // Native consumers need synchronous value events before ownership changes.
    private let _activeProjectEvents = CurrentValueSubject<WritingProject?, Never>(nil)
    var activeProjectChanges: AnyPublisher<WritingProject?, Never> { _activeProjectEvents.eraseToAnyPublisher() }
    private let _runtimeIdentityEvents = CurrentValueSubject<ProjectRuntimeIdentity?, Never>(nil)
    var runtimeIdentityChanges: AnyPublisher<ProjectRuntimeIdentity?, Never> { _runtimeIdentityEvents.eraseToAnyPublisher() }
    private let _isTransitioningEvents = CurrentValueSubject<Bool, Never>(false)
    var isTransitioningChanges: AnyPublisher<Bool, Never> { _isTransitioningEvents.eraseToAnyPublisher() }
    private let _phaseEvents = CurrentValueSubject<ProjectSessionPhase, Never>(.loading)
    var phaseChanges: AnyPublisher<ProjectSessionPhase, Never> { _phaseEvents.eraseToAnyPublisher() }
    private let _workspaceModeEvents = CurrentValueSubject<WorkspaceMode, Never>(.write)
    var workspaceModeChanges: AnyPublisher<WorkspaceMode, Never> { _workspaceModeEvents.eraseToAnyPublisher() }

    @ObservationIgnored private var projectValue: WritingProject?
    public private(set) var activeProject: WritingProject? {
        get { access(keyPath: \.activeProject); return projectValue }
        set { publishProject(newValue, metadataChanged: true) }
    }

    /// Metadata-only observation for titles, navigation and chrome. The returned value
    /// is current, but body consumers must read activeProject/document instead.
    var projectPresentation: WritingProject? {
        access(keyPath: \.projectPresentation)
        return projectValue
    }

    private func publishProject(_ project: WritingProject?, metadataChanged: Bool) {
        _activeProjectEvents.send(project)
        withMutation(keyPath: \.activeProject) {
            if metadataChanged {
                withMutation(keyPath: \.projectPresentation) { projectValue = project }
            } else { projectValue = project }
        }
    }
    public private(set) var selectedDocumentID: WritingDocumentID?
    public private(set) var workspaceMode: WorkspaceMode = .write { willSet { _workspaceModeEvents.send(newValue) } }
    public private(set) var phase: ProjectSessionPhase = .loading { willSet { _phaseEvents.send(newValue) } }
    public private(set) var savePhase: ProjectSavePhase = .saved
    public private(set) var runtimeIdentity: ProjectRuntimeIdentity? { willSet { _runtimeIdentityEvents.send(newValue) } }
    public private(set) var assetCatalog: ProjectAssetCatalog?
    public private(set) var recentProjects: [RecentProjectSummary] = []
    public private(set) var lastErrorMessage: String?
    /// `false` means persistence scope is still unknown; callers must not assume legacy.
    public private(set) var hasLoadedActiveProject = false
    /// Generic mutation gate exposed so native editor bridges can mirror ownership transitions.
    public private(set) var isTransitioning = false { willSet { _isTransitioningEvents.send(newValue) } }

    @ObservationIgnored public var willTransition: (() -> Void)?
    @ObservationIgnored public var documentDidChange: ((ProjectDocumentSnapshot) -> Void)?

    package let store: ProjectStore
    let sourceSearchIndex: ProjectSourceIndex
    private let defaults: UserDefaults
    private let autosaveDelay: Duration
    private let prepareProject: (@Sendable (WritingProject, ProjectStore) async throws -> WritingProject)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var dirtyGeneration: UInt64?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suspensionReleaseCheck: (() -> Bool)?

    public init(
        store: ProjectStore,
        defaults: UserDefaults = .standard,
        autosaveDelay: Duration = .milliseconds(800),
        prepareProject: (@Sendable (WritingProject, ProjectStore) async throws -> WritingProject)? = nil
    ) {
        self.store = store
        self.sourceSearchIndex = ProjectSourceIndex(store: store)
        self.defaults = defaults
        self.autosaveDelay = autosaveDelay
        self.prepareProject = prepareProject
    }

    public var availableWorkspaceModes: [WorkspaceMode] {
        guard let activeProject = projectPresentation else { return [.write] }
        return WorkspaceRouting.availableModes(for: activeProject.mode)
    }

    public var selectedDocument: WritingDocument? {
        guard let activeProject, let selectedDocumentID else { return nil }
        return activeProject.documents.first { $0.id == selectedDocumentID }
    }

    public var isEditorEditable: Bool {
        phase == .ready && selectedDocumentPresentation != nil && !isTransitioning
    }

    /// Project-scoped presentation preferences do not belong in manuscript storage.
    var presentationPreferences: UserDefaults { defaults }
    private(set) var activationEpoch: UInt64 = 0

    func document(_ id: WritingDocumentID) -> WritingDocument? {
        guard let project = activeProject, !project.trashedDocumentIDs.contains(id) else { return nil }
        return project.documents.first { $0.id == id }
    }

    var selectedDocumentPresentation: WritingDocument? {
        selectedDocumentID.flatMap(documentPresentation)
    }

    func documentPresentation(_ id: WritingDocumentID) -> WritingDocument? {
        guard let project = projectPresentation, !project.trashedDocumentIDs.contains(id) else { return nil }
        return project.documents.first { $0.id == id }
    }

    func updateDocumentBody(_ body: String, for key: ProjectDocumentKey, activationEpoch: UInt64? = nil) {
        guard activationEpoch == nil || activationEpoch == self.activationEpoch else { return }
        try? applyDocumentEdits([ProjectDocumentEdit(key: key, expectedBody: nil, body: body)])
    }

    /// Accepted native edits own an immutable source immediately, including before autosave.
    /// Activation is checked before reading source bytes so stale callbacks stay cheap and inert.
    func updateDocumentSource(_ source: DocumentSource, for key: ProjectDocumentKey, activationEpoch: UInt64) {
        guard self.activationEpoch == activationEpoch, phase == .ready, !isTransitioning,
              var project = activeProject, project.id == key.projectID,
              !project.trashedDocumentIDs.contains(key.documentID),
              let index = project.documents.firstIndex(where: { $0.id == key.documentID }),
              !project.documents[index].source.isSameVersion(as: source) else { return }
        project.documents[index].source = source
        publishProject(project, metadataChanged: false)
        noteDocumentChange(); markDirty()
    }

    /// Validate every source before publishing any replacement. Selection is not a write address.
    func applyDocumentEdits(_ edits: [ProjectDocumentEdit]) throws {
        guard phase == .ready, !isTransitioning, var project = activeProject,
              Set(edits.map(\.key)).count == edits.count else { throw ProjectSessionError.staleRuntime }
        var replacements: [(Int, String)] = []
        for edit in edits {
            guard edit.key.projectID == project.id,
                  !project.trashedDocumentIDs.contains(edit.key.documentID),
                  let index = project.documents.firstIndex(where: { $0.id == edit.key.documentID }),
                  edit.expectedBody.map({ project.documents[index].body.utf16.elementsEqual($0.utf16) }) != false
            else { throw ProjectSessionError.staleRuntime }
            if !project.documents[index].body.utf16.elementsEqual(edit.body.utf16) {
                replacements.append((index, edit.body))
            }
        }
        guard !replacements.isEmpty else { return }
        for (index, body) in replacements { project.documents[index].body = body }
        publishProject(project, metadataChanged: false)
        noteDocumentChange(); markDirty()
    }

    func reorderDocuments(_ ids: some Sequence<WritingDocumentID>, projectID: WritingProjectID) {
        let ids = Array(ids)
        guard phase == .ready, !isTransitioning, var project = activeProject, project.id == projectID,
              ids.count == project.documents.count, Set(ids).count == ids.count,
              Set(ids) == Set(project.documents.map(\.id)), ids != project.documents.map(\.id) else { return }
        let documents = Dictionary(uniqueKeysWithValues: project.documents.map { ($0.id, $0) })
        project.documents = ids.compactMap { documents[$0] }
        activeProject = project; noteDocumentChange(); markDirty()
    }

    public var selectedDocumentSnapshot: ProjectDocumentSnapshot? {
        guard let runtimeIdentity, let selectedDocument, let activeProject else { return nil }
        return ProjectDocumentSnapshot(
            identity: runtimeIdentity, title: selectedDocument.title,
            source: selectedDocument.source, kind: selectedDocument.kind, mode: activeProject.mode,
            userData: activeProject.userData)
    }

    /// Derived memory stays unscoped until active-project lookup has completed. Once
    /// known, a nil active project represents an explicit legacy session.
    public func storyMemoryScope(for entryID: UUID) -> StoryMemoryScope? {
        guard hasLoadedActiveProject else { return nil }
        return StoryMemoryScopeResolver.resolve(
            activeProject: activeProject, entryID: entryID)
    }

    /// Load and prepare the verified active project before adoption.
    public func loadActiveProject() async throws {
        try await bootstrap()
    }

    /// Resolve the durable active marker into the sole mutable in-memory project value.
    public func bootstrap(initialProject: (() async throws -> WritingProjectID?)? = nil) async throws {
        guard phase != .suspended, !isTransitioning else {
            throw ProjectSessionError.transitionInProgress
        }
        isTransitioning = true
        defer { finishTransition() }
        phase = .loading
        lastErrorMessage = nil
        do {
            let existing = try await store.activeProject()
            let initialID = existing == nil ? try await initialProject?() : nil
            let initial: WritingProject?
            if let initialID { initial = try await store.load(id: initialID) }
            else { initial = existing }
            let candidate = try await preparedForAdoption(initial)
            let catalog: ProjectAssetCatalog?
            if let candidate { catalog = try await store.assetCatalog(id: candidate.id) }
            else { catalog = nil }
            let project: WritingProject?
            if let initialID { project = try await store.activateInitialProject(id: initialID, expected: candidate) }
            else { project = candidate }
            assetCatalog = catalog
            adopt(project)
            hasLoadedActiveProject = true
            phase = project == nil ? .needsProject : .ready
            if let project { recordRecent(project) }
            await resolveRecentProjects(activeProject: project)
        } catch {
            phase = .failed
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Switch only after ProjectStore has verified and activated the target.
    public func activateProject(id: WritingProjectID) async throws {
        try await activateProject(preparing: { id })
    }

    /// Fence editing and termination for the entire import, including preparation.
    public func activateProject(preparing prepare: () async throws -> WritingProjectID) async throws {
        try beginTransition()
        defer { finishTransition() }
        cancelAutosave()
        do {
            try await flush()
            phase = .loading
            let id = try await prepare()
            let expected = prepareProject == nil ? nil : try await preparedForAdoption(store.load(id: id))
            let catalog = try await store.assetCatalog(id: id)
            let project = try await store.activateAndLoad(id: id, expected: expected)
            // Activation has committed. Adoption intentionally has no cancellation point.
            assetCatalog = catalog
            adopt(project)
            hasLoadedActiveProject = true
            phase = .ready
            savePhase = .saved
            lastErrorMessage = nil
            recordRecent(project)
            mergeRecentSummary(project)
        } catch {
            phase = activeProject == nil ? .failed : .ready
            lastErrorMessage = error.localizedDescription
            // The barrier detached readers, but persistence kept the previous owner.
            // Reconnect only that surviving snapshot; do not advance its generation.
            if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
            throw error
        }
    }

    /// Flush and detach the mutable project while retaining the durable active marker.
    public func suspend(canResume: @escaping () -> Bool = { true }) async throws {
        guard phase != .loading else { throw ProjectSessionError.transitionInProgress }
        try beginTransition()
        defer { finishTransition() }
        do {
            try await flush()
            suspensionReleaseCheck = canResume
            assetCatalog = nil
            adopt(nil)
            phase = .suspended
        } catch {
            lastErrorMessage = error.localizedDescription
            if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
            throw error
        }
    }

    /// Resume without another owner only after the suspension release check permits it.
    public func resume() async throws {
        guard suspensionReleaseCheck?() != false else {
            throw ProjectSessionError.transitionInProgress
        }
        try await resume(releasing: {})
    }

    /// Verify every fallible input while the other owner is retained. Release and adoption
    /// then occur synchronously on the main actor, with no remaining suspension/failure point.
    func resume(releasing releaseOwner: () -> Void) async throws {
        guard phase == .suspended, !isTransitioning else {
            throw ProjectSessionError.transitionInProgress
        }
        isTransitioning = true
        defer { finishTransition() }
        do {
            let project = try await preparedForAdoption(store.activeProject())
            let catalog: ProjectAssetCatalog?
            if let project { catalog = try await store.assetCatalog(id: project.id) }
            else { catalog = nil }
            releaseOwner()
            assetCatalog = catalog
            phase = project == nil ? .needsProject : .ready
            adopt(project)
            suspensionReleaseCheck = nil
            hasLoadedActiveProject = true
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Used by onboarding/import after a project has been explicitly created by the user.
    /// Save + verification complete before active UI state changes.
    public func saveAndActivate(_ project: WritingProject) async throws {
        try beginTransition()
        defer { finishTransition() }
        cancelAutosave()
        do {
            try await flush()
            try await store.save(project)
            let expected = prepareProject == nil ? nil : try await preparedForAdoption(store.load(id: project.id))
            let catalog = try await store.assetCatalog(id: project.id)
            let verified = try await store.activateAndLoad(id: project.id, expected: expected)
            // Activation has committed. Adoption intentionally has no cancellation point.
            assetCatalog = catalog
            adopt(verified)
            hasLoadedActiveProject = true
            phase = .ready
            savePhase = .saved
            lastErrorMessage = nil
            recordRecent(verified)
            mergeRecentSummary(verified)
        } catch {
            phase = activeProject == nil ? .failed : .ready
            lastErrorMessage = error.localizedDescription
            if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
            throw error
        }
    }

    /// Preview is read-only, including after an initial open of a damaged current manifest.
    func backupForRecovery() async throws -> ProjectBackupPreview {
        let id = try await recoveryProjectID()
        return try await store.previousBackup(id: id)
    }

    /// Explicit restore adopts only a verified independent copy through the existing owner.
    func restoreBackup(_ preview: ProjectBackupPreview) async throws {
        guard try await recoveryProjectID() == preview.project.id else { throw ProjectSessionError.staleRuntime }
        try beginTransition()
        defer { finishTransition() }
        cancelAutosave()
        do {
            try await flush()
            phase = .loading
            let copy = try await store.prepareBackupRestore(preview, title: preview.project.title + " (복구)")
            let expected = try await preparedForAdoption(copy)
            let catalog = try await store.assetCatalog(id: copy.id)
            let verified = try await store.activateAndLoad(id: copy.id, expected: expected)
            // All fallible work precedes the durable marker; adoption has no cancellation point.
            assetCatalog = catalog
            adopt(verified)
            hasLoadedActiveProject = true
            phase = .ready
            savePhase = .saved
            lastErrorMessage = nil
            recordRecent(verified)
            mergeRecentSummary(verified)
        } catch {
            phase = activeProject == nil ? .failed : .ready
            lastErrorMessage = error.localizedDescription
            if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
            throw error
        }
    }

    private func recoveryProjectID() async throws -> WritingProjectID {
        guard !isTransitioning, phase == .ready || phase == .failed else {
            throw ProjectSessionError.transitionInProgress
        }
        if let activeProject { return activeProject.id }
        let stored = try await store.activeProjectID()
        guard !isTransitioning, phase == .ready || phase == .failed else {
            throw ProjectSessionError.transitionInProgress
        }
        if let activeProject { return activeProject.id }
        guard let stored else { throw CocoaError(.fileReadNoSuchFile) }
        return stored
    }

    /// Optional domain preparation must finish durably before a mutable owner is adopted.
    private func preparedForAdoption(_ project: WritingProject?) async throws -> WritingProject? {
        guard let original = project else { return nil }
        let project = try await store.prepareDocumentNavigation(original)
        guard let prepareProject else { return project }
        let prepared = try await prepareProject(project, store)
        guard prepared.id == project.id else { throw ProjectStoreError.invalidManifest }
        let verified = try await store.load(id: project.id)
        guard prepared == verified else { throw ProjectStoreError.changedDuringSave }
        try Task.checkCancellation()
        return verified
    }

    public func selectDocument(_ id: WritingDocumentID?) {
        guard !isTransitioning else { return }
        guard let project = activeProject else {
            selectedDocumentID = nil
            runtimeIdentity = nil
            return
        }
        guard let id else {
            guard selectedDocumentID != nil else { return }
            willTransition?()
            selectedDocumentID = nil
            defaults.removeObject(forKey: selectionPreferenceKey(project.id))
            noteDocumentChange()
            return
        }
        guard id != selectedDocumentID,
            !project.trashedDocumentIDs.contains(id),
            project.documents.contains(where: { $0.id == id })
        else { return }
        willTransition?()
        selectedDocumentID = id
        persistSelection(id, for: project.id)
        noteDocumentChange()
    }

    public func selectWorkspaceMode(_ requested: WorkspaceMode) {
        guard !isTransitioning else { return }
        guard let project = activeProject else {
            workspaceMode = .write
            return
        }
        let normalized = WorkspaceRouting.normalizedSelection(requested, for: project.mode)
        workspaceMode = normalized
        defaults.set(normalized.rawValue, forKey: workspacePreferenceKey(project.id))
    }

    public func updateSelectedDocumentBody(_ body: String) {
        guard !isTransitioning else { return }
        guard var project = activeProject,
            let selectedDocumentID,
            let index = project.documents.firstIndex(where: { $0.id == selectedDocumentID }),
            !project.documents[index].body.utf16.elementsEqual(body.utf16)
        else { return }

        project.documents[index].body = body
        publishProject(project, metadataChanged: false)
        noteDocumentChange()
        markDirty()
    }

    /// Captured ownership gates writer edits exactly like other project-scoped work.
    public func updateUserData(_ data: Data?, for key: String, identity: ProjectRuntimeIdentity) throws {
        guard phase == .ready, !isTransitioning, runtimeIdentity == identity,
              var project = activeProject else { throw ProjectSessionError.staleRuntime }
        try ProjectUserDataKey.validate(key)
        guard project.userData[key] != data else { return }
        project.userData[key] = data
        activeProject = project
        noteDocumentChange()
        markDirty()
    }

    func updateProjectUserData(_ entries: [String: Data], projectID: WritingProjectID) throws {
        guard phase == .ready, !isTransitioning, var project = activeProject,
              project.id == projectID else { throw ProjectSessionError.staleRuntime }
        var changed = false
        for (key, data) in entries {
            try ProjectUserDataKey.validate(key)
            if project.userData[key] != data {
                project.userData[key] = data
                changed = true
            }
        }
        guard changed else { return }
        publishProject(project, metadataChanged: false)
        noteDocumentChange()
        markDirty()
    }

    /// The returned reference is insertable only by the initiating full runtime generation.
    /// Bytes already committed for an obsolete request remain durable, without a marker.
    public func importAsset(
        data: Data, reference: String, for identity: ProjectRuntimeIdentity
    ) async throws -> String {
        guard !isTransitioning, runtimeIdentity == identity else { throw ProjectSessionError.staleRuntime }
        try await store.addAsset(data, reference: reference, to: identity.key.projectID)
        let catalog = try await store.assetCatalog(id: identity.key.projectID)
        guard !isTransitioning, runtimeIdentity == identity else { throw ProjectSessionError.staleRuntime }
        assetCatalog = catalog
        return reference
    }

    public func renameSelectedDocument(to title: String) {
        guard let projectID = activeProject?.id, let selectedDocumentID else { return }
        renameDocument(
            ProjectDocumentKey(projectID: projectID, documentID: selectedDocumentID),
            to: title)
    }

    /// Renames a captured project/document identity without changing a newer editor selection.
    /// Deferred UI commits must not retarget a title edit after navigation or trashing.
    public func renameDocument(_ key: ProjectDocumentKey, to title: String) {
        guard !isTransitioning else { return }
        guard var project = activeProject,
            project.id == key.projectID,
            !project.trashedDocumentIDs.contains(key.documentID),
            let index = project.documents.firstIndex(where: { $0.id == key.documentID }),
            project.documents[index].title != title
        else { return }

        project.documents[index].title = title
        activeProject = project
        noteDocumentChange()
        markDirty()
    }

    @discardableResult
    public func createDocument(
        title: String = "Untitled",
        kind: WritingDocument.Kind = .manuscript,
        in folderID: UUID? = nil
    ) -> WritingDocumentID? {
        guard !isTransitioning else { return nil }
        guard activeProject != nil else { return nil }
        willTransition?()
        guard var project = activeProject else { return nil }
        let document = WritingDocument(
            id: WritingDocumentID(),
            title: title.isEmpty ? "Untitled" : title,
            body: "",
            kind: kind)
        project.documents.append(document)
        do {
            var navigation = try ProjectNavigation.read(project)
            if let folderID {
                guard navigation.contains(.folder(folderID), in: project) else { throw ProjectSessionError.staleRuntime }
                navigation.documentFolders[document.id] = folderID
            }
            navigation.createdDates[document.id] = Date()
            try navigation.write(to: &project)
        } catch { reportError(error); return nil }
        activeProject = project
        selectedDocumentID = document.id
        persistSelection(document.id, for: project.id)
        noteDocumentChange()
        markDirty()
        return document.id
    }

    public func trashSelectedDocument() {
        guard let project = activeProject, let id = selectedDocumentID else { return }
        do { try applyNavigation(.trash(.document(id)), projectID: project.id) }
        catch { reportError(error) }
    }

    public func restoreDocument(_ id: WritingDocumentID) {
        guard let project = activeProject else { return }
        do { try applyNavigation(.restore(.document(id)), projectID: project.id) }
        catch { reportError(error) }
    }

    /// Organization edits use the same durable owner and activation fence as writing.
    func applyNavigation(_ edit: ProjectNavigationEdit, projectID: WritingProjectID,
                         epoch: UInt64? = nil, undoManager: UndoManager? = nil) throws {
        guard phase == .ready, !isTransitioning, var project = activeProject, project.id == projectID,
              epoch == nil || epoch == activationEpoch else { throw ProjectSessionError.staleRuntime }
        var navigation = try ProjectNavigation.read(project)
        var preview = project
        try navigation.apply(edit, to: &preview)
        if let id = selectedDocumentID,
           preview.trashedDocumentIDs.contains(id) || preview.documents.first(where: { $0.id == id })?.kind != selectedDocument?.kind {
            willTransition?()
            guard let current = activeProject, current.id == projectID else { throw ProjectSessionError.staleRuntime }
            project = current
        }
        let before = project
        navigation = try ProjectNavigation.read(project)
        try navigation.apply(edit, to: &project)
        if project.documents.allSatisfy({ project.trashedDocumentIDs.contains($0.id) }) {
            let replacement = WritingDocument(id: WritingDocumentID(), title: "Untitled", body: "", kind: selectedDocument?.kind ?? .manuscript)
            project.documents.append(replacement); navigation.createdDates[replacement.id] = Date()
            try navigation.write(to: &project)
        }
        guard project != before else { return }
        let previousSelection = selectedDocumentID
        activeProject = project
        if selectedDocumentID == nil || project.trashedDocumentIDs.contains(selectedDocumentID!) || !project.documents.contains(where: { $0.id == selectedDocumentID }) {
            selectedDocumentID = project.documents.first { !project.trashedDocumentIDs.contains($0.id) }?.id
            if let selectedDocumentID { persistSelection(selectedDocumentID, for: project.id) }
        }
        noteDocumentChange(); markDirty()
        registerNavigationUndo(before: before, after: project, selection: previousSelection, manager: undoManager)
    }

    private func registerNavigationUndo(before: WritingProject, after: WritingProject,
                                        selection: WritingDocumentID?, manager: UndoManager?) {
        guard let manager else { return }
        let epoch = activationEpoch
        manager.registerUndo(withTarget: self) { owner in
            MainActor.assumeIsolated {
                guard owner.activationEpoch == epoch, !owner.isTransitioning, let current = owner.activeProject,
                      current.id == before.id, current.userData[ProjectNavigation.key] == after.userData[ProjectNavigation.key],
                      current.documents.map(\.id) == after.documents.map(\.id), current.trashedDocumentIDs == after.trashedDocumentIDs else { return }
                let previousIDs = Set(before.documents.map(\.id))
                guard current.documents.filter({ !previousIDs.contains($0.id) }).allSatisfy({ $0.body.isEmpty }) else { return }
                owner.willTransition?()
                guard let live = owner.activeProject else { return }
                var restored = live
                restored.documents = before.documents.map { old in
                    var document = live.documents.first { $0.id == old.id } ?? old
                    document.kind = old.kind
                    return document
                }
                restored.userData[ProjectNavigation.key] = before.userData[ProjectNavigation.key]
                restored.trashedDocumentIDs = before.trashedDocumentIDs
                let oldSelection = owner.selectedDocumentID
                owner.activeProject = restored; owner.selectedDocumentID = selection
                if let selection { owner.persistSelection(selection, for: restored.id) }
                owner.noteDocumentChange(); owner.markDirty()
                owner.registerNavigationUndo(before: live, after: restored, selection: oldSelection, manager: manager)
            }
        }
        manager.setActionName("문서 정리")
    }

    /// Persist every generation observed while the store actor hop is in flight. A save
    /// only clears dirty state when its captured generation is still current.
    public func flush() async throws {
        cancelAutosave()
        while let targetGeneration = dirtyGeneration, let snapshot = activeProject {
            cancelAutosave()
            savePhase = .saving
            do {
                try await store.save(snapshot)
            } catch {
                savePhase = .failed
                lastErrorMessage = error.localizedDescription
                throw error
            }

            if dirtyGeneration == targetGeneration {
                dirtyGeneration = nil
                savePhase = .saved
                lastErrorMessage = nil
                return
            }
        }
    }

    /// Keep mutations fenced after a successful final save until the process exits.
    /// A failed save reopens editing and reconnects the surviving project consumers.
    func flushForTermination() async throws {
        guard phase != .loading else { throw ProjectSessionError.transitionInProgress }
        try beginTransition()
        do {
            try await flush()
        } catch {
            finishTransition()
            if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
            throw error
        }
    }

    /// Explicit save accepts marked text before fencing and reconnects the same editor.
    public func saveNow() async throws {
        guard phase != .loading else { throw ProjectSessionError.transitionInProgress }
        try beginTransition()
        defer {
            finishTransition()
            if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
        }
        try await flush()
    }

    public func reportError(_ error: Error) {
        lastErrorMessage = error.localizedDescription
    }

    /// Transition participants may synchronously commit marked text before the gate closes.
    /// Once closed, stale UI callbacks cannot mutate either side of the ownership handoff.
    private func beginTransition() throws {
        guard !isTransitioning, phase != .suspended else { throw ProjectSessionError.transitionInProgress }
        willTransition?()
        isTransitioning = true
    }

    private func finishTransition() {
        isTransitioning = false
    }

    private func adopt(_ project: WritingProject?) {
        activationEpoch &+= 1
        cancelAutosave()
        dirtyGeneration = nil
        activeProject = project

        guard let project else {
            selectedDocumentID = nil
            workspaceMode = .write
            runtimeIdentity = nil
            savePhase = .saved
            return
        }

        let remembered = defaults.string(forKey: selectionPreferenceKey(project.id))
            .flatMap(UUID.init(uuidString:))
            .map { WritingDocumentID(rawValue: $0) }
        if let remembered,
            !project.trashedDocumentIDs.contains(remembered),
            project.documents.contains(where: { $0.id == remembered })
        {
            selectedDocumentID = remembered
        } else {
            selectedDocumentID = project.documents.first {
                !project.trashedDocumentIDs.contains($0.id)
            }?.id
        }
        if let selectedDocumentID {
            persistSelection(selectedDocumentID, for: project.id)
        } else {
            defaults.removeObject(forKey: selectionPreferenceKey(project.id))
        }

        let saved = defaults.string(forKey: workspacePreferenceKey(project.id))
            .flatMap(WorkspaceMode.init(rawValue:))
        let normalized = WorkspaceRouting.normalizedSelection(saved, for: project.mode)
        workspaceMode = normalized

        // Normalize stale preferences immediately so General never keeps an old Fiction Map.
        if saved != normalized {
            defaults.set(normalized.rawValue, forKey: workspacePreferenceKey(project.id))
        }

        savePhase = .saved
        noteDocumentChange()
    }

    private func noteDocumentChange() {
        generation += 1
        guard let projectID = activeProject?.id, let selectedDocumentID else {
            runtimeIdentity = nil
            return
        }
        let identity = ProjectRuntimeIdentity(
            key: ProjectDocumentKey(projectID: projectID, documentID: selectedDocumentID),
            generation: generation)
        runtimeIdentity = identity
        if let snapshot = selectedDocumentSnapshot { documentDidChange?(snapshot) }
    }

    private func markDirty() {
        dirtyGeneration = generation
        if savePhase != .dirty { savePhase = .dirty }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, autosaveDelay] in
            do {
                try await Task.sleep(for: autosaveDelay)
                guard !Task.isCancelled, let self else { return }
                try await self.flushFromAutosave()
            } catch is CancellationError {
                // Replaced debounce timers are expected and are not save failures.
            } catch {
                guard let self else { return }
                self.savePhase = .failed
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func flushFromAutosave() async throws {
        saveTask = nil
        try await flush()
    }

    private func cancelAutosave() {
        saveTask?.cancel()
        saveTask = nil
    }

    private func persistSelection(_ id: WritingDocumentID, for projectID: WritingProjectID) {
        defaults.set(id.rawValue.uuidString, forKey: selectionPreferenceKey(projectID))
    }

    private func recordRecent(_ project: WritingProject) {
        let value = project.id.rawValue.uuidString
        var stored = defaults.stringArray(forKey: Self.recentProjectsPreferenceKey) ?? []
        stored.removeAll { UUID(uuidString: $0) == project.id.rawValue }
        stored.insert(value, at: 0)
        defaults.set(stored, forKey: Self.recentProjectsPreferenceKey)
    }

    private func mergeRecentSummary(_ project: WritingProject) {
        let summary = RecentProjectSummary(id: project.id, title: project.title, mode: project.mode)
        recentProjects.removeAll { $0.id == project.id }
        recentProjects.insert(summary, at: 0)
    }

    private func resolveRecentProjects(activeProject: WritingProject?) async {
        let stored = defaults.stringArray(forKey: Self.recentProjectsPreferenceKey) ?? []
        var resolved: [RecentProjectSummary] = []
        var firstFailure: String?

        for value in stored {
            guard let rawID = UUID(uuidString: value) else {
                firstFailure = firstFailure ?? "Recent project identifier is invalid: \(value)"
                continue
            }
            let id = WritingProjectID(rawValue: rawID)
            do {
                let project: WritingProject
                if activeProject?.id == id, let activeProject {
                    project = activeProject
                } else {
                    project = try await store.load(id: id)
                }
                guard !resolved.contains(where: { $0.id == id }) else { continue }
                resolved.append(RecentProjectSummary(
                    id: project.id,
                    title: project.title,
                    mode: project.mode))
            } catch {
                firstFailure = firstFailure ?? error.localizedDescription
            }
        }

        recentProjects = resolved
        if let firstFailure { lastErrorMessage = firstFailure }
    }

    private func workspacePreferenceKey(_ id: WritingProjectID) -> String {
        "purlory.workspaceMode.\(id.rawValue.uuidString)"
    }

    private func selectionPreferenceKey(_ id: WritingProjectID) -> String {
        "purlory.selectedDocument.\(id.rawValue.uuidString)"
    }

    private static let recentProjectsPreferenceKey = "purlory.recentProjects"
}
