import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Compatibility UI receives only its legacy writer, never project mutation closures or assets.
struct LegacyWorkspaceView: View {
    @ObservedObject var workspace: LegacyWorkspaceController
    @ObservedObject var store: EntryStore
    @ObservedObject var completion: CompletionController
    @ObservedObject var settings: CompletionSettings
    let indexer: BackgroundIndexer
    let updateBody: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var palette = PaletteSettings.shared
    @AppStorage("purlory.sidebarVisible") private var sidebarVisible = true
    @State private var trafficLightMaxX: CGFloat?

    var body: some View {
        let theme = palette.theme(for: colorScheme)
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(store: store, completion: completion, theme: theme, indexer: indexer)
                    .frame(width: 260)
            }
            VStack(spacing: 0) {
                HStack {
                    Text("레거시 라이브러리 · \(store.activeEntry?.title ?? "문서")")
                    Spacer()
                    Menu("내보내기") {
                        Button("Markdown…") { exportMarkdown() }
                        Button("EPUB…") {
                            if let entry = store.activeEntry { EpubExporter.exportWithPanel(entry) }
                        }
                        Button("라이브러리 사본…") { exportLibraryCopy() }
                    }
                }
                .purloryUIFont(12)
                .padding(14)
                .padding(.leading, sidebarVisible ? 0 : 72)
                if let recovery = store.pendingRecovery {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("복구 모드 — 원본을 보존하고 별도 파일에 저장합니다.")
                        Text(recovery.sessionURL.path).textSelection(.enabled)
                        HStack {
                            Button("원본 위치 보기") {
                                NSWorkspace.shared.activateFileViewerSelecting([recovery.originalURL])
                            }
                            Button("복구 사본 내보내기…") { exportLibraryCopy() }
                        }
                    }
                    .purloryUIFont(12)
                    .padding(12)
                }
                theme.sepC.frame(height: 1)
                PurloryBlockEditor(
                    text: Binding(get: { store.activeEntry?.body ?? "" }, set: { updateBody($0) }),
                    controller: completion, theme: theme,
                    lineSpacing: CGFloat(settings.lineSpacing),
                    baseFontSize: CGFloat(settings.editorFontSize),
                    entryID: store.activeID, isEditable: !workspace.isTransitioning,
                    focusRequest: store.editorFocusRequests,
                    searchJump: store.searchJump,
                    onEditorWindowChange: { [weak workspace, weak store] editor in
                        guard let store, let editor = editor as? BlockTextView else { return }
                        workspace?.attachEditor(editor, to: store)
                    })
                    .focusedValue(\.hasPurloryEditor, true)
                HStack {
                    if case .failed(let message, _) = store.savePhase {
                        Text(message).foregroundStyle(.red)
                        Button("다시 저장") { store.retrySave() }
                    } else {
                        Text(store.isSaveInFlight ? "저장 중…" : "\(store.saveTargetFileName)")
                    }
                    Spacer()
                    if let notice = store.notice { Text(notice) }
                }
                .purloryUIFont(11)
                .padding(10)
            }
            .background(theme.editorSurfaceC)
        }
        .tint(theme.blueC)
        .environment(\.purloryWindowChromeLeadingInset,
            WindowChromeGeometry.leadingContentInset(trafficLightMaxX: trafficLightMaxX))
        .background(WindowChromeProbe(trafficLightMaxX: $trafficLightMaxX))
    }

    /// All legacy providers are weak and explicitly clear the project inference path.
    static func connect(store: EntryStore, completion: CompletionController, indexer: BackgroundIndexer) {
        completion.prepareForProjectTransition()
        completion.projectDocumentProvider = nil
        completion.documentContextProvider = { [weak store] in store?.activeDocumentContext }
        completion.knowledgeProvider = { [weak store, weak indexer] in
            guard let store, indexer?.snapshot?.entryID == store.activeID else { return nil }
            return indexer?.snapshot
        }
        completion.onRecordConversation = { [weak store] record in
            guard let store else { return }
            store.recordConversation(record, in: store.activeID)
        }
        completion.recordedConversationHashesProvider = { [weak store] in
            Set(store?.activeEntry?.recordedConversations?.map(\.contentHash) ?? [])
        }
        indexer.attachLegacy(store: store)
        ContentView.connectGhostContext(completion: completion, indexer: indexer)
        var observedID = store.activeID
        store.documentDidChange = { [weak store, weak completion, weak indexer] id in
            guard store != nil else { return }
            if observedID != id {
                observedID = id
                completion?.prepareForProjectTransition()
                completion?.noteDocumentSwitch(to: id)
                indexer?.noteScopeChange(entryID: id)
            } else {
                indexer?.noteChange(entryID: id)
            }
        }
        store.narrativeOverridesDidChange = { [weak indexer] id in indexer?.rehydrate(entryID: id) }
        completion.noteDocumentSwitch(to: store.activeID)
        indexer.noteScopeChange(entryID: store.activeID)
    }

    private func exportMarkdown() {
        guard let entry = store.activeEntry else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = entry.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = try MarkdownExporter.export(entry, to: url)
            if !report.missingSources.isEmpty {
                showError("일부 이미지 없이 내보냈습니다: \(report.missingSources.joined(separator: ", "))")
            }
        } catch { showError(error.localizedDescription) }
    }

    private func exportLibraryCopy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "legacy-library-copy.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.exportSessionCopy(to: url) { showError("라이브러리 사본을 저장하지 못했습니다.") }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
