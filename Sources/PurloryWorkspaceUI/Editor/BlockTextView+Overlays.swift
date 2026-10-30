import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

// Caret, selection, Ghost and transient editing tools.
extension BlockTextView {

    /// 접근성 경로가 쓰는 현재 제안 스냅샷 — 시각 드로잉과 **같은 원천**이다 (#24).
    func ghostSnapshotForAccessibility() -> (text: String, generation: Int)? {
        guard let ghost = ghostText, !ghost.isEmpty else { return nil }
        return (ghost, ghostGeneration)
    }

    /// NSTextView can notify selection/insertion changes before an insertion or
    /// IME update has finished. Resolve the final layout once those edits unwind.
    func finishNativeTextUpdate() {
        nativeTextUpdateDepth -= 1
        guard nativeTextUpdateDepth == 0 else { return }
        scheduleEditingOverlayRefresh(restartBlink: true)
    }

    func scheduleEditingOverlayRefresh(restartBlink: Bool = false) {
        pendingCaretBlinkRestart = pendingCaretBlinkRestart || restartBlink
        guard !editingOverlayRefreshPending else { return }
        editingOverlayRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editingOverlayRefreshPending = false
            let restart = self.pendingCaretBlinkRestart
            self.pendingCaretBlinkRestart = false
            guard self.window != nil else { return }
            self.refreshActiveLineHighlight(restartBlink: restart)
        }
    }

    /// Synchronize the paragraph background, selection cleanup and caret after
    /// selection, focus or layout changes. Keep one background view so moving
    /// between paragraphs cannot leave stale bands behind.
    func refreshActiveLineHighlight(restartBlink: Bool = true) {
        guard nativeTextUpdateDepth == 0, !isTransforming else {
            scheduleEditingOverlayRefresh(restartBlink: restartBlink)
            return
        }
        guard !refreshingEditingOverlays else { return }
        refreshingEditingOverlays = true
        defer { refreshingEditingOverlays = false }
        syncActiveLineView()
        // 직전 선택 하이라이트 영역 무효화 — 공백·개행 선택 잔상 방지.
        let selection = selectionHighlightRect()
        if selection != lastSelectionRect, let oldSelection = lastSelectionRect {
            setNeedsDisplay(oldSelection.insetBy(dx: -4, dy: -4))
        }
        lastSelectionRect = selection
        syncCaretView(restartBlink: restartBlink)
    }

    /// 현재 선택 하이라이트가 그려질 수 있는 영역 (뷰 좌표). 선택이 없으면 nil.
    ///
    /// 개행 선택은 마지막 글리프 오른쪽 바깥까지 그려지므로, 세로는 글리프
    /// bounding rect를 따르되 가로는 컨테이너 전체 폭으로 잡는다 — 지우기
    /// 전용이라 넓게 잡아도 다시 그리는 비용만 조금 늘 뿐 안전하다.
    func selectionHighlightRect() -> NSRect? {
        let range = selectedRange()
        guard range.length > 0, let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // 문서 끝 개행까지 선택되면 여분 라인 프래그먼트에도 하이라이트가 걸친다.
        if range.upperBound >= (string as NSString).length {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { rect = rect.union(extra) }
        }
        rect.origin.x = 0
        rect.size.width = textContainer.size.width
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Highlight the native paragraph, including wraps and U+2028 line breaks.
    /// TextKit's used fragments include first-line indents and author alignment;
    /// a container-wide band starts too far left in indented manuscripts.
    func activeParagraphRect() -> NSRect? {
        guard let window, window.firstResponder === self,
            selectedRange().length == 0,
            selectedRange().location != NSNotFound,
            selectedImageLocation == nil,
            !isEditingMath,
            let layoutManager, let textContainer
        else { return nil }
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        layoutManager.ensureLayout(forCharacterRange: paragraph)
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        var bounds: NSRect?
        func include(_ fragment: NSRect, used: NSRect) {
            guard fragment.height > 0 else { return }
            let top = max(fragment.minY, used.minY - 2)
            let bottom = min(fragment.maxY, used.maxY + 2)
            let rect = NSRect(x: used.minX, y: top,
                width: max(1, fragment.maxX - padding - used.minX),
                height: max(1, bottom - top))
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        if paragraph.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, _, _ in
                include(fragment, used: used)
            }
        }
        // A terminal soft break has an empty visual line in the SAME paragraph.
        // A terminal Enter instead belongs to the next, empty paragraph.
        let endsWithSoftBreak = paragraph.upperBound == ns.length && ns.length > 0
            && ns.character(at: ns.length - 1) == 0x2028
        if paragraph.length == 0 || endsWithSoftBreak {
            layoutManager.ensureLayout(for: textContainer)
            let extra = layoutManager.extraLineFragmentRect
            if layoutManager.extraLineFragmentTextContainer === textContainer, extra.height > 0 {
                var used = layoutManager.extraLineFragmentUsedRect
                if caret == ns.length, let insertion = caretRectInView() {
                    used.origin.x = insertion.minX - origin.x
                }
                include(extra, used: used)
            }
        }
        return bounds?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 선택이 생기면 잠깐 안정된 뒤 툴바를 띄우고, 사라지면 감춘다.
    func updateSelectionToolbar() {
        toolbarShowTask?.cancel()
        let sel = selectedRange()
        // 공백만 있는(단어 삭제용 같은) 사소한 선택이나 IME 조합 중이면 띄우지 않는다.
        let selected = sel.length > 0 ? (string as NSString).substring(with: sel) : ""
        guard sel.length > 0, !hasMarkedText(),
            !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            hideSelectionToolbar()
            return
        }
        // 드래그 중 깜빡임 방지 — 선택이 멈춘 뒤에 띄우되, 지연은 짧게(120ms)해 굼떠
        // 보이지 않게 한다.
        toolbarShowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.presentSelectionToolbar()
        }
    }

    func hideSelectionToolbar() {
        toolbarShowTask?.cancel()
        if let panel = workspaceSelectionPanel {
            workspaceSelectionPanel = nil
            panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close()
        }
        toolbarHost?.removeFromSuperview()
    }

    func presentSelectionToolbar() {
        guard isEditable, !hasMarkedText() else { hideSelectionToolbar(); return }
        guard let layoutManager, let textContainer else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        let ns = string as NSString
        var trimmedSel = sel
        while trimmedSel.length > 0 {
            let ch = ns.character(at: trimmedSel.upperBound - 1)
            if ch == 0x0A || ch == 0x0D || ch == 0x2028 {
                trimmedSel.length -= 1
            } else {
                break
            }
        }
        guard trimmedSel.length > 0 else { hideSelectionToolbar(); return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: trimmedSel, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let view = SelectionToolbarView(
            theme: palette, state: currentSelectionState(), onAction: { [weak self] action in self?.perform(action) },
            onPolish: workspaceInteraction.map { interaction in { [weak interaction] in interaction?.polishSelection() } })
        let host: NSHostingView<SelectionToolbarView>
        if let existing = toolbarHost {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            toolbarHost = host
        }
        let size = host.fittingSize
        if editorialWorkspaceStyle, let window {
            // A fixed source popover crosses tile boundaries instead of being clipped by a column.
            let anchor = window.convertToScreen(convert(rect, to: nil))
            let screen = window.screen?.visibleFrame ?? window.frame
            let panel = workspaceSelectionPanel ?? WorkspaceSelectionPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let appeared = workspaceSelectionPanel == nil
            panel.becomesKeyOnlyIfNeeded = true
            panel.initialFirstResponder = nil
            panel.title = "선택 서식"; panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = true; panel.level = .floating
            panel.contentView = host; panel.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            if appeared {
                let point = CGPoint(x: min(screen.maxX - size.width - 8, max(screen.minX + 8, anchor.midX - size.width / 2)),
                    y: min(screen.maxY - size.height - 8, anchor.maxY + 8))
                panel.setFrameOrigin(.init(x: point.x, y: point.y - 4))
                window.addChildWindow(panel, ordered: .above)
                panel.alphaValue = 0.01
                panel.orderFront(nil)
                panel.makeFirstResponder(nil)
                WorkspaceHTMLStyle.animate(0.22) { panel.animator().alphaValue = 1; panel.animator().setFrameOrigin(point) }
            } else if !panel.isKeyWindow {
                panel.makeFirstResponder(nil)
            }
            workspaceSelectionPanel = panel
            return
        }
        // 이미 떠 있으면 위치를 고정한다 — 글자 크기를 줄이면 선택 rect가 움직여
        // 툴바가 따라다니며 연타를 방해했다. 한번 뜬 툴바는 선택이 사라질 때까지
        // 그 자리(상단 중앙 기준)에 머문다 (요구 3).
        if host.superview === self {
            let old = host.frame
            host.frame = NSRect(
                x: old.midX - size.width / 2, y: old.minY,
                width: size.width, height: size.height)
            return
        }
        // 선택 위 중앙 — 문서 맨 위라 걸리면 선택 아래로 내린다 (flipped 좌표).
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = rect.maxY + 8 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        host.frame = NSRect(origin: origin, size: size)
        addSubview(host)
        if editorialWorkspaceStyle && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            host.alphaValue = 0; host.frame.origin.y += 4
            WorkspaceHTMLStyle.animate(0.22) {
                host.animator().alphaValue = 1; host.animator().setFrameOrigin(origin)
            }
        }
    }

    // MARK: 커서 펄스 · 리플 · 커서 줄 하이라이트 드로잉

    /// 캐럿은 본문 픽셀에 직접 그리지 않는다 — 레거시 캐럿 드로잉도, 시스템
    /// `NSTextInsertionIndicator`도 이 macOS에서 페이드 블링크 중 커서가
    /// 이동하면 사라지던 잔상을 남긴다. 대신 우리가 소유한 단일 NSView를
    /// 캐럿으로 쓴다: 뷰가 하나뿐이고 블링크 애니메이션도 그 뷰의 레이어에만
    /// 붙으므로, 프레임을 옮기면 페이드 중이던 픽셀까지 통째로 따라와
    /// 잔상이 구조적으로 불가능하다.
    /// 이 오버라이드는 시스템 캐럿을 비활성화하는 스위치 역할만 한다.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    /// Ordinary editing has no persistent paragraph background.
    func syncActiveLineView() {
        // Source-navigation flashes are drawn by the workspace; ordinary editing
        // shows only the caret, without a persistent paragraph background.
        activeLineView.isHidden = true
    }

    /// AppKit이 캐럿 상태를 갱신하는 모든 시점(커서 이동·포커스 변화·블링크
    /// 재시작)에 캐럿 뷰·커서 줄 하이라이트를 함께 맞춘다 — 선택 변경 알림이
    /// 오지 않는 경로까지 덮는 안전망.
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        scheduleEditingOverlayRefresh(restartBlink: restartFlag)
    }

    /// 줄바꿈 폭 변경 등 재배치 후에도 캐럿 뷰·하이라이트가 글자를 따라가게 한다.
    override func layout() {
        super.layout()
        refreshActiveLineHighlight(restartBlink: false)
    }

    /// 캐럿 뷰를 현재 커서 위치·테마 색에 맞추고 블링크를 처음부터 다시 시작한다.
    ///
    /// 높이: 시스템 캐럿 rect는 라인 전체를 덮어 글자 위로 떠 보인다. 베이스라인
    /// 위 "글자 실제 높이"만큼만 잡아 글자에 딱 맞춘다. 라틴 capHeight로 자르면
    /// 한글보다 짧아 보이므로 capHeight~ascender 사이로 올려 한글 상단까지 덮는다.
    /// 이미지가 객체로 선택된 동안엔 숨긴다 — 이미지 내부는 편집 대상이 아니라
    /// 조작 대상이므로 커서가 보이면 혼란스럽다.
    func syncCaretView(restartBlink: Bool) {
        let visible =
            window?.firstResponder === self
            && selectedRange().length == 0
            && selectedImageLocation == nil
        guard visible, let line = caretLineGeometry(), let rect = caretRectInView() else {
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            caretView.isHidden = true
            return
        }
        let font = caretLineFont()
        let baseline = line.baselineY
        let glyphTop = font.capHeight + (font.ascender - font.capHeight) * 0.4
        var caret = rect
        caret.origin.y = baseline - glyphTop
        caret.size.height = max(1, glyphTop - font.descender)  // descender 음수
        caret.size.width = 2  // firstRect의 캐럿 폭은 0 — 얇은 표준 폭으로.
        let moved = caretView.isHidden || caretView.frame != caret
        // A typing frame must never inherit a surrounding SwiftUI/AppKit animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if caretView.layer?.backgroundColor != insertionPointColor.cgColor {
                caretView.layer?.backgroundColor = insertionPointColor.cgColor
            }
            if caretView.frame != caret { caretView.frame = caret }
            if caretView.isHidden { caretView.isHidden = false }
        }
        if restartBlink || moved || caretBlinkTimer == nil { restartCaretBlink() }
    }

    /// 블링크를 "보임" 상태부터 다시 시작한다 — 타이핑·이동 중엔 캐럿이
    /// 항상 또렷하게 보이고, 멈춘 뒤부터 부드럽게 깜빡인다.
    func restartCaretBlink() {
        caretBlinkTimer?.invalidate()
        caretView.layer?.removeAllAnimations()
        caretView.alphaValue = 1
        caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target: CGFloat = self.caretView.alphaValue > 0.5 ? 0 : 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    self.caretView.animator().alphaValue = target
                }
            }
        }
    }

    /// 커서가 놓인 줄의 폰트 — 캐럿·하이라이트가 공유하는 메트릭 소스.
    func caretLineFont() -> NSFont {
        if hasMarkedText(), let storage = textStorage, storage.length > 0 {
            let index = min(max(markedRange().location, selectedRange().location - 1), storage.length - 1)
            if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
        }
        return (typingAttributes[.font] as? NSFont) ?? bodyFont
    }

    /// 제안 표시/숨김 — 컨트롤러의 conversationSuggestionDidChange가 부른다.
    func showConversationPrompt(_ range: NSRange?) {
        conversationPromptRange = range.flatMap {
            $0.location + $0.length <= (string as NSString).length ? $0 : nil
        }
        layoutConversationPrompt()
        needsDisplay = true
    }

    /// pill을 대화 마지막 줄 끝 아래에 놓는다 — 화면을 흔들지 않는다 (§3 조용한 UI).
    func layoutConversationPrompt() {
        guard let range = conversationPromptRange,
            let layoutManager, let textContainer
        else {
            conversationPromptView.isHidden = true
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else {
            conversationPromptView.isHidden = true
            return
        }
        let bounding = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let label = conversationPromptView
        label.stringValue = "  이 대화를 기록할까요?  ⏎ 기록 · esc 닫기  "
        label.textColor = palette.novel
        label.layer?.backgroundColor = palette.pill.cgColor
        label.layer?.borderColor = palette.pillBorder.cgColor
        label.sizeToFit()
        var frame = label.frame
        frame.size.height += 6
        frame.origin.x = min(
            bounding.maxX + origin.x - frame.width,
            bounds.width - frame.width - textContainerInset.width)
        frame.origin.x = max(frame.origin.x, origin.x + 4)
        frame.origin.y = bounding.maxY + origin.y + 4
        label.frame = frame
        label.isHidden = false
    }

    /// 블록 전체의 아주 약한 배경 하이라이트 — draw(_:)가 본문 아래에 깐다.
    func drawConversationHighlight(in dirtyRect: NSRect) {
        guard let range = conversationPromptRange,
            let layoutManager, let textContainer
        else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let origin = textContainerOrigin
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer
        ) { rect, _ in
            let shifted = rect.offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: -3, dy: -1)
            guard shifted.intersects(dirtyRect) else { return }
            self.palette.novel.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: shifted, xRadius: 5, yRadius: 5).fill()
        }
    }

    // MARK: 고스트 렌더

    /// AI 제안을 **즉시** 표시한다 (#27 모션 감사). 과거엔 150ms 페이드인을
    /// 12ms redraw 루프로 그렸는데, 제안 하나마다 메인 액터가 12회 다시 그려졌고
    /// 첫 글자 지연 예산(PLAN §10)을 깎아 먹었다. "고스트는 조용히"의 정답은
    /// 모션이 아니라 침묵이다 — 나타나고, 거절되면 흔적 없이 사라진다.
    func startGhostFadeIn() {
        ghostFadeTask?.cancel()
        ghostOpacity = 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The single activeLineView covers the active paragraph and clears its
        // old frame atomically when selection or layout changes.

        // 드래그 선택 영역 — 시스템 사각 하이라이트 대신 줄별 라운드 사각형을
        // 본문 아래에 깔아 그린다 (우리식 드래그 표시, 테마 selection 토큰).
        drawSelectionHighlight(in: dirtyRect)

        // 대화 기록 제안 중인 블록의 은은한 하이라이트 (요구사항 §20).
        drawConversationHighlight(in: dirtyRect)

        workspaceInteraction?.drawBackground(dirtyRect)

        super.draw(dirtyRect)
        // TextKit has now drawn the final glyph layout, including first-character
        // fallback fonts and the empty-to-nonempty paragraph transition.
        refreshActiveLineHighlight(restartBlink: false)
        workspaceInteraction?.draw(dirtyRect)

        // 이미지 이동 드래그 중 드롭 위치 표시선 (요구 B).
        if let y = imageDropIndicatorY {
            let inset = textContainerInset.width
            palette.blue.setFill()
            NSRect(x: inset, y: y - 1, width: bounds.width - inset * 2, height: 2).fill()
        }

        guard let ghost = ghostText, !ghost.isEmpty,
            !hasMarkedText(),
            selectedRange().length == 0,
            let caretRect = caretRectInView()
        else { return }

        // 커서 문단의 실제 폰트로 그린다 — 제목 줄에서도 크기가 맞는다.
        let font = (typingAttributes[.font] as? NSFont) ?? bodyFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.ghostSuggestion.withAlphaComponent(ghostOpacity),
        ]
        // 프래그먼트 top(caretRect.minY)이 아니라 본문 글리프와 같은
        // 베이스라인에 맞춰야 실제 글자 높이와 일치한다 (줄 간격과 무관하게).
        let y = caretBaselineY().map { $0 - font.ascender } ?? caretRect.minY
        let attributed = NSAttributedString(string: ghost, attributes: attributes)
        let containerWidth = textContainer?.size.width ?? bounds.width
        // 커서 오른쪽 남은 폭 — 줄 끝·좁은 창에서 클리핑되지 않게 (#24).
        let inlineAvailable = containerWidth - caretRect.maxX + textContainerOrigin.x
        if Self.ghostFitsInline(
            textWidth: attributed.size().width, availableWidth: inlineAvailable)
        {
            attributed.draw(at: NSPoint(x: caretRect.maxX, y: y))
            return
        }
        // 줄바꿈 — 다음 줄 시작(컨테이너 좌측)에서 최대 3줄로 감싸 그린다.
        let wrappedWidth = max(120, containerWidth)
        var bounding = attributed.boundingRect(
            with: NSSize(width: wrappedWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        bounding.size.height = min(bounding.height, CGFloat(Self.ghostMaxLines) * lineHeight)
        // NSTextView/TextKit view coordinates are flipped (Y grows downward).  The old
        // code subtracted a line height from the current glyph top, which moved wrapped
        // Ghost text upward.  Anchor the overlay to the actual current TextKit line
        // fragment and start at its maxY: that is the next visual line boundary and it
        // naturally includes heading/paragraph spacing and extra-line-fragment geometry.
        let wrappedY = Self.ghostWrappedOriginY(
            currentLineFragment: caretLineFragmentRectInView(),
            caretRect: caretRect,
            fallbackLineHeight: lineHeight)
        attributed.draw(
            with: NSRect(
                x: textContainerOrigin.x + 2, y: wrappedY,
                width: wrappedWidth, height: bounding.height),
            options: [.usesLineFragmentOrigin])
    }

    /// Whether the Ghost suggestion still fits to the right of the caret.
    nonisolated static func ghostFitsInline(textWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        textWidth <= availableWidth && availableWidth > 0
    }

    /// Wrapped Ghost starts at the next visual line boundary in flipped view coordinates.
    ///
    /// The preferred input is an actual TextKit line fragment already converted into
    /// view coordinates.  The caret fallback keeps empty/unlaid-out editor states safe.
    nonisolated static func ghostWrappedOriginY(
        currentLineFragment: NSRect?,
        caretRect: NSRect,
        fallbackLineHeight: CGFloat
    ) -> CGFloat {
        if let currentLineFragment, currentLineFragment.height > 0 {
            return currentLineFragment.maxY
        }
        if caretRect.height > 0 {
            return caretRect.maxY
        }
        return caretRect.minY + max(0, fallbackLineHeight)
    }

    // MARK: 고스트 접근성 (#24)

    /// VoiceOver 사용자에게만 조용한 알림 — 일반 사용자의 시각 흐름을 건드리지 않는다.
    func postGhostAnnouncement(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.low,
            ])
    }

    /// 제안 등장 안내 — 내용과 조작법을 함께 (완료 조건 1).
    func announceGhostAppearance(_ ghost: String) {
        postGhostAnnouncement("AI 제안: \(ghost.prefix(80)) — Tab으로 수락, Esc로 거절")
    }

    /// NSAccessibility 값 위트니스 — 셀렉터를 프로토콜과 맞춰 기본 구현을
    /// 대체한다(상위 클래스 선언이 없어 override는 불가). #24
    @objc(accessibilityValue)
    public func accessibilityValue() -> Any? {
        return ghostAwareAccessibilityValue()
    }

    /// 실제 조립 본체 — 위트니스와 테스트가 공유한다(모듈 내 자기 호출은
    /// 자기 선언으로 결정적 귀결된다). #24
    func ghostAwareAccessibilityValue() -> Any? {
        // 제안은 텍스트 영역 값의 일부로 노출 — VO가 읽고 복사할 수 있게 (#24).
        guard let snapshot = ghostSnapshotForAccessibility(), !hasMarkedText() else {
            return super.accessibilityValue()
        }
        let base = super.accessibilityValue() ?? ""
        return base + "\n[AI 제안 #\(snapshot.generation) · Tab 수락 · Esc 거절] "
            + snapshot.text
    }

    /// 선택 영역을 하나의 병합 실루엣으로 그린다 — 글자 주위를 살짝(3pt) 감싸는
    /// Purlory만의 민트 틴트 영역 + 헤어라인 테두리 (요구 4).
    ///
    /// 줄별 라운드 사각형을 개별로 그리거나 union하면 폭이 다른 줄의 접합부에
    /// 각 사각형의 코너가 돌출부·계단으로 남는다. 대신 줄 rect들을 하나의
    /// 폴리곤 경계로 만들어 시계 방향으로 한 번에 추적하고, 모든 꼭짓점(볼록·오목)을
    /// 탄젠트 아크로 둥글려 TextEdit·Notes처럼 연속된 윤곽을 얻는다. 무효화는
    /// refreshActiveLineHighlight의 lastSelectionRect(전체 폭 밴드)가 담당하므로
    /// 여기선 그리기만 한다.
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting flag: Bool
    ) {
        let eventType = NSApp?.currentEvent?.type
        let isMouseSelection = flag
            || eventType == .leftMouseDragged
            || eventType == .leftMouseUp
            || eventType == .leftMouseDown
        if isMouseSelection, ranges.count == 1, let storage = textStorage {
            var r = ranges[0].rangeValue
            let ns = storage.string as NSString
            if r.length > 0, r.upperBound <= ns.length {
                let firstPara = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
                // 마우스 드래그가 한 줄(단일 문단) 안에서만 이루어졌는데 줄 끝 빈 공간을
                // 스쳤다는 이유로 뒤따르는 개행이 선택에 포함되면, 줄 끝 빈 공간이 잡히고
                // 삭제·입력 시 다음 줄까지 딸려 올라온다. 단일 문단 내 마우스 드래그에서는
                // 후행 개행을 선택에서 제외한다.
                if r.upperBound == firstPara.upperBound {
                    let lastChar = ns.character(at: r.upperBound - 1)
                    if lastChar == 0x0A || lastChar == 0x0D || lastChar == 0x2028 {
                        r.length -= 1
                    }
                }
            }
            super.setSelectedRanges([NSValue(range: r)], affinity: affinity, stillSelecting: flag)
            return
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
    }

    func drawSelectionHighlight(in dirtyRect: NSRect) {
        let sel = selectedRange()
        guard sel.length > 0, let layoutManager, let textContainer, let storage = textStorage else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let origin = textContainerOrigin
        let ns = storage.string as NSString
        let unselected = NSRange(location: NSNotFound, length: 0)

        // 줄마다 개행 문자(\n, \r, U+2028)를 제외한 실제 글자 범위만 감싼다.
        // withinSelectedGlyphRange에 선택 범위를 그대로 넘기면 AppKit이 개행이 포함된 줄의
        // 사각형을 컨테이너 우측 끝까지(줄 끝 빈 공간 전체) 늘려 버리고, 문단 아래
        // paragraphSpacing까지 높이에 포함시켜 빈 공간이 잡히는 문제가 생긴다.
        var rawRects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphRange, _ in
            let lineChars = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            var subChars = NSIntersectionRange(sel, lineChars)
            while subChars.length > 0 {
                let ch = ns.character(at: subChars.upperBound - 1)
                if ch == 0x0A || ch == 0x0D || ch == 0x2028 {
                    subChars.length -= 1
                } else {
                    break
                }
            }
            guard subChars.length > 0 else { return }
            let subGlyphs = layoutManager.glyphRange(forCharacterRange: subChars, actualCharacterRange: nil)
            guard subGlyphs.length > 0 else { return }

            let font = (subChars.location < storage.length
                ? storage.attribute(.font, at: subChars.location, effectiveRange: nil) as? NSFont
                : nil) ?? self.bodyFont
            let baselineLocalY = lineRect.minY + layoutManager.location(forGlyphAt: subGlyphs.location).y
            let glyphTop = font.capHeight + (font.ascender - font.capHeight) * 0.45
            let topY = origin.y + baselineLocalY - glyphTop - 2
            let bottomY = origin.y + baselineLocalY - font.descender + 2

            var lineUnion: NSRect?
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: subGlyphs, withinSelectedGlyphRange: unselected, in: textContainer
            ) { rect, _ in
                guard rect.width > 0 else { return }
                let r = NSRect(
                    x: rect.minX + origin.x - 3,
                    y: topY,
                    width: rect.width + 6,
                    height: max(1, bottomY - topY))
                lineUnion = lineUnion.map { $0.union(r) } ?? r
            }
            if let lineUnion {
                if let last = rawRects.last, lineUnion.minY < last.maxY - 0.5 {
                    rawRects[rawRects.count - 1] = last.union(lineUnion)
                } else {
                    rawRects.append(lineUnion)
                }
            }
        }
        guard !rawRects.isEmpty else { return }

        // 가로로 겹치고 세로로 인접한 줄들만 하나의 연결 폴리곤 그룹으로 묶는다.
        // 줄 중간 엔터로 인해 윗줄 끝과 아랫줄 시작이 가로로 겹치지 않거나 빈 줄이 끼어 있으면
        // 별도 폴리곤으로 분리해 빈 공간을 가로지르지 않게 한다.
        var groups: [[NSRect]] = [[rawRects[0]]]
        let maxBridgeGap = lineSpacing + 4
        for i in 1..<rawRects.count {
            let prev = groups[groups.count - 1].last!
            let curr = rawRects[i]
            let verticalGap = curr.minY - prev.maxY
            let horizontalOverlap = min(prev.maxX, curr.maxX) - max(prev.minX, curr.minX)
            if verticalGap <= maxBridgeGap && horizontalOverlap > 2 {
                groups[groups.count - 1].append(curr)
            } else {
                groups.append([curr])
            }
        }

        let radius: CGFloat = 5
        let snap = radius * 2 + 2
        let combinedPath = CGMutablePath()

        for var rects in groups {
            let n = rects.count
            for i in 0..<(n - 1) {
                rects[i].size.height = rects[i + 1].minY - rects[i].minY
            }
            rects[0].origin.y += 0.5
            rects[0].size.height -= 0.5
            rects[n - 1].size.height -= 0.5

            for _ in 0..<2 {
                for i in 0..<(n - 1) {
                    if abs(rects[i].minX - rects[i + 1].minX) < snap {
                        let x = min(rects[i].minX, rects[i + 1].minX)
                        rects[i].size.width = rects[i].maxX - x
                        rects[i].origin.x = x
                        rects[i + 1].size.width = rects[i + 1].maxX - x
                        rects[i + 1].origin.x = x
                    }
                    if abs(rects[i].maxX - rects[i + 1].maxX) < snap {
                        let x = max(rects[i].maxX, rects[i + 1].maxX)
                        rects[i].size.width = x - rects[i].minX
                        rects[i + 1].size.width = x - rects[i + 1].minX
                    }
                }
            }

            var corners: [CGPoint] = []
            corners.append(CGPoint(x: rects[0].maxX, y: rects[0].minY))
            for i in 0..<(n - 1) where abs(rects[i].maxX - rects[i + 1].maxX) > 0.5 {
                corners.append(CGPoint(x: rects[i].maxX, y: rects[i].maxY))
                corners.append(CGPoint(x: rects[i + 1].maxX, y: rects[i].maxY))
            }
            corners.append(CGPoint(x: rects[n - 1].maxX, y: rects[n - 1].maxY))
            corners.append(CGPoint(x: rects[n - 1].minX, y: rects[n - 1].maxY))
            for i in stride(from: n - 1, to: 0, by: -1) where abs(rects[i].minX - rects[i - 1].minX) > 0.5 {
                corners.append(CGPoint(x: rects[i].minX, y: rects[i].minY))
                corners.append(CGPoint(x: rects[i - 1].minX, y: rects[i].minY))
            }
            corners.append(CGPoint(x: rects[0].minX, y: rects[0].minY))

            let first = corners[0]
            let last = corners[corners.count - 1]
            combinedPath.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
            for i in 0..<corners.count {
                let prev = i == 0 ? last : corners[i - 1]
                let c = corners[i]
                let next = corners[(i + 1) % corners.count]
                let r = min(
                    radius,
                    hypot(c.x - prev.x, c.y - prev.y) / 2,
                    hypot(next.x - c.x, next.y - c.y) / 2)
                combinedPath.addArc(tangent1End: c, tangent2End: next, radius: max(r, 0))
            }
            combinedPath.closeSubpath()
        }

        guard combinedPath.boundingBoxOfPath.intersects(dirtyRect),
            let ctx = NSGraphicsContext.current?.cgContext
        else { return }
        ctx.saveGState()
        ctx.addPath(combinedPath)
        ctx.setFillColor(palette.selection.cgColor)
        ctx.fillPath()
        ctx.addPath(combinedPath)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(palette.selectionBorder.cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func caretRectInView() -> NSRect? {
        guard let window else { return nil }
        let caret = selectedRange().location
        guard caret != NSNotFound else { return nil }
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        guard screenRect.height > 0 else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        return convert(windowRect, from: nil)
    }

    /// One TextKit coordinate source for the caret and inline Ghost.
    /// Keep AppKit's insertion-point x position and selection/IME handling intact.
    func caretLineGeometry() -> CaretLineGeometry? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        guard selectedRange().location != NSNotFound else { return nil }
        let caret = min(selectedRange().location, ns.length)
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let extra = layoutManager.extraLineFragmentRect
        // Empty documents and final hard/soft breaks have no following glyph.
        // Use the new line's font metrics, never the previous line's baseline.
        let endsWithBreak = ns.length == 0
            || [0x0A, 0x0D, 0x2028, 0x2029].contains(Int(ns.character(at: ns.length - 1)))
        if caret == ns.length,
           endsWithBreak,
           extra.height > 0,
           layoutManager.extraLineFragmentTextContainer === textContainer {
            return CaretLineGeometry(
                fragment: extra.offsetBy(dx: origin.x, dy: origin.y),
                baselineY: origin.y + extra.minY
                    + layoutManager.defaultBaselineOffset(for: caretLineFont()))
        }
        guard ns.length > 0 else { return nil }
        var glyphIndex = layoutManager.glyphIndexForCharacter(at: min(caret, ns.length - 1))
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        var glyphRange = NSRange()
        var fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
        // A soft-wrap boundary has two insertion positions. Upstream affinity
        // belongs to the preceding visual line, never across an explicit break.
        if selectionAffinity == .upstream, caret > 0, caret < ns.length,
           glyphIndex == glyphRange.location,
           ns.lineRange(for: NSRange(location: caret, length: 0)).location < caret {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: caret - 1)
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        guard fragment.height > 0 else { return nil }
        return CaretLineGeometry(
            fragment: fragment.offsetBy(dx: origin.x, dy: origin.y),
            baselineY: origin.y + fragment.minY + layoutManager.location(forGlyphAt: glyphIndex).y)
    }

    func caretLineFragmentRectInView() -> NSRect? { caretLineGeometry()?.fragment }

    func caretBaselineY() -> CGFloat? { caretLineGeometry()?.baselineY }

    // MARK: 타자기 존 스크롤

    /// 커서를 드러낼 때 커서 **아래로 여백(gutter)까지** 함께 보이도록 스크롤한다 —
    /// 활성 줄이 창 바닥에 붙지 않고 화면 중하단의 편안한 위치에 park한다.
    ///
    /// 기본 `scrollRangeToVisible`은 커서를 뷰 하단 끝에 딱 맞춰 park시켜, 글이 한
    /// 화면을 넘기면 그 뒤로 줄곧 바닥을 긁으며 써진다(답답함 → 그만 쓰고 싶음).
    /// 여백은 스크롤 뷰의 `contentInsets.bottom`(=`WritingScrollView`가 뷰 높이에
    /// 비례해 잡아 둔 값)에서 읽는다 — 그래야 문서 끝에서도 그 인셋만큼 더 스크롤할
    /// 수 있어 마지막 줄까지 실제로 들어 올려진다. 인셋이 0이거나(타자기 존 미적용)
    /// 드래그 선택(length>0)·수식 편집 등은 기본 동작으로 넘긴다.
    override func scrollRangeToVisible(_ range: NSRange) {
        let gutter = enclosingScrollView?.contentInsets.bottom ?? 0
        guard range.length == 0, gutter > 0, let window else {
            super.scrollRangeToVisible(range)
            return
        }
        let screen = firstRect(forCharacterRange: range, actualRange: nil)
        guard screen.height > 0 else {
            super.scrollRangeToVisible(range)
            return
        }
        let inView = convert(window.convertFromScreen(screen), from: nil)
        _ = scrollToVisible(
            NSRect(
                x: inView.minX, y: inView.minY,
                width: max(1, inView.width), height: inView.height + gutter))
    }
}
