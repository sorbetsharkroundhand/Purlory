import AppKit
import Combine

@MainActor final class WorkspaceQuickCommandPanel: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var active: WorkspaceQuickCommandPanel?
    let searchField = NSSearchField()
    private let table = WorkspaceCommandTable()
    private let session: ProjectSession
    private let requests: ProjectEditorRequests
    private let inspection: ProjectSourceInspection
    private let token: ProjectSourceInspection.Token
    private let toggleTheme: () -> Void
    private var items: [WorkspaceCommandItem] = []
    private var monitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var closing = false
    private let theme: PurloryTheme
    private let backdrop = WorkspaceModalBackdrop()
    private let emptyLabel = NSTextField(labelWithString: "일치하는 장면이나 명령이 없습니다")

    @discardableResult static func present(session: ProjectSession, requests: ProjectEditorRequests, theme: PurloryTheme, toggleTheme: @escaping () -> Void) -> WorkspaceQuickCommandPanel? {
        guard requests.captureSourcePosition(in: session) != nil, let parent = requests.nativeEditor?.window else { return nil }
        active?.close()
        let inspection = ProjectSourceInspection(session: session)
        guard let token = inspection.capture() else { return nil }
        let panel = WorkspaceQuickCommandPanel(session: session, requests: requests, inspection: inspection, token: token, theme: theme, toggleTheme: toggleTheme)
        active = panel
        let width = min(500, max(300, parent.frame.width - 48)), height: CGFloat = 354
        panel.window?.setContentSize(NSSize(width: width, height: height))
        panel.window?.setFrameOrigin(.init(x: parent.frame.midX - width / 2, y: parent.frame.maxY - height - 80))
        panel.window?.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        panel.backdrop.show(over: parent, opacity: 0.40)
        if let window = panel.window { parent.addChildWindow(window, ordered: .above) }
        panel.window?.makeKeyAndOrderFront(nil); panel.window?.makeFirstResponder(panel.searchField)
        return panel
    }
    private init(session: ProjectSession, requests: ProjectEditorRequests, inspection: ProjectSourceInspection,
                 token: ProjectSourceInspection.Token, theme: PurloryTheme, toggleTheme: @escaping () -> Void) {
        self.theme = theme; self.session = session; self.requests = requests; self.inspection = inspection; self.token = token; self.toggleTheme = toggleTheme
        let window = WorkspaceModalPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.title = "빠른 검색 및 명령"
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = true
        super.init(window: window); window.delegate = self
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        let surface = NSView(); surface.wantsLayer = true
        surface.layer?.backgroundColor = theme.pill.cgColor; surface.layer?.cornerRadius = 13
        surface.layer?.masksToBounds = true; window.contentView = surface
        searchField.placeholderString = "장면, 인물, 원고 본문 검색 또는 명령 실행…"
        searchField.font = PurloryFonts.ui(12); searchField.textColor = theme.ink
        searchField.isBordered = false; searchField.drawsBackground = false
        searchField.maximumRecents = 0; searchField.sendsSearchStringImmediately = true; searchField.delegate = self
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        searchField.setAccessibilityIdentifier("purlory.commands.query"); searchField.setAccessibilityLabel("빠른 검색 및 명령")
        let searchIcon = NSImageView()
        searchIcon.image = WorkspaceIcons.image("magnifyingglass", size: 16); searchIcon.contentTintColor = theme.workspaceMuted
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        searchIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let escape = NSTextField(labelWithString: "ESC")
        escape.font = PurloryFonts.mono(9.5); escape.textColor = theme.workspaceMuted
        escape.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [searchIcon, searchField, escape]); header.spacing = 10
        table.addTableColumn(NSTableColumn(identifier: .init("command"))); table.headerView = nil
        table.rowHeight = 46; table.intercellSpacing = .init(width: 0, height: 2)
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular; table.focusRingType = .none
        table.target = self; table.action = #selector(activateSelected)
        table.setAccessibilityIdentifier("purlory.commands.results")
        table.hover = { [weak self] row in self?.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        emptyLabel.font = PurloryFonts.ui(12); emptyLabel.textColor = theme.workspaceMuted; emptyLabel.alignment = .center
        for view in [header, scroll, emptyLabel] { view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 24),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 44),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24)
        ])
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if let self, event.window !== self.window { self.close(); return nil }; return event
        }) { monitors.append(monitor) }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).sink { [weak self] notification in
            guard let self, let parent = notification.object as? NSWindow, parent === self.window?.parent else { return }
            self.close()
        }.store(in: &subscriptions)
        session.$activeProject.dropFirst().sink { [weak self] _ in self?.close() }.store(in: &subscriptions)
        session.$isTransitioning.dropFirst().sink { [weak self] value in if value { self?.close() } }.store(in: &subscriptions)
        reload()
    }
    required init?(coder: NSCoder) { nil }
    private func reload() {
        guard let project = session.activeProject else { return }
        items = WorkspaceCommandSearch.items(in: project, query: searchField.stringValue,
            typewriter: requests.spatialWorkspace?.typewriter == true, focus: requests.spatialWorkspace?.focusDimming == true)
        table.reloadData(); emptyLabel.isHidden = !items.isEmpty
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }; reload()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelected(); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !items.isEmpty else { return true }
            let delta = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = (table.selectedRow + delta + items.count) % items.count
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row); return true
        default: return false
        }
    }
    @objc private func activateSelected() {
        guard inspection.isCurrent(token, in: session), items.indices.contains(table.selectedRow),
            (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let action = items[table.selectedRow].action
        switch action {
        case .typewriter: requests.spatialWorkspace?.typewriter.toggle()
        case .focus: requests.spatialWorkspace?.focusDimming.toggle()
        case .openAll: requests.spatialWorkspace?.openAll()
        case .theme: toggleTheme()
        case .tool(let tile):
            if tile == .inspector { requests.spatialWorkspace?.openPouchTools() }
            else if requests.spatialWorkspace?.layout.contains(tile) == false { requests.spatialWorkspace?.toggle(tile) }
        case .document(let id): session.selectDocument(id); requests.spatialWorkspace?.open(id)
        case .character(let id, let card):
            session.selectDocument(id)
            if let project = session.activeProject, let document = session.document(id),
               let record = try? WriterDocumentData.decode(project.userData[WriterDocumentData.key(for: id)], documentID: id).characters.first(where: { $0.id == card }),
               !record.name.isEmpty {
                let body = document.body as NSString, match = (document.body as NSString).range(of: record.name)
                if match.location != NSNotFound {
                    let paragraph = body.paragraphRange(for: match)
                    if let reference = OriginalSourceReference.exact(.init(documentID: id, quote: body.substring(with: paragraph), utf16Hint: paragraph.location), in: project),
                       let current = inspection.capture() {
                        _ = requests.jump(to: reference, inspection: inspection, token: current, in: session)
                    }
                }
            }
        case .source(let reference):
            guard requests.jump(to: reference, inspection: inspection, token: token, in: session) else { return }
        }
        close()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let title = NSTextField(labelWithString: item.title), detail = NSTextField(labelWithString: item.detail)
        let kind = NSTextField(labelWithString: item.kind.rawValue), enter = NSTextField(labelWithString: "↵")
        title.font = PurloryFonts.ui(12, weight: .medium); title.textColor = theme.ink
        detail.font = PurloryFonts.ui(10.5); detail.textColor = theme.workspaceMuted
        kind.font = PurloryFonts.ui(9.5, weight: .semibold); kind.textColor = theme.ink2
        kind.wantsLayer = true; kind.layer?.backgroundColor = theme.chip.cgColor; kind.layer?.cornerRadius = 4
        enter.font = .monospacedSystemFont(ofSize: 10, weight: .regular); enter.textColor = theme.workspaceMuted
        for field in [title, detail] { field.lineBreakMode = .byTruncatingTail; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
        let rowView = NSView()
        for view in [kind, labels, enter] { view.translatesAutoresizingMaskIntoConstraints = false; rowView.addSubview(view) }
        NSLayoutConstraint.activate([
            kind.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 12),
            kind.centerYAnchor.constraint(equalTo: rowView.centerYAnchor), kind.widthAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: enter.leadingAnchor, constant: -12),
            enter.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -12),
            enter.centerYAnchor.constraint(equalTo: rowView.centerYAnchor), enter.widthAnchor.constraint(equalToConstant: 12)
        ])
        return rowView
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = WorkspaceCommandRow(); view.tint = theme.activeBg; return view
    }
    override func close() { if !closing { window?.close() } }
    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }; closing = true
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll(); subscriptions.removeAll()
        backdrop.close()
        if let window { window.parent?.removeChildWindow(window) }
        if Self.active === self { Self.active = nil }
        requests.focusEditor()
    }
}

@MainActor private final class WorkspaceCommandTable: NSTableView {
    var hover: ((Int) -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea); super.updateTrackingAreas()
        addTrackingArea(.init(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil)); if row >= 0 { hover?(row) }
    }
}

@MainActor private final class WorkspaceCommandRow: NSTableRowView {
    var tint = NSColor.clear
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        tint.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
