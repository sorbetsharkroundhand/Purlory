import AppKit
import Combine

/// Temporary original-source inspection. The manuscript keeps its native view and undo owner.
@MainActor
final class SourceSearchPanel: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private static var active: SourceSearchPanel?
    let searchField = NSSearchField()
    let scopePicker = NSPopUpButton()
    let resultTable = SourceResultTable()
    let statusLabel = NSTextField(labelWithString: "")
    let model: SourceSearchController
    let askButton = NSButton(title: "이 결과로 질문", target: nil, action: nil)
    private(set) var questionView: AskQuestionView?
    private var searchStack: NSStackView?
    private var subscriptions: Set<AnyCancellable> = []
    private let session: ProjectSession
    private let requests: ProjectEditorRequests
    private let identity: ProjectRuntimeIdentity
    private let openButton = NSButton(title: "원문 열기", target: nil, action: nil)
    private var isClosing = false
    private var parentCloseObserver: NSObjectProtocol?

    @discardableResult
    static func present(session: ProjectSession, requests: ProjectEditorRequests) -> SourceSearchPanel? {
        guard let point = requests.captureSourcePosition(in: session), let identity = session.runtimeIdentity,
            let parent = requests.nativeEditor?.window else { return nil }
        if let active, active.identity == identity, !active.model.isInvalidated {
            active.window?.makeKeyAndOrderFront(nil); return active
        }
        active?.close()
        let panel = SourceSearchPanel(session: session, requests: requests, point: point, identity: identity)
        active = panel
        let size = NSSize(width: min(640, max(360, parent.frame.width - 48)),
            height: min(420, max(300, parent.frame.height - 80)))
        panel.window?.setContentSize(size)
        panel.window?.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2,
            y: parent.frame.midY - size.height / 2))
        if let window = panel.window { parent.addChildWindow(window, ordered: .above) }
        panel.parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: parent, queue: .main) { [weak panel] _ in MainActor.assumeIsolated { panel?.close() } }
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.makeFirstResponder(panel.searchField)
        return panel
    }

    private init(session: ProjectSession, requests: ProjectEditorRequests,
                 point: SourceWritingPosition, identity: ProjectRuntimeIdentity) {
        self.session = session; self.requests = requests; self.identity = identity
        model = SourceSearchController(session: session, origin: identity, cursor: point.sourceCursor)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "원문 검색"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 360, height: 300)
        window.hidesOnDeactivate = true
        super.init(window: window)
        window.delegate = self
        configure()
        requests.askSupport?.$available.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }.store(in: &subscriptions)
        model.didChange = { [weak self] in self?.reload() }
        model.didInvalidate = { [weak self] in self?.close() }
        reload()
    }

    required init?(coder: NSCoder) { nil }

    private func configure() {
        searchField.placeholderString = "단어 또는 이름"
        searchField.maximumRecents = 0; searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("원고 검색")
        searchField.setAccessibilityIdentifier("purlory.source-search.query")
        scopePicker.addItems(withTitles: ["여기", "챕터", "프로젝트"])
        scopePicker.selectItem(at: 2); scopePicker.target = self; scopePicker.action = #selector(scopeChanged)
        scopePicker.setAccessibilityLabel("검색 범위")
        scopePicker.setAccessibilityIdentifier("purlory.source-search.scope")
        let header = NSStackView(views: [searchField, scopePicker]); header.spacing = 8
        header.orientation = .horizontal
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        resultTable.addTableColumn(column); resultTable.headerView = nil
        resultTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        resultTable.rowHeight = 72; resultTable.delegate = self; resultTable.dataSource = self
        resultTable.target = self; resultTable.doubleAction = #selector(openSelected)
        resultTable.activate = { [weak self] in self?.openSelected() }
        resultTable.cancel = { [weak self] in self?.close() }
        resultTable.setAccessibilityLabel("원문 검색 결과")
        resultTable.setAccessibilityIdentifier("purlory.source-search.results")
        let scroll = NSScrollView(); scroll.documentView = resultTable
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        statusLabel.textColor = .secondaryLabelColor; statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityIdentifier("purlory.source-search.status")
        let cancel = NSButton(title: "닫기", target: self, action: #selector(closeSearch))
        cancel.setAccessibilityIdentifier("purlory.source-search.close")
        openButton.title = "원문 열기"; openButton.target = self; openButton.action = #selector(openSelected)
        openButton.keyEquivalent = "\r"; openButton.setAccessibilityIdentifier("purlory.source-search.open")
        askButton.target = self; askButton.action = #selector(openQuestion)
        askButton.setAccessibilityIdentifier("purlory.ask.open")
        let buttons = NSStackView(views: [cancel, askButton, openButton]); buttons.orientation = .horizontal
        let teaching = NSTextField(labelWithString: "↑↓ 선택 · Return 원문 열기 · Esc 닫기")
        teaching.font = .systemFont(ofSize: 11); teaching.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, scroll, statusLabel, teaching, buttons])
        searchStack = stack
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.hits.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.hits.indices.contains(row) else { return nil }
        let hit = model.hits[row]
        let title = NSTextField(labelWithString: String(hit.title.prefix(120)))
        title.font = .systemFont(ofSize: 12, weight: .medium); title.maximumNumberOfLines = 1
        let quote = NSTextField(wrappingLabelWithString: String(hit.evidence.quote.prefix(200)).replacingOccurrences(of: "\n", with: " "))
        quote.font = .systemFont(ofSize: 12); quote.maximumNumberOfLines = 2
        let reason = NSTextField(labelWithString: hit.reason == .literal ? "단어 일치" : "저장된 이름·별칭")
        reason.font = .systemFont(ofSize: 10); reason.textColor = .secondaryLabelColor
        let cell = NSTableCellView(), stack = NSStackView(views: [title, quote, reason])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        updateSearch()
    }
    @objc private func scopeChanged() { updateSearch() }
    private func updateSearch() {
        let scope = SourceSearchScope.allCases[max(0, min(2, scopePicker.indexOfSelectedItem))]
        model.search(query: searchField.stringValue, scope: scope)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !model.hits.isEmpty else { return true }
            let delta = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(model.hits.count - 1, resultTable.selectedRow + delta))
            resultTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            resultTable.scrollRowToVisible(row); return true
        default: return false
        }
    }
    @objc private func openSelected() {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true,
            model.hits.indices.contains(resultTable.selectedRow) else { return }
        if requests.jump(to: model.hits[resultTable.selectedRow], in: session) { close() }
        else { statusLabel.stringValue = requests.sourceNavigationError ?? "다시 검색하세요." }
    }
    private func reload() {
        resultTable.reloadData()
        openButton.isEnabled = !model.hits.isEmpty && !model.isInvalidated
        askButton.isEnabled = requests.askSupport?.available == true && model.preparedInput != nil && !model.hits.isEmpty && !model.isInvalidated
        askButton.toolTip = requests.askSupport?.available == true ? "검색 원문에서 직접 질문해요." : "AI가 켜지고 선택한 로컬 모델이 준비되면 질문할 수 있어요. 원문 검색은 계속 사용할 수 있어요."
        if !model.hits.isEmpty { resultTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        statusLabel.stringValue = model.errorMessage ?? (model.isSearching ? "검색 중…" :
            searchField.stringValue.isEmpty ? "단어나 이름으로 원문을 찾아보세요." : "\(model.hits.count)개 결과")
    }
    @objc private func closeSearch() { close() }
    @objc private func openQuestion() {
        guard questionView == nil, let support = requests.askSupport, support.available,
              let input = model.preparedInput, !model.isInvalidated else { return }
        let view = AskQuestionView(model: support.makeController(session: session, input: input), scope: input.scope)
        view.onBack = { [weak self] in self?.showSearch() }
        view.onInvalidated = { [weak self] in self?.close() }
        view.answerView.onSource = { [weak self] packetID, id in self?.openAnswerSource(packetID: packetID, id: id) }
        guard let content = window?.contentView else { view.model.dismiss(); return }
        questionView = view; searchStack?.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        window?.title = "Ask Purlory"; window?.contentMinSize.height = 420
        if let size = window?.contentView?.bounds.size { window?.setContentSize(NSSize(width: size.width, height: max(460, size.height))) }
        window?.makeFirstResponder(view.questionField)
    }
    private func showSearch() {
        questionView?.answerView.update(packet: nil, blocks: [])
        questionView?.model.didChange = nil; questionView?.model.dismiss()
        questionView?.removeFromSuperview(); questionView = nil
        searchStack?.isHidden = false; window?.title = "원문 검색"; window?.contentMinSize.height = 300
        window?.makeFirstResponder(searchField); reload()
    }
    private func openAnswerSource(packetID: UUID, id: String) {
        guard let questionView, questionView.model.status != .invalidated,
              let packet = questionView.model.packet, packet.id == packetID, session.runtimeIdentity == packet.origin,
              let hit = packet.sources.first(where: { $0.id == id })?.hit,
              let project = session.activeProject, project.id == hit.projectID,
              let document = project.documents.first(where: { $0.id == hit.documentID }),
              !project.trashedDocumentIDs.contains(document.id), DocumentOutline.stableHash(document.body) == hit.revision,
              let hint = hit.evidence.utf16Hint,
              SourceAnchor.uniqueOriginalRange(for: hit.evidence.quote, in: document.body,
                within: NSRange(location: hint, length: hit.evidence.quote.utf16.count))?.location == hint,
              requests.jump(to: hit, in: session) else {
            self.questionView?.showNavigationError(); return
        }
        close()
    }
    override func close() { if !isClosing { window?.close() } }
    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }; isClosing = true
        questionView?.answerView.update(packet: nil, blocks: [])
        questionView?.model.didChange = nil; questionView?.model.dismiss(); subscriptions.removeAll()
        model.didInvalidate = nil; model.dismiss()
        if let observer = parentCloseObserver { NotificationCenter.default.removeObserver(observer) }
        if let window { window.parent?.removeChildWindow(window) }
        if Self.active === self { Self.active = nil }
        if session.isEditorEditable { requests.focusEditor() }
    }
}

@MainActor
final class SourceResultTable: NSTableView {
    var activate: (() -> Void)?
    var cancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { activate?() }
        else if event.keyCode == 53 { cancel?() }
        else { super.keyDown(with: event) }
    }
}
