import AppKit
import Combine
import CryptoKit
import SwiftUI
import PurloryFoundation
import PurloryDocumentEngine
import PurloryIntelligence

@MainActor final class WorkspaceEntityController: ObservableObject {
    struct Peek: Equatable {
        let name: String; let note: String; let aliases: String
        let badge: String; let role: String; let tags: String
        let reference: OriginalSourceReference
    }
    private struct Record {
        let name: String; let aliases: String; let note: String
        let badge: String; let role: String; let tags: String
        let reference: OriginalSourceReference?
        let terms: [String]
        init(name: String, aliases: String, note: String, badge: String, role: String, tags: String, reference: OriginalSourceReference?) {
            self.name = name; self.aliases = aliases; self.note = note
            self.badge = badge; self.role = role; self.tags = tags; self.reference = reference
            self.terms = ([name] + aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                .filter { !$0.isEmpty && $0.count <= 80 }
        }
    }
    private struct CachedNote {
        let title: String
        let source: DocumentSource
        let records: [Record]
    }
    @Published private(set) var peek: Peek?
    private(set) var noteParagraphScanCount = 0
    private weak var session: ProjectSession?
    private weak var requests: ProjectEditorRequests?
    private var hideTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var characterRecords: [Record] = []
    private var records: [Record] = []
    private var events: [Record] = []
    private var cachedNotes: [WritingDocument] = []
    private var noteCache: [WritingDocumentID: CachedNote] = [:]
    private var notesNeedPreparation = false
    private var cachedTrash: Set<WritingDocumentID> = []
    private weak var highlightedEditor: BlockTextView?
    private var highlightedRange: NSRange?
    private var cachedData: [String: Data] = [:]
    private var projectID: WritingProjectID?
    private var provenNativeRevision: UInt64?
    private var provenNativeRange: NSRange?
    private var subscriptions: Set<AnyCancellable> = []
    init(session: ProjectSession, requests: ProjectEditorRequests) {
        self.session = session; self.requests = requests
        session.activeProjectChanges.sink { [weak self] project in
            guard let self else { return }
            self.hide()
            guard let project else {
                self.characterRecords = []; self.records = []; self.cachedNotes = []
                self.noteCache = [:]; self.notesNeedPreparation = false
                self.updateTerms(); return
            }
            let notes = project.documents.filter { $0.kind == .note && !project.trashedDocumentIDs.contains($0.id) }
            let projectChanged = project.id != self.projectID
            let userDataChanged = projectChanged || project.userData != self.cachedData
            let trashChanged = projectChanged || project.trashedDocumentIDs != self.cachedTrash
            let notesChanged = projectChanged || !Self.sameNoteVersions(notes, self.cachedNotes)
            guard userDataChanged || trashChanged || notesChanged else { return }
            if projectChanged { self.noteCache.removeAll() }
            self.projectID = project.id
            self.cachedNotes = notes
            self.cachedTrash = project.trashedDocumentIDs
            if userDataChanged || trashChanged {
                self.cachedData = project.userData
                var seen: Set<UUID> = []
                self.characterRecords = project.documents.filter { !project.trashedDocumentIDs.contains($0.id) }.flatMap { document in
                    (try? WriterDocumentData.decode(project.userData[WriterDocumentData.key(for: document.id)], documentID: document.id).characters) ?? []
                }.filter { !$0.name.isEmpty && $0.autoRegistered != true && seen.insert($0.id).inserted }.map {
                    Record(name: $0.name, aliases: $0.aliases, note: $0.note, badge: "인물", role: $0.role ?? "",
                        tags: ($0.traits ?? []).map { "#" + $0 }.joined(separator: " "), reference: nil)
                }
            }
            // Notes are read only when the writer explicitly inspects a term.
            // The input callback retires their old references without joining or
            // hashing manuscript-sized notes, including equal-length IME edits.
            self.records = self.characterRecords
            self.notesNeedPreparation = true
            self.updateTerms()
        }.store(in: &subscriptions)
        requests.spatialWorkspace?.entityEventsChanges.sink { [weak self] values in
            guard let self else { return }
            self.events = values.map { .init(name: $0.name, aliases: "", note: $0.note, badge: "사건", role: "서사 흐름", tags: "", reference: $0.reference) }
            self.updateTerms()
        }.store(in: &subscriptions)
        requests.spatialWorkspace?.whisperTypingChanges.sink { [weak self] value in if value { self?.hide() } }.store(in: &subscriptions)
        requests.spatialWorkspace?.isDraggingChanges.sink { [weak self] value in if value { self?.hide() } }.store(in: &subscriptions)
    }
    private static func sameNoteVersions(_ lhs: [WritingDocument], _ rhs: [WritingDocument]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.source.isSameVersion(as: $1.source)
        }
    }

