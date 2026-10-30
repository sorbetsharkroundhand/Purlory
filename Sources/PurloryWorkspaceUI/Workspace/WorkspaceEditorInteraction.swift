import AppKit
import Combine

/// Workspace-owned gestures/decorations. The editor exposes only native presentation hooks.
@MainActor final class WorkspaceEditorInteraction: EditorWorkspaceInteraction {
    let key: ProjectDocumentKey
    func polishSelection() { if let editor { requests?.workspacePolish?(editor) } }
    private weak var editor: BlockTextView?
    private weak var session: ProjectSession?
    private weak var requests: ProjectEditorRequests?
    private weak var model: SpatialWorkspaceController?
    private var subscription: AnyCancellable?
    private var hovered: Int?
    private(set) var optionHeld = false
    private var modifierMonitor: Any?
    private var drag: (source: WorkspaceParagraphAnchor, start: CGPoint, active: Bool)?
    var ownsEscapeKey: Bool { drag != nil }
    private var target: WorkspaceParagraphAnchor?
    private var after = false
    private weak var targetEditor: BlockTextView?
    private var pill: NSPanel?
    private var flashRange: NSRange?
    private var flashTask: Task<Void, Never>?
    private var flashBegan = 0.0
    private var pointerInEditor = CGPoint.zero
    private var presentationClock: WorkspaceDisplayClock?
    private struct MotionRegion { var rect: CGRect; var until: Double }
    private var motionRegions: [Int: MotionRegion] = [:]
    private var previousFocus = false
    private var previousWhisper = false
    private var previousResonance: String?
    private var previousTerms: [String] = []
    private var previousActive = false
    private var previousSelection: Int?
    private var previewTask: Task<Void, Never>?
    private struct Fade { let from: CGFloat; let to: CGFloat; let began: Double }
    private var fades: [Int: Fade] = [:]
    private var renderedOpacity: [Int: CGFloat] = [:]
    func flash(_ range: NSRange) {
        flashTask?.cancel()
        if let previous = flashRange { invalidateParagraph(at: previous.location) }
        flashRange = range; flashBegan = ProcessInfo.processInfo.systemUptime
        invalidateParagraph(at: range.location, duration: 0.9)
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900)); guard !Task.isCancelled else { return }
            self?.flashRange = nil; self?.invalidateParagraph(at: range.location)
        }
    }
    private let pointerSpring = WorkspacePointerSpring()
    private var preview: (range: NSRange, style: NSParagraphStyle, text: String, after: Bool)?
    private var centering = false
    private var previousTypewriter = false
    private var previousEditorSize = CGSize.zero

    init(editor: BlockTextView, key: ProjectDocumentKey, session: ProjectSession,
         requests: ProjectEditorRequests, model: SpatialWorkspaceController) {
        self.editor = editor; self.key = key; self.session = session; self.requests = requests; self.model = model
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, event.window === self.editor?.window {
                self.setOptionHeld(event.modifierFlags.contains(.option))
            }
            return event
        }
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.presentationDidChange() }
        }
        layoutDidChange()
    }

    func paragraphRect(at offset: Int) -> CGRect? {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return nil }
        let native = nativeParagraph(at: offset)
        if editor.string.isEmpty { manager.ensureLayout(for: container) }
        else { manager.ensureLayout(forCharacterRange: native) }
        var rect: CGRect
        if native.length == 0 { rect = manager.extraLineFragmentUsedRect }
        else {
            let glyphs = manager.glyphRange(forCharacterRange: native, actualCharacterRange: nil)
            rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        rect = rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        rect.origin.x = editor.textContainerOrigin.x
        rect.size.width = max(10, editor.bounds.width - editor.textContainerOrigin.x * 2)
        if rect.height < 10 { rect.size.height = editor.bodyFont.ascender - editor.bodyFont.descender + editor.lineSpacing }
        return rect
    }
    func paragraphGrip(at offset: Int) -> CGRect? {
        guard let editor, let rect = paragraphRect(at: offset) else { return nil }
        return CGRect(x: max(0, editor.textContainerOrigin.x - 32), y: rect.midY - 14, width: 28, height: 28)
    }
    func paragraphOpacity(at offset: Int) -> CGFloat {
        guard let editor, model?.focusDimming == true else { return 1 }
        let range = nativeParagraph(at: offset)
        if session?.selectedDocumentID == key.documentID,
           nativeParagraph(at: editor.selectedRange().location).location == range.location { return 1 }
        return 0.24
    }
    func setOptionHeld(_ held: Bool) {
        guard held != optionHeld else { return }
        optionHeld = held
        if held, hovered != nil, model?.whisperTyping == true { model?.whisperTyping = false }
        if let hovered { invalidateParagraph(at: hovered) }
        if !held { requests?.workspaceHoverEnd?() }
        else if let editor, let hovered, model?.whisperTyping != true {
            requests?.workspaceHover?(editor, key, hovered)
        }
    }
    private func presentedOpacity(at offset: Int) -> CGFloat {
        let desired = paragraphOpacity(at: offset), now = ProcessInfo.processInfo.systemUptime
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return desired }
        if fades[offset]?.to != desired {
            fades[offset] = .init(from: renderedOpacity[offset] ?? 1, to: desired, began: now)
            if renderedOpacity[offset, default: 1] != desired { invalidateParagraph(at: offset, duration: 0.28) }
        }
        guard let fade = fades[offset] else { return desired }
        let value = fade.from + (fade.to - fade.from) * WorkspaceHTMLStyle.progress((now - fade.began) / 0.28)
        renderedOpacity[offset] = value
        return value
    }
    /// Includes the gutter grip and background bleed, clipped to the viewport.
    func paragraphDamage(at offset: Int) -> CGRect? {
        guard let editor, let paragraph = paragraphRect(at: offset) else { return nil }
        var rect = paragraph.insetBy(dx: -12, dy: -4)
        if let grip = paragraphGrip(at: offset) { rect = rect.union(grip) }
        rect = rect.intersection(editor.visibleRect)
        return rect.isEmpty || rect.isNull ? nil : rect
    }
    private func invalidateParagraph(at offset: Int, duration: Double = 0) {
        guard let editor, let rect = paragraphDamage(at: offset) else { return }
        editor.setNeedsDisplay(rect)
        guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let end = ProcessInfo.processInfo.systemUptime + duration
        motionRegions[offset] = MotionRegion(rect: rect, until: max(end, motionRegions[offset]?.until ?? 0))
        guard presentationClock == nil else { return }
        presentationClock = WorkspaceDisplayClock(view: editor) { [weak self] in
            guard let self else { return false }
            guard let editor = self.editor, editor.window != nil else {
                self.motionRegions.removeAll(); self.presentationClock = nil; return false
            }
            let now = ProcessInfo.processInfo.systemUptime
            for (offset, region) in self.motionRegions {
                let rect = region.rect.intersection(editor.visibleRect)
                if !rect.isNull && !rect.isEmpty { editor.setNeedsDisplay(rect) }
                if now >= region.until || rect.isEmpty || rect.isNull { self.motionRegions.removeValue(forKey: offset) }
            }
            if self.motionRegions.isEmpty { self.presentationClock = nil; return false }
            return true
        }
    }
    private func presentationDidChange() {
        layoutDidChange()
        let focus = model?.focusDimming == true
        let active = session?.selectedDocumentID == key.documentID
        let whisper = model?.whisperTyping == true
        let resonance = model?.resonatingTerm
        let terms = model?.entityTerms ?? []
        if focus != previousFocus || (focus && active != previousActive) {
            for range in visibleParagraphs() { invalidateParagraph(at: range.location, duration: 0.28) }
        } else if resonance != previousResonance || terms != previousTerms {
            for range in visibleParagraphs() { invalidateParagraph(at: range.location) }
        } else if whisper != previousWhisper, let hovered { invalidateParagraph(at: hovered) }
        previousFocus = focus; previousActive = active; previousWhisper = whisper
        previousResonance = resonance; previousTerms = terms
    }
    private func nativeParagraph(at offset: Int) -> NSRange {
        guard let editor else { return NSRange(location: 0, length: 0) }
        let ns = editor.string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        var range = ns.paragraphRange(for: NSRange(location: min(max(0, offset), ns.length), length: 0))
        let block = editor.blockInfo(in: range).block
        if block == .code || block == .math {
            while range.location > 0 {
                let previous = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
                guard editor.blockInfo(in: previous).block == block else { break }
                range = NSUnionRange(previous, range)
            }
            while range.upperBound < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: range.upperBound, length: 0))
                guard editor.blockInfo(in: next).block == block else { break }
                range = NSUnionRange(range, next)
            }
        }
        return range
    }
    private func offset(at point: CGPoint) -> Int {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return 0 }
        // Gutter grips are outside the text container. Hit the same visual line at
        // its leading glyph instead of asking TextKit to resolve an out-of-bounds X.
        let translated = CGPoint(x: max(1, point.x - editor.textContainerOrigin.x), y: point.y - editor.textContainerOrigin.y)
        return min(editor.string.utf16.count, manager.characterIndex(for: translated, in: container, fractionOfDistanceBetweenInsertionPoints: nil))
    }
    private func anchor(at offset: Int) -> WorkspaceParagraphAnchor? {
        guard let editor, !editor.hasMarkedText(), let body = session?.document(key.documentID)?.body else { return nil }
        // Explicit user drag, outside the typing/prediction path. Prove the native source once.
        guard editor.serialize().utf16.elementsEqual(body.utf16) else { return nil }
        let native = nativeParagraph(at: offset)
        let range = native.length == 0 ? NSRange(location: 0, length: 0)
            : editor.originalParagraphRange(forNative: native)
        guard let range else { return nil }
        return WorkspaceParagraphAnchor(key: key, body: body, range: range)
    }

    func mouseDown(_ event: NSEvent) -> Bool {
        guard let editor, let session, event.buttonNumber == 0, event.modifierFlags.contains(.option), !editor.hasMarkedText(),
              model?.isDragging != true, model?.whisperTyping != true else { return false }
        let point = editor.convert(event.locationInWindow, from: nil), position = offset(at: point)
        guard let grip = paragraphGrip(at: position), grip.contains(point) else { return false }
        session.selectDocument(key.documentID); editor.window?.makeFirstResponder(editor)
        guard let anchor = anchor(at: position), anchor.range.length > 0 else { return false }
        drag = (anchor, event.locationInWindow, false)
        requests?.workspaceHoverEnd?(); editor.hideSelectionToolbar()
        return true
    }
    func mouseDragged(_ event: NSEvent) -> Bool {
        guard var drag, let editor, let requests else { return false }
        editor.enclosingSpatialCanvas?.autoscroll(with: event)
        if !drag.active {
            guard hypot(event.locationInWindow.x - drag.start.x, event.locationInWindow.y - drag.start.y) > 6 else { return true }
            drag.active = true; NSCursor.closedHand.push()
        }
        self.drag = drag
        var nextEditor: BlockTextView?, nextAnchor: WorkspaceParagraphAnchor?, nextAfter = false
        for (candidateKey, candidate) in requests.registeredEditors where candidateKey.projectID == key.projectID && candidate.window === editor.window {
            let point = candidate.convert(event.locationInWindow, from: nil)
            guard candidate.visibleRect.contains(point), !candidate.hasMarkedText(),
                  let interaction = candidate.workspaceInteraction as? WorkspaceEditorInteraction else { continue }
            candidate.autoscroll(with: event)
            let position = interaction.offset(at: point)
            guard let rect = interaction.paragraphRect(at: position), let anchor = interaction.anchor(at: position) else { continue }
            if anchor.key == drag.source.key && NSIntersectionRange(anchor.range, drag.source.range).length > 0 { break }
            nextEditor = candidate; nextAnchor = anchor; nextAfter = point.y > rect.midY
            if targetEditor !== candidate || target?.range != anchor.range || after != nextAfter {
                clearTargetPreview(); interaction.showDropPreview(at: position, after: nextAfter)
            }
            break
        }
        if nextEditor == nil { clearTargetPreview() }
        targetEditor = nextEditor; target = nextAnchor; after = nextAfter
        showPill(event, copying: event.modifierFlags.contains(.command))
        return true
    }
    func mouseUp(_ event: NSEvent) -> Bool {
        guard let drag else { return false }
        let target = target
        clearTargetPreview(); self.drag = nil; self.target = nil; targetEditor = nil
        pointerSpring.stop(); pill?.orderOut(nil); pill?.close(); pill = nil
        if drag.active { NSCursor.pop() }
        guard drag.active, let target, let session, let requests else { return true }
        do {
            try WorkspaceParagraphTransfer.perform(source: drag.source, target: target, after: after,
                copy: event.modifierFlags.contains(.command), session: session, requests: requests,
                undoManager: requests.editor(for: target.key)?.undoManager)
            let remaining = (drag.source.body as NSString).replacingCharacters(in: drag.source.range, with: "")
            let copying = event.modifierFlags.contains(.command) || remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            model?.showToast(target.key == drag.source.key ? "문단 순서를 옮겼습니다" :
                "‘\(session.document(target.key.documentID)?.title ?? "")’ 파일로 문단을 \(copying ? "복사" : "이동")했습니다")
        } catch { session.reportError(error) }
        editor?.needsDisplay = true
        return true
    }
    func mouseMoved(_ event: NSEvent) {
        guard let editor else { return }
        pointerInEditor = editor.convert(event.locationInWindow, from: nil)
        setOptionHeld(event.modifierFlags.contains(.option))
        model?.notePointer(at: editor.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
        let previous = hovered
        hovered = offset(at: pointerInEditor)
        let oldParagraph = previous.map { nativeParagraph(at: $0).location }
        let newParagraph = hovered.map { nativeParagraph(at: $0).location }
        if optionHeld, oldParagraph != newParagraph {
            if let oldParagraph { invalidateParagraph(at: oldParagraph) }
            if let newParagraph { invalidateParagraph(at: newParagraph) }
        } else if optionHeld, let hovered, let grip = paragraphGrip(at: hovered) {
            editor.setNeedsDisplay(grip)
        }
        if optionHeld, model?.whisperTyping != true, drag == nil, model?.isDragging != true, let hovered {
            requests?.workspaceHover?(editor, key, hovered)
        }
    }
    func mouseExited() {
        let previous = hovered; hovered = nil
        if let previous { invalidateParagraph(at: previous) }
        requests?.workspaceHoverEnd?()
    }
    func keyDown(_ event: NSEvent) {
        if event.keyCode == 53, drag != nil { cancelDrag(); return }
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option), !(event.characters ?? "").isEmpty else { return }
        model?.noteTyping(at: NSEvent.mouseLocation); requests?.workspaceHoverEnd?()
    }
    func selectionDidChange() {
        centerTypewriter()
        if let editor, session?.selectedDocumentID == key.documentID, !editor.hasMarkedText() {
            let range = nativeParagraph(at: editor.selectedRange().location)
            if previousSelection != range.location {
                if let previousSelection { invalidateParagraph(at: previousSelection) }
                invalidateParagraph(at: range.location)
                previousSelection = range.location
            }
            model?.activeParagraph = (editor.string as NSString).substring(with: range)
        }
    }
    func layoutDidChange() {
        guard let editor else { return }
        let typewriter = model?.typewriter == true
        let changed = previousTypewriter != typewriter || previousEditorSize != editor.bounds.size
        previousTypewriter = typewriter; previousEditorSize = editor.bounds.size
        if changed, let scroll = editor.enclosingScrollView as? WritingScrollView {
            scroll.workspacePresentationEnabled = true; scroll.workspaceTypewriter = typewriter
            scroll.updateWorkspaceInsets()
        }
        if changed {
            motionRegions.removeAll(); presentationClock?.invalidate(); presentationClock = nil
            centerTypewriter()
            let now = ProcessInfo.processInfo.systemUptime
            for (offset, fade) in fades where now < fade.began + 0.28 {
                invalidateParagraph(at: offset, duration: fade.began + 0.28 - now)
            }
            if let flashRange, now < flashBegan + 0.9 {
                invalidateParagraph(at: flashRange.location, duration: flashBegan + 0.9 - now)
            }
        }
    }
    private func centerTypewriter() {
        guard !centering, model?.typewriter == true, let editor, !editor.hasMarkedText(),
              model?.isDragging != true, editor.window?.firstResponder === editor, editor.selectedRange().length == 0,
              session?.selectedDocumentID == key.documentID, let scroll = editor.enclosingScrollView,
              let rect = editor.caretRectInView() else { return }
        centering = true; defer { centering = false }
        let clip = scroll.contentView
        let minimum = -scroll.contentInsets.top
        let maximum = max(minimum, editor.bounds.height - clip.bounds.height + scroll.contentInsets.bottom)
        let y = min(maximum, max(minimum, rect.midY - clip.bounds.height / 2))
        guard abs(clip.bounds.minY - y) > 0.5 else { return }
        // Use the same native caret rect as selection, IME and Ghost. Queued scroll
        // animations can otherwise pull a newer insertion point back to an old line.
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
    }

    private func visibleParagraphs(in dirtyRect: CGRect? = nil) -> [NSRange] {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return [] }
        var rect = (dirtyRect ?? editor.visibleRect).intersection(editor.visibleRect)
        guard !rect.isEmpty && !rect.isNull else { return [] }
        rect = rect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        // A gutter-only invalidation must still enumerate the adjacent text line.
        rect.origin.x = 0; rect.size.width = container.size.width
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var seen: Set<Int> = []
        return editor.indexedMediaParagraphs(in: characters).compactMap {
            let range = nativeParagraph(at: $0.range.location)
            return seen.insert(range.location).inserted ? range : nil
        }
    }
    func drawBackground(_ dirtyRect: CGRect) {
        if let editor, let flashRange, let rect = paragraphRect(at: flashRange.location), rect.intersects(dirtyRect) {
            let t = WorkspaceHTMLStyle.progress((ProcessInfo.processInfo.systemUptime - flashBegan) / 0.9)
            (editor.palette.activeBg.blended(withFraction: t, of: editor.palette.activeLine) ?? editor.palette.activeBg).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -12, dy: -3), xRadius: 8, yRadius: 8).fill()
        }
        guard optionHeld, let editor, let term = model?.resonatingTerm, !term.isEmpty else { return }
        for range in visibleParagraphs(in: dirtyRect) {
            guard (editor.string as NSString).substring(with: range).contains(term), let rect = paragraphRect(at: range.location), rect.intersects(dirtyRect) else { continue }
            editor.palette.hover.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: -12, dy: -3), xRadius: 8, yRadius: 8).fill()
        }
    }
    func draw(_ dirtyRect: CGRect) {
        guard let editor else { return }
        for range in visibleParagraphs(in: dirtyRect) {
            guard let rect = paragraphRect(at: range.location), let damage = paragraphDamage(at: range.location), damage.intersects(dirtyRect) else { continue }
            let opacity = presentedOpacity(at: range.location)
            if opacity < 1 {
                editor.palette.editorSurface.withAlphaComponent(1 - opacity).setFill()
                rect.insetBy(dx: -12, dy: -3).fill()
            }
            if optionHeld, model?.whisperTyping != true, hovered.map({ nativeParagraph(at: $0).location == range.location }) == true,
               let grip = paragraphGrip(at: range.location) {
                let overGrip = grip.contains(pointerInEditor)
                if overGrip { editor.palette.hover.setFill(); NSBezierPath(roundedRect: grip, xRadius: 5, yRadius: 5).fill() }
                (overGrip ? editor.palette.ink : editor.palette.ink2.withAlphaComponent(0.65)).setFill()
                for row in 0..<3 { for column in 0..<2 {
                    NSBezierPath(ovalIn: CGRect(x: grip.midX - 4 + CGFloat(column) * 5,
                        y: grip.midY - 5 + CGFloat(row) * 4, width: 1.7, height: 1.7)).fill()
                } }
                drawEntityUnderlines(in: range, editor: editor)
            }
        }
        if let preview, let rect = paragraphRect(at: preview.range.location) {
            editor.palette.workspaceMuted.withAlphaComponent(0.32).setFill()
            CGRect(x: rect.minX, y: (preview.after ? rect.maxY + 12 : rect.minY - 12), width: rect.width, height: 1.5).fill()
        }
    }
    private func drawEntityUnderlines(in paragraph: NSRange, editor: BlockTextView) {
        guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let native = editor.string as NSString
        for term in model?.entityTerms ?? [] where !term.isEmpty && term.count <= 80 {
            var cursor = paragraph.location
            while cursor < paragraph.upperBound {
                let range = native.range(of: term, range: .init(location: cursor, length: paragraph.upperBound - cursor))
                guard range.location != NSNotFound else { break }; cursor = range.upperBound
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: .init(location: NSNotFound, length: 0), in: container) { rect, _ in
                    let rect = rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    let path = NSBezierPath(); path.lineWidth = 1; path.setLineDash([1, 2], count: 2, phase: 0)
                    path.move(to: .init(x: rect.minX, y: rect.maxY - 3)); path.line(to: .init(x: rect.maxX, y: rect.maxY - 3))
                    (self.model?.resonatingTerm == term ? editor.palette.novel : editor.palette.sepStrong).setStroke(); path.stroke()
                }
            }
        }
    }
    private func showDropPreview(at position: Int, after: Bool) {
        guard let editor, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        clearDropPreview()
        let range = nativeParagraph(at: position)
        guard range.length > 0, range.location < storage.length else { return }
        let original = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
        preview = (range, original, editor.string, after)
        let text = editor.string
        previewTask = Task { [weak self, weak editor] in
            let began = ProcessInfo.processInfo.systemUptime
            repeat {
                guard !Task.isCancelled, let self, let editor, editor.string == text, !editor.hasMarkedText(), self.preview?.range == range else { return }
                let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : (ProcessInfo.processInfo.systemUptime - began) / 0.26
                let changed = original.mutableCopy() as! NSMutableParagraphStyle
                let gap = 26 * WorkspaceHTMLStyle.progress(progress)
                if after { changed.paragraphSpacing += gap } else { changed.paragraphSpacingBefore += gap }
                editor.textStorage?.addAttribute(.paragraphStyle, value: changed, range: range); editor.needsDisplay = true
                if progress >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            } while !Task.isCancelled
        }
    }
    private func clearDropPreview() {
        previewTask?.cancel(); previewTask = nil
        guard let preview, let editor else { return }
        self.preview = nil
        if editor.string.utf16.elementsEqual(preview.text.utf16), preview.range.upperBound <= editor.string.utf16.count {
            editor.textStorage?.addAttribute(.paragraphStyle, value: preview.style, range: preview.range)
        }
        editor.needsDisplay = true
    }
    private func clearTargetPreview() { (targetEditor?.workspaceInteraction as? WorkspaceEditorInteraction)?.clearDropPreview() }
    private func showPill(_ event: NSEvent, copying: Bool) {
        guard let editor, let drag else { return }
        if pill == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 58),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.level = .floating
            pill = panel
        }
        let text = (drag.source.body as NSString).substring(with: drag.source.range)
        let meta = NSTextField(labelWithString: copying ? "문단 복제 (다른 파일로 복사)" : "문단 이동 (⌘ 누르면 복제)")
        meta.font = PurloryFonts.mono(10); meta.textColor = editor.palette.ink2
        let label = NSTextField(wrappingLabelWithString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        label.font = PurloryFonts.serif(11.5); label.textColor = editor.palette.ink; label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        let width = min(320, max(meta.fittingSize.width + 42, min(296, label.fittingSize.width) + 24))
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 62)); surface.wantsLayer = true
        surface.layer?.cornerRadius = 10; surface.layer?.backgroundColor = editor.palette.pill.cgColor
        let icon = NSImageView(frame: .init(x: 12, y: 42, width: 12, height: 12))
        icon.image = WorkspaceIcons.image("file-symlink", size: 12); icon.contentTintColor = editor.palette.ink2
        meta.frame = .init(x: 30, y: 40, width: width - 42, height: 16)
        label.frame = CGRect(x: 12, y: 8, width: width - 24, height: 30)
        surface.addSubview(icon); surface.addSubview(meta); surface.addSubview(label)
        pill?.setContentSize(surface.frame.size); pill?.contentView = surface; pill?.alphaValue = 0.95
        let point = editor.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if let pill { pointerSpring.move(pill, to: CGPoint(x: point.x + 14, y: point.y + 18 - pill.frame.height), reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        pill?.orderFrontRegardless()
    }
    private func cancelDrag() {
        clearTargetPreview(); clearDropPreview()
        if drag?.active == true { NSCursor.pop() }
        drag = nil; target = nil; targetEditor = nil
        pointerSpring.stop(); pill?.orderOut(nil); pill?.close(); pill = nil
    }
    func detach() {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
        cancelDrag(); flashTask?.cancel(); flashTask = nil; presentationClock?.invalidate(); presentationClock = nil
        motionRegions.removeAll(); subscription?.cancel(); subscription = nil
    }
}
