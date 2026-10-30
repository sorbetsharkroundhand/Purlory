import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

// Native commands, IME, undo and text-storage edit routing.
extension BlockTextView {
    @objc func undo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let manager = undoManager, manager.canUndo else { return }
        breakUndoCoalescing(); manager.undo()
    }
    @objc func redo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let manager = undoManager, manager.canRedo else { return }
        breakUndoCoalescing(); manager.redo()
    }
    func historyCommandEnabled(_ action: Selector?) -> Bool? {
        if action == #selector(undo(_:)) { return isEditable && !hasMarkedText() && undoManager?.canUndo == true }
        if action == #selector(redo(_:)) { return isEditable && !hasMarkedText() && undoManager?.canRedo == true }
        return nil
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        historyCommandEnabled(menuItem.action) ?? super.validateMenuItem(menuItem)
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        historyCommandEnabled(item.action) ?? super.validateUserInterfaceItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { workspaceInteraction?.detach(); hideSelectionToolbar() }
        editorWindowDidChange?(self)
        guard automaticallyFocusOnAttachment, !didInitialFocus, window != nil else { return }
        didInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            editorDidActivate?()
            // AppKit may provide the window undo manager only after editor activation.
            editorWindowDidChange?(self)
            DispatchQueue.main.async { [weak self] in
                // 포커스가 돌아오면 커서 문단의 수식을 소스 모드로 되돌린다.
                self?.refreshRenderedBlocks()
                self?.refreshActiveLineHighlight()
            }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            // 포커스를 잃으면 커서가 수식 문단에 남아 있어도 렌더로 전환하고,
            // 커서 줄 하이라이트도 지운다.
            DispatchQueue.main.async { [weak self] in
                self?.refreshRenderedBlocks()
                self?.refreshActiveLineHighlight()
            }
        }
        return ok
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let workspaceTrackingArea { removeTrackingArea(workspaceTrackingArea); self.workspaceTrackingArea = nil }
        guard workspaceInteraction != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); workspaceTrackingArea = area
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); workspaceInteraction?.mouseMoved(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); workspaceInteraction?.mouseExited() }
    override func mouseDragged(with event: NSEvent) {
        if workspaceInteraction?.mouseDragged(event) == true { return }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if workspaceInteraction?.mouseUp(event) == true { return }
        super.mouseUp(with: event)
    }

    /// 전체 경로에서 마커 유무를 실측해 캐시를 되돌린다. 이 경로는 이미 O(문서)라
    /// 스캔 한 번이 복잡도를 바꾸지 않는다 — 마커를 지운 뒤 빠른 경로로 복귀하는 길.
    func syncMarkerFlag() {
        let ns = string as NSString
        mayHaveMarkers =
            ns.range(of: "$$").location != NSNotFound
            || ns.range(of: "![").location != NSNotFound
    }

    /// 직렬화 캐시를 강제로 무효화한다 — 문서 로드 등 대량 교체 후.
    func invalidateSerialCache() {
        serialLinesValid = false
        serialFastDirty = false
    }

    /// 편집 **직전**에 삭제될 텍스트의 개행을 센다 — 직렬화 증분 캐시의 안전
    /// 판정에 필요하다(`updateSerialCacheState`). `didProcessEditing`은 이미 바뀐
    /// storage만 보므로 "무엇이 지워졌는지"를 알 수 없다. 이 훅은 타이핑·IME·
    /// 붙여넣기·삭제·undo 등 NSText 경로 전부에서 편집 전에 불린다.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?)
        -> Bool
    {
        let ns = string as NSString
        if affectedCharRange.length > 0, affectedCharRange.upperBound <= ns.length {
            let old = ns.substring(with: affectedCharRange)
            serialPendingRemovedNewlines = old.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        } else {
            serialPendingRemovedNewlines = 0
        }
        serialPendingTracked = true
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        guard !isTransforming else { return }
        if !isSourceMode, !hasMarkedText() {
            transformMarkerIfNeeded()
            transformInlineMarkerIfNeeded()
        }
        // IME 조합 중에도 갱신 — 문단 위치가 밀리면 렌더 range를 다시 잡아야 한다.
        if !isSourceMode {
            refreshRenderedBlocks()
        }
        scheduleEditingOverlayRefresh(restartBlink: true)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        writingProjectionCapture.beginComposition()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        writingProjectionCapture.endComposition(hasMarkedText() ? markedRange() : nil)
    }

    override func unmarkText() {
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        writingProjectionCapture.beginComposition()
        super.unmarkText()
        writingProjectionCapture.endComposition(nil)
    }

    /// 커서 바로 앞에서 완성된 인라인 마커(`***…***` `**…**` `*…*` `~~…~~` `==…==` `` `…` ``)를
    /// 소비해 서식 속성으로 바꾼다 — transformMarkdown의 인라인 판.
    func transformInlineMarkerIfNeeded() {
        guard !isSourceMode, let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: sel)
        let info = blockInfo(in: para)
        guard ![PurloryBlock.code, .math, .divider, .image].contains(info.block) else { return }
        let text = paragraphContent(para)
        let nsText = text as NSString
        let caretInPara = sel.location - para.location

        // "$…$" 닫기 타이핑 — 인라인 수식 원자로 즉시 전환 (이슈 #20).
        // 코드 스팬에 걸친 쌍은 변환하지 않는다 — 코드는 문자 그대로다.
        if let region = MathScanner.closingInline(in: text, atCaret: caretInPara) {
            let skips = inlineCodeSkips(in: para)
            if !skips.contains(where: { NSIntersectionRange($0, region.range).length > 0 }) {
                convertInlineMath(in: para)
                return
            }
        }

        for rule in InlineMarkdown.typingRules {
            let matches = rule.pattern.matches(
                in: text, range: NSRange(location: 0, length: nsText.length))
            // 방금 타이핑으로 닫힌 마커만 — 커서 위치에서 끝나는 매치.
            guard let match = matches.first(where: { $0.range.upperBound == caretInPara })
            else { continue }
            let inner = nsText.substring(with: match.range(at: 1))
            let markerRange = NSRange(
                location: para.location + match.range.location, length: match.range.length)
            isTransforming = true
            if shouldChangeText(in: markerRange, replacementString: inner) {
                storage.replaceCharacters(in: markerRange, with: inner)
                storage.addAttributes(
                    rule.attrs,
                    range: NSRange(
                        location: markerRange.location, length: (inner as NSString).length))
                didChangeText()
            }
            isTransforming = false
            let newPara = (string as NSString).paragraphRange(
                for: NSRange(location: para.location, length: 0))
            applyBlock(
                info.block, checked: info.checked, marker: info.marker,
                indent: info.indent, codeLang: info.codeLang,
                to: newPara, registerUndo: false)
            // 변환 직후 이어지는 타이핑은 일반 글씨 — 서식이 계속 번지지 않게.
            var typing = styleAttributes(for: info.block, checked: info.checked, indent: info.indent)
            typing[.purloryBlock] = info.block.rawValue
            if info.checked { typing[.purloryChecked] = true }
            if let marker = info.marker { typing[.purloryMarker] = marker }
            if info.indent > 0 { typing[.purloryIndent] = info.indent }
            if let codeLang = info.codeLang { typing[.purloryCodeLang] = codeLang }
            typingAttributes = typing
            updateTailSnapshot()
            return
        }

        // `[텍스트](주소)` 닫는 `)` 타이핑 시 즉시 인라인 링크 장식 갱신.
        if caretInPara > 0, nsText.character(at: caretInPara - 1) == 41 {
            decorateInlineLinks(in: para)
        }
    }

    func transformMarkerIfNeeded() {
        guard !isSourceMode else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: sel)
        let info = blockInfo(in: para)
        let text = paragraphContent(para)

        if info.block == .bullet {
            // "- [ ] "를 두 단계로 쓰는 경우: bullet 상태에서 "[ ] " → todo.
            if let match = text.range(of: #"^\[\s?\]\s"#, options: .regularExpression) {
                consumeMarker(
                    length: text[text.startIndex..<match.upperBound].utf16.count,
                    in: para, block: .todo, indent: info.indent)
            }
            return
        }
        if info.block == .quote, text.hasPrefix("> "), info.indent < 6 {
            consumeMarker(length: 2, in: para, block: .quote, indent: info.indent + 1)
            return
        }
        guard info.block == .p else { return }

        if text == "```" {
            consumeMarker(length: 3, in: para, block: .code)
        } else if let match = text.range(of: #"^```([A-Za-z0-9_+#.-]+)\s$"#, options: .regularExpression) {
            let lang = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            consumeMarker(
                length: text[text.startIndex..<match.upperBound].utf16.count,
                in: para, block: .code, codeLang: lang.isEmpty ? nil : lang)
        } else if text == "$$ " {
            consumeMarker(length: 3, in: para, block: .math)
        } else if text.hasPrefix("$$"), text.hasSuffix("$$"), text.count >= 5 {
            // "$$H_2$$"처럼 여닫는 마커까지 통째로 타이핑한 경우 — 마커를 벗겨
            // 수식 블록으로 바꾼다 ("$$ " 두 글자+공백 방식과 동일한 결과).
            consumeMathWrapper(in: para)
        } else if text == "---" {
            consumeDivider(in: para)
        } else if text.hasPrefix("###### ") {
            consumeMarker(length: 7, in: para, block: .h6)
        } else if text.hasPrefix("##### ") {
            consumeMarker(length: 6, in: para, block: .h5)
        } else if text.hasPrefix("#### ") {
            consumeMarker(length: 5, in: para, block: .h4)
        } else if text.hasPrefix("### ") {
            consumeMarker(length: 4, in: para, block: .h3)
        } else if text.hasPrefix("## ") {
            consumeMarker(length: 3, in: para, block: .h2)
        } else if text.hasPrefix("# ") {
            consumeMarker(length: 2, in: para, block: .h1)
        } else if let match = text.range(of: #"^\[\s?\]\s"#, options: .regularExpression) {
            consumeMarker(
                length: text[text.startIndex..<match.upperBound].utf16.count,
                in: para, block: .todo)
        } else if text.hasPrefix("> ") {
            consumeMarker(length: 2, in: para, block: .quote)
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
            consumeMarker(length: 2, in: para, block: .bullet)
        } else if let match = text.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let marker = String(text[text.startIndex..<match.upperBound])
                .trimmingCharacters(in: .whitespaces)
            consumeMarker(
                length: text[text.startIndex..<match.upperBound].utf16.count,
                in: para, block: .number, marker: marker)
        }
    }

    func consumeMarker(
        length: Int, in paragraph: NSRange, block: PurloryBlock,
        marker: String? = nil, indent: Int = 0, codeLang: String? = nil
    ) {
        guard let storage = textStorage else { return }
        isTransforming = true
        let markerRange = NSRange(location: paragraph.location, length: length)
        if shouldChangeText(in: markerRange, replacementString: "") {
            storage.replaceCharacters(in: markerRange, with: "")
            didChangeText()
        }
        isTransforming = false
        let ns = string as NSString
        let newPara = ns.paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        applyBlock(block, marker: marker, indent: indent, codeLang: codeLang, to: newPara)
    }

    /// "$$…$$" 한 줄을 마커 없이 수식 블록으로 — 내용만 남기고 블록을 부여한다.
    func consumeMathWrapper(in paragraph: NSRange) {
        guard let storage = textStorage else { return }
        let text = paragraphContent(paragraph)
        guard text.count >= 5 else { return }
        let inner = String(text.dropFirst(2).dropLast(2))
        isTransforming = true
        let contentRange = NSRange(
            location: paragraph.location, length: (text as NSString).length)
        if shouldChangeText(in: contentRange, replacementString: inner) {
            storage.replaceCharacters(in: contentRange, with: inner)
            didChangeText()
        }
        isTransforming = false
        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: paragraph.location, length: 0))
        applyBlock(.math, to: newPara)
        refreshRenderedBlocks()
    }

    func consumeDivider(in paragraph: NSRange) {
        guard let storage = textStorage else { return }
        isTransforming = true
        let markerRange = NSRange(location: paragraph.location, length: 3)
        if shouldChangeText(in: markerRange, replacementString: "") {
            storage.replaceCharacters(in: markerRange, with: "")
            didChangeText()
        }
        isTransforming = false
        let ns = string as NSString
        let dividerPara = ns.paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        applyBlock(.divider, to: dividerPara)
        // 디자인처럼 아래에 새 문단을 만들고 커서를 옮긴다.
        setSelectedRange(NSRange(location: dividerPara.upperBound > dividerPara.location
            ? dividerPara.upperBound - 1 : dividerPara.location, length: 0))
        insertText("\n", replacementRange: selectedRange())
        let caretPara = (string as NSString).paragraphRange(
            for: NSRange(location: selectedRange().location, length: 0))
        applyBlock(.p, to: caretPara)
    }

    // MARK: 키 동작 (Enter/Backspace/Tab 블록 규칙)

    override func insertTab(_ sender: Any?) {
        if !isSourceMode, !hasMarkedText(), indentListOrQuote(delta: 1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if !isSourceMode, !hasMarkedText(), indentListOrQuote(delta: -1) { return }
        super.insertBacktab(sender)
    }

    /// 목록(`.bullet`, `.number`, `.todo`) 및 인용(`.quote`) 문단의 들여쓰기를 증감한다.
    @discardableResult
    func indentListOrQuote(delta: Int) -> Bool {
        let sel = selectedRange()
        let ns = string as NSString
        let firstPara = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let firstInfo = blockInfo(in: firstPara)
        guard [.bullet, .number, .todo, .quote].contains(firstInfo.block) else { return false }
        var changed = false
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
            let info = blockInfo(in: para)
            if [.bullet, .number, .todo, .quote].contains(info.block) {
                let nextIndent = min(6, max(0, info.indent + delta))
                if nextIndent != info.indent {
                    let nextMarker = info.block == .number && delta > 0 ? "1." : info.marker
                    applyBlock(
                        info.block, checked: info.checked, marker: nextMarker,
                        indent: nextIndent, to: para)
                    changed = true
                }
            }
            location = para.upperBound
        } while location < sel.upperBound
        return changed || [.bullet, .number, .todo, .quote].contains(firstInfo.block)
    }

    override func insertLineBreak(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertLineBreak(sender) }
        guard selectedImageLocation == nil else { return insertNewline(sender) }
        // U+2028 is a line separator, not a paragraph separator. Use the normal
        // input path for undo, autosave and inline attributes without resetting
        // the block or advancing a list number as Enter does.
        insertText("\u{2028}", replacementRange: selectedRange())
        refreshActiveLineHighlight()
    }

    override func insertNewline(_ sender: Any?) {
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        if isSourceMode {
            super.insertNewline(sender)
            return
        }
        // 이미지 객체 선택 중 Enter — 이미지 아래에 새 문단을 만들고 커서를 옮긴다
        // (그림 블럭 완성도). insertText가 막혀 있어 기본 경로로는 아무 일도 없다.
        if let loc = selectedImageLocation {
            let para = (string as NSString).paragraphRange(
                for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            imageLineBreak(after: para)
            return
        }
        guard !hasMarkedText() else { return super.insertNewline(sender) }
        defer { breakUndoCoalescing() }
        let sel = selectedRange()
        let ns = string as NSString
        let para = ns.paragraphRange(for: sel)
        let info = blockInfo(in: para)

        // 빈 목록/코드 블록에서 Enter → 들여쓰기가 있으면 한 단계 내리고, 0이면 본문으로 해제.
        if sel.length == 0, paragraphContent(para).isEmpty,
            [.bullet, .number, .todo, .code].contains(info.block) {
            if info.indent > 0 {
                applyBlock(
                    info.block, checked: false, marker: info.marker,
                    indent: info.indent - 1, to: para)
            } else {
                applyBlock(.p, to: para)
            }
            return
        }

        super.insertNewline(sender)

        // 새 문단의 블록 상속 규칙.
        let caretPara = (string as NSString).paragraphRange(
            for: NSRange(location: selectedRange().location, length: 0))
        switch info.block {
        case .h1, .h2, .h3, .h4, .h5, .h6, .quote, .math, .divider, .image:
            applyBlock(.p, to: caretPara)
        case .todo:
            applyBlock(.todo, checked: false, indent: info.indent, to: caretPara)
        case .number:
            let next = (Int((info.marker ?? "1.").dropLast()) ?? 1) + 1
            applyBlock(.number, marker: "\(next).", indent: info.indent, to: caretPara)
        case .bullet:
            applyBlock(.bullet, indent: info.indent, to: caretPara)
        case .code:
            applyBlock(.code, codeLang: info.codeLang, to: caretPara)
        case .p:
            applyBlock(.p, to: caretPara)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if isSourceMode {
            super.deleteBackward(sender)
            return
        }
        // 이미지가 객체 선택된 상태면 백스페이스로 문단째 지운다 (요구 3).
        if let loc = selectedImageLocation {
            let para = (string as NSString).paragraphRange(
                for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            deleteImageParagraph(para)
            return
        }
        let sel = selectedRange()
        if sel.length == 0, !hasMarkedText() {
            let ns = string as NSString
            let para = ns.paragraphRange(for: sel)
            let info = blockInfo(in: para)
            // 블록 문단 맨 앞에서 Backspace → 들여쓰기가 있으면 먼저 내리고, 0이면 블록 해제.
            if sel.location == para.location, info.block != .p {
                if info.indent > 0 {
                    applyBlock(
                        info.block, checked: info.checked, marker: info.marker,
                        indent: info.indent - 1, to: para)
                } else {
                    applyBlock(.p, to: para)
                }
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func keyDown(with event: NSEvent) {
        workspaceInteraction?.keyDown(event)
        if selectedImageLocation != nil, handleObjectKey(event) { return }
        if handleMathEditingKey(event) { return }
        // AppKit coalesces adjacent typing even across idle time and event groups.
        // A new burst must not undo earlier writing; never split a live IME session.
        if !hasMarkedText(), let previous = lastTypingKeyTimestamp,
           event.timestamp - previous >= 2 {
            breakUndoCoalescing()
        }
        lastTypingKeyTimestamp = event.timestamp
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let previousSoftReturn = isHandlingSoftReturn
        isHandlingSoftReturn = modifiers == .shift && (event.keyCode == 36 || event.keyCode == 76)
        defer { isHandlingSoftReturn = previousSoftReturn }
        // Let the input method handle/commit marked text before remapping the
        // resulting newline command. A raw key interception skips Hangul IME.
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if isHandlingSoftReturn, !hasMarkedText(),
           selector == #selector(NSStandardKeyBindingResponding.insertNewline(_:))
            || selector == #selector(NSStandardKeyBindingResponding.insertNewlineIgnoringFieldEditor(_:)) {
            super.doCommand(by: #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)))
        } else {
            super.doCommand(by: selector)
        }
    }

    /// 수식 소스 모드에서의 객체 조작 키 — 이동(⌥↑↓)과 문단 삭제(⌘⌦)만 가로채고
    /// 나머지 입력은 LaTeX 편집으로 그대로 흘려보낸다 (이슈 #22).
    func handleMathEditingKey(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !isTransforming else { return false }
        let ns = string as NSString
        let sel = selectedRange()
        let para = ns.paragraphRange(
            for: NSRange(location: min(sel.location, ns.length), length: 0))
        guard blockInfo(in: para).block == .math,
              NSIntersectionRange(sel, para).length > 0 || NSLocationInRange(sel.location, para)
        else { return false }
        let raw = event.charactersIgnoringModifiers ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (raw, flags.contains(.option), flags.contains(.command)) {
        case ("\u{F700}", true, false):
            moveMathParagraph(para, offset: -1)
        case ("\u{F704}", true, false):
            moveMathParagraph(para, offset: 1)
        case ("\u{F728}", _, true):
            deleteMathParagraph(para)
        default:
            return false
        }
        return true
    }

    func widthOfSelectedImage() -> Int {
        guard let loc = selectedImageLocation else { return 100 }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        return Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces))?.width ?? 100
    }

    /// 이미지 문단을 이웃 문단과 맞바꿔 위(offset -1)·아래(+1)로 옮긴다 —
    /// undo 가능 (shouldChangeText). 성공해도 실패해도 원문 손상은 없다.
    /// internal — 키보드 이동 경로의 회귀 테스트용 (이슈 #16). 선택 UI 갱신은
    /// 호출부(키 핸들러)가 이어서 한다.
    func moveImageParagraph(_ para: NSRange, offset: Int) {
        moveBlockParagraph(para, offset: offset, undoName: "이미지 이동")
    }

    /// 수식(단일·그룹) 문단의 키보드 이동 — undo 이름만 다르다 (이슈 #22).
    func moveMathParagraph(_ para: NSRange, offset: Int) {
        moveBlockParagraph(para, offset: offset, undoName: "수식 이동")
    }

    func moveBlockParagraph(_ para: NSRange, offset: Int, undoName: String) {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let neighbor: NSRange
        if offset < 0 {
            guard para.location > 0 else { return }
            neighbor = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
        } else {
            guard para.upperBound < ns.length else { return }
            neighbor = ns.paragraphRange(for: NSRange(location: para.upperBound, length: 0))
        }
        let lower = min(para.location, neighbor.location)
        let upper = max(para.upperBound, neighbor.upperBound)
        let span = NSRange(location: lower, length: upper - lower)
        let imageText = ns.substring(with: para)
        let otherText = ns.substring(with: neighbor)
        // 문단은 자기 개행을 데리고 다닌다. 위 이동은 그대로 붙여도 줄 구조가
        // 유지되지만, 아래 이동에서 이웃이 **마지막 문단**(개행 없음)이면
        // 개행을 재배치해야 두 줄이 한 줄로 붙지 않는다.
        let newText: String
        if offset < 0 {
            newText = imageText + otherText
        } else if !otherText.hasSuffix("\n"), imageText.hasSuffix("\n") {
            newText = otherText + "\n" + String(imageText.dropLast())
        } else {
            newText = otherText + imageText
        }
        guard shouldChangeText(in: span, replacementString: newText) else { return }
        nameCurrentUndo(undoName)
        isTransforming = true
        storage.replaceCharacters(in: span, with: newText)
        isTransforming = false

        // 새 자리의 이미지를 다시 객체 선택 — 키보드 이동이 연속되도록.
        selectedImageLocation = offset < 0 ? lower : lower + otherText.count
        refreshRenderedBlocks()
    }


    // MARK: 체크박스 클릭

    override func mouseDown(with event: NSEvent) {
        if workspaceInteraction?.mouseDown(event) == true { return }
        let point = convert(event.locationInWindow, from: nil)
        // 인라인 수식 원자 더블클릭 — 소스(`$latex$`)로 펼쳐 편집한다 (이슈 #20).
        if event.clickCount == 2, revealInlineMathSource(at: point) { return }
        if let layoutManager, let textContainer {
            let containerPoint = NSPoint(
                x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let index = layoutManager.characterIndex(
                for: containerPoint, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)
            let ns = string as NSString
            if ns.length > 0, index <= ns.length {
                let para = ns.paragraphRange(
                    for: NSRange(location: min(index, ns.length), length: 0))
                let info = blockInfo(in: para)
                // ⌘+클릭: 인라인 마크다운 링크(`[텍스트](URL)`) 열기.
                if event.modifierFlags.contains(.command),
                   ![PurloryBlock.code, .math, .divider, .image].contains(info.block),
                   openInlineMarkdownLink(at: index, inParagraph: para) {
                    return
                }
                // 체크박스 히트 존: 문단 들여쓰기(32px + indentOffset) 안쪽.
                let checkboxZone = 28 + CGFloat(info.indent) * 24
                if info.block == .todo, containerPoint.x < checkboxZone {
                    applyBlock(.todo, checked: !info.checked, indent: info.indent, to: para)
                    return
                }
                // 렌더된 이미지 클릭 — 항상 객체 선택(소스는 절대 노출하지 않는다).
                let isRendered = imageRenders.contains { $0.range.location == para.location }
                if info.block == .image, isRendered {
                    selectImageObject(at: para)
                    return
                }
                // 렌더된 수식 박스 클릭 — 끌면 블록 이동, 그 자리에서 떼면
                // 기존처럼 소스 편집 모드 (요구 6).
                if info.block == .math,
                    let mathBox = mathDrawnRect(forParagraphAt: para.location)?
                        .insetBy(dx: -Self.mathBoxMargin, dy: -Self.mathBoxMargin),
                    mathBox.contains(point) {
                    clearImageSelection()
                    trackMathDrag(from: event, paragraph: para)
                    return
                }
            }
        }
        // 이미지가 아닌 곳을 누르면 객체 선택을 해제한다.
        clearImageSelection()
        super.mouseDown(with: event)
    }

    /// 문단 내 `characterIndex`가 `[텍스트](URL)` 링크 안에 있으면 URL을 브라우저로 연다.
    func openInlineMarkdownLink(at characterIndex: Int, inParagraph para: NSRange) -> Bool {
        let text = paragraphContent(para)
        let localOffset = characterIndex - para.location
        guard localOffset >= 0, localOffset <= (text as NSString).length else { return false }
        for link in WritingProseProjection.links(in: text) where !link.image {
            guard NSLocationInRange(localOffset, link.source) else { continue }
            let rawSpan = (text as NSString).substring(with: link.source)
            guard let openParen = rawSpan.range(of: "](") else { continue }
            var dest = String(rawSpan[openParen.upperBound...].dropLast())
                .trimmingCharacters(in: .whitespaces)
            if let spaceIdx = dest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                dest = String(dest[..<spaceIdx])
            }
            if dest.hasPrefix("<"), dest.hasSuffix(">"), dest.count >= 2 {
                dest = String(dest.dropFirst().dropLast())
            }
            if let url = URL(string: dest), url.scheme != nil {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let layoutManager, let textContainer {
            let containerPoint = NSPoint(
                x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let index = layoutManager.characterIndex(
                for: containerPoint, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)
            let ns = string as NSString
            if ns.length > 0 {
                let para = ns.paragraphRange(
                    for: NSRange(location: min(index, ns.length), length: 0))
                if blockInfo(in: para).block == .math,
                    let latex = mathSource(at: para.location), !latex.isEmpty
                {
                    mathActionLocation = para.location
                    let menu = NSMenu(title: "수식")
                    menu.addItem(withTitle: "LaTeX 복사", action: #selector(copyMathLatex(_:)), keyEquivalent: "")
                    menu.addItem(withTitle: "이미지 복사", action: #selector(copyMathImage(_:)), keyEquivalent: "")
                    menu.addItem(withTitle: "PDF로 복사", action: #selector(copyMathPDF(_:)), keyEquivalent: "")
                    menu.addItem(.separator())
                    if let base = super.menu(for: event) {
                        for item in base.items { menu.addItem(item.copy() as! NSMenuItem) }
                    }
                    return menu
                }
            }
        }
        return super.menu(for: event)
    }

    /// 폭이 바뀌면 수식·이미지 축소 배율이 달라진다 — 줄 높이를 다시 맞춘다.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            let inset = editorialWorkspaceStyle
                ? EditorMetrics.workspaceSideInset(forWidth: newSize.width, windowWidth: window?.frame.width ?? 640)
                : EditorMetrics.sideInset(forWidth: newSize.width)
            if abs(textContainerInset.width - inset) > 0.5 {
                textContainerInset = NSSize(width: inset, height: textContainerInset.height)
            }
        }
        workspaceInteraction?.layoutDidChange()
        guard widthChanged else { return }
        // 폭이 바뀌면 수식·이미지 축소 배율이 달라진다 — 줄 높이를 다시 맞춘다.
        if !mathRenders.isEmpty || !imageRenders.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.refreshRenderedBlocks() }
        }
    }

    func currentSelectionState() -> SelectionStyleState {
        var state = SelectionStyleState()
        guard let storage = textStorage else { return state }
        let sel = selectedRange()
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        state.block = blockInfo(in: para).block
        // 줄 간격은 문단 단위 — 선택 시작 문단의 저장값(없으면 전역 설정) 기준.
        state.lineSpacing =
            (para.location < storage.length
                ? storage.attribute(.purloryLineSpacing, at: para.location, effectiveRange: nil)
                    as? Double : nil) ?? Double(lineSpacing)
        let attrs = sel.location < storage.length
            ? storage.attributes(at: sel.location, effectiveRange: nil) : typingAttributes
        state.bold = attrs[.purloryBold] as? Bool == true
        state.italic = attrs[.purloryItalic] as? Bool == true
        state.strikethrough = attrs[.purloryStrikethrough] as? Bool == true
        state.highlight = attrs[.purloryHighlight] as? Bool == true
        state.code = attrs[.purloryCode] as? Bool == true
        state.align = attrs[.purloryAlign] as? String
        state.colorHex = attrs[.purloryColor] as? String
        state.fontSize =
            (attrs[.purloryFontSize] as? Double)
            ?? Double((attrs[.font] as? NSFont ?? bodyFont).pointSize)
        return state
    }

    /// 툴바 액션 실행 — 끝나면 포커스를 에디터로 되돌리고 하이라이트를 갱신한다.
    func perform(_ action: SelectionToolbarAction) {
        switch action {
        case .toggleBold: toggleInlineStyle(.purloryBold)
        case .toggleItalic: toggleInlineStyle(.purloryItalic)
        case .toggleStrikethrough: toggleInlineStyle(.purloryStrikethrough)
        case .toggleHighlight: toggleInlineStyle(.purloryHighlight)
        case .toggleCode: toggleInlineStyle(.purloryCode)
        case .insertLink: insertMarkdownLinkAtSelection()
        case .color(let hex): applyInlineColor(hex)
        case .fontSize(let size): applyInlineFontSize(size)
        case .lineSpacing(let v): applyLineSpacing(v)
        case .align(let align): applyAlignment(align)
        case .block(let block): convertSelectionBlock(to: block)
        }
        workspaceSelectionPanel?.makeFirstResponder(nil)
        if let window, !window.isKeyWindow { window.makeKey() }
        window?.makeFirstResponder(self)
        presentSelectionToolbar()
    }

    /// 선택 범위를 `[선택](https://)` 마크다운 링크로 감싸고 URL 자리를 선택한다.
    public func insertMarkdownLinkAtSelection() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let sel = selectedRange()
        let ns = storage.string as NSString
        let label = sel.length > 0 ? ns.substring(with: sel) : "링크"
        guard !label.contains("\n") else { return }
        let pasteboardURL: String? = {
            guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                raw.hasPrefix("https://") || raw.hasPrefix("http://"),
                !raw.contains(where: { $0.isWhitespace })
            else { return nil }
            return raw
        }()
        let urlPart = pasteboardURL ?? "https://"
        let replacement = "[\(label)](\(urlPart))"
        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        isTransforming = true
        storage.replaceCharacters(in: sel, with: replacement)
        let insertedRange = NSRange(location: sel.location, length: (replacement as NSString).length)
        redecorateParagraphs(in: insertedRange)
        isTransforming = false
        didChangeText()
        let urlStart = sel.location + 1 + (label as NSString).length + 2
        let urlLen = (urlPart as NSString).length
        setSelectedRange(NSRange(location: urlStart, length: urlLen))
    }

    /// 선택 범위의 인라인 속성 토글 — 전체가 켜져 있으면 끄고, 아니면 켠다.
    func toggleInlineStyle(_ key: NSAttributedString.Key) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        var allOn = true
        storage.enumerateAttribute(key, in: sel, options: []) { value, _, stop in
            if (value as? Bool) != true {
                allOn = false
                stop.pointee = true
            }
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        isTransforming = true
        if allOn {
            storage.removeAttribute(key, range: sel)
        } else {
            storage.addAttribute(key, value: true, range: sel)
            if key == .purloryCode {
                // 인라인 코드는 배타 — 굵게·기울임·취소선·하이라이트·색과 겹치지 않는다.
                storage.removeAttribute(.purloryBold, range: sel)
                storage.removeAttribute(.purloryItalic, range: sel)
                storage.removeAttribute(.purloryStrikethrough, range: sel)
                storage.removeAttribute(.purloryHighlight, range: sel)
                storage.removeAttribute(.purloryColor, range: sel)
            }
        }
        redecorateParagraphs(in: sel)
        isTransforming = false
        didChangeText()
    }

    /// 선택 범위 글자색 적용 (nil = 기본 잉크색으로 복원).
    func applyInlineColor(_ hex: String?) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        isTransforming = true
        if let hex {
            storage.addAttribute(.purloryColor, value: hex, range: sel)
        } else {
            storage.removeAttribute(.purloryColor, range: sel)
        }
        redecorateParagraphs(in: sel)
        isTransforming = false
        didChangeText()
    }

    /// 선택 범위 글자 크기 적용 — 블록 기본 크기와 같아지면 속성을 제거한다
    /// (저장 마크다운에 불필요한 `<font size>` 래퍼를 남기지 않는다).
    func applyInlineFontSize(_ size: Double) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let info = blockInfo(in: para)
        let baseSize =
            (styleAttributes(
                for: info.block, checked: info.checked,
                indent: info.indent)[.font] as? NSFont)?
            .pointSize ?? bodyFont.pointSize
        isTransforming = true
        if abs(CGFloat(size) - baseSize) < 0.5 {
            storage.removeAttribute(.purloryFontSize, range: sel)
        } else {
            storage.addAttribute(.purloryFontSize, value: size, range: sel)
        }
        redecorateParagraphs(in: sel)
        isTransforming = false
        didChangeText()
    }

    /// 선택이 걸친 문단들의 정렬 지정 (nil = 왼쪽 기본).
    /// 저장은 .p 문단만 지원 — 다른 블록에선 화면 정렬만 바뀐다.
    func applyAlignment(_ align: String?) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let ns = string as NSString
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            if para.length > 0, para.location < storage.length {
                _ = shouldChangeText(in: para, replacementString: nil)
                isTransforming = true
                if let align {
                    storage.addAttribute(.purloryAlign, value: align, range: para)
                } else {
                    storage.removeAttribute(.purloryAlign, range: para)
                }
                let info = blockInfo(in: para)
                applyBlock(
                    info.block, checked: info.checked, marker: info.marker,
                    indent: info.indent, codeLang: info.codeLang,
                    to: para, registerUndo: false)
                isTransforming = false
                didChangeText()
            }
            location = para.upperBound
        } while location < sel.upperBound
    }

    /// 선택이 걸친 문단들의 줄 간격(pt)을 지정한다 — 선택 줄에 한해 (요구 4).
    /// 표시 전용 속성(.purloryLineSpacing)이라 마크다운엔 저장되지 않는다.
    func applyLineSpacing(_ value: Double) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        let ns = string as NSString
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            if para.length > 0, para.location < storage.length {
                _ = shouldChangeText(in: para, replacementString: nil)
                isTransforming = true
                storage.addAttribute(.purloryLineSpacing, value: value, range: para)
                let info = blockInfo(in: para)
                applyBlock(
                    info.block, checked: info.checked, marker: info.marker,
                    indent: info.indent, codeLang: info.codeLang,
                    to: para, registerUndo: false)
                isTransforming = false
                didChangeText()
            }
            location = para.upperBound
        } while location < sel.upperBound
    }

    /// 선택이 걸친 문단들을 블록으로 전환 — 이미 그 블록이면 본문으로 토글.
    func convertSelectionBlock(to target: PurloryBlock) {
        let sel = selectedRange()
        let ns = string as NSString
        let firstPara = ns.paragraphRange(
            for: NSRange(location: min(sel.location, ns.length), length: 0))
        let resolved: PurloryBlock = blockInfo(in: firstPara).block == target ? .p : target
        var location = sel.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            let current = blockInfo(in: para)
            let keepIndent = [.bullet, .number, .todo, .quote].contains(resolved) ? current.indent : 0
            applyBlock(resolved, indent: keepIndent, to: para)
            location = para.upperBound
        } while location < sel.upperBound
        refreshRenderedBlocks()
    }

    /// 범위에 걸친 문단들을 다시 장식 (블록 기본 + 인라인 조립, undo 미등록).
    func redecorateParagraphs(in range: NSRange) {
        let ns = string as NSString
        var location = range.location
        repeat {
            let para = ns.paragraphRange(
                for: NSRange(location: min(location, ns.length), length: 0))
            let info = blockInfo(in: para)
            applyBlock(
                info.block, checked: info.checked, marker: info.marker,
                indent: info.indent, codeLang: info.codeLang,
                to: para, registerUndo: false)
            location = para.upperBound
        } while location < range.upperBound
    }

    /// ⌘F 검색 · ⌘G 다음/이전 매치 · ⌘B/⌘I 서식 토글(선택 있을 때만).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        // 한글 입력기에선 charactersIgnoringModifiers가 자모("ㄹ")를 돌려줘 문자
        // 비교가 조용히 실패한다 — ⌘F를 눌러도 찾기 바가 안 뜨던 버그. 레이아웃
        // 무관한 물리 keyCode(F=3 · G=5)로 함께 판정한다.
        let code = event.keyCode
        // 서식·이미지 단축키는 메뉴 막대(PurloryCommands)로 옮겨 단일 소스로 관리한다 —
        // 여기선 문서 내 검색만 처리한다.
        if flags == .command {
            if key == "f" || code == 3 {
                performFind(.showFindInterface)
                return true
            }
            if key == "g" || code == 5 {
                performFind(.nextMatch)
                return true
            }
        } else if flags == [.command, .shift], key == "g" || code == 5 {
            performFind(.previousMatch)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // 메뉴(보기 ▸ 문서에서 찾기)용 리스폰더 체인 진입점 — 단축키가 IME 사정으로
    // 뷰에 닿지 못해도 메뉴 경로로는 항상 열리게 한다.
    @objc func purloryFindInDocument(_ sender: Any?) { performFind(.showFindInterface) }
    @objc func purloryFindNext(_ sender: Any?) { performFind(.nextMatch) }
    @objc func purloryFindPrevious(_ sender: Any?) { performFind(.previousMatch) }

    // MARK: 메뉴 명령 (리스폰더 체인 — PurloryCommands가 NSApp.sendAction으로 호출)
    //
    // 선택이 있으면 선택에, 없으면 커서 문단에 적용된다(convert/align은 문단 단위,
    // toggleInlineStyle은 선택이 있어야 동작). 에디터가 first responder일 때만 도달한다.

    @objc func purloryFormatBold(_ sender: Any?) { toggleInlineStyle(.purloryBold) }
    @objc func purloryFormatItalic(_ sender: Any?) { toggleInlineStyle(.purloryItalic) }
    @objc func purloryFormatStrikethrough(_ sender: Any?) { toggleInlineStyle(.purloryStrikethrough) }
    @objc func purloryFormatHighlight(_ sender: Any?) { toggleInlineStyle(.purloryHighlight) }
    @objc func purloryFormatCode(_ sender: Any?) { toggleInlineStyle(.purloryCode) }
    @objc func purloryFormatLink(_ sender: Any?) { insertMarkdownLinkAtSelection() }
    @objc func purloryHeading1(_ sender: Any?) { convertSelectionBlock(to: .h1) }
    @objc func purloryHeading2(_ sender: Any?) { convertSelectionBlock(to: .h2) }
    @objc func purloryHeading3(_ sender: Any?) { convertSelectionBlock(to: .h3) }
    @objc func purloryHeading4(_ sender: Any?) { convertSelectionBlock(to: .h4) }
    @objc func purloryHeading5(_ sender: Any?) { convertSelectionBlock(to: .h5) }
    @objc func purloryHeading6(_ sender: Any?) { convertSelectionBlock(to: .h6) }
    @objc func purloryBodyText(_ sender: Any?) { convertSelectionBlock(to: .p) }
    @objc func purloryBulletList(_ sender: Any?) { convertSelectionBlock(to: .bullet) }
    @objc func purloryNumberedList(_ sender: Any?) { convertSelectionBlock(to: .number) }
    @objc func purloryQuoteBlock(_ sender: Any?) { convertSelectionBlock(to: .quote) }
    @objc func purloryCodeBlock(_ sender: Any?) { convertSelectionBlock(to: .code) }
    @objc func purloryAlignLeft(_ sender: Any?) { applyAlignment(nil) }
    @objc func purloryAlignCenter(_ sender: Any?) { applyAlignment("center") }
    @objc func purloryAlignRight(_ sender: Any?) { applyAlignment("right") }
    @objc func purloryMoveParagraphUp(_ sender: Any?) { moveCurrentParagraph(direction: -1) }
    @objc func purloryMoveParagraphDown(_ sender: Any?) { moveCurrentParagraph(direction: 1) }
    @objc func purloryToggleSourceMode(_ sender: Any?) { setSourceMode(!isSourceMode) }

    /// 마크다운 원문 모드 전환 (⌘/) — 현재 문서를 직렬화한 뒤 원문/블록 뷰로 다시 로드한다.
    public func setSourceMode(_ enabled: Bool) {
        guard !hasMarkedText(), isSourceMode != enabled else { return }
        let markdown = serialize()
        load(markdown: markdown, sourceMode: enabled)
        didChangeText()
    }

    /// 현재 커서 문단을 위(-1) 또는 아래(+1) 문단과 맞바꾼다 (⌥↑ / ⌥↓).
    public func moveCurrentParagraph(direction: Int) {
        guard !hasMarkedText() else { return }
        let raw = serialize()
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return }
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        var currentLineIndex = 0
        if caret > 0 {
            let prefix = ns.substring(to: caret)
            currentLineIndex = prefix.utf16.filter { $0 == 0x0A }.count
        }
        guard currentLineIndex >= 0, currentLineIndex < lines.count else { return }
        let targetIndex = currentLineIndex + direction
        guard targetIndex >= 0, targetIndex < lines.count else { return }
        lines.swapAt(currentLineIndex, targetIndex)
        let updated = lines.joined(separator: "\n")
        load(markdown: updated)
        let newNS = string as NSString
        var targetLoc = 0
        var lineIdx = 0
        while lineIdx < targetIndex && targetLoc < newNS.length {
            let para = newNS.paragraphRange(for: NSRange(location: targetLoc, length: 0))
            targetLoc = para.upperBound
            lineIdx += 1
        }
        setSelectedRange(NSRange(location: min(targetLoc, newNS.length), length: 0))
        didChangeText()
    }
    func performFind(_ action: NSTextFinder.Action) {
        if workspaceFind?(action) == true { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}

extension BlockTextView: @preconcurrency NSTextStorageDelegate {

    /// 편집된 범위에 수식·이미지 마커가 들어왔는지만 본다 — 문서 길이와 무관.
    ///
    /// 범위를 **양옆 1글자 넓혀** 검사하는 이유: `$`를 치고 다음 키에 `$`를 치면
    /// 각 편집 범위엔 `$`가 하나뿐이라 `$$`를 놓친다. 넓히면 두 번째 키에서 잡힌다.
    /// 같은 이유로 `!` 다음 `[`도 잡힌다.
    ///
    /// 삭제로 마커가 사라지는 경우는 여기서 알 수 없다 — 플래그가 true인 채 남아
    /// 전체 경로를 한 번 더 타고, 거기서 `syncMarkerFlag`가 정확히 되돌린다.
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Font/paragraph edits and undo can bypass text input overrides. Wait
        // until TextKit has processed their layout invalidation before measuring.
        scheduleEditingOverlayRefresh()
        writingProjectionCapture.storageChanged(mask: editedMask, range: editedRange, delta: delta, storage: textStorage)
        updateMediaRenderIndex(mask: editedMask, range: editedRange, delta: delta)
        // 직렬화 증분 캐시 판정 — 모든 편집에 대해 먼저(마커 조기 반환에 가리지 않게).
        updateSerialCacheState(editedMask: editedMask, editedRange: editedRange, delta: delta)

        guard editedMask.contains(.editedCharacters) else { return }
        let ns = textStorage.string as NSString
        let start = max(0, editedRange.location - 1)
        let end = min(ns.length, editedRange.upperBound + 1)
        guard end > start else { return }
        let touched = ns.substring(with: NSRange(location: start, length: end - start))
        // 인라인 수식 후보 — `$` 하나만으로도 보수적으로 켠다 (이슈 #20).
        // 접기 검사(collapseRawInlineMath)가 실측으로 다시 끝낸다.
        if touched.contains("$") {
            mayHaveInlineMath = true
        }
        // 마커 플래그가 이미 true면 더 볼 필요 없다 — syncMarkerFlag가 정리한다.
        guard !mayHaveMarkers else { return }
        if touched.contains("$$") || touched.contains("![") {
            mayHaveMarkers = true
        }
    }
}