    private func prepareNotes(in project: WritingProject) {
        guard notesNeedPreparation, project.id == projectID else { return }
        notesNeedPreparation = false
        var nextRecords = characterRecords
        var validNoteIDs: Set<WritingDocumentID> = []
        for note in cachedNotes {
            validNoteIDs.insert(note.id)
            if let cached = noteCache[note.id], cached.title == note.title, cached.source.isSameVersion(as: note.source) {
                nextRecords.append(contentsOf: cached.records)
                continue
            }
            let body = note.body
            let source = body as NSString
            let noteKey = ProjectDocumentKey(projectID: project.id, documentID: note.id)
            let noteRevision = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            var cursor = 0, headings: [(String, NSRange)] = []
            while cursor < source.length {
                let hashMatch = source.range(of: "#", options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
                guard hashMatch.location != NSNotFound else { break }
                noteParagraphScanCount += 1
                let range = source.paragraphRange(for: NSRange(location: hashMatch.location, length: 0))
                cursor = max(range.upperBound, hashMatch.upperBound)
                let line = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("#"), let space = line.firstIndex(of: " "), line[..<space].allSatisfy({ $0 == "#" }) {
                    headings.append((String(line[line.index(after: space)...]), range))
                }
            }
            if headings.isEmpty, source.length > 0 { headings = [(note.title, NSRange(location: 0, length: 0))] }
            var extracted: [Record] = []
            for (index, heading) in headings.enumerated() where !heading.0.isEmpty && heading.0.count <= 80 {
                let end = index + 1 < headings.count ? headings[index + 1].1.location : source.length
                let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: heading.1.location, length: min(1024, end - heading.1.location)))
                guard range.length > 0 else { continue }
                let quote = source.substring(with: range)
                guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let reference = OriginalSourceReference(
                    key: noteKey,
                    revision: noteRevision,
                    evidence: .init(documentID: note.id, quote: quote, utf16Hint: range.location),
                    selection: .passage
                )
                var bodyStart = heading.1.upperBound
                while bodyStart < end {
                    let ch = source.character(at: bodyStart)
                    if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D { bodyStart += 1 } else { break }
                }
                let previewRange = source.rangeOfComposedCharacterSequences(
                    for: NSRange(location: bodyStart, length: min(1024, max(0, end - bodyStart))))
                let text = (previewRange.length > 0 ? source.substring(with: previewRange) : "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                extracted.append(.init(name: heading.0, aliases: "", note: String(text.prefix(240)), badge: "고증", role: note.title, tags: "", reference: reference))
            }
            noteCache[note.id] = CachedNote(title: note.title, source: note.source, records: extracted)
            nextRecords.append(contentsOf: extracted)
        }
        noteCache = noteCache.filter { validNoteIDs.contains($0.key) }
        records = nextRecords
        updateTerms()
    }

