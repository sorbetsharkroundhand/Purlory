import Combine
import Foundation

/// One workspace consumer of prepared diagnostics. Surface opening has no execution role.
@MainActor
final class WritingDiagnosticsWorkspaceBinding {
    private let controller: WritingDiagnosticsController
    private weak var session: ProjectSession?
    private weak var bridge: ProjectEditorBridge?
    private weak var margin: LivingMarginModel?
    private var observation: AnyCancellable?
    private var publication: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var active = true
    private var findingIDs: [String: String] = [:]
    private let actions: WritingDiagnosticsActions

    init(controller: WritingDiagnosticsController, session: ProjectSession, bridge: ProjectEditorBridge, margin: LivingMarginModel) {
        self.controller = controller; self.session = session; self.bridge = bridge; self.margin = margin
        actions = WritingDiagnosticsActions(controller: controller, editor: { [weak bridge] in bridge?.editor },
            currentSnapshot: { [weak session] in session?.selectedDocumentSnapshot }, session: session)
    }
    func matches(session: ProjectSession, bridge: ProjectEditorBridge, margin: LivingMarginModel) -> Bool {
        self.session === session && self.bridge === bridge && self.margin === margin
    }
    func connect() {
        guard let bridge else { return }
        bridge.snapshotDidChange = { [weak controller] in controller?.noteSnapshot($0) }
        bridge.commitDidChange = { [weak controller] in controller?.noteEditorCommit($0, snapshot: $1) }
        bridge.compositionDidChange = { [weak controller] in controller?.setMarkedRange($0) }
        bridge.editorDidChange = { [weak controller] _ in controller?.suspendNativeAuthority() }
        bridge.nativeLoadDidChange = { [weak controller] in controller?.noteNativeLoad($0) }
        observation = controller.$state.sink { [weak self] _ in self?.schedulePublication() }
        refresh()
    }
    func refresh() {
        if let snapshot = session?.selectedDocumentSnapshot {
            controller.noteSnapshot(snapshot)
            if let editor = bridge?.editor, !controller.isNativeBound(to: snapshot.identity, revision: editor.writingNativeRevision) {
                bridge?.replayPreparedAuthority(baseIdentity: controller.nativeAuthorityBase)
            } else { bridge?.noteSnapshot(snapshot) }
        }
        schedulePublication()
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
    private func publish() {
        guard let snapshot = session?.selectedDocumentSnapshot, let editor = bridge?.editor,
              editor.writingRuntimeIdentityProvider?() == snapshot.identity else {
            findingIDs.removeAll(); margin?.replace(writingQuality: []); return
        }
        var prepared = controller.state
        prepared.findings = prepared.findings.filter { controller.isCurrent($0.stamp) && $0.stamp.runtime == snapshot.identity }
        let insights = WritingDiagnosticsPresentation.insights(from: prepared)
        findingIDs = Dictionary(uniqueKeysWithValues: prepared.findings.map { ("writing-quality:" + $0.id, $0.id) })
        editor.setWritingDiagnostics(prepared.findings, revision: editor.writingNativeRevision)
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
        epoch &+= 1; publication?.cancel(); publication = nil; findingIDs.removeAll()
        if let editor = bridge?.editor { editor.setWritingDiagnostics([], revision: editor.writingNativeRevision) }
        margin?.replace(writingQuality: [])
    }
    func stop() {
        guard active else { return }
        active = false; observation?.cancel(); observation = nil; resetPublication()
        bridge?.snapshotDidChange = nil; bridge?.commitDidChange = nil; bridge?.compositionDidChange = nil
        bridge?.editorDidChange = nil; bridge?.nativeLoadDidChange = nil
    }
}
