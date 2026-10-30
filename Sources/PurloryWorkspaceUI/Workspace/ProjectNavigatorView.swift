import SwiftUI

/// Transient editor requests shared by the project workspace and menu commands. Manuscript
/// state remains exclusively owned by `ProjectSession`.
@MainActor
public final class ProjectEditorRequests: ObservableObject {
    @Published public private(set) var editorFocusRequest = 0
    @Published public private(set) var searchFocusRequest = 0
    @Published public private(set) var renameRequest = 0
    @Published public internal(set) var searchJump: EditorSearchJump?
    @Published internal var sourceReturnPoint: SourceWritingPosition?
    @Published internal var sourceNavigationError: String?
    weak var nativeEditor: BlockTextView?
    var nativeEditorKey: ProjectDocumentKey?
    var askSupport: AskPurlorySupport?
    var judgeSupport: ContinuityJudgeSupport?
    weak var spatialWorkspace: SpatialWorkspaceController?
    weak var pouch: WorkspacePouchController?
    weak var registeredSession: ProjectSession?
    var pendingSpatialJump: (jump: EditorSearchJump, identity: ProjectRuntimeIdentity)?
    private final class EditorReference { weak var editor: BlockTextView?; init(_ editor: BlockTextView) { self.editor = editor } }
    private var editors: [ProjectDocumentKey: EditorReference] = [:]
    var workspaceHover: ((BlockTextView, ProjectDocumentKey, Int) -> Void)?
    var workspaceHoverEnd: (() -> Void)?
    var workspacePolish: ((BlockTextView) -> Void)?
    func register(_ editor: BlockTextView, for key: ProjectDocumentKey, session: ProjectSession? = nil) {
        editors = editors.filter { $0.value.editor != nil }
        editors[key] = EditorReference(editor)
        if let session {
            registeredSession = session
            installSpatialInteraction(editor, key: key, session: session)
            scheduleSpatialNavigation()
        }
    }
    func editor(for key: ProjectDocumentKey) -> BlockTextView? { editors[key]?.editor }
    var registeredEditors: [ProjectDocumentKey: BlockTextView] { editors.compactMapValues(\.editor) }
    func installSpatialInteraction(_ editor: BlockTextView, key: ProjectDocumentKey, session: ProjectSession) {
        guard let spatialWorkspace, key.projectID == session.activeProject?.id else { return }
        editor.workspaceFind = { [weak self, weak editor] action in
            guard let self, let spatial = self.spatialWorkspace else { return false }
            if action == .showFindInterface {
                var query: String?
                if let editor, !editor.hasMarkedText(), editor.selectedRange().length > 0,
                   editor.selectedRange().length <= 500 {
                    query = (editor.string as NSString).substring(with: editor.selectedRange())
                }
                spatial.openSearch(scope: .document, query: query)
            } else if action == .nextMatch || action == .previousMatch {
                if let advance = spatial.advanceSearch { advance(action == .nextMatch ? 1 : -1) }
                else { spatial.openSearch(scope: .document) }
            } else { return false }
            return true
        }
        if let existing = editor.workspaceInteraction as? WorkspaceEditorInteraction, existing.key == key { return }
        editor.workspaceInteraction = WorkspaceEditorInteraction(editor: editor, key: key,
            session: session, requests: self, model: spatialWorkspace)
        editor.updateTrackingAreas()
    }
    private var consumedSearchFocusRequest = 0

    public init() {}

    public func focusEditor() { editorFocusRequest += 1 }
    public func focusSearch() { searchFocusRequest += 1 }
    func consumeSearchFocusRequest() -> Bool {
        guard searchFocusRequest != consumedSearchFocusRequest else { return false }
        consumedSearchFocusRequest = searchFocusRequest
        return true
    }

    public func beginRename() { renameRequest += 1 }

    public func jump(to result: ProjectSearchResult, in session: ProjectSession) {
        guard let project = session.activeProject,
            project.id == result.projectID,
            !project.trashedDocumentIDs.contains(result.documentID),
            project.documents.contains(where: { $0.id == result.documentID })
        else { return }
        session.selectDocument(result.documentID)
        issueJump(documentID: result.documentID, query: result.query)
    }

    public func issueJump(documentID: WritingDocumentID, query: String) {
        searchJump = EditorSearchJump(
            documentID: documentID,
            query: query,
            sequence: (searchJump?.sequence ?? 0) + 1)
        if let spatialWorkspace, let session = registeredSession {
            spatialWorkspace.open(documentID)
            if let identity = session.runtimeIdentity, identity.key.documentID == documentID, let searchJump {
                pendingSpatialJump = (searchJump, identity); scheduleSpatialNavigation()
            }
        }
        focusEditor()
    }
}

