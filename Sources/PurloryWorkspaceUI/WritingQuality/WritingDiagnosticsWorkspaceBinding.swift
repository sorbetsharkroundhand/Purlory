import AppKit
import Combine
import Foundation

/// One workspace consumer of prepared diagnostics. Surface opening has no execution role.
@MainActor
final class WritingDiagnosticsWorkspaceBinding {
    private let controller: WritingDiagnosticsController
    private weak var session: ProjectSession?
    private weak var bridge: ProjectEditorBridge?
    private weak var margin: LivingMarginModel?
    private weak var spatial: SpatialWorkspaceController?
    private weak var settings: CompletionSettings?
    private var observation: AnyCancellable?
    private var spatialObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    private var selectionObservation: AnyCancellable?
    private var publication: Task<Void, Never>?
    private var quietWindowTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var active = true
    private(set) var isActiveParagraphQuietWindow = false
    private var activeTypingParagraphRange: WritingDiagnosticRange?
    private var findingIDs: [String: String] = [:]
    private var insightCache: [String: (stamp: WritingDiagnosticsStamp, insight: MarginInsight?)] = [:]
    private let actions: WritingDiagnosticsActions

    init(controller: WritingDiagnosticsController, session: ProjectSession, bridge: ProjectEditorBridge, margin: LivingMarginModel,
         spatial: SpatialWorkspaceController? = nil, settings: CompletionSettings? = nil) {
        self.controller = controller; self.session = session; self.bridge = bridge; self.margin = margin
        self.spatial = spatial; self.settings = settings
        actions = WritingDiagnosticsActions(controller: controller, editor: { [weak bridge] in bridge?.editor },
            currentSnapshot: { [weak session] in session?.selectedDocumentSnapshot }, session: session)
    }
    func matches(session: ProjectSession, bridge: ProjectEditorBridge, margin: LivingMarginModel) -> Bool {
        self.session === session && self.bridge === bridge && self.margin === margin
    }
    func configurePresentation(spatial: SpatialWorkspaceController? = nil, settings: CompletionSettings? = nil) {
        if let spatial, self.spatial !== spatial {
            self.spatial = spatial
            observeSpatial(spatial)
        }
        if let settings, self.settings !== settings {
            self.settings = settings
            observeSettings(settings)
        }
        attachEditorInteraction()
    }
    private func observeSpatial(_ model: SpatialWorkspaceController) {
        spatialObservation = model.presentationDidChange.sink { [weak self] _ in
            self?.handlePresentationChange()
        }
    }
    private func observeSettings(_ settings: CompletionSettings) {
        settingsObservation = settings.$showsWritingDiagnosticsInEditor.dropFirst().sink { [weak self] shows in
            self?.handlePresentationChange(showsInEditorOverride: shows)
        }
    }
    private func attachEditorInteraction() {
        guard let interaction = bridge?.editor?.workspaceInteraction as? WorkspaceEditorInteraction else { return }
        interaction.onPresentationChange = { [weak self] in self?.handlePresentationChange() }
        if spatial == nil, let model = interaction.model {
            spatial = model
            observeSpatial(model)
        }
    }
    func connect() {
        guard let bridge else { return }
        if let spatial { observeSpatial(spatial) }
        if let settings { observeSettings(settings) }
        selectionObservation = NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)
            .sink { [weak self] notification in
                self?.handleSelectionChange(notification)
            }
        bridge.snapshotDidChange = { [weak self, weak controller] snapshot in
            self?.clearQuietWindow()
            controller?.noteSnapshot(snapshot)
        }
        bridge.commitDidChange = { [weak self, weak controller] commit, snapshot in
            self?.noteEditorCommit(commit)
            controller?.noteEditorCommit(commit, snapshot: snapshot)
        }
        bridge.compositionDidChange = { [weak controller] in controller?.setMarkedRange($0) }
        bridge.editorDidChange = { [weak self, weak controller] _ in
            self?.clearQuietWindow()
            self?.attachEditorInteraction()
            controller?.suspendNativeAuthority()
        }
        bridge.nativeLoadDidChange = { [weak self, weak controller] snapshot in
            self?.clearQuietWindow()
            controller?.noteNativeLoad(snapshot)
        }
        observation = controller.$state.sink { [weak self] _ in self?.schedulePublication() }
        refresh()
    }
    func refresh() {
        attachEditorInteraction()
        if let snapshot = session?.selectedDocumentSnapshot {
            controller.noteSnapshot(snapshot)
            if let editor = bridge?.editor, !controller.isNativeBound(to: snapshot.identity, revision: editor.writingNativeRevision) {
                bridge?.replayPreparedAuthority(baseIdentity: controller.nativeAuthorityBase)
            } else { bridge?.noteSnapshot(snapshot) }
        }
        schedulePublication()
    }
    private func noteEditorCommit(_ commit: WritingEditorCommit) {
        let patch = commit.patch, old = patch.oldSourceRange.nsRange
        let isInitialLoadCommit = old.location == 0 && old.length == 0 && patch.replacement.isEmpty
        guard !isInitialLoadCommit,
              let editor = bridge?.editor,
              editor.window?.firstResponder === editor,
              editor.selectedRange().length == 0 else {
            if isInitialLoadCommit { clearQuietWindow() }
            return
        }
        isActiveParagraphQuietWindow = true
        activeTypingParagraphRange = editor.activeEditingSourceParagraphRange(revision: commit.nativeRevision)
        quietWindowTask?.cancel()
        quietWindowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard let self, self.active, !Task.isCancelled else { return }
            self.flushActiveParagraphQuietWindow()
        }
    }
    private func clearQuietWindow() {
        quietWindowTask?.cancel()
        quietWindowTask = nil
        isActiveParagraphQuietWindow = false
        activeTypingParagraphRange = nil
    }
    func flushActiveParagraphQuietWindow() {
        guard isActiveParagraphQuietWindow || activeTypingParagraphRange != nil else { return }
        clearQuietWindow()
        publish()
    }
    private func handleSelectionChange(_ notification: Notification) {
        guard active, isActiveParagraphQuietWindow,
              let editor = bridge?.editor,
              notification.object as? BlockTextView === editor else { return }
        let currentParagraph = editor.activeEditingSourceParagraphRange(revision: editor.writingNativeRevision)
        if editor.selectedRange().length > 0 || currentParagraph != activeTypingParagraphRange {
            clearQuietWindow()
            publish()
        }
    }
    private func handlePresentationChange(showsInEditorOverride: Bool? = nil) {
        guard active else { return }
        clearQuietWindow()
        publish(showsInEditorOverride: showsInEditorOverride)
    }
    private func schedulePublication() {
        guard active else { return }
        epoch &+= 1; let owned = epoch
        publication?.cancel()
        publication = Task(priority: .utility) { [weak self] in
            await Task.yield()
            guard let self, self.active, self.epoch == owned, !Task.isCancelled else { return }
            self.publish()
            if self.epoch == owned { self.publication = nil }
        }
    }
    private func shouldShowDiagnosticsInEditor(_ editor: BlockTextView, showsInEditorOverride: Bool? = nil) -> (show: Bool, marginOpen: Bool) {
        let activeSpatial = spatial ?? (editor.workspaceInteraction as? WorkspaceEditorInteraction)?.model
        let marginOpen = activeSpatial?.layout.contains(.margin) == true
        if marginOpen { return (true, true) }
        if activeSpatial?.focusDimming == true { return (false, false) }
        if let showsInEditorOverride { return (showsInEditorOverride, false) }
        if let settings, !settings.showsWritingDiagnosticsInEditor { return (false, false) }
        if let prefs = session?.presentationPreferences,
           let shows = prefs.object(forKey: "editor.showsWritingDiagnostics") as? Bool, !shows {
            return (false, false)
        }
        return (true, false)
    }
    private func publish(showsInEditorOverride: Bool? = nil) {
        attachEditorInteraction()
        guard let snapshot = session?.selectedDocumentSnapshot, let editor = bridge?.editor,
              editor.writingRuntimeIdentityProvider?() == snapshot.identity else {
            findingIDs.removeAll(); insightCache.removeAll(); margin?.replace(writingQuality: []); return
        }
        var prepared = controller.state
        prepared.findings = prepared.findings.filter { controller.isCurrent($0.stamp) && $0.stamp.runtime == snapshot.identity }
        var nextCache: [String: (stamp: WritingDiagnosticsStamp, insight: MarginInsight?)] = [:]
        nextCache.reserveCapacity(prepared.findings.count)
        var insights: [MarginInsight] = []
        insights.reserveCapacity(prepared.findings.count)
        for finding in prepared.findings {
            let insight: MarginInsight?
            if let cached = insightCache[finding.id], cached.stamp == finding.stamp {
                insight = cached.insight
            } else {
                insight = WritingDiagnosticsPresentation.insight(for: finding)
            }
            nextCache[finding.id] = (finding.stamp, insight)
            if let insight { insights.append(insight) }
        }
        insightCache = nextCache
        findingIDs = Dictionary(uniqueKeysWithValues: prepared.findings.map { ("writing-quality:" + $0.id, $0.id) })
        let policy = shouldShowDiagnosticsInEditor(editor, showsInEditorOverride: showsInEditorOverride)
        let editorFindings: [WritingDiagnosticsFinding]
        if !policy.show {
            editorFindings = []
        } else if !policy.marginOpen,
                  isActiveParagraphQuietWindow,
                  editor.window?.firstResponder === editor,
                  editor.selectedRange().length == 0,
                  let activeParagraph = editor.activeEditingSourceParagraphRange(revision: editor.writingNativeRevision) ?? activeTypingParagraphRange {
            editorFindings = prepared.findings.filter { finding in
                !finding.sourceRanges.contains { range in
                    NSIntersectionRange(range.nsRange, activeParagraph.nsRange).length > 0
                }
            }
        } else {
            editorFindings = prepared.findings
        }
        editor.setWritingDiagnostics(editorFindings, revision: editor.writingNativeRevision)
        margin?.replace(writingQuality: insights)
    }
    func waitForPublication() async { while let current = publication { await current.value } }
    func navigate(insightID: String, evidence: EvidenceAnchor, requests: ProjectEditorRequests) -> Bool {
        guard active, let margin, !margin.dismissedIDs.contains(insightID),
              let insight = margin.insights.first(where: { $0.id == insightID }), insight.kind == .writingQuality,
              insight.evidence.contains(where: { WritingDiagnosticsActions.sameEvidence($0, evidence) }),
              let findingID = findingIDs[insightID] else { return false }
        return actions.navigate(findingID: findingID, evidence: evidence, requests: requests)
    }
    @discardableResult
    func perform(insightID: String, action: MarginAction) throws -> WritingCorrectionResult? {
        guard active, let margin, !margin.dismissedIDs.contains(insightID),
              let insight = margin.insights.first(where: { $0.id == insightID }), insight.actions.contains(action),
              let findingID = findingIDs[insightID] else { throw WritingDiagnosticsActionError.stale }
        return try actions.perform(action, findingID: findingID)
    }
    func resetPublication() {
        epoch &+= 1; publication?.cancel(); publication = nil; clearQuietWindow(); findingIDs.removeAll(); insightCache.removeAll()
        if let editor = bridge?.editor { editor.setWritingDiagnostics([], revision: editor.writingNativeRevision) }
        margin?.replace(writingQuality: [])
    }
    func stop() {
        guard active else { return }
        active = false; observation?.cancel(); observation = nil
        spatialObservation?.cancel(); spatialObservation = nil
        settingsObservation?.cancel(); settingsObservation = nil
        selectionObservation?.cancel(); selectionObservation = nil
        resetPublication()
        bridge?.snapshotDidChange = nil; bridge?.commitDidChange = nil; bridge?.compositionDidChange = nil
        bridge?.editorDidChange = nil; bridge?.nativeLoadDidChange = nil
    }
}
