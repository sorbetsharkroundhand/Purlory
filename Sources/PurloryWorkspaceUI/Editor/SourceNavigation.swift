import AppKit

struct SourceWritingPosition: Equatable, Sendable {
    let key: ProjectDocumentKey
    let manuscript: String
    let nativeText: String
    let selection: NSRange
    let scrollOrigin: NSPoint
    let sourceCursor: Int
}

enum SourceNavigationIntent: Equatable, Sendable {
    case passage(SourceSearchHit)
    case heading(OutlineSourceTarget)
    case storyMap(StoryMapSourceTarget)
    case original(OriginalSourceTarget)
    case returnTo(SourceWritingPosition)
    var key: ProjectDocumentKey {
        switch self {
        case .passage(let hit): ProjectDocumentKey(projectID: hit.projectID, documentID: hit.documentID)
        case .heading(let target): target.identity.key
        case .storyMap(let target): target.identity.key
        case .original(let target): target.identity.key
        case .returnTo(let point): point.key
        }
    }
}

@MainActor
extension ProjectEditorRequests {
    @discardableResult
    func jump(to row: StoryMapProjection.Row, prepared: PreparedStoryMap, in session: ProjectSession) -> Bool {
        let target = StoryMapSourceTarget(identity: prepared.identity, revision: prepared.projection.revision, row: row)
        guard session.workspaceMode == .map, session.activeProject?.mode == .fiction,
              session.runtimeIdentity == prepared.identity, prepared.projection.rows.contains(row),
              let body = session.selectedDocument?.body, target.matchesSource(body),
              let point = captureSourcePosition(in: session) else {
            sourceNavigationError = "원문 위치를 확인할 수 없어요. 지도가 갱신된 뒤 다시 선택하세요."
            return false
        }
        if sourceReturnPoint?.key.projectID != point.key.projectID { sourceReturnPoint = point }
        sourceNavigationError = nil; issueSourceNavigation(.storyMap(target)); return true
    }

    @discardableResult
    func jump(to heading: DocumentOutlineProjection.Heading, prepared: PreparedDocumentOutline,
              in session: ProjectSession) -> Bool {
        let target = OutlineSourceTarget(identity: prepared.identity, revision: prepared.projection.revision,
            evidence: .init(documentID: prepared.identity.key.documentID, quote: heading.quote, utf16Hint: heading.id),
            level: heading.level, sourceOffset: heading.id)
        guard session.runtimeIdentity == prepared.identity,
              prepared.projection.headings.contains(heading),
              let body = session.selectedDocument?.body, target.matchesSource(body),
              let point = captureSourcePosition(in: session) else {
            sourceNavigationError = "원문 위치를 확인할 수 없어요. 개요가 갱신된 뒤 다시 선택하세요."
            return false
        }
        if sourceReturnPoint?.key.projectID != point.key.projectID { sourceReturnPoint = point }
        sourceNavigationError = nil
        issueSourceNavigation(.heading(target))
        return true
    }

    func captureSourcePosition(in session: ProjectSession) -> SourceWritingPosition? {
        guard session.isEditorEditable, let key = session.runtimeIdentity?.key,
            nativeEditorKey == key, let view = nativeEditor, !view.hasMarkedText(),
            view.writingDocumentIdentity == .project(key),
            let manuscript = session.selectedDocument?.body, view.serialize().utf16.elementsEqual(manuscript.utf16) else { return nil }
        return SourceWritingPosition(key: key, manuscript: manuscript, nativeText: view.string,
            selection: view.selectedRange(), scrollOrigin: view.enclosingScrollView?.contentView.bounds.origin ?? .zero,
            sourceCursor: view.sourceCursorOffset())
    }

    @discardableResult
    func jump(to hit: SourceSearchHit, in session: ProjectSession) -> Bool {
        guard let point = captureSourcePosition(in: session),
            let project = session.activeProject, project.id == hit.projectID,
            !project.trashedDocumentIDs.contains(hit.documentID),
            let document = project.documents.first(where: { $0.id == hit.documentID }),
            SourceAnchor.exactRange(for: hit.evidence, in: document.body, revision: hit.revision) != nil else {
            sourceNavigationError = "원문이 변경되었습니다. 다시 검색하세요."
            return false
        }
        if sourceReturnPoint?.key.projectID != point.key.projectID { sourceReturnPoint = point }
        sourceNavigationError = nil
        session.selectDocument(hit.documentID)
        issueSourceNavigation(.passage(hit))
        return true
    }