    private func updateTerms() {
        var seen: Set<String> = []
        let next = (records + events).flatMap(\.terms).filter { seen.insert($0).inserted }
        if requests?.spatialWorkspace?.entityTerms != next {
            requests?.spatialWorkspace?.entityTerms = next
        }
    }
    func hover(editor: BlockTextView, key: ProjectDocumentKey, nativeOffset: Int) {
        guard let session, session.isEditorEditable, session.activeProject?.id == key.projectID,
              requests?.spatialWorkspace?.whisperTyping != true, requests?.spatialWorkspace?.isDragging != true,
              !editor.hasMarkedText(), let project = session.activeProject,
              let document = session.document(key.documentID) else { scheduleHide(); return }
        prepareNotes(in: project)
        let native = editor.string as NSString
        guard nativeOffset >= 0, nativeOffset < native.length else { scheduleHide(); return }
        let line = native.paragraphRange(for: .init(location: nativeOffset, length: 0))
        for card in records + events {
            for term in card.terms {
                var start = line.location
                while start < line.upperBound {
                    let range = native.range(of: term, range: .init(location: start, length: line.upperBound - start))
                    guard range.location != NSNotFound else { break }; start = range.upperBound
                    guard NSLocationInRange(nativeOffset, range) else { continue }
                    if let reference = card.reference {
                        guard reference.key.projectID == project.id,
                              let target = session.document(reference.key.documentID),
                              reference.matchesSource(target.body) else { continue }
                    }
                    if peek?.name == card.name && peek?.reference.key == key && provenNativeRevision == editor.writingNativeRevision && provenNativeRange == range {
                        keepAlive(); return
                    }
                    let editorSource = editor.serializationCache.isClean
                        ? editor.serializationCache.markdownCodec.source : editor.serializedSource()
                    guard editorSource == document.source else { continue }
                    let original = document.body as NSString
                    let startOffset = editor.sourceCursorOffset(at: range.location)
                    let endOffset = editor.sourceCursorOffset(at: range.upperBound)
                    let source = NSRange(location: startOffset, length: endOffset - startOffset)
                    guard startOffset >= 0, endOffset > startOffset, endOffset <= original.length, source.length <= 2048,
                          original.rangeOfComposedCharacterSequences(for: source) == source else { continue }
                    provenNativeRevision = editor.writingNativeRevision; provenNativeRange = range
                    let reference: OriginalSourceReference
                    if let cardReference = card.reference {
                        reference = cardReference
                    } else {
                        reference = OriginalSourceReference(
                            key: key,
                            revision: SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined(),
                            evidence: .init(documentID: key.documentID, quote: original.substring(with: source), utf16Hint: source.location),
                            selection: .passage
                        )
                    }
                    let next = Peek(name: card.name, note: card.note, aliases: card.aliases, badge: card.badge,
                        role: card.role, tags: card.tags, reference: reference)
                    clearHighlight()
                    highlightedEditor = editor; highlightedRange = range
                    editor.layoutManager?.addTemporaryAttribute(.foregroundColor, value: editor.palette.novel, forCharacterRange: range)
                    editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: editor.palette.novelBg, forCharacterRange: range)
                    keepAlive(); requests?.spatialWorkspace?.resonatingTerm = term
                    if peek != next { peek = next; present(next, editor: editor, range: range) }
                    return
                }
            }
        }
        scheduleHide()
    }
    func keepAlive() { hideTask?.cancel(); hideTask = nil }
    func scheduleHide() {
        guard hideTask == nil, peek != nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(190)); guard !Task.isCancelled else { return }; self?.hide()
        }
    }
    func hide() {
        keepAlive()
        if peek != nil { peek = nil }
        clearHighlight()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
        }
        if requests?.spatialWorkspace?.resonatingTerm != nil {
            requests?.spatialWorkspace?.resonatingTerm = nil
        }
    }
    private func clearHighlight() {
        if let editor = highlightedEditor, let range = highlightedRange, range.upperBound <= editor.string.utf16.count {
            editor.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        highlightedEditor = nil; highlightedRange = nil
    }
    private func present(_ value: Peek, editor: BlockTextView, range: NSRange) {
        guard let parent = editor.window else { return }
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 268, height: 108), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "인물·고증·사건"
        panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.level = .floating; panel.hidesOnDeactivate = true
        panel.isOpaque = false; panel.backgroundColor = .clear
        let theme = editor.palette
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(value.badge).purloryUIFont(9.5, .semibold).foregroundStyle(theme.novelC)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(theme.novelBgC, in: RoundedRectangle(cornerRadius: 4))
                Text(value.name).font(PurloryFonts.serifUI(12, .bold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(value.role).purloryUIFont(10).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
            }
            Text(value.note).purloryUIFont(11).lineSpacing(4).foregroundStyle(theme.ink2C).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(value.tags).purloryUIFont(10).foregroundStyle(theme.workspaceMutedC).lineLimit(1)
                Spacer(minLength: 4)
                Button("관련 문단 →") { [weak self] in
                    guard let self, let session = self.session, let requests = self.requests else { return }
                    let inspection = ProjectSourceInspection(session: session)
                    if let token = inspection.capture() { requests.jump(to: value.reference, inspection: inspection, token: token, in: session) }
                    self.hide()
                }.buttonStyle(.plain).purloryUIFont(10, .medium).foregroundStyle(theme.novelC)
            }.padding(.top, 4)
        }.padding(12).frame(width: 268, alignment: .leading).foregroundStyle(theme.inkC)
            .background(theme.pillC, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(theme.pillBorderC))
            .onHover { [weak self] inside in if inside { self?.keepAlive() } else { self?.scheduleHide() } })
        panel.contentView = host
        let height = max(92, host.fittingSize.height)
        panel.setContentSize(.init(width: 268, height: height))
        let anchor = editor.firstRect(forCharacterRange: range, actualRange: nil)
        let visible = parent.screen?.visibleFrame ?? parent.frame
        let target = CGPoint(x: max(visible.minX + 14, min(visible.maxX - 282, anchor.midX - 134)),
            y: min(visible.maxY - height - 14, anchor.maxY + 108 - height))
        panel.setFrameOrigin(.init(x: target.x, y: target.y - 4)); panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above); panel.orderFront(nil); self.panel = panel
        WorkspaceHTMLStyle.animate(0.22) { panel.animator().setFrameOrigin(target); panel.animator().alphaValue = 1 }
    }
}