import AppKit
import UniformTypeIdentifiers

struct ProjectNavigatorDragRegion: NSViewRepresentable {
    let node: ProjectNavigationNode?
    let owner: ProjectNavigatorController
    var onClick: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var backgroundDrop: ProjectNavigationDrop? = nil

    func makeNSView(context: Context) -> ProjectNavigatorRowDragView {
        ProjectNavigatorRowDragView()
    }

    func updateNSView(_ view: ProjectNavigatorRowDragView, context: Context) {
        view.node = node
        view.owner = owner
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.backgroundDrop = backgroundDrop
        switch node {
        case .document(let id):
            view.setAccessibilityIdentifier("purlory.navigator.drag.\(id.rawValue.uuidString)")
            view.toolTip = "위·아래에 놓아 순서 변경 · 가운데에 놓아 새 폴더로 묶기 · 폴더 영역 밖에 놓아 꺼내기 · 작업 공간에 놓아 열기"
        case .folder(let id):
            view.setAccessibilityIdentifier("purlory.navigator.drag.folder.\(id.uuidString)")
            view.toolTip = "클릭해 펼치기 · 더블클릭해 이름 바꾸기 · 끌어서 순서 변경"
        case nil:
            view.setAccessibilityIdentifier("purlory.navigator.drag.root")
            view.toolTip = nil
        }
        if backgroundDrop != nil { view.setAccessibilityIdentifier("purlory.navigator.folder-boundary") }
        view.setAccessibilityElement(false)
    }
}

