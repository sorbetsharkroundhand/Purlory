import AppKit
import SwiftUI

enum WorkspaceSearchScope: String, CaseIterable, Sendable {
    case document = "현재 문서", project = "프로젝트", commands = "도구·명령"
}

struct WorkspaceSearchRequest: Equatable {
    var sequence = 0
    var scope: WorkspaceSearchScope = .project
    var query: String?
    var documentID: WritingDocumentID?
}

struct WorkspaceSearchResult: Identifiable, Sendable {
    enum Action: Sendable {
        case command(WorkspaceCommandItem.Action)
        case native(ProjectDocumentKey, NSRange, String)
    }
    let id: String
    let title: String
    let detail: String
    let action: Action
}

/// One persistent, explicit search surface. No inference or disk work is involved.
@MainActor final class WorkspaceSearchModel: ObservableObject {
    @Published var query = ""
    @Published var scope: WorkspaceSearchScope = .project
    @Published private(set) var results: [WorkspaceSearchResult] = []
    @Published var selection = 0
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    var documentID: WritingDocumentID?
    private var task: Task<Void, Never>?
    private var ticket = 0

    func cancel() { ticket += 1; task?.cancel(); task = nil; searching = false }

    func update(session: ProjectSession, requests: ProjectEditorRequests, spatial: SpatialWorkspaceController) {
        cancel(); results = []; selection = 0; message = nil
        guard let project = session.activeProject, let identity = session.runtimeIdentity else { return }
        let origin = documentID.flatMap { session.document($0) != nil ? $0 : nil } ?? identity.key.documentID
        documentID = origin
        let key = ProjectDocumentKey(projectID: project.id, documentID: origin)
        let native = requests.editor(for: key)?.string
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines), scope = scope
        guard query.utf16.count <= 500 else { message = "검색어를 조금 줄여 주세요."; return }
        let typewriter = spatial.typewriter, focus = spatial.focusDimming, current = ticket
        searching = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
                let worker = Task.detached(priority: .userInitiated) {
                    try Self.build(project: project, origin: origin, native: native, query: query,
                        scope: scope, typewriter: typewriter, focus: focus)
                }
                let found = try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.ticket == current else { return }
                guard session.activeProject == project else { self.searching = false; self.task = nil; return }
                self.results = found; self.searching = false; self.task = nil
            } catch {
                guard let self, self.ticket == current else { return }
                self.searching = false; self.task = nil
                if !(error is CancellationError) { self.message = "검색을 다시 시도해 주세요." }
            }
        }
    }

    nonisolated private static func build(project: WritingProject, origin: WritingDocumentID, native: String?,
        query: String, scope: WorkspaceSearchScope, typewriter: Bool, focus: Bool) throws -> [WorkspaceSearchResult] {
        try Task.checkCancellation()
        if scope == .document {
            guard !query.isEmpty, let native else { return [] }
            let text = native as NSString, revision = DocumentOutline.stableHash(native)
            var offset = 0, matches: [WorkspaceSearchResult] = []
            while offset < text.length {
                try Task.checkCancellation()
                let range = text.range(of: query, options: .caseInsensitive,
                    range: NSRange(location: offset, length: text.length - offset))
                guard range.location != NSNotFound else { break }
                offset = range.upperBound
                let start = max(0, range.location - 24), end = min(text.length, range.upperBound + 48)
                let context = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                matches.append(.init(id: "native.\(range.location)",
                    title: text.substring(with: context).replacingOccurrences(of: "\n", with: " "),
                    detail: "본문 · \(matches.count + 1)번째 일치",
                    action: .native(.init(projectID: project.id, documentID: origin), range, revision)))
            }
            return matches
        }
        var results = WorkspaceCommandSearch.items(in: project, query: query, typewriter: typewriter,
            focus: focus, includeSources: false, limit: 100)
            .filter { scope != .commands || $0.kind == .command }
            .map { WorkspaceSearchResult(id: $0.id, title: $0.title,
                detail: "\($0.kind.rawValue) · \($0.detail)", action: .command($0.action)) }
        if scope == .project, !query.isEmpty {
            for hit in try SourceSearch.results(query: query, in: project, origin: origin, cursor: 0, scope: .project) {
                let reference = OriginalSourceReference(key: .init(projectID: project.id, documentID: hit.documentID),
                    revision: hit.revision,
                    evidence: .init(documentID: hit.documentID, quote: hit.matchedText, utf16Hint: hit.matchedRange.location),
                    selection: .passage)
                results.append(.init(id: hit.id, title: hit.evidence.quote.replacingOccurrences(of: "\n", with: " "),
                    detail: "원문 · \(hit.title)", action: .command(.source(reference))))
            }
        }
        return results
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func activate(session: ProjectSession, requests: ProjectEditorRequests, spatial: SpatialWorkspaceController,
                  toggleTheme: () -> Void) {
        guard results.indices.contains(selection), let project = session.activeProject else { return }
        switch results[selection].action {
        case .native(let key, let range, let revision):
            guard key.projectID == project.id, let editor = requests.editor(for: key),
                  !editor.hasMarkedText(), DocumentOutline.stableHash(editor.string) == revision,
                  range.upperBound <= editor.string.utf16.count else {
                message = "문서가 바뀌었습니다. 새 검색 결과를 선택해 주세요."; return
            }
            guard editor.window?.makeFirstResponder(editor) == true else { return }
            editor.setSelectedRange(range); editor.scrollRangeToVisible(range); editor.showFindIndicator(for: range)
        case .command(let action):
            switch action {
            case .typewriter: spatial.typewriter.toggle()
            case .focus: spatial.focusDimming.toggle()
            case .openAll: spatial.openAll()
            case .theme: toggleTheme()
            case .tool(let tile):
                if tile == .inspector { spatial.openPouchTools() }
                else if !spatial.layout.contains(tile) { spatial.toggle(tile) }
                else { spatial.selectTile(tile) }
            case .document(let id): spatial.open(id)
            case .character(let id, let card):
                spatial.open(id)
                if !spatial.layout.contains(.characters) { spatial.toggle(.characters) }
                spatial.expandedItem = card.uuidString; spatial.selectTile(.characters); spatial.pouchSection = .object
            case .source(let reference):
                let inspection = ProjectSourceInspection(session: session)
                guard let token = inspection.capture(),
                      requests.jump(to: reference, inspection: inspection, token: token, in: session) else {
                    message = requests.sourceNavigationError ?? "원문 위치를 확인할 수 없습니다."; return
                }
            }
        }
    }
}

