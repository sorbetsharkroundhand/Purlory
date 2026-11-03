import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

// Markdown round-trip, source coordinates and serialization cache.
extension BlockTextView {

    /// typingAttributes 변경 후 호출해 스냅샷을 갱신한다.
    func updateTailSnapshot() {
        tailBlockInfo = (
            typingAttributes[.purloryBlock] as? String,
            typingAttributes[.purloryChecked] as? Bool ?? false,
            typingAttributes[.purloryMarker] as? String,
            typingAttributes[.purloryIndent] as? Int ?? 0,
            typingAttributes[.purloryCodeLang] as? String
        )
    }

    // MARK: 마크다운 ↔ 블록 변환

    /// Replaces the manuscript at a stable document boundary. This is intentionally separate
    /// from ordinary binding synchronization: only a real document identity change may discard
    /// native undo and transient editor state.
    @discardableResult
    func prepareForDocumentTransition(
        from previous: EditorDocumentIdentity?,
        to next: EditorDocumentIdentity,
        markdown: String
    ) -> Bool {
        guard previous != next else { return false }
        prepareForDocumentTransition(markdown: markdown)
        return true
    }

    func prepareForDocumentTransition(markdown: String) {
        if hasMarkedText() {
            // Commit Hangul composition before replacing TextKit storage. Persisting the outgoing
            // position remains the coordinator's responsibility and never records marked state.
            unmarkText()
        }
        ghostText = nil
        showConversationPrompt(nil)
        hideImageToolbar()
        hideSelectionToolbar()
        load(markdown: markdown)
        undoManager?.removeAllActions()
    }

    /// 인용(`> `, `> > `) 접두 파싱 — 중첩 단계(0...6)와 본문을 돌려준다.
    /// 공백 없는 `>literal`은 인용으로 오독하지 않는다.
    nonisolated static func parseQuotePrefix(_ line: String) -> (indent: Int, body: String)? {
        if line == ">" { return (0, "") }
        guard line.hasPrefix("> ") else { return nil }
        var rest = line[...]
        var count = 0
        while count < 7 {
            if rest.hasPrefix("> ") {
                count += 1
                rest = rest.dropFirst(2)
            } else if rest == ">" {
                count += 1
                rest = rest.dropFirst(1)
                break
            } else {
                break
            }
        }
        guard count > 0 else { return nil }
        return (count - 1, String(rest))
    }