final class ProjectNavigatorRowDragView: NSView {
    var node: ProjectNavigationNode?
    var backgroundDrop: ProjectNavigationDrop?
    weak var owner: ProjectNavigatorController?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let node else { super.mouseDown(with: event); return }
        if event.clickCount >= 2, let onDoubleClick {
            enclosingSpatialCanvas?.cancelInteraction()
            owner?.cancelDrag()
            onDoubleClick()
            return
        }
        if case .document(let id) = node, let canvas = enclosingSpatialCanvas {
            canvas.beginPanelDrag(.document(id), event: event, fromNavigator: true)
        } else {
            owner?.beginDrag(node, event: event, from: self) { [weak self] in
                self?.onClick?()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if case .document = node, let canvas = enclosingSpatialCanvas {
            canvas.continuePanelDrag(event)
        } else {
            owner?.continueDrag(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .document = node, let canvas = enclosingSpatialCanvas {
            let moved = canvas.model?.isDragging == true
            canvas.finishPanelDrag(event)
            if !moved { onClick?() }
        } else {
            owner?.finishDrag(event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        enclosingSpatialCanvas?.cancelInteraction()
        owner?.cancelDrag()
    }

    override func resetCursorRects() {
        if node != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

@MainActor
enum ProjectNavigatorActions {
    static func changeDate(_ documentID: WritingDocumentID, navigator: ProjectNavigatorController) {
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = navigator.organization.createdDates[documentID] ?? Date()

        let alert = NSAlert()
        alert.messageText = "작성일 바꾸기"
        alert.informativeText = "어제 일을 오늘 적었다면 날짜를 맞춰 두세요."
        alert.accessoryView = picker
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = navigator.perform(.date(documentID, picker.dateValue))
    }

    static func export(_ document: WritingDocument, session: ProjectSession, epub: Bool) {
        guard let assets = session.assetCatalog,
              assets.projectID == session.activeProject?.id else { return }
        let panel = NSSavePanel()
        let ext = epub ? "epub" : "md"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        let title = document.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = (title.isEmpty ? "Untitled" : title) + "." + ext
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let author = CompletionSettings.shared.authorName
        Task {
            do {
                if epub {
                    try await EpubExporter.exportAsync(document, assets: assets, to: destination, author: author)
                } else {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try MarkdownExporter.export(document, assets: assets, to: destination)
                    }.value
                    if !report.missingSources.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "일부 이미지 없이 내보냈습니다"
                        alert.informativeText = report.missingSources.joined(separator: "\n")
                        alert.runModal()
                    }
                }
            } catch is CancellationError {} catch {
                session.reportError(error)
            }
        }
    }
}

struct ProjectNavigatorTrashView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var navigator: ProjectNavigatorController
    let theme: PurloryTheme
    @Environment(\.dismiss) private var dismiss

    private var trashedRootFolders: [ProjectFolder] {
        navigator.organization.folders.filter { navigator.organization.trashBundles[$0.id] != nil }
    }

    private var bundledDocuments: Set<WritingDocumentID> {
        navigator.organization.trashBundles.values.reduce(into: Set<WritingDocumentID>()) { $0.formUnion($1.documents) }
    }

    private var standaloneTrashedDocuments: [WritingDocument] {
        guard let project = session.activeProject else { return [] }
        return project.documents.filter {
            project.trashedDocumentIDs.contains($0.id) && !bundledDocuments.contains($0.id)
        }
    }

    private var allTrashedDocuments: [WritingDocument] {
        guard let project = session.activeProject else { return [] }
        return project.documents.filter { project.trashedDocumentIDs.contains($0.id) }
    }

    private var isEmpty: Bool {
        trashedRootFolders.isEmpty && allTrashedDocuments.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("휴지통").purloryUIFont(13, .semibold).foregroundStyle(theme.inkC)
                Spacer()
                if !isEmpty {
                    Button("휴지통 비우기", role: .destructive) { confirmEmptyTrash() }
                        .buttonStyle(.borderless)
                        .purloryUIFont(11, .medium)
                        .foregroundStyle(theme.dangerC)
                        .accessibilityIdentifier("purlory.navigator.trash.empty")
                }
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
                    .purloryUIFont(11, .medium)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(theme.workspaceMutedC)
                    Text("휴지통이 비어 있습니다").purloryUIFont(12).foregroundStyle(theme.ink2C)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(trashedRootFolders) { folder in
                            folderTrashRow(folder)
                        }
                        ForEach(allTrashedDocuments) { document in
                            documentTrashRow(document)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 400, height: 340)
        .background(theme.cardSurfaceC)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purlory.navigator.trash.sheet")
    }

    private func folderTrashRow(_ folder: ProjectFolder) -> some View {
        let count = navigator.organization.trashBundles[folder.id]?.documents.count ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(theme.ink2C)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).purloryUIFont(12, .medium).foregroundStyle(theme.inkC).lineLimit(1)
                Text("문서 \(count)개 포함").purloryUIFont(10).foregroundStyle(theme.workspaceMutedC)
            }
            Spacer(minLength: 4)
            Button("복원") { _ = navigator.perform(.restore(.folder(folder.id))) }
                .buttonStyle(.borderless)
                .purloryUIFont(11, .medium)
                .accessibilityIdentifier("purlory.navigator.trash.restore.folder.\(folder.id.uuidString)")
            Button("영구 삭제", role: .destructive) {
                confirmPurge(title: "'\(folder.name)' 폴더를 영구 삭제할까요?", node: .folder(folder.id))
            }
            .buttonStyle(.borderless)
            .purloryUIFont(11)
            .foregroundStyle(theme.dangerC)
            .accessibilityIdentifier("purlory.navigator.trash.purge.folder.\(folder.id.uuidString)")
        }
        .padding(8)
        .background(theme.chipC, in: RoundedRectangle(cornerRadius: 8))
    }

    private func documentTrashRow(_ document: WritingDocument) -> some View {
        HStack(spacing: 8) {
            Image(systemName: document.kind.navigatorSymbol).font(.system(size: 12)).foregroundStyle(theme.ink2C)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title).purloryUIFont(12, .medium).foregroundStyle(theme.inkC).lineLimit(1)
                if let folderID = navigator.organization.documentFolders[document.id] {
                    Text(navigator.organization.path(folderID)).purloryUIFont(10).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button("복원") { _ = navigator.perform(.restore(.document(document.id))) }
                .buttonStyle(.borderless)
                .purloryUIFont(11, .medium)
                .accessibilityIdentifier("purlory.navigator.trash.restore.document.\(document.id.rawValue.uuidString)")
            Button("영구 삭제", role: .destructive) {
                confirmPurge(title: "'\(document.title)' 문서를 영구 삭제할까요?", node: .document(document.id))
            }
            .buttonStyle(.borderless)
            .purloryUIFont(11)
            .foregroundStyle(theme.dangerC)
            .accessibilityIdentifier("purlory.navigator.trash.purge.document.\(document.id.rawValue.uuidString)")
        }
        .padding(8)
        .background(theme.chipC, in: RoundedRectangle(cornerRadius: 8))
    }

    private func confirmPurge(title: String, node: ProjectNavigationNode) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "영구 삭제한 항목은 되돌릴 수 없습니다."
        alert.addButton(withTitle: "영구 삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = navigator.perform(.purge(node), undo: false)
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "휴지통을 비울까요?"
        alert.informativeText = "휴지통에 있는 모든 폴더와 문서가 영구적으로 삭제됩니다."
        alert.addButton(withTitle: "비우기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for folder in trashedRootFolders {
            _ = navigator.perform(.purge(.folder(folder.id)), undo: false)
        }
        for document in standaloneTrashedDocuments {
            _ = navigator.perform(.purge(.document(document.id)), undo: false)
        }
    }
}