struct WorkspaceSearchPane: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var spatial: SpatialWorkspaceController
    let theme: PurloryTheme
    let toggleTheme: () -> Void
    @StateObject private var search = WorkspaceSearchModel()
    private var scopeTitle: String {
        guard search.scope == .document else { return "문서·인물·원문·도구" }
        return (search.documentID ?? session.selectedDocumentID).flatMap { session.document($0)?.title } ?? "현재 문서"
    }

    var body: some View {
        VStack(spacing: 10) {
            WorkspaceSearchField(query: $search.query, focusSequence: spatial.searchRequest.sequence,
                activate: activate, move: { search.move($0) }, cancel: { requests.focusEditor() })
                .frame(height: 28)
            Picker("검색 범위", selection: $search.scope) {
                ForEach(WorkspaceSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Text(scopeTitle).lineLimit(1)
                Spacer(minLength: 4)
                if search.searching { ProgressView().controlSize(.mini) }
                Text(search.results.isEmpty ? "0개" : "\(search.selection + 1) / \(search.results.count)")
                Button { advance(-1) } label: { Image(systemName: "chevron.up") }.help("이전 결과")
                Button { advance(1) } label: { Image(systemName: "chevron.down") }.help("다음 결과")
            }.purloryUIFont(10).foregroundStyle(theme.ink2C).buttonStyle(.plain)
            if let message = search.message { Text(message).purloryUIFont(11).foregroundStyle(theme.dangerC) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(search.results.enumerated()), id: \.element.id) { index, result in
                            Button { search.selection = index; activate() } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.title).purloryUIFont(12, .medium).foregroundStyle(theme.inkC).lineLimit(2)
                                    Text(result.detail).purloryUIFont(10).foregroundStyle(theme.ink2C).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(search.selection == index ? theme.activeBgC : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).id(index)
                        }
                        if search.results.isEmpty && !search.searching {
                            Text(search.query.isEmpty ? "검색어를 입력해 주세요" : "일치하는 결과가 없습니다")
                                .purloryUIFont(12).foregroundStyle(theme.ink2C).padding(.vertical, 24)
                        }
                    }
                }.onChange(of: search.selection) { _, index in proxy.scrollTo(index) }
            }
            Text("↑↓ 선택 · Enter 열기 · ⌘G 다음 찾기").purloryUIFont(9).foregroundStyle(theme.ink3C)
        }.padding(12)
            .focusedValue(\.hasPurloryEditor, true)
            .accessibilityIdentifier("purlory.workspace.search")
            .onAppear { configure(); spatial.advanceSearch = { advance($0) } }
            .onDisappear { search.cancel(); spatial.advanceSearch = nil }
            .onChange(of: spatial.searchRequest) { _, _ in configure() }
            .onChange(of: search.query) { _, _ in update() }
            .onChange(of: search.scope) { _, _ in update() }
            .onChange(of: session.activeProject) { _, _ in update() }
            .onChange(of: session.isTransitioning) { _, value in if value { search.cancel() } else { update() } }
            .onChange(of: spatial.typewriter) { _, _ in update() }
            .onChange(of: spatial.focusDimming) { _, _ in update() }
    }
    private func configure() {
        search.scope = spatial.searchRequest.scope
        search.documentID = spatial.searchRequest.documentID ?? session.selectedDocumentID
        if let query = spatial.searchRequest.query { search.query = query }
        update()
    }
    private func update() { search.update(session: session, requests: requests, spatial: spatial) }
    private func activate() { search.activate(session: session, requests: requests, spatial: spatial, toggleTheme: toggleTheme) }
    private func advance(_ delta: Int) { search.move(delta); activate() }
}

private struct WorkspaceSearchField: NSViewRepresentable {
    @Binding var query: String
    let focusSequence: Int
    let activate: () -> Void
    let move: (Int) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.delegate = context.coordinator
        field.placeholderString = "문장, 문서, 인물 또는 도구 찾기"
        field.sendsSearchStringImmediately = true; field.maximumRecents = 0
        field.setAccessibilityIdentifier("purlory.workspace.search.query")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != query {
            field.stringValue = query
        }
        if context.coordinator.focusSequence != focusSequence {
            context.coordinator.focusSequence = focusSequence
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }; field.window?.makeFirstResponder(field)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: WorkspaceSearchField
        var focusSequence = -1
        init(_ parent: WorkspaceSearchField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)): parent.activate()
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