    @discardableResult
    func returnToWriting(in session: ProjectSession) -> Bool {
        guard session.isEditorEditable, nativeEditor?.hasMarkedText() == false,
            let point = sourceReturnPoint, let project = session.activeProject,
            point.key.projectID == project.id, !project.trashedDocumentIDs.contains(point.key.documentID),
            let body = project.documents.first(where: { $0.id == point.key.documentID })?.body,
            body.utf16.elementsEqual(point.manuscript.utf16) else {
            sourceNavigationError = "이전 집필 위치의 문서가 변경되었습니다."
            return false
        }
        session.selectDocument(point.key.documentID)
        sourceNavigationError = nil
        issueSourceNavigation(.returnTo(point))
        return true
    }

    func issueSourceNavigation(_ source: SourceNavigationIntent) {
        var resolved = source
        if let spatialWorkspace, let session = registeredSession {
            spatialWorkspace.open(source.key.documentID)
            // Opening a middle file can persist a new column reading order. That
            // synchronous mutation advances the runtime without changing its original.
            if case .original(let target) = source, let identity = session.runtimeIdentity,
               identity.key == target.reference.key, let body = session.document(identity.key.documentID)?.body,
               target.reference.matchesSource(body) {
                resolved = .original(.init(identity: identity, reference: target.reference))
            }
        }
        searchJump = EditorSearchJump(documentID: source.key.documentID, query: "",
            sequence: (searchJump?.sequence ?? 0) + 1, source: resolved)
        if spatialWorkspace != nil, let identity = registeredSession?.runtimeIdentity, let searchJump {
            pendingSpatialJump = (searchJump, identity); scheduleSpatialNavigation()
        }
        focusEditor()
    }

    func scheduleSpatialNavigation() {
        guard let pending = pendingSpatialJump else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingSpatialJump?.jump == pending.jump,
                  let session = self.registeredSession, session.runtimeIdentity == pending.identity,
                  session.isEditorEditable, let editor = self.editor(for: pending.identity.key),
                  editor.window != nil, !editor.hasMarkedText() else { return }
            // New tiles initialize their native source projection during attachment. Leave
            // the fresh request pending until that exact runtime has a proven mapping.
            if case .original = pending.jump.source, !editor.ownsOriginalSource(pending.identity) { return }
            self.pendingSpatialJump = nil
            if let source = pending.jump.source {
                self.didNavigateSource(editor.applySourceNavigation(source), jump: pending.jump)
            } else {
                editor.revealMatch(of: pending.jump.query)
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    func didNavigateSource(_ succeeded: Bool, jump: EditorSearchJump) {
        guard searchJump == jump else { return }
        if !succeeded { sourceNavigationError = "원문 위치를 확인할 수 없습니다. 다시 검색하세요." }
        else if case .returnTo = jump.source { sourceReturnPoint = nil }
    }
}

@MainActor
extension BlockTextView {
    /// Markdown offsets never become TextKit offsets. Match occurrence order only when
    /// all original occurrences are also present in the rendered native text.
    @discardableResult
    func applySourceNavigation(_ intent: SourceNavigationIntent) -> Bool {
        guard !hasMarkedText() else { return false }
        switch intent {
        case .heading(let target):
            guard applyOutlineHeading(target) else { return false }
        case .storyMap(let target):
            guard applyStoryMapSource(target) else { return false }
        case .original(let target):
            guard applyOriginalSource(target) else { return false }
        case .returnTo(let point):
            guard serialize().utf16.elementsEqual(point.manuscript.utf16),
                string.utf16.elementsEqual(point.nativeText.utf16) else { return false }
            restoreSelection(to: point.selection)
            if let scroll = enclosingScrollView {
                var bounds = scroll.contentView.bounds; bounds.origin = point.scrollOrigin
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        case .passage(let hit):
            let manuscript = serialize()
            guard let quote = SourceAnchor.exactRange(for: hit.evidence, in: manuscript, revision: hit.revision),
                let oldQuoteStart = hit.evidence.utf16Hint else { return false }
            let location = quote.location + hit.matchedRange.location - oldQuoteStart
            func matches(_ text: String) -> [NSRange] {
                let ns = text as NSString; var ranges: [NSRange] = [], start = 0
                while start < ns.length {
                    let range = ns.range(of: hit.matchedText, options: .caseInsensitive,
                        range: NSRange(location: start, length: ns.length - start))
                    guard range.location != NSNotFound else { break }
                    ranges.append(range); start = NSMaxRange(range)
                }
                return ranges
            }
            let originals = matches(manuscript), native = matches(string)
            guard originals.count == native.count,
                let index = originals.firstIndex(where: { $0.location == location }) else { return false }
            restoreSelection(to: native[index])
        }
        window?.makeFirstResponder(self)
        refreshActiveLineHighlight()
        workspaceInteraction?.flash(selectedRange())
        return true
    }
}
