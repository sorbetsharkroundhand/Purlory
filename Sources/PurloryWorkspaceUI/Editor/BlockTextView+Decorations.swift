import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

// Attributed presentation and TextKit block drawing.
extension BlockTextView {

    /// 커서 문단에 블록을 부여하고 스타일을 다시 입힌다 (undo 등록 포함).
    func applyBlock(
        _ block: PurloryBlock, checked: Bool = false, marker: String? = nil,
        indent: Int = 0, codeLang: String? = nil,
        to paragraph: NSRange, registerUndo: Bool = true
    ) {
        guard let storage = textStorage else { return }
        let wasTransforming = isTransforming
        isTransforming = true
        let clampedIndent = [.bullet, .number, .todo, .quote].contains(block)
            ? min(6, max(0, indent)) : 0
        var attrs = styleAttributes(for: block, checked: checked, indent: clampedIndent)
        attrs[.purloryBlock] = block.rawValue
        if checked { attrs[.purloryChecked] = true }
        if let marker { attrs[.purloryMarker] = marker }
        if clampedIndent > 0 { attrs[.purloryIndent] = clampedIndent }
        if block == .code, let codeLang, !codeLang.isEmpty {
            attrs[.purloryCodeLang] = codeLang
        }
        if paragraph.length > 0 {
            if registerUndo {
                _ = shouldChangeText(in: paragraph, replacementString: nil)
            }
            // setAttributes는 인라인 서식 키까지 지운다 — 코드·수식·구분선·이미지가
            // 아니면 보존했다가 되살린 뒤 폰트·색을 다시 조립한다.
            let keepInline = ![PurloryBlock.code, .math, .divider, .image].contains(block)
            let preserved = keepInline ? inlineSnapshot(in: paragraph) : []
            storage.setAttributes(attrs, range: paragraph)
            for (range, inline) in preserved {
                storage.addAttributes(inline, range: range)
            }
            decorateInline(in: paragraph)
            applyStoredAlignment(base: attrs, in: paragraph)
            applyStoredLineSpacing(in: paragraph)
            if registerUndo { didChangeText() }
        }
        // 커서가 이 문단 안에 있을 때만 typingAttributes를 덮는다.
        let caret = selectedRange().location
        if caret >= paragraph.location, caret <= paragraph.upperBound {
            typingAttributes = attrs
            updateTailSnapshot()
        }
        isTransforming = wasTransforming
        needsDisplay = true
        scheduleEditingOverlayRefresh()
    }

