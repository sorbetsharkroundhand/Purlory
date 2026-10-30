import AppKit
import SwiftUI

struct ProjectNavigatorView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var editorRequests: ProjectEditorRequests
    let theme: PurloryTheme
    let onClose: () -> Void
    var spatial: SpatialWorkspaceController? = nil
    var completion: CompletionController? = nil
    @StateObject private var navigator = ProjectNavigatorController()
    @State private var searchText = ""
    @State private var searchResults: [ProjectSearchResult] = []
    @State private var editing: ProjectNavigationNode?
    @State private var editingProject: WritingProjectID?
    @State private var editingEpoch: UInt64 = 0
    @State private var draftTitle = ""
    @State private var hovered: ProjectNavigationNode?
    @State private var showingTrash = false
    @AppStorage("purlory.navigator.sortMode") private var sortModeRaw = NavigatorSortMode.titleAscending.rawValue
    private var sortMode: NavigatorSortMode {
        get { NavigatorSortMode(rawValue: sortModeRaw) ?? .titleAscending }
        nonmutating set { sortModeRaw = newValue.rawValue }
    }
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var organization: ProjectNavigation { navigator.organization }
    private var trashCount: Int { (session.activeProject?.trashedDocumentIDs.count ?? 0) + organization.trashBundles.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searchVisible || spatial == nil { searchField }
            if let error = session.lastErrorMessage {
                Text(error).purloryUIFont(11).foregroundStyle(theme.dangerC)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if isSearching { searchRows }
                    else if let project = session.activeProject {
                        let rows = organization.rows(in: project, collapsed: navigator.collapsed, sortMode: sortMode)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            let nextDepth = index + 1 < rows.count ? rows[index + 1].depth : 0
                            VStack(alignment: .leading, spacing: 0) {
                                switch row.node {
                                case .folder(let id):
                                    if let folder = organization.folders.first(where: { $0.id == id }) { folderRow(folder, depth: row.depth) }
                                case .document(let id):
                                    if let document = session.document(id) { documentRow(document, depth: row.depth) }
                                }
                                if row.depth > 0 && nextDepth < row.depth {
                                    let parents = organization.ancestors(of: row.node)
                                    folderBoundaryDivider(depth: nextDepth, parent: nextDepth > 0 ? parents[nextDepth - 1] : nil)
                                }
                            }
                        }
                        ProjectNavigatorDragRegion(node: nil, owner: navigator).frame(height: 44)
                            .overlay(alignment: .top) { if navigator.dropIndicator == .root { theme.blueC.frame(height: 2) } }
                    }
                }.padding(6)
            }
            .background { ProjectNavigatorDragRegion(node: nil, owner: navigator) }
            footer
        }
        .background(theme.cardSurfaceC)
        .accessibilityElement(children: .contain).accessibilityIdentifier("purlory.navigator").accessibilityLabel("문서 탐색기")
        .onAppear(perform: configure)
        .onChange(of: session.activeProject?.userData[ProjectNavigation.key]) { _, _ in configure() }
        .onChange(of: session.activeProject?.id) { _, _ in cancelRename(); searchText = ""; configure() }
        .onDisappear { navigator.cancelDrag() }
        .task(id: "\(session.runtimeIdentity?.generation ?? 0):\(searchText)") {
            guard isSearching, let project = session.activeProject else { searchResults = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let query = searchText
            let results = await Task.detached(priority: .userInitiated) { ProjectSearch.results(query: query, in: project) }.value
            if !Task.isCancelled { searchResults = results }
        }
        .task(id: editorRequests.searchFocusRequest) {
            guard editorRequests.consumeSearchFocusRequest() else { return }
            showSearch()
        }
        .onChange(of: editorRequests.renameRequest) { _, _ in
            if let document = session.selectedDocument { startRename(.document(document.id), title: document.title) }
        }
        .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
        .sheet(isPresented: $showingTrash) { ProjectNavigatorTrashView(session: session, navigator: navigator, theme: theme) }
    }
    private func configure() { navigator.configure(session: session, requests: editorRequests, completion: completion) }
    private func showSearch() {
        searchVisible = true
        DispatchQueue.main.async { searchFocused = true }
    }
    private var header: some View {
        SpatialTileHeader(tile: .navigator, title: "문서", theme: theme, actions: [
            SpatialHeaderAction(id: "purlory.navigator.new", label: "새 원고·메모·폴더", symbol: "plus", perform: creationMenu),
            SpatialHeaderAction(id: "purlory.navigator.sort", label: "정렬: \(sortMode.shortLabel)", symbol: "arrow.up.arrow.down", perform: sortMenu),
            SpatialHeaderAction(id: "purlory.navigator.search-toggle", label: "문서 검색", symbol: "magnifyingglass", perform: showSearch),
            SpatialHeaderAction(id: "purlory.navigator.close", label: "파일 목록 숨기기", symbol: "xmark", perform: onClose)
        ]).frame(height: 32)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(session.recentProjects) { recent in
                    Button(recent.title) {
                        Task { do { try await session.activateProject(id: recent.id); editorRequests.focusEditor() } catch { session.reportError(error) } }
                    }
                }
            } label: {
                Text(session.activeProject?.title ?? "프로젝트").lineLimit(1).truncationMode(.middle).purloryUIFont(10.5)
            }.menuStyle(.borderlessButton).accessibilityLabel("최근 프로젝트")
            Spacer(minLength: 2)
            Button { showingTrash = true } label: {
                Image(systemName: "trash").frame(width: 26, height: 26)
            }.buttonStyle(.plain).help("휴지통 · \(trashCount)개").accessibilityLabel("휴지통")
                .accessibilityIdentifier("purlory.navigator.trash")
        }.foregroundStyle(theme.ink2C).padding(.horizontal, 10).padding(.bottom, 5)
    }
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.workspaceMutedC)
            TextField("프로젝트 검색", text: $searchText).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("purlory.navigator.search")
            Button { searchText = ""; searchVisible = false; editorRequests.focusEditor() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel("검색 닫기")
        }.purloryUIFont(12).padding(8).background(theme.chipC, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 8).padding(.bottom, 5)
    }
    @ViewBuilder private var searchRows: some View {
        if searchResults.isEmpty { Text("일치하는 문서가 없어요").purloryUIFont(11).foregroundStyle(theme.ink2C).padding(8) }
        ForEach(searchResults) { result in
            Button { editorRequests.jump(to: result, in: session) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).purloryUIFont(12, .medium).foregroundStyle(theme.inkC).lineLimit(1)
                    if let snippet = result.snippet { Text(snippet).purloryUIFont(11).foregroundStyle(theme.ink2C).lineLimit(2) }
                    if let folder = organization.documentFolders[result.documentID] {
                        Text(organization.path(folder)).purloryUIFont(9.5).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
    private func folderRow(_ folder: ProjectFolder, depth: Int) -> some View {
        let node = ProjectNavigationNode.folder(folder.id), expanded = !navigator.collapsed.contains(folder.id)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 10)
            Image(systemName: expanded ? "folder.fill" : "folder").font(.system(size: 12))
            if editing == node { renameField("폴더 이름") }
            else { Text(folder.name).purloryUIFont(11.5, .medium).lineLimit(1) }
            if completion?.namingFolderIDs.contains(folder.id) == true {
                ProgressView().controlSize(.mini).scaleEffect(0.65).help("폴더 이름 짓는 중…")
            }
            Spacer(minLength: 3)
            if editing != node {
                Button { navigator.createDocument(.manuscript, in: folder.id) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("폴더에 새 원고").accessibilityLabel("폴더에 새 원고")
                    .opacity(hovered == node ? 1 : 0).allowsHitTesting(hovered == node)
            }
        }
        .foregroundStyle(theme.ink2C).padding(.leading, CGFloat(depth) * 14 + 8).padding(.trailing, 5).frame(height: 34)
        .background(rowBackground(node, selected: false))
        .overlay(alignment: .leading) { folderGuide(depth: depth) }
        .overlay { dropDecoration(node) }
        .overlay {
            if editing != node {
                ProjectNavigatorDragRegion(node: node, owner: navigator,
                    onClick: { navigator.toggle(folder.id) }, onDoubleClick: { startRename(node, title: folder.name) }).padding(.trailing, 28)
            }
        }
        .onHover { hovered = $0 ? node : nil }
        .onDisappear { completion?.cancelFolderName(for: folder.id) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("purlory.folder.\(folder.id.uuidString)")
        .accessibilityLabel("폴더 \(folder.name)").accessibilityValue(expanded ? "펼침" : "접힘")
        .accessibilityAction { navigator.toggle(folder.id) }
        .accessibilityAction(named: Text("이름 바꾸기")) { startRename(node, title: folder.name) }
        .contextMenu {
            Button("새 원고") { navigator.createDocument(.manuscript, in: folder.id) }
            Button("새 메모") { navigator.createDocument(.note, in: folder.id) }
            Button("새 참고자료") { navigator.createDocument(.reference, in: folder.id) }
            Button("새 하위 폴더") { newFolder(in: folder.id) }
            Divider()
            Button("이름 바꾸기") { startRename(node, title: folder.name) }
            moveMenu(node)
            sortOptionsMenu
            Button("휴지통으로 이동", role: .destructive) { navigator.perform(.trash(node)) }
        }
    }
    private var sortOptionsMenu: some View {
        Menu("정렬 기준") {
            ForEach(NavigatorSortMode.allCases) { mode in
                Button {
                    sortMode = mode
                } label: {
                    HStack {
                        Text(mode.label)
                        if sortMode == mode { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }
    private func documentRow(_ document: WritingDocument, depth: Int) -> some View {
        let node = ProjectNavigationNode.document(document.id), selected = session.selectedDocumentID == document.id
        let open = spatial?.layout.contains(.document(document.id)) == true
        return HStack(spacing: 7) {
            Image(systemName: document.kind.navigatorSymbol).font(.system(size: 11))
                .foregroundStyle(selected ? theme.blueC : theme.workspaceMutedC)
            if editing == node { renameField("문서 이름") }
            else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title).purloryUIFont(11.5, selected ? .medium : .regular).foregroundStyle(selected ? theme.inkC : theme.ink2C).lineLimit(1)
                    if hovered == node, let date = organization.createdDates[document.id] {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).purloryUIFont(9).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 2)
            if editing != node {
                if open, spatial?.layout.openDocuments.count == 1 {
                    Circle().fill(theme.blueC).frame(width: 5, height: 5).accessibilityLabel("열림")
                } else if open {
                    WorkspaceActionButton(identifier: "purlory.navigator.tile.\(document.id.rawValue.uuidString)", label: "이 문서 창 닫기", symbol: "xmark", theme: theme) {
                        _ = spatial?.close(.document(document.id)); editorRequests.focusEditor()
                    }.frame(width: 22, height: 24).opacity(hovered == node ? 1 : 0)
                }
            }
        }.padding(.leading, CGFloat(depth) * 14 + 10).padding(.trailing, 8).frame(height: 38)
        .background(rowBackground(node, selected: selected))
        .overlay(alignment: .leading) { folderGuide(depth: depth) }
        .overlay { dropDecoration(node) }
        .overlay {
            if editing != node {
                ProjectNavigatorDragRegion(node: node, owner: navigator, onClick: { openDocument(document.id) },
                    onDoubleClick: { startRename(node, title: document.title) }).padding(.trailing, 28)
            }
        }
        .onHover { hovered = $0 ? node : nil }
        .accessibilityElement(children: editing == node ? .contain : .combine)
        .accessibilityIdentifier("purlory.document.\(document.id.rawValue.uuidString)").accessibilityLabel(document.title)
        .accessibilityAction { openDocument(document.id) }
        .accessibilityAction(named: Text("이름 바꾸기")) { startRename(node, title: document.title) }
        .contextMenu {
            Button("열기") { openDocument(document.id) }
            Button("이름 바꾸기") { startRename(node, title: document.title) }
            Button("작성일 바꾸기…") { ProjectNavigatorActions.changeDate(document.id, navigator: navigator) }
            moveMenu(node)
            sortOptionsMenu
            Menu("문서 종류") {
                ForEach([WritingDocument.Kind.manuscript, .note, .reference], id: \.rawValue) { kind in
                    Button { navigator.perform(.kind(document.id, kind)) } label: {
                        Label(kind.navigatorTitle, systemImage: kind == document.kind ? "checkmark" : kind.navigatorSymbol)
                    }
                }
            }
            Divider()
            Button("Markdown으로 내보내기…") { ProjectNavigatorActions.export(document, session: session, epub: false) }
            Button("EPUB으로 내보내기…") { ProjectNavigatorActions.export(document, session: session, epub: true) }
            Divider()
            Button("휴지통으로 이동", role: .destructive) { navigator.perform(.trash(node)) }
        }
    }
    @ViewBuilder private func folderGuide(depth: Int) -> some View {
        if depth > 0 {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    theme.sepStrongC
                        .frame(width: 1)
                        .padding(.leading, 13)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .allowsHitTesting(false)
        }
    }
    private func folderBoundaryDivider(depth: Int, parent: UUID?) -> some View {
        let destination: ProjectNavigationDrop = parent.map { .inside(.folder($0)) } ?? .root
        return HStack(spacing: 0) {
            (navigator.dropIndicator == destination ? theme.blueC : theme.sepStrongC).frame(height: 1)
        }
        .padding(.leading, CGFloat(depth) * 14 + 10)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityIdentifier("purlory.navigator.folder-divider")
        .background(WorkspaceAccessibilityProbe(identifier: "purlory.navigator.folder-divider", label: "폴더 영역 구분선", role: .splitter))
        .background { ProjectNavigatorDragRegion(node: nil, owner: navigator, backgroundDrop: destination) }
    }
    private func rowBackground(_ node: ProjectNavigationNode, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7).fill(selected || navigator.dropIndicator == .inside(node) ? theme.activeBgC : (hovered == node ? theme.hoverC : .clear))
    }
    @ViewBuilder private func dropDecoration(_ node: ProjectNavigationNode) -> some View {
        if navigator.dropIndicator == .inside(node) { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.blueC, lineWidth: 1) }
        if navigator.dropIndicator == .before(node) { VStack { theme.blueC.frame(height: 2); Spacer(minLength: 0) } }
        if navigator.dropIndicator == .after(node) { VStack { Spacer(minLength: 0); theme.blueC.frame(height: 2) } }
    }
    private func moveMenu(_ node: ProjectNavigationNode) -> some View {
        Menu("이동") {
            Button("최상위로 이동") { navigator.perform(.drop(node, .root)) }.disabled(organization.parent(of: node) == nil)
            ForEach(organization.folders.filter { !organization.trashedFolders.contains($0.id) }) { folder in
                let excluded: Bool = if case .folder(let id) = node { organization.descendants(of: id).contains(folder.id) } else { false }
                Button(organization.path(folder.id)) { navigator.perform(.drop(node, .inside(.folder(folder.id)))) }
                    .disabled(excluded || organization.parent(of: node) == folder.id)
            }
        }
    }
    private func renameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $draftTitle).textFieldStyle(.plain).purloryUIFont(11.5).focused($renameFocused)
            .accessibilityIdentifier("purlory.navigator.rename").onSubmit(commitRename).onExitCommand(perform: cancelRename)
    }
    private func startRename(_ node: ProjectNavigationNode, title: String) {
        editing = node; editingProject = session.activeProject?.id; editingEpoch = session.activationEpoch; draftTitle = title
        DispatchQueue.main.async { renameFocused = true }
    }
    private func commitRename() {
        guard let node = editing, let project = editingProject else { return }
        editing = nil
        guard session.activeProject?.id == project, session.activationEpoch == editingEpoch else { return }
        let name = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch node {
        case .document(let id): session.renameDocument(.init(projectID: project, documentID: id), to: name)
        case .folder(let id): navigator.perform(.renameFolder(id, name), project: project, epoch: editingEpoch)
        }
    }
    private func cancelRename() { editing = nil; editingProject = nil; renameFocused = false }
    private func openDocument(_ id: WritingDocumentID) {
        if let spatial { spatial.open(id) } else { session.selectDocument(id) }
        editorRequests.focusEditor()
    }
    private func newFolder(in parent: UUID? = nil) {
        if let id = navigator.createFolder(in: parent) { startRename(.folder(id), title: "새 폴더") }
    }
    private func creationMenu() {
        let menu = NSMenu()
        for kind in [WritingDocument.Kind.manuscript, .note, .reference] {
            menu.addItem(NavigatorMenuAction.item("새 " + kind.navigatorTitle, symbol: kind.navigatorSymbol) { navigator.createDocument(kind) })
        }
        menu.addItem(.separator())
        menu.addItem(NavigatorMenuAction.item("새 폴더", symbol: "folder.badge.plus") { newFolder() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    private func sortMenu() {
        let menu = NSMenu()
        for mode in NavigatorSortMode.allCases {
            let item = NavigatorMenuAction.item(mode.label, symbol: nil) {
                self.sortMode = mode
            }
            item.state = sortMode == mode ? NSControl.StateValue.on : NSControl.StateValue.off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

extension WritingDocument.Kind {
    var navigatorTitle: String { switch self { case .manuscript: "원고"; case .note: "메모"; case .reference: "참고자료" } }
    var navigatorSymbol: String { switch self { case .manuscript: "doc.text"; case .note: "note.text"; case .reference: "doc.richtext" } }
}

private final class NavigatorMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
    static func item(_ title: String, symbol: String?, action: @escaping () -> Void) -> NSMenuItem {
        let target = NavigatorMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(invoke), keyEquivalent: "")
        item.target = target; item.representedObject = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}