    /// 들여쓰기된 목록(`  - `, `  1. `, `  - [ ] `) 접두 파싱 — 2칸 공백 단위로 최대 6단계.
    nonisolated static func parseListPrefix(_ line: String) -> (
        block: PurloryBlock, checked: Bool, marker: String?, indent: Int, body: String
    )? {
        var leadingSpaces = 0
        for ch in line {
            if ch == " " { leadingSpaces += 1 }
            else { break }
        }
        let indent = min(6, leadingSpaces / 2)
        let rest = String(line.dropFirst(indent * 2))
        if rest.hasPrefix("- [ ] ") || rest.hasPrefix("- [x] ") {
            return (.todo, rest.hasPrefix("- [x] "), nil, indent, String(rest.dropFirst(6)))
        } else if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            return (.bullet, false, nil, indent, String(rest.dropFirst(2)))
        } else if let match = rest.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let marker = String(rest[rest.startIndex..<match.upperBound])
                .trimmingCharacters(in: .whitespaces)
            return (.number, false, marker, indent, String(rest[match.upperBound...]))
        }
        return nil
    }

    /// 마크다운을 파싱해 storage를 블록 문서로 채운다 (buildDOM).
    func load(markdown: String, sourceMode: Bool = false) {
        guard let storage = textStorage else { return }
        isSourceMode = sourceMode
        lastTypingKeyTimestamp = nil
        invalidateMediaIndex()
        isTransforming = true
        let result = NSMutableAttributedString()
        var inCode = false
        var currentCodeLang: String?
        // 다중 행 display 수식 그룹 상태 — "$$"만 있는(혹은 $$ 뒤 내용이 이어지는)
        // 줄에 열리고 $$로 닫힌다. 그룹 안에선 다른 블록 파싱(#·-·>)을 전부 건너뛴다:
        // 행렬·cases 내용 줄이 헤딩·목록으로 오독되면 원문 구조가 깨진다 (이슈 #20).
        var inMathGroup = false
        let lines = markdown.components(separatedBy: "\n")
        if sourceMode {
            result.append(NSAttributedString(string: markdown, attributes: styleAttributes(for: .p, checked: false)))
        } else {
            for (index, rawLine) in lines.enumerated() {
                var line = rawLine
                let trimmedFence = line.trimmingCharacters(in: .whitespaces)
                if !inMathGroup {
                    if !inCode, trimmedFence.hasPrefix("```"), !trimmedFence.dropFirst(3).contains("`") {
                        inCode = true
                        let lang = String(trimmedFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        currentCodeLang = lang.isEmpty ? nil : lang
                        continue
                    } else if inCode, trimmedFence == "```" {
                        inCode = false
                        currentCodeLang = nil
                        continue
                    }
                }
                var block = PurloryBlock.p
                var checked = false
                var marker: String?
                var indent = 0
                var codeLang: String?
                // 정렬 래퍼(<p align="…">…</p>)는 블록 판정 전에 벗긴다.
                var align: String?
                if !inCode, !inMathGroup, line.hasPrefix("<p ") {
                    let full = NSRange(location: 0, length: (line as NSString).length)
                    if let match = Self.alignWrapper.firstMatch(in: line, range: full) {
                        align = (line as NSString).substring(with: match.range(at: 1))
                        line = (line as NSString).substring(with: match.range(at: 2))
                    }
                }
                // 이 줄이 수식 그룹에서 어떤 역할인지 — 속성으로 기록해 serialize가
                // 구분자를 정확히 되돌려준다.
                var mathDelim: String?
                if inCode {
                    block = .code
                    codeLang = currentCodeLang
                } else if inMathGroup {
                    block = .math
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed == "$$" || trimmed.hasSuffix("$$"), trimmed.count >= 2 {
                        // 닫는 줄. 텍스트는 **원문 그대로** 둔다 — 빈 문단은 storage에서
                        // 존재하지 않아(마지막 줄이면 특히) 속성째 사라진다. 구분자를
                        // 벗기는 일은 렌더·직렬화가 역할 속성으로 처리한다 (이슈 #20).
                        mathDelim = "close"
                        inMathGroup = false
                    } else {
                        // 중간 내용 줄 — 완결 단독 수식과 구별해야 serialize가 $$를
                        // 덧붙이지 않는다.
                        mathDelim = "mid"
                    }
                } else if line.hasPrefix("###### ") {
                    block = .h6; line = String(line.dropFirst(7))
                } else if line.hasPrefix("##### ") {
                    block = .h5; line = String(line.dropFirst(6))
                } else if line.hasPrefix("#### ") {
                    block = .h4; line = String(line.dropFirst(5))
                } else if line.hasPrefix("### ") {
                    block = .h3; line = String(line.dropFirst(4))
                } else if line.hasPrefix("## ") {
                    block = .h2; line = String(line.dropFirst(3))
                } else if line.hasPrefix("# ") {
                    block = .h1; line = String(line.dropFirst(2))
                } else if let quoteMatch = Self.parseQuotePrefix(line) {
                    block = .quote; indent = quoteMatch.indent; line = quoteMatch.body
                } else if let listMatch = Self.parseListPrefix(line) {
                    block = listMatch.block; checked = listMatch.checked
                    marker = listMatch.marker; indent = listMatch.indent; line = listMatch.body
                } else if line.hasPrefix("---"), line.range(of: #"^---+\s*$"#, options: .regularExpression) != nil {
                    block = .divider; line = ""
                } else if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count >= 4 {
                    block = .math; line = String(line.dropFirst(2).dropLast(2))
                } else if line.trimmingCharacters(in: .whitespaces) == "$$"
                    || (line.hasPrefix("$$") && !line.dropFirst(2).hasPrefix("$")) {
                    // "$$" 단독 또는 "$$내용…" — 여러 줄 display의 열기 (이슈 #20).
                    // 텍스트는 원문 그대로 — 벗기는 일은 렌더·직렬화가 한다.
                    block = .math
                    mathDelim = "open"
                    inMathGroup = true
                } else if line.hasPrefix("!["), line.range(
                    of: #"^!\[[^\]]*\]\([^)\s]+\)(?:\{[^}]*\})?$"#,
                    options: .regularExpression) != nil {
                    // 한 줄 전체가 이미지 마크다운 — 원문(![](src){…})을 소스로 보관하고
                    // 커서가 밖이면 렌더 이미지로 덮어 그린다 (수식과 같은 방식).
                    block = .image
                }
                var attrs = styleAttributes(for: block, checked: checked, indent: indent)
                attrs[.purloryBlock] = block.rawValue
                if checked { attrs[.purloryChecked] = true }
                if let marker { attrs[.purloryMarker] = marker }
                if indent > 0 { attrs[.purloryIndent] = indent }
                if let codeLang { attrs[.purloryCodeLang] = codeLang }
                if let mathDelim { attrs[.purloryMathDelim] = mathDelim }
                if let align {
                    attrs[.purloryAlign] = align
                    if let ps = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                        as? NSMutableParagraphStyle {
                        ps.alignment = align == "right" ? .right : .center
                        attrs[.paragraphStyle] = ps
                    }
                }
                let suffix = index < lines.count - 1 ? "\n" : ""
                switch block {
                case .code, .math, .divider, .image:
                    // 코드·수식·이미지엔 인라인 서식이 없다 — 원문 그대로.
                    result.append(NSAttributedString(string: line + suffix, attributes: attrs))
                default:
                    for segment in InlineMarkdown.parse(line) {
                        var merged = attrs
                        for (key, value) in segment.attrs { merged[key] = value }
                        result.append(NSAttributedString(string: segment.text, attributes: merged))
                    }
                    result.append(NSAttributedString(string: suffix, attributes: attrs))
                }
            }
        }
        storage.setAttributedString(result)
        if !sourceMode {
            decorateInline(in: NSRange(location: 0, length: storage.length))
            convertAllInlineMath()
        }
        // 저널을 열면 맨 위·처음에 커서를 둔다 — 예전엔 문서 끝에 놓여, 뷰포트는
        // 위인데 커서는 아래라 첫 키 입력이 바닥으로 순간이동하는 혼란이 있었다.
        setSelectedRange(NSRange(location: 0, length: 0))
        // 뷰포트도 맨 위로 — 긴 저널을 열면 처음부터 보이게.
        scrollToBeginningOfDocument(nil)
        if storage.length == 0 {
            applyBlock(.p, to: NSRange(location: 0, length: 0), registerUndo: false)
        }
        syncTypingAttributes()
        isTransforming = false
        selectedImageLocation = nil
        hideImageToolbar()
        hideSelectionToolbar()
        // 새 문서의 마커 캐시를 실측으로 초기화 — 로드는 드물어 전체 스캔이 싸다.
        // (이전 문서의 플래그를 물려받으면 빠른 경로 판정이 틀린다.)
        syncMarkerFlag()
        // 직렬화 캐시도 새 문서 기준으로 — 다음 serialize()가 전체 재구축한다.
        invalidateSerialCache()
        // 커서가 어느 문단에 있든(수식·이미지 포함) 로드 직후엔 전부 렌더로 강제한다 —
        // 소스가 잠깐 보였다 사라지지 않게. 사용자가 커서를 움직이면 평소 규칙으로 복귀.
        if !sourceMode { refreshRenderedBlocks(forceRender: true) }
        writingDidLoad(markdown)
        needsDisplay = true
    }

    /// 전역 검색 결과 클릭 — 본문에서 질의어의 첫 매치를 선택하고 화면 가운데쯤으로
    /// 스크롤한다 (요구 2). 선택 하이라이트(민트 영역)가 곧 "여기예요" 표시가 된다.
    /// 매치가 없으면(제목만 걸렸거나 마커에 걸친 경우) 그대로 둔다.
    func revealMatch(of query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let ns = string as NSString
        let match = ns.range(of: q, options: .caseInsensitive)
        guard match.location != NSNotFound else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(match)
        // 매치 줄이 화면 가장자리에 걸리지 않게 위아래 여유를 두고 드러낸다.
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: match, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            _ = scrollToVisible(rect.insetBy(dx: 0, dy: -140))
        } else {
            scrollRangeToVisible(match)
        }
        refreshActiveLineHighlight()
    }

    /// 현재 집필 위치 스냅샷 — 문서별 복원 저장용 (#36). `marked`를 함께 반환해
    /// 스토어가 확정되지 않은 IME 조합 위치를 기록하지 않도록 한다.
    func writingPositionSnapshot() -> (
        location: Int, selectionLength: Int, before: String, after: String, marked: Bool
    )? {
        let ns = string as NSString
        let location = max(0, min(selectedRange().location, ns.length))
        let selectionLength = max(0, min(selectedRange().length, ns.length - location))
        let selectionEnd = location + selectionLength
        let beforeStart = max(0, location - 24)
        let afterEnd = min(ns.length, selectionEnd + 24)
        return (
            location,
            selectionLength,
            ns.substring(with: NSRange(location: beforeStart, length: location - beforeStart)),
            ns.substring(with: NSRange(location: selectionEnd, length: afterEnd - selectionEnd)),
            hasMarkedText()
        )
    }

    /// 재안착 사다리를 통과한 위치로 복원(#36) — 앵커가 문맥에 맞으면 true.
    func restoreWritingPosition(_ position: WritingPositionStore.Position, entryID: UUID) -> Bool {
        guard let resolved = WritingPositionStore.shared.resolve(for: entryID, in: string)
        else { return false }
        restoreWritingPosition(
            .init(
                location: resolved,
                selectionLength: position.selectionLength,
                before: position.before,
                after: position.after))
        return true
    }

    func restoreWritingPosition(_ position: WritingPositionStore.Position) {
        let length = (string as NSString).length
        let location = max(0, min(position.location, length))
        let selectionLength = max(0, min(position.selectionLength, length - location))
        setSelectedRange(NSRange(location: location, length: selectionLength))
        syncTypingAttributes()
        scrollRangeToVisible(selectedRange())
    }

    /// 저장해 둔 커서 위치로 되돌리고 그 자리로 스크롤한다 (저널 재방문, M6).
    func restoreCaret(to location: Int) {
        restoreSelection(to: NSRange(location: location, length: 0))
    }

    func restoreSelection(to range: NSRange) {
        let textLength = (string as NSString).length
        let location = max(0, min(range.location, textLength))
        let selectionLength = max(0, min(range.length, textLength - location))
        setSelectedRange(NSRange(location: location, length: selectionLength))
        syncTypingAttributes()
        scrollRangeToVisible(selectedRange())
    }

    /// Explicit string consumers share the immutable source's cached materialization.
    /// Ordinary project edits publish serializedSource() without joining the document.
    /// Uncertain native mappings still use the full load/rebuild oracle.
    func serialize() -> String { serializedSource().string }

    func serializedSource() -> DocumentSource {
        if isSourceMode { return DocumentSource(string) }
        writingProjectionCapture.serializationInvocationCount += 1
        writingProjectionCapture.beginSerialization(storage: textStorage)
        if !serialLinesValid {
            rebuildSerialCache()
        } else if let dirty = serialDirtyRange {
            applySerialDirtyRangeUpdate(dirty)
        } else if serialFastDirty {
            applyFastSerialUpdate()
        }
        return markdownCodec.source
    }

    /// Explicit inspection maps the native caret to original Markdown coordinates.
    /// Consumed block markers and code fences contribute only to source coordinates.
    func sourceCursorOffset(at requestedOffset: Int? = nil) -> Int {
        if isSourceMode {
            let ns = string as NSString
            return min(max(0, requestedOffset ?? selectedRange().location), ns.length)
        }
        let ns = string as NSString, caret = min(max(0, requestedOffset ?? selectedRange().location), ns.length)
        var nativeOffset = 0, sourceOffset = 0, inCode = false
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: nativeOffset, length: 0))
            let line = serializedLine(of: para)
            if line.isCode != inCode {
                sourceOffset += line.isCode ? 4 + (line.codeLang?.utf16.count ?? 0) : 4
                inCode = line.isCode
            }
            if caret < NSMaxRange(para) || NSMaxRange(para) == ns.length {
                let info = storageBlockInfo(in: para), plain = paragraphContent(para)
                let length = min(max(0, caret - para.location), plain.utf16.count)
                let indentCount = info.indent * 2
                let blockPrefix: Int
                switch info.block {
                case .h1: blockPrefix = 2
                case .h2: blockPrefix = 3
                case .h3: blockPrefix = 4
                case .h4: blockPrefix = 5
                case .h5: blockPrefix = 6
                case .h6: blockPrefix = 7
                case .quote: blockPrefix = (info.indent + 1) * 2
                case .bullet: blockPrefix = indentCount + 2
                case .number: blockPrefix = indentCount + (info.marker ?? "1.").utf16.count + 1
                case .todo: blockPrefix = indentCount + 6
                case .math:
                    let content = serializedContent(of: para, block: info.block)
                    blockPrefix = line.text == content ? 0 : 2
                default:
                    if let align = alignValue(at: para), info.block == .p {
                        blockPrefix = "<p align=\"\(align)\">".utf16.count
                    } else { blockPrefix = 0 }
                }
                guard let storage = textStorage,
                    ![PurloryBlock.code, .math, .divider, .image].contains(info.block) else {
                    return sourceOffset + blockPrefix + length
                }
                var prefixLength = InlineMarkdown.serialize(storage,
                    in: NSRange(location: para.location, length: length)).utf16.count
                if length > 0 {
                    var run = NSRange()
                    let attrs = storage.attributes(at: para.location + length - 1, effectiveRange: &run)
                    if NSMaxRange(run) > para.location + length,
                        !(attrs[.attachment] is MathAtomAttachment) {
                        if attrs[.purloryCode] as? Bool == true { prefixLength -= 1 }
                        else {
                            prefixLength -= (attrs[.purloryBold] as? Bool == true ? 2 : 0)
                                + (attrs[.purloryItalic] as? Bool == true ? 1 : 0)
                                + (attrs[.purloryStrikethrough] as? Bool == true ? 2 : 0)
                                + (attrs[.purloryHighlight] as? Bool == true ? 2 : 0)
                        }
                        if attrs[.purloryColor] != nil || attrs[.purloryFontSize] != nil { prefixLength -= 7 }
                    }
                }
                return sourceOffset + blockPrefix + max(0, prefixLength)
            }
            sourceOffset += line.text.utf16.count + 1
            nativeOffset = NSMaxRange(para)
        } while nativeOffset < ns.length
        return sourceOffset
    }

    /// Read-only original coverage for complete native paragraphs. Unlike a caret,
    /// a block owns its opening/closing fences and consumed Markdown prefixes.
    /// This also works before an inactive tile has attached a diagnostics runtime.
    func originalParagraphRange(forNative range: NSRange) -> NSRange? {
        let ns = string as NSString
        guard range.location >= 0, range.length > 0, range.location <= ns.length,
              range.length <= ns.length - range.location else { return nil }
        var native = 0, source = 0, inCode = false, start: Int?
        while native < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: native, length: 0))
            let line = serializedLine(of: paragraph), wasCode = inCode, beforeFence = source
            if line.isCode != inCode {
                source += line.isCode ? 4 + (line.codeLang?.utf16.count ?? 0) : 4
                inCode = line.isCode
            }
            if paragraph.location == range.location { start = line.isCode && !wasCode ? beforeFence : source }
            source += line.text.utf16.count + (ns.character(at: paragraph.upperBound - 1) == 10 ? 1 : 0)
            if paragraph.upperBound == range.upperBound, let start {
                if line.isCode {
                    let nextCode: Bool
                    if paragraph.upperBound < ns.length {
                        let next = ns.paragraphRange(for: NSRange(location: paragraph.upperBound, length: 0))
                        nextCode = serializedLine(of: next).isCode
                    } else { nextCode = false }
                    if !nextCode { source += 4 }
                }
                return NSRange(location: start, length: source - start)
            }
            native = paragraph.upperBound
        }
        return nil
    }

    /// 문단 하나가 직렬화에 기여하는 줄과 코드 여부. 전체 재구축·증분 갱신이
    /// **같은 코드**를 쓰므로 두 경로의 출력이 구조적으로 일치한다.
    func serializedLine(of para: NSRange) -> (text: String, isCode: Bool, codeLang: String?) {
        // Trust stored block attributes, never typing attributes from an empty caret paragraph.
        let info = storageBlockInfo(in: para)
        let native = string as NSString
        let hasFeed = para.length > 0 && para.upperBound <= native.length && native.character(at: para.upperBound - 1) == 0x0A
        writingProjectionCapture.beginLine(para, hasLineFeed: hasFeed)
        let content = serializedContent(of: para, block: info.block)
        func result(prefix: String = "", suffix: String = "", code: Bool = false,
                    codeLang: String? = nil, literal: Bool = false) -> (text: String, isCode: Bool, codeLang: String?) {
            let text = prefix + (literal ? "" : content) + suffix
            writingProjectionCapture.finishLine(text: text, prefix: prefix, suffix: suffix, isCode: code,
                eligible: ![PurloryBlock.code, .math, .divider, .image].contains(info.block), literal: literal)
            return (text, code, codeLang)
        }
        let indentPrefix = info.indent > 0 ? String(repeating: "  ", count: info.indent) : ""
        switch info.block {
        case .code: return result(code: true, codeLang: info.codeLang)
        case .h1: return result(prefix: "# ")
        case .h2: return result(prefix: "## ")
        case .h3: return result(prefix: "### ")
        case .h4: return result(prefix: "#### ")
        case .h5: return result(prefix: "##### ")
        case .h6: return result(prefix: "###### ")
        case .quote: return result(prefix: String(repeating: "> ", count: info.indent + 1))
        case .bullet: return result(prefix: indentPrefix + "- ")
        case .number: return result(prefix: indentPrefix + (info.marker ?? "1.") + " ")
        case .todo: return result(prefix: indentPrefix + "- [" + (info.checked ? "x" : " ") + "] ")
        case .math:
            if let storage = textStorage, para.location < storage.length {
                let attrs = storage.attributes(at: para.location, effectiveRange: nil)
                switch attrs[.purloryMathDelim] as? String {
                case "open", "mid", "close": return result()
                default: break
                }
            }
            return result(prefix: "$$", suffix: "$$")
        case .divider: return result(prefix: "---", literal: true)
        case .image: return result()
        default:
            if let align = alignValue(at: para) {
                return result(prefix: "<p align=\"\(align)\">", suffix: "</p>")
            }
            return result()
        }
    }

    /// 전체 재구축 — 예전 serialize의 전체 순회. `serialLinesValid`가 false일 때만
    /// 돈다(첫 호출·구조 변화·불확실). 이후 증분 갱신의 기준선이 된다.
    func rebuildSerialCache() {
        serialCacheRebuildCount += 1
        let ns = string as NSString
        var lines: [(text: String, isCode: Bool, codeLang: String?)] = []
        let selLoc = min(selectedRange().location, ns.length)
        var fastIdx: Int?
        var fastStart = 0
        var location = 0
        repeat {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var line = serializedLine(of: para)
            // 네이티브 UTF-8로 강제 — join에서 문자 단위 재변환을 없앤다(핵심).
            line.text.makeContiguousUTF8()
            lines.append(line)
            // 커서가 든 문단을 빠른 경로의 시작점으로 삼는다(타이핑은 여기서 이어진다).
            if fastIdx == nil, para.lowerBound <= selLoc, selLoc <= para.upperBound {
                fastIdx = lines.count - 1
                fastStart = para.location
            }
            location = para.upperBound
        } while location < ns.length
        serialLines = lines
        markdownCodec.reset(lines, trailingLineFeed: ns.length > 0 && ns.character(at: ns.length - 1) == 0x0A)
        serialLinesValid = true
        serialFastDirty = false
        serialDirtyRange = nil
        serialSyncedLength = ns.length
        serialFastIndex = fastIdx
        serialFastStart = fastStart
        if ns.length > 0, mediaParagraphIndex?.utf16Length != ns.length {
            _ = indexedMediaParagraphs(in: NSRange(location: 0, length: 0))
        }
    }

    /// 빠른 경로: 추적 중인 문단 하나만 다시 브리지해 캐시에 splice.
    func applyFastSerialUpdate() {
        serialFastDirty = false
        guard let idx = serialFastIndex, idx < serialLines.count else {
            rebuildSerialCache()
            return
        }
        let ns = string as NSString
        guard serialFastStart <= ns.length else {
            rebuildSerialCache()
            return
        }
        let anchor = min(serialFastStart, max(0, ns.length - 1))
        let para = ns.paragraphRange(for: NSRange(location: anchor, length: 0))
        // 추적하던 문단의 시작이 어긋났으면(예상 못 한 구조 변화) 전체로 후퇴.
        guard para.location == serialFastStart else {
            rebuildSerialCache()
            return
        }
        var line = serializedLine(of: para)
        line.text.makeContiguousUTF8()
        let codeBoundaryChanged = serialLines[idx].isCode != line.isCode
        serialLines[idx] = line
        markdownCodec.update(serialLines, at: idx, codeBoundaryChanged: codeBoundaryChanged,
            trailingLineFeed: ns.length > 0 && ns.character(at: ns.length - 1) == 0x0A)
        serialSyncedLength = ns.length
    }

    /// 문단 이동·줄바꿈·병합·속성 편집 시 더티 문단 범위만 다시 직렬화해 캐시에 splice한다.
    func applySerialDirtyRangeUpdate(_ dirty: NSRange) {
        serialDirtyRange = nil
        serialFastDirty = false
        let ns = string as NSString
        guard serialSyncedLength > 0, ns.length > 0, !serialLines.isEmpty,
              let index = mediaParagraphIndex, index.utf16Length == ns.length else {
            rebuildSerialCache()
            return
        }
        var effectiveDirty = dirty
        if let captureDirty = writingProjectionCapture.currentDirtyRange {
            let start = min(effectiveDirty.location, captureDirty.location)
            let end = max(effectiveDirty.upperBound, captureDirty.upperBound)
            effectiveDirty = NSRange(location: start, length: max(0, end - start))
        }
        let queryStart = min(max(0, effectiveDirty.location - 1), ns.length)
        let queryEnd = min(max(queryStart, effectiveDirty.upperBound + 1), ns.length)
        let newParaRange = ns.paragraphRange(
            for: NSRange(location: queryStart, length: queryEnd - queryStart))
        guard let startRank = index.paragraphRank(forParagraphAt: newParaRange.location),
              let newEndRank = index.paragraphRank(forParagraphAt: newParaRange.upperBound) else {
            rebuildSerialCache()
            return
        }
        let newTotalRows = index.paragraphCount
        let oldTotalRows = serialLines.count
        let oldEndRank = oldTotalRows - (newTotalRows - newEndRank)
        guard startRank >= 0, startRank <= oldEndRank, oldEndRank <= oldTotalRows,
              startRank <= newEndRank, newEndRank <= newTotalRows else {
            rebuildSerialCache()
            return
        }
        var updatedLines: [(text: String, isCode: Bool, codeLang: String?)] = []
        updatedLines.reserveCapacity(newEndRank - startRank)
        var location = newParaRange.location
        let selLoc = min(selectedRange().location, ns.length)
        var fastIdx: Int?
        var fastStart = 0
        while location < newParaRange.upperBound {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            guard para.upperBound > location else { break }
            var line = serializedLine(of: para)
            line.text.makeContiguousUTF8()
            updatedLines.append(line)
            if fastIdx == nil, para.lowerBound <= selLoc, selLoc <= para.upperBound {
                fastIdx = startRank + updatedLines.count - 1
                fastStart = para.location
            }
            location = para.upperBound
        }
        guard updatedLines.count == newEndRank - startRank else {
            rebuildSerialCache()
            return
        }
        let trailingLineFeed = ns.length > 0 && ns.character(at: ns.length - 1) == 0x0A
        serialLines.replaceSubrange(startRank..<oldEndRank, with: updatedLines)
        markdownCodec.replaceSubrange(
            startRank..<oldEndRank, with: updatedLines.count,
            in: serialLines, trailingLineFeed: trailingLineFeed)
        serialSyncedLength = ns.length
        if let fastIdx {
            serialFastIndex = fastIdx
            serialFastStart = fastStart
        } else {
            let caretPara = ns.paragraphRange(for: NSRange(location: selLoc, length: 0))
            if let rank = index.paragraphRank(forParagraphAt: caretPara.location), rank < serialLines.count {
                serialFastIndex = rank
                serialFastStart = caretPara.location
            } else {
                serialFastIndex = nil
            }
        }
    }

    // MARK: 긴 문단 나누기 (docs/editor-paragraph-split.md)

    /// `trigger`를 넘는 산문(`.p`) 문단의 개수·최대 크기. UI 설명문의 실제 수치.
    /// O(문서)지만 키 입력 경로가 아니다 — 사용자가 표시를 누를 때만 계산한다.
    /// 산문만 대상 — 헤딩·코드·수식·목록·인용은 이 크기가 되지 않고, 나누면
    /// 의미가 깨진다(코드 펜스 등).
    func oversizedProseParagraphs() -> (count: Int, maxLength: Int) {
        let ns = string as NSString
        var count = 0
        var maxLength = 0
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if para.length > ParagraphSplitter.trigger,
                storageBlockInfo(in: para).block == .p
            {
                count += 1
                maxLength = max(maxLength, para.length)
            }
            location = para.upperBound
        }
        return (count, maxLength)
    }

    /// 산문 문단 중 가장 흔한 크기(중앙값 근사) — "보통 문단의 N배" 설명용.
    /// 대략치면 충분하므로 앞쪽 산문 문단들만 표본한다.
    func typicalProseParagraphLength() -> Int {
        let ns = string as NSString
        var lengths: [Int] = []
        var location = 0
        while location < ns.length, lengths.count < 200 {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let len = para.length
            if len > 20, len <= ParagraphSplitter.trigger,
                storageBlockInfo(in: para).block == .p
            {
                lengths.append(len)
            }
            location = para.upperBound
        }
        guard !lengths.isEmpty else { return 0 }
        lengths.sort()
        return lengths[lengths.count / 2]
    }

    /// 긴 산문 문단을 문장 경계에서 `\n\n`으로 나눈다 — **단일 undo 그룹**.
    ///
    /// 글자는 하나도 바꾸지 않고 문단 구분 개행만 삽입한다(ParagraphSplitter가
    /// 오프셋을 계산, 검증은 텍스트 보존 테스트). 뒤 문단부터 처리해 앞 오프셋이
    /// 밀리지 않게 한다. `\n\n` 삽입은 `insertText`로 — 네이티브 undo에 잡히고
    /// typingAttributes(주변 산문 속성)를 물려받아 새 문단도 `.p`가 된다.
    /// 나눈 문단 수를 돌려준다(0이면 대상 없음).
    @discardableResult
    func splitOversizedProseParagraphs() -> Int {
        let ns = string as NSString
        // 대상 문단을 먼저 모은다(문서 순서) — 편집 중 순회하면 오프셋이 흔들린다.
        var targets: [NSRange] = []
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if para.length > ParagraphSplitter.trigger,
                storageBlockInfo(in: para).block == .p
            {
                targets.append(para)
            }
            location = para.upperBound
        }
        guard !targets.isEmpty else { return 0 }

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("긴 문단 나누기")
        var splitCount = 0
        // 뒤 문단부터 → 앞 문단의 절대 오프셋이 보존된다.
        for para in targets.reversed() {
            // 문단 평문(끝 개행 제외)에서 나눌 위치를 구한다.
            let content = paragraphContent(para)
            let offsets = ParagraphSplitter.breakOffsetsUTF16(in: content)
            guard !offsets.isEmpty else { continue }
            splitCount += 1
            // 한 문단 안에서도 뒤 오프셋부터 삽입해 앞 오프셋을 지킨다.
            for offset in offsets.reversed() {
                let at = para.location + offset
                if shouldChangeText(
                    in: NSRange(location: at, length: 0), replacementString: "\n\n")
                {
                    textStorage?.replaceCharacters(
                        in: NSRange(location: at, length: 0), with: "\n\n")
                    didChangeText()
                }
            }
        }
        undoManager?.endUndoGrouping()
        // 구조가 크게 바뀌었으니 직렬화 캐시·렌더를 새로 잡는다.
        invalidateSerialCache()
        refreshRenderedBlocks()
        return splitCount
    }

    /// 편집이 캐시를 어떻게 바꾸는지 판정한다 (델리게이트에서 호출).
    ///
    /// **안전한 빠른 경로**: 문단 경계를 바꾸지 않는 단일 문단 내 편집.
    /// - 개행이 삭제되지 않았다(문단 병합 없음) — `shouldChangeText`가 편집 전에
    ///   삭제될 텍스트의 개행을 세어 알려준다(`serialPendingRemovedNewlines`).
    /// - 개행이 삽입되지 않았다(문단 분할 없음) — 편집된 새 범위를 직접 스캔.
    /// - 편집이 추적 중인 문단 안이다 — 아니면 인덱스가 어긋나므로 전체로 후퇴.
    ///
    /// 위 조건이 하나라도 불확실하면 `serialLinesValid = false`로 전체 재구축을
    /// 예약한다. `shouldChangeText`를 거치지 않는 프로그래matic 편집(마커 변환 등)은
    /// `serialPendingTracked == false`라 자동으로 전체 재구축된다.
    func updateSerialCacheState(
        editedMask: NSTextStorageEditActions, editedRange: NSRange, delta: Int
    ) {
        let tracked = serialPendingTracked
        let removedNewlines = serialPendingRemovedNewlines
        serialPendingTracked = false
        serialPendingRemovedNewlines = 0

        guard serialLinesValid, !editedMask.isEmpty else { return }

        let ns = string as NSString
        let clamped = NSRange(
            location: min(editedRange.location, ns.length),
            length: min(editedRange.length, max(0, ns.length - editedRange.location)))

        // 단일 문단 내 문자 편집이고 기존 범위 더티가 없을 때:
        if serialDirtyRange == nil, editedMask.contains(.editedCharacters), tracked, removedNewlines == 0,
           clamped.length == 0 || ns.rangeOfCharacter(from: .newlines, options: [], range: clamped).location == NSNotFound {
            let para = ns.paragraphRange(
                for: NSRange(location: min(editedRange.location, max(0, ns.length)), length: 0))
            // 문단 내부(경계 1글자 안쪽) 편집은 이웃 문단 프로젝션 캡처에 영향을 주지 않는다.
            let strictlyInsideParagraph = clamped.location > para.location
                && (clamped.upperBound < para.upperBound || para.upperBound == ns.length)
            if para.location == serialFastStart, strictlyInsideParagraph {
                serialFastDirty = true
                return
            }
            if !serialFastDirty, strictlyInsideParagraph, ns.length > 0,
               let index = mediaParagraphIndex, index.utf16Length == ns.length,
               index.paragraphCount == serialLines.count,
               let rank = index.paragraphRank(forParagraphAt: para.location),
               rank < serialLines.count {
                serialFastIndex = rank
                serialFastStart = para.location
                serialFastDirty = true
                return
            }
        }

        // 다중 문단/경계/개행/속성 편집: 더티 범위를 누적해 부분 문단 splice로 처리한다.
        let oldRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta))
        var baseDirty = serialDirtyRange
        if baseDirty == nil, serialFastDirty {
            let fastEnd = min(ns.length, max(serialFastStart, editedRange.location))
            baseDirty = NSRange(location: min(serialFastStart, fastEnd), length: max(0, fastEnd - serialFastStart))
            serialFastDirty = false
        }
        if let previous = baseDirty {
            let rebased = rebaseMediaRange(previous, replacing: oldRange, withLength: clamped.length)
            let start = min(rebased.location, clamped.location)
            let end = max(rebased.upperBound, clamped.upperBound)
            serialDirtyRange = NSRange(location: start, length: max(0, end - start))
        } else {
            serialDirtyRange = clamped
        }
    }

    /// storage 속성만으로 읽는 블록 정보 — 직렬화 전용 (문자 없는 문단은 항상 p).
    func storageBlockInfo(in paragraph: NSRange)
        -> (block: PurloryBlock, checked: Bool, marker: String?, indent: Int, codeLang: String?)
    {
        guard let storage = textStorage, paragraph.location < storage.length else {
            return (.p, false, nil, 0, nil)
        }
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

    /// 문단의 블록 정보. 빈 마지막 문단은 typingAttributes에서 읽는다 (편집 규칙용).
    func blockInfo(in paragraph: NSRange)
        -> (block: PurloryBlock, checked: Bool, marker: String?, indent: Int, codeLang: String?)
    {
        let attrs: [NSAttributedString.Key: Any]
        if let storage = textStorage, paragraph.location < storage.length {
            attrs = storage.attributes(at: paragraph.location, effectiveRange: nil)
        } else {
            attrs = typingAttributes
        }
        let block = (attrs[.purloryBlock] as? String).flatMap(PurloryBlock.init(rawValue:)) ?? .p
        return (
            block,
            attrs[.purloryChecked] as? Bool ?? false,
            attrs[.purloryMarker] as? String,
            attrs[.purloryIndent] as? Int ?? 0,
            attrs[.purloryCodeLang] as? String
        )
    }

    func paragraphContent(_ paragraph: NSRange) -> String {
        let ns = string as NSString
        var text = ns.substring(with: paragraph)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// 문단 내용 직렬화 — 코드·수식·구분선은 원문 그대로, 나머지는 인라인
    /// 서식을 마크다운 마커로 복원한다.
    func serializedContent(of paragraph: NSRange, block: PurloryBlock) -> String {
        let plain = paragraphContent(paragraph)
        guard let storage = textStorage,
            ![PurloryBlock.code, .math, .divider, .image].contains(block)
        else {
            writingProjectionCapture.recordRawBody()
            return plain
        }
        let contentRange = NSRange(
            location: paragraph.location, length: (plain as NSString).length)
        return InlineMarkdown.serialize(storage, in: contentRange,
            capture: writingProjectionCapture.capturesCurrentLine ? { [writingProjectionCapture] span in
                writingProjectionCapture.recordSpan(span)
            } : nil)
    }

    /// 문단의 저장된 정렬 값 ("center"/"right") — 직렬화용.
    func alignValue(at paragraph: NSRange) -> String? {
        guard let storage = textStorage, paragraph.location < storage.length else { return nil }
        return storage.attribute(.purloryAlign, at: paragraph.location, effectiveRange: nil)
            as? String
    }
}