    /// 팔레트/테마 변경 시 문서 전체를 다시 입힌다.
    func restyleAll() {
        let ns = string as NSString
        let caret = min(max(0, selectedRange().location), ns.length)
        let caretParagraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let emptyTail = caretParagraph.length == 0 ? blockInfo(in: caretParagraph) : nil
        let emptyTailInline = typingAttributes.filter { InlineMarkdown.inlineKeys.contains($0.key) }
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let info = blockInfo(in: para)
            applyBlock(
                info.block, checked: info.checked, marker: info.marker,
                indent: info.indent, codeLang: info.codeLang,
                to: para, registerUndo: false)
            location = para.upperBound
        }
        // The final empty paragraph has no storage attributes. Do not inherit the preceding
        // heading/list when a theme or font change restyles the document.
        if let emptyTail {
            applyBlock(
                emptyTail.block, checked: emptyTail.checked, marker: emptyTail.marker,
                indent: emptyTail.indent, codeLang: emptyTail.codeLang,
                to: caretParagraph, registerUndo: false)
            typingAttributes.merge(emptyTailInline) { _, inherited in inherited }
            typingAttributes.merge(inlineDecoration(for: typingAttributes)) { _, decorated in decorated }
            if let ps = typingAttributes[.paragraphStyle] as? NSMutableParagraphStyle {
                if let align = emptyTailInline[.purloryAlign] as? String {
                    ps.alignment = align == "right" ? .right : .center
                }
                if let spacing = emptyTailInline[.purloryLineSpacing] as? Double {
                    ps.minimumLineHeight = 0; ps.maximumLineHeight = 0
                    ps.lineSpacing = CGFloat(spacing)
                }
            }
        }
        syncTypingAttributes()
        // 테마가 바뀌면 잉크 색으로 수식을 다시 렌더한다.
        rerenderInlineAtoms()
        // Rebuild every paragraph without forcing focused math out of source mode.
        invalidateMediaIndex()
        refreshRenderedBlocks()
        needsDisplay = true
        scheduleEditingOverlayRefresh()
    }

    /// 커서 문단의 속성을 typingAttributes로 동기화 — 빈 문단에서도 블록 유지.
    func syncTypingAttributes() {
        // The input method owns attributes while composing the first character.
        guard !hasMarkedText(), let storage = textStorage else { return }
        let caret = selectedRange().location
        guard caret != NSNotFound else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(caret, ns.length), length: 0))
        if para.location < storage.length {
            // 굵게 같은 인라인 서식이 커서 앞 글자에서 이어지도록 caret-1 기준 —
            // 블록 속성은 문단 안에서 균일해 어디를 읽어도 같다.
            let anchor = min(
                max(para.location, min(caret, ns.length) - 1), storage.length - 1)
            typingAttributes = storage.attributes(at: anchor, effectiveRange: nil)
        }
        updateTailSnapshot()
    }

    // MARK: 인라인 서식 (굵게·기울임·취소선·하이라이트·코드·링크·색·정렬)

    /// purlory 인라인 키 런 스냅샷 — setAttributes로 지워지기 전에 보관한다.
    func inlineSnapshot(
        in range: NSRange
    ) -> [(NSRange, [NSAttributedString.Key: Any])] {
        guard let storage = textStorage, range.length > 0 else { return [] }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range, options: []) { attrs, run, _ in
            let kept = attrs.filter { InlineMarkdown.inlineKeys.contains($0.key) }
            if !kept.isEmpty { runs.append((run, kept)) }
        }
        return runs
    }

    /// purlory 인라인 키를 읽어 폰트·색을 조립한다 — 항상 블록 기본 폰트 위에서
    /// 호출돼야 한다 (setAttributes 직후 / 로드 직후).
    func decorateInline(in range: NSRange) {
        guard let storage = textStorage, range.length > 0 else { return }
        storage.enumerateAttributes(in: range, options: []) { attrs, run, _ in
            let addition = inlineDecoration(for: attrs)
            if !addition.isEmpty { storage.addAttributes(addition, range: run) }
        }
        decorateInlineLinks(in: range)
    }

    /// 산문 문단 내 `[보이는 말](URL)` 인라인 링크에 시각적 강조(액센트 색·밑줄·툴팁)를 입힌다.
    /// 원문 텍스트는 보존하고 표시 속성만 사용해 `WritingNativeProjectionIndex`와 충돌하지 않는다.
    func decorateInlineLinks(in range: NSRange) {
        guard !isSourceMode, let storage = textStorage, range.length > 0 else { return }
        let ns = storage.string as NSString
        var loc = range.location
        while loc < min(range.upperBound, ns.length) {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = max(para.upperBound, loc + 1) }
            let info = storageBlockInfo(in: para)
            guard ![PurloryBlock.code, .math, .divider, .image].contains(info.block) else { continue }
            let text = paragraphContent(para)
            for link in WritingProseProjection.links(in: text) where !link.image {
                let fullRange = NSRange(location: para.location + link.source.location, length: link.source.length)
                let labelRange = NSRange(location: para.location + link.label.location, length: link.label.length)
                let openBracket = NSRange(location: fullRange.location, length: max(0, labelRange.location - fullRange.location))
                let tailSyntax = NSRange(location: labelRange.upperBound, length: max(0, fullRange.upperBound - labelRange.upperBound))
                if openBracket.length > 0 {
                    storage.addAttribute(.foregroundColor, value: palette.ink3, range: openBracket)
                }
                if tailSyntax.length > 0 {
                    storage.addAttribute(.foregroundColor, value: palette.ink3, range: tailSyntax)
                }
                if labelRange.length > 0 {
                    storage.addAttributes([
                        .foregroundColor: palette.blue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: palette.blue.withAlphaComponent(0.55),
                    ], range: labelRange)
                }
            }
        }
    }

    func inlineDecoration(for attrs: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any] {
        var addition: [NSAttributedString.Key: Any] = [:]
        var base = attrs[.font] as? NSFont ?? bodyFont
        // 크기 조절은 블록 기본 폰트를 리사이즈한 것 위에 굵게·기울임을 쌓는다.
        if let size = attrs[.purloryFontSize] as? Double,
            abs(base.pointSize - CGFloat(size)) > 0.1 {
            base = NSFontManager.shared.convert(base, toSize: CGFloat(size))
            addition[.font] = base
        }
        if attrs[.purloryCode] as? Bool == true {
            addition[.font] = NSFont.monospacedSystemFont(
                ofSize: base.pointSize * 0.78, weight: .regular)
            addition[.backgroundColor] = palette.codeBg
        } else {
            if attrs[.purloryBold] as? Bool == true {
                // NSFontManager does not select the bundled variable font's weight axis.
                let converted = base.familyName == bodyFont.familyName
                    ? PurloryFonts.serif(base.pointSize, weight: .bold)
                    : NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
                if converted != base { addition[.font] = converted }
                // 시스템 serif(New York) 폴백은 볼드가 한글 글리프에
                // 적용되지 않는다 — 커버하지 못하면 스트로크로 가짜 볼드.
                if !converted.coveredCharacterSet.contains(
                    UnicodeScalar(0xAC00)!) {
                    addition[.strokeWidth] = -2.5
                }
            }
            // 기울임은 항상 obliqueness — 한글엔 이탤릭 페이스가 없어
            // 폰트 변환으론 라틴만 기울어진다.
            if attrs[.purloryItalic] as? Bool == true {
                addition[.obliqueness] = 0.18
            }
            if attrs[.purloryStrikethrough] as? Bool == true {
                addition[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                addition[.strikethroughColor] =
                    (attrs[.purloryColor] as? String).flatMap(NSColor.init(inlineHex:)) ?? palette.ink2
            }
            if attrs[.purloryHighlight] as? Bool == true {
                addition[.backgroundColor] = palette.warning.withAlphaComponent(0.22)
            }
        }
        if let hex = attrs[.purloryColor] as? String, let color = NSColor(inlineHex: hex) {
            addition[.foregroundColor] = color
        }
        return addition
    }

    /// 문단에 저장된 .purloryAlign을 문단 스타일에 반영한다.
    func applyStoredAlignment(
        base attrs: [NSAttributedString.Key: Any], in paragraph: NSRange
    ) {
        guard let storage = textStorage, paragraph.location < storage.length,
            let align = storage.attribute(
                .purloryAlign, at: paragraph.location, effectiveRange: nil) as? String,
            let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle
        else { return }
        ps.alignment = align == "right" ? .right : .center
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    /// 문단에 저장된 .purloryLineSpacing을 문단 스타일에 반영한다 (선택 줄 줄 간격, 요구 4).
    /// 정렬 반영(applyStoredAlignment) 뒤에 호출해 현재 문단 스타일을 이어받는다.
    func applyStoredLineSpacing(in paragraph: NSRange) {
        guard let storage = textStorage, paragraph.location < storage.length,
            let spacing = storage.attribute(
                .purloryLineSpacing, at: paragraph.location, effectiveRange: nil) as? Double
        else { return }
        let current =
            storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle ?? .default
        guard let ps = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        // Explicit author formatting keeps its native line-spacing semantics.
        ps.minimumLineHeight = 0; ps.maximumLineHeight = 0
        ps.lineSpacing = CGFloat(spacing)
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    // MARK: 스타일 (디자인 CSS와 1:1)

    func styleAttributes(
        for block: PurloryBlock, checked: Bool, indent: Int = 0
    ) -> [NSAttributedString.Key: Any] {
        let t = palette
        var font = bodyFont
        var color = t.ink
        let ps = NSMutableParagraphStyle()
        // 자연 줄 높이 + 사용자 줄 간격 — 글자가 커서 높이의 중앙에 오도록
        // 라인 박스를 부풀리지 않는다 (요구 1·4, lineHeightMultiple 대체).
        ps.lineSpacing = lineSpacing
        let indentOffset = CGFloat(min(6, max(0, indent))) * 24

        switch block {
        case .p:
            if proseLayout == .continuous {
                ps.firstLineHeadIndent = baseFontSize
                ps.paragraphSpacing = round(baseFontSize * 0.22)
                ps.alignment = .left
                ps.lineBreakMode = .byWordWrapping
                ps.lineBreakStrategy = .hangulWordPriority
            } else {
                ps.paragraphSpacing = round(baseFontSize * 0.65)
            }
        case .h1:
            font = PurloryFonts.serif(editorialWorkspaceStyle ? baseFontSize * 1.52 : 31 * fontScale, weight: .bold)
            ps.paragraphSpacingBefore = editorialWorkspaceStyle ? baseFontSize * 1.52 * 0.2 : 16
            ps.paragraphSpacing = editorialWorkspaceStyle ? baseFontSize * 1.52 * 0.25 : 4
        case .h2:
            font = PurloryFonts.serif(editorialWorkspaceStyle ? baseFontSize * 1.12 : 25 * fontScale, weight: editorialWorkspaceStyle ? .medium : .semibold)
            if editorialWorkspaceStyle { color = t.workspaceMuted }
            ps.paragraphSpacingBefore = editorialWorkspaceStyle ? baseFontSize * 1.12 * 0.1 : 12
            ps.paragraphSpacing = editorialWorkspaceStyle ? baseFontSize * 1.12 : 2
        case .h3:
            font = PurloryFonts.serif(21 * fontScale, weight: .semibold)
            ps.paragraphSpacingBefore = 8
        case .h4:
            font = PurloryFonts.serif(19 * fontScale, weight: .semibold)
            ps.paragraphSpacingBefore = 6
        case .h5:
            font = PurloryFonts.serif(17.5 * fontScale, weight: .semibold)
            ps.paragraphSpacingBefore = 4
        case .h6:
            font = PurloryFonts.serif(16 * fontScale, weight: .medium)
            color = t.ink2
            ps.paragraphSpacingBefore = 4
        case .quote:
            color = t.ink2
            if editorialWorkspaceStyle { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let qIndent = 19 + CGFloat(min(6, max(0, indent))) * 14
            ps.firstLineHeadIndent = qIndent
            ps.headIndent = qIndent
            ps.paragraphSpacingBefore = 6
            ps.paragraphSpacing = 6
        case .bullet:
            ps.firstLineHeadIndent = 26 + indentOffset
            ps.headIndent = 26 + indentOffset
        case .number:
            ps.firstLineHeadIndent = 34 + indentOffset
            ps.headIndent = 34 + indentOffset
        case .todo:
            ps.firstLineHeadIndent = 32 + indentOffset
            ps.headIndent = 32 + indentOffset
            if checked { color = t.ink3 }
        case .code:
            font = NSFont.monospacedSystemFont(ofSize: 14.5 * fontScale, weight: .regular)
            ps.firstLineHeadIndent = 18
            ps.headIndent = 18
            ps.tailIndent = -18
        case .math:
            font = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            ps.alignment = .center
            ps.paragraphSpacingBefore = 10
            ps.paragraphSpacing = 10
            ps.firstLineHeadIndent = 20
            ps.headIndent = 20
            ps.tailIndent = -48
        case .divider:
            ps.minimumLineHeight = 28
            ps.maximumLineHeight = 28
        case .image:
            // 소스(![](…)) 편집 모드에서 가운데 정렬 — 렌더 이미지도 중앙에 온다.
            color = t.ink3
            font = PurloryFonts.ui(13 * fontScale)
            ps.alignment = .center
            ps.paragraphSpacingBefore = 8
            ps.paragraphSpacing = 8
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: ps,
        ]
        if block == .p || block == .quote { attrs[.kern] = CGFloat.zero }
        if editorialWorkspaceStyle, [.h1, .h2].contains(block) {
            attrs[.kern] = -font.pointSize * (block == .h1 ? 0.025 : 0.012)
        }
        if editorialWorkspaceStyle, block == .quote { attrs[.obliqueness] = 0.18 }
        if block == .todo, checked {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = t.ink3
        }
        return attrs
    }
}

final class PurloryLayoutManager: NSLayoutManager {
    private(set) var processingStorageEdit = false

    override func textStorage(_ textStorage: NSTextStorage, edited editedMask: Int,
                              range editedRange: NSRange, changeInLength delta: Int,
                              invalidatedRange invalidatedCharRange: NSRange) {
        let wasProcessing = processingStorageEdit
        processingStorageEdit = true
        defer { processingStorageEdit = wasProcessing }
        super.textStorage(textStorage, edited: editedMask, range: editedRange,
                          changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    // TextKit drawing uses this snapshot rather than actor-isolated view state.
    nonisolated(unsafe) var editorialWorkspaceStyle = false

    private var view: BlockTextView? {
        firstTextView as? BlockTextView
    }

    /// 문단 블록 정보 — storage 속성에서 직접 읽는다 (nonisolated 드로잉용).
    /// 문서 끝 빈 문단은 뷰의 tailBlockInfo 스냅샷으로 보완한다.
    private func blockInfo(
        _ storage: NSTextStorage, in paragraph: NSRange, view: BlockTextView
    ) -> (block: PurloryBlock, checked: Bool, marker: String?, indent: Int, codeLang: String?) {
        if paragraph.location < storage.length {
            let attrs = storage.attributes(at: paragraph.location, effectiveRange: nil)
            let block = (attrs[.purloryBlock] as? String).flatMap(PurloryBlock.init(rawValue:)) ?? .p
            return (
                block,
                attrs[.purloryChecked] as? Bool ?? false,
                attrs[.purloryMarker] as? String,
                attrs[.purloryIndent] as? Int ?? 0,
                attrs[.purloryCodeLang] as? String
            )
        }
        let snapshot = view.tailBlockInfo
        return (
            snapshot.block.flatMap(PurloryBlock.init(rawValue:)) ?? .p,
            snapshot.checked, snapshot.marker, snapshot.indent, snapshot.codeLang
        )
    }

    /// 배경(코드·수식 블록) 그리기 — **보이는 문단만** 훑는다.
    ///
    /// 예전엔 `glyphsToShow`를 인자로 받아놓고 무시한 채 문서 전체 문단을 돌았다.
    /// 그리기는 키 입력마다 일어나므로 그대로 키 입력당 O(문서)였다 —
    /// 30만 자에서 5.15ms (측정: docs/editor-perf.md). 이제 문서 길이와 무관하다.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let view, let storage = textStorage else { return }
        let theme = view.palette
        let ns = storage.string as NSString
        guard ns.length > 0, glyphsToShow.length > 0 else { return }

        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let firstPara = ns.paragraphRange(
            for: NSRange(location: min(shown.location, ns.length - 1), length: 0))
        let lastPara = ns.paragraphRange(
            for: NSRange(location: min(shown.upperBound, ns.length - 1), length: 0))

        // 코드 런은 여러 문단을 하나의 라운드 사각형으로 병합해 그린다 (디자인).
        // 화면 위/아래로 이어지는 런은 잘린 배경이 되므로 런의 시작·끝까지만
        // 넓힌다 — 넓히는 비용은 **런 길이**에 비례하지 문서 길이가 아니다.
        var start = firstPara.location
        while start > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
            guard blockInfo(storage, in: prev, view: view).block == .code else { break }
            start = prev.location
        }
        var end = lastPara.upperBound
        while end < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            guard blockInfo(storage, in: next, view: view).block == .code else { break }
            end = next.upperBound
        }

        var location = start
        var codeStart: Int? = nil
        while location < end {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let block = blockInfo(storage, in: para, view: view).block
            if block == .code {
                if codeStart == nil { codeStart = para.location }
            } else {
                if let runStart = codeStart {
                    drawGroupBackground(
                        charRange: NSRange(location: runStart, length: para.location - runStart),
                        origin: origin, color: theme.codeBg)
                    codeStart = nil
                }
                if block == .math {
                    // 렌더 모드 수식의 박스는 drawGlyphs가 **수식 크기에 맞춰**
                    // 그린다 (요구 5) — 여기선 소스 편집 중일 때만 문단 폭 배경.
                    // 다중 행 그룹 소속 문단도 렌더 중이면 박스를 생략한다 (이슈 #20).
                    let rendered = view.mathRenders.contains {
                        NSLocationInRange(para.location, $0.range)
                    }
                    if !rendered {
                        drawGroupBackground(
                            charRange: para, origin: origin, color: theme.codeBg)
                    }
                }
            }
            location = para.upperBound
        }
        if let runStart = codeStart {
            // end까지 넓혀 둔 덕에 여기가 곧 런의 끝이다.
            drawGroupBackground(
                charRange: NSRange(location: runStart, length: end - runStart),
                origin: origin, color: theme.codeBg)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let view, let storage = textStorage, storage.length > 0 else { return }
        let theme = view.palette
        let ns = storage.string as NSString
        let shownChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawWritingDiagnostics(forGlyphRange: glyphsToShow, at: origin, view: view)

        var location = shownChars.location
        while location < min(shownChars.upperBound + 1, ns.length + 1) {
            let para = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
            defer { location = max(para.upperBound, location + 1) }
            let info = blockInfo(storage, in: para, view: view)
            guard info.block != .p else { continue }
            guard let rect = paragraphRect(charRange: para, origin: origin) else { continue }
            let firstLine = firstLineRect(charRange: para, origin: origin) ?? rect
            let indentOffset = CGFloat(info.indent) * 24

            switch info.block {
            case .quote:
                (editorialWorkspaceStyle ? theme.workspaceTerracotta : theme.ink2).setFill()
                let barWidth: CGFloat = editorialWorkspaceStyle ? 2 : 3
                for level in 0...max(0, info.indent) {
                    let barX = rect.minX + CGFloat(level) * 20
                    NSRect(x: barX, y: rect.minY + 2, width: barWidth, height: rect.height - 4)
                        .fill()
                }
            case .bullet:
                let bullets = ["•", "◦", "▪"]
                let symbol = bullets[max(0, info.indent) % bullets.count]
                draw(marker: symbol, color: theme.ink2, size: 20,
                     x: leftEdge(origin) + 8 + indentOffset, line: firstLine,
                     baseline: firstBaseline(charRange: para, line: firstLine))
            case .number:
                // 본문(bodyFont serif 20)과 같은 크기·베이스라인으로 정렬.
                draw(marker: info.marker ?? "1.", color: theme.ink2, size: 20,
                     x: leftEdge(origin) + 6 + indentOffset, line: firstLine,
                     baseline: firstBaseline(charRange: para, line: firstLine))
            case .todo:
                // 체크박스는 글자 캡하이트의 세로 중앙에 맞춘다.
                let centerY = firstBaseline(charRange: para, line: firstLine)
                    .map { $0 - PurloryFonts.serif(20).capHeight / 2 } ?? firstLine.midY
                drawCheckbox(
                    checked: info.checked, theme: theme,
                    at: NSPoint(x: leftEdge(origin) + 4 + indentOffset, y: centerY - 8))
            case .code:
                if let lang = info.codeLang, !lang.isEmpty {
                    let isFirstInRun: Bool = {
                        guard para.location > 0 else { return true }
                        let prev = ns.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
                        return blockInfo(storage, in: prev, view: view).block != .code
                    }()
                    if isFirstInRun {
                        let tag = NSAttributedString(
                            string: lang,
                            attributes: [
                                .font: PurloryFonts.mono(10), .foregroundColor: theme.ink3,
                                .kern: 0.4,
                            ])
                        tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 12, y: rect.minY + 2))
                    }
                }
            case .divider:
                theme.sepStrong.setFill()
                NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1).fill()
            case .math:
                if let render = view.mathRenders.first(
                    where: { NSLocationInRange(para.location, $0.range) })
                {
                    // 다중 행 그룹이면 그룹 **전체** rect에 한 번만 그린다 —
                    // 문단별로 그리면 같은 이미지가 줄마다 찍힌다 (이슈 #20).
                    if para.location == render.range.location {
                        let unionRect = paragraphRect(
                            charRange: render.range, origin: origin) ?? rect
                        drawMath(render.image, in: unionRect, theme: theme)
                    }
                } else {
                    // 편집 중이거나 아직 파싱 안 되는 소스 — "수식" 태그만.
                    let tag = NSAttributedString(
                        string: "수식",
                        attributes: [
                            .font: PurloryFonts.ui(10), .foregroundColor: theme.ink3,
                            .kern: 0.6,
                        ])
                    tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 12, y: rect.minY + 6))
                }
            case .image:
                if let render = view.imageRenders.first(
                    where: { $0.range.location == para.location }) {
                    drawImage(
                        render.image, in: rect, display: render.size,
                        align: render.align, selected: render.selected, theme: theme)
                } else {
                    // 편집 중이거나 파일을 못 읽음 — "이미지" 태그만.
                    let tag = NSAttributedString(
                        string: "이미지",
                        attributes: [
                            .font: PurloryFonts.ui(10), .foregroundColor: theme.ink3,
                            .kern: 0.6,
                        ])
                    tag.draw(at: NSPoint(x: rect.maxX - tag.size().width - 12, y: rect.minY + 6))
                }
            default:
                break
            }
        }
    }

    // MARK: 헬퍼

    /// 문단 좌측 기준선(들여쓰기 이전의 텍스트 시작 x).
    private func leftEdge(_ origin: NSPoint) -> CGFloat {
        guard let container = textContainers.first else { return origin.x }
        return origin.x + container.lineFragmentPadding
    }

    private func paragraphRect(charRange: NSRange, origin: NSPoint) -> NSRect? {
        guard let container = textContainers.first else { return nil }
        let range = charRange
        // 빈 문단(개행만)도 rect가 나오도록 개행 포함 그대로 사용.
        if range.length == 0 {
            guard let extra = extraLineRect(origin: origin) else { return nil }
            return extra
        }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        rect.size.width = container.size.width - container.lineFragmentPadding * 2
        rect.origin.x = origin.x + container.lineFragmentPadding
        return rect
    }

    private func firstLineRect(charRange: NSRange, origin: NSPoint) -> NSRect? {
        guard charRange.length > 0 else { return nil }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var effective = NSRange()
        var rect = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &effective)
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    private func extraLineRect(origin: NSPoint) -> NSRect? {
        var rect = extraLineFragmentRect
        guard rect.height > 0 else { return nil }
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    /// 첫 라인의 텍스트 베이스라인 y — 프래그먼트 중앙이 아니라 글리프
    /// 베이스라인(실측) 기준으로 마커를 놓아야 본문 글자와 높이가 맞는다.
    private func firstBaseline(charRange: NSRange, line: NSRect) -> CGFloat? {
        guard charRange.length > 0 else { return nil }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return line.minY + location(forGlyphAt: glyphs.location).y
    }

    private func draw(
        marker: String, color: NSColor, size: CGFloat,
        x: CGFloat, line: NSRect, baseline: CGFloat?
    ) {
        let font = PurloryFonts.serif(size)
        let attr = NSAttributedString(
            string: marker,
            attributes: [.font: font, .foregroundColor: color])
        let y = baseline.map { $0 - font.ascender }
            ?? line.minY + (line.height - attr.size().height) / 2
        attr.draw(at: NSPoint(x: x, y: y))
    }

    /// 렌더된 LaTeX 이미지를 수식 문단 중앙에 그린다 (폭 초과 시 축소).
    /// 배경 박스는 문단 폭이 아니라 **수식 크기 + 사방 mathBoxMargin(10pt)** —
    /// 분수처럼 큰 수식이면 박스도 함께 커진다 (요구 5).
    private func drawMath(_ image: NSImage, in rect: NSRect, theme: PurloryTheme) {
        var size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let maxWidth = max(40, rect.width - 32)
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        let target = NSRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height)
        let box = target.insetBy(
            dx: -BlockTextView.mathBoxMargin, dy: -BlockTextView.mathBoxMargin)
        theme.codeBg.setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        image.draw(
            in: target, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    /// 렌더된 이미지를 지정 크기(`display`)·정렬(`align`)로 그린다. 객체 선택 시엔
    /// 선택 테두리도 두른다 (요구 3). display는 뷰의 `imageDisplaySize`가 계산한 값.
    private func drawImage(
        _ image: NSImage, in rect: NSRect, display: NSSize,
        align: String, selected: Bool, theme: PurloryTheme
    ) {
        guard display.width > 0, display.height > 0 else { return }
        // 줄 높이(=display 높이+여유)를 넘지 않게 안전하게 한 번 더 맞춘다.
        let box = rect.insetBy(dx: 8, dy: 6)
        let scale = min(box.width / display.width, box.height / display.height, 1)
        let size = NSSize(width: display.width * scale, height: display.height * scale)
        // 가로 정렬 — 좌/우는 살짝 안쪽(8pt)에서 시작한다.
        let x: CGFloat
        switch align {
        case "left": x = box.minX
        case "right": x = box.maxX - size.width
        default: x = rect.midX - size.width / 2
        }
        let target = NSRect(
            x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(
            in: target, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
        // 선택 테두리·핸들은 ImageBoxOverlay(별도 뷰)가 그린다.
    }

    private func drawCheckbox(checked: Bool, theme: PurloryTheme, at point: NSPoint) {
        let box = NSRect(x: point.x, y: point.y, width: 16, height: 16)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        path.lineWidth = 1.5
        if checked {
            theme.blue.setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
                .applying(.init(paletteColors: [theme.blue.accessibleForeground()]))
            guard let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let size = check.size
            check.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                width: size.width, height: size.height), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            theme.ink3.setStroke()
            path.stroke()
        }
    }

    private func drawGroupBackground(charRange: NSRange, origin: NSPoint, color: NSColor) {
        guard let container = textContainers.first, charRange.length > 0 else { return }
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x = origin.x + container.lineFragmentPadding
        rect.origin.y += origin.y
        rect.size.width = container.size.width - container.lineFragmentPadding * 2
        rect = rect.insetBy(dx: 0, dy: -6)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
    }

}
