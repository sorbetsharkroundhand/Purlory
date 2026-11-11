import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

// Image/math editing, assets and visible media rendering.
extension BlockTextView {

    func resolvedImage(for reference: String, maxPixelWidth: CGFloat? = nil) -> NSImage? {
        guard usesProjectAssets else {
            if let maxPixelWidth { return PurloryImageStore.displayImage(for: reference, maxPixelWidth: maxPixelWidth) }
            return PurloryImageStore.image(for: reference)
        }
        guard let bytes = projectAssetCatalog?.data(for: reference) else { return nil }
        let key = "\(reference)|\(maxPixelWidth ?? 0)"
        if let image = projectImageCache.find(key) { return image }
        let image = maxPixelWidth.map { PurloryImageStore.displayImage(data: bytes, maxPixelWidth: $0) }
            ?? NSImage(data: bytes)
        guard let image else { return nil }
        projectImageCache.insert(key: key, image: image,
            bytes: max(1, Int(image.size.width * image.size.height * 4)))
        return image
    }

    func imageFailure(for reference: String) -> ImageLoadFailure? {
        guard usesProjectAssets else { return ImageFailure.classify(reference) }
        switch ImageReferenceParser.classify(reference) {
        case .remote, .blocked: return nil
        case .managedRelative, .externalFile: break
        }
        let ext = (reference as NSString).pathExtension.lowercased()
        if !ext.isEmpty, !PurloryImageStore.imageExtensions.contains(ext) { return .unsupported }
        guard projectAssetCatalog?.data(for: reference) != nil else { return .missing }
        guard let image = resolvedImage(for: reference), image.size.width > 0 else { return .corrupt }
        return nil
    }

    func insertProjectImage(data: Data, reference: String, object: PurloryImageObject? = nil) async throws {
        try await insertProjectImage(data: data, reference: reference, object: object,
            context: captureProjectImageOperation())
    }

    /// Capture before enqueuing: SwiftUI may reuse this view before the task starts.
    func captureProjectImageOperation() throws -> ProjectImageOperation {
        guard usesProjectAssets, let importer = projectAssetImporter,
            let projectID = projectAssetCatalog?.projectID, !hasMarkedText()
        else { throw ProjectSessionError.staleRuntime }
        return ProjectImageOperation(importer: importer, body: string,
            selection: selectedRange(), projectID: projectID)
    }

    func insertProjectImage(
        data: Data, reference: String, object: PurloryImageObject?, context: ProjectImageOperation
    ) async throws {
        try await importProjectAsset(data: data, reference: reference, context: context) { view in
            if var object {
                object.src = reference
                view.insertImageParagraph(markdown: object.markdown)
            } else {
                view.insertImageBlock(relativePath: reference)
            }
        }
    }

    /// Keep a multi-file drop in one runtime generation until every asset is durable.
    func insertProjectImages(_ images: [(data: Data, reference: String)]) async throws {
        try await insertProjectImages(images, context: captureProjectImageOperation())
    }

    func insertProjectImages(
        _ images: [(data: Data, reference: String)], context: ProjectImageOperation
    ) async throws {
        for image in images {
            try await importProjectAsset(data: image.data, reference: image.reference, context: context) { _ in }
        }
        for image in images { insertImageBlock(relativePath: image.reference) }
    }

    func importProjectAsset(
        data: Data, reference: String, context: ProjectImageOperation, apply: (BlockTextView) -> Void
    ) async throws {
        try Task.checkCancellation()
        let catalog = try await context.importer(data, reference)
        guard !Task.isCancelled, !hasMarkedText(), string == context.body, selectedRange() == context.selection,
            projectAssetCatalog?.projectID == context.projectID, catalog.projectID == context.projectID
        else { throw ProjectSessionError.staleRuntime }
        projectAssetCatalog = catalog
        apply(self)
    }

    func saveAndInsertImage(_ data: Data, ext: String, object: PurloryImageObject? = nil) {
        guard usesProjectAssets else {
            guard let relative = PurloryImageStore.save(data, ext: ext) else {
                alertAssetWriteFailure("이미지 파일을 저장하지 못했어요.")
                return
            }
            insertImageBlock(relativePath: relative)
            return
        }
        let suffix = PurloryImageStore.imageExtensions.contains(ext.lowercased()) ? ext.lowercased() : "png"
        let reference = "images/\(UUID().uuidString).\(suffix)"
        guard let context = try? captureProjectImageOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await insertProjectImage(data: data, reference: reference, object: object, context: context) }
            catch ProjectSessionError.staleRuntime {} catch is CancellationError {}
            catch { alertAssetWriteFailure(error.localizedDescription) }
        }
    }

    /// 스크롤이 멈춘 뒤 120ms에 1번만 가시 범위 재수집.
    func scheduleVisibleRefresh() {
        visibleRefreshTask?.cancel()
        visibleRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.refreshVisibleBlocks()
        }
    }

    // MARK: 이미지 원자 모델 (이슈 #16)

    /// 캐럿 제안이 이미지 문단 **내부**로 들어오면 문단 앞·뒤 경계로 튕겨 낸다 —
    /// 렌더된 이미지는 원자 객체라 숨은 소스를 문자 단위로 돌아다닐 수 없다.
    /// 화살표 한 번이면 이미지 앞/뒤로 건너뛴다. 범위 선택(Shift 확장)은 그대로 둔다.
    static func atomicCaretRange(
        _ proposedLocation: Int, result: NSRange, in ns: NSString,
        isImage: (NSRange) -> Bool
    ) -> NSRange {
        guard result.length == 0 else { return result }
        let loc = min(max(result.location, 0), ns.length)
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        // 문단 시작·끝 경계는 "이미지 앞/뒤" 자리라 유효하다.
        guard isImage(para), para.location < loc, loc < para.upperBound else { return result }
        return proposedLocation <= para.location
            ? NSRange(location: para.location, length: 0)
            : NSRange(location: para.upperBound, length: 0)
    }

    override func selectionRange(
        forProposedRange proposedRange: NSRange, granularity: NSSelectionGranularity
    ) -> NSRange {
        let base = super.selectionRange(
            forProposedRange: proposedRange, granularity: granularity)
        let ns = string as NSString
        return Self.atomicCaretRange(proposedRange.location, result: base, in: ns) { para in
            self.blockInfo(in: para).block == .image
        }
    }

    /// VoiceOver가 이미지 문단 대신 읽을 문장 — alt 기반 label에 너비·정렬
    /// value를 덧붙인다. alt가 비었으면 파일명으로 대체한다.
    static func spokenDescription(
        attrs: ImageAttrs, failure: ImageLoadFailure?
    ) -> String {
        var parts: [String] = ["이미지"]
        if failure != nil { parts.append("표시 불가") }
        parts.append(attrs.alt.isEmpty ? (attrs.src as NSString).lastPathComponent : attrs.alt)
        parts.append("너비 \(attrs.width)%")
        let alignName =
            ["left": "왼쪽", "center": "가운데", "right": "오른쪽"][attrs.align]
            ?? attrs.align
        parts.append("\(alignName) 정렬")
        return parts.joined(separator: ", ")
    }

    /// 접근성 읽기에서 이미지 소스(`![…](…){…}`)를 말 문장으로 바꾼다 — VO 사용자는
    /// 마크다운 구문 대신 이미지의 의미를 듣는다.
    override func accessibilityString(for range: NSRange) -> String {
        let ns = string as NSString
        guard ns.length > 0 else {
            return super.accessibilityString(for: range) ?? ""
        }
        let upper = min(range.location + range.length, ns.length)
        guard range.location < upper else { return "" }

        var out = ""
        var cursor = range.location
        while cursor < upper {
            let para = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            if blockInfo(in: para).block == .image,
                let attrs = Self.imageAttrs(
                    from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
                    definitions: currentImageDefinitions()),
                !isTransforming
            {
                out += Self.spokenDescription(
                    attrs: attrs, failure: imageFailure(for: attrs.src))
            } else {
                // 산문 — 인라인 수식 원자(U+FFFC+attachment)를 "수식: …"로 치환해
                // 읽고, 나머지 글자는 그대로 흘려보낸다 (이슈 #22).
                let end = min(para.upperBound, upper)
                var runCursor = cursor
                while runCursor < end {
                    if let atom = textStorage?.attribute(
                            .attachment, at: runCursor, effectiveRange: nil)
                        as? MathAtomAttachment
                    {
                        out += "수식: \(atom.latex)"
                        runCursor += 1
                    } else {
                        out += ns.substring(with: NSRange(location: runCursor, length: 1))
                        runCursor += 1
                    }
                }
            }
            cursor = para.upperBound
        }
        return out
    }

    /// 객체 선택 중 키 → 동작 해석. 순수 함수 — 키보드 이벤트 합성 없이
    /// 회귀 테스트가 가능하다.
    static func objectKeyAction(
        _ raw: String, command: Bool, option: Bool
    ) -> ImageObjectKeyAction? {
        // 특수키는 charactersIgnoringModifiers의 사유 코드로 온다 (F700~F703).
        switch (raw, command, option) {
        case ("\u{F702}", false, false), ("\u{F700}", false, false):
            return .exitBefore
        case ("\u{F703}", false, false), ("\u{F704}", false, false):
            return .exitAfter
        case ("\u{F702}", true, _):
            return .align("left")
        case ("\u{F700}", true, _):
            return .align("center")
        case ("\u{F703}", true, _):
            return .align("right")
        case ("+", false, _), ("=", false, _):
            return .adjustWidth(10)
        case ("-", false, _), ("_", false, _):
            return .adjustWidth(-10)
        case ("\u{F700}", false, true):
            return .move(-1)
        case ("\u{F704}", false, true):
            return .move(1)
        case ("\r", false, false), (" ", false, false):
            return .revealToolbar
        default:
            return nil
        }
    }

    /// 객체 선택 중 키 조작 — Full Keyboard Access로 정렬·크기·이동·삭제·툴바를
    /// 다루는 경로 (이슈 #16). 이 모드에선 텍스트 입력이 차단돼 있으므로
    /// 화살표·부호키를 객체 조작에 쓸 수 있다. 소비한 키만 true.
    @discardableResult
    func handleObjectKey(_ event: NSEvent) -> Bool {
        guard let loc = selectedImageLocation else { return false }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        guard let action = Self.objectKeyAction(
            event.charactersIgnoringModifiers ?? "",
            command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option))
        else { return false }

        switch action {
        case .exitBefore:
            clearImageSelection()
            setSelectedRange(NSRange(location: para.location, length: 0))
        case .exitAfter:
            clearImageSelection()
            setSelectedRange(NSRange(location: para.upperBound, length: 0))
        case .align(let a):
            rewriteImage(para, setAlign: a)
        case .adjustWidth(let delta):
            rewriteImage(para, setWidth: min(100, max(10, widthOfSelectedImage() + delta)))
        case .move(let offset):
            moveImageParagraph(para, offset: offset)
            // 새 자리에서 선택 UI를 다시 얹는다 — ⌥↑↓ 연속 입력이 이어지도록.
            if let newLoc = selectedImageLocation {
                showImageBox(for: newLoc)
                presentImageToolbar(for: NSRange(location: newLoc, length: 0))
            }
        case .revealToolbar:
            showImageBox(for: para.location)
            presentImageToolbar(for: para)
        }
        return true
    }

    /// Native Paste and pasteboard reads share the managed image path. Plain text
    /// still uses NSTextView's normal insertion and undo behavior.
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        if insertImages(from: pasteboard) { return true }
        // 텍스트가 선택된 상태에서 URL을 붙여넣으면 `[선택 텍스트](URL)` 링크로 자동 감싼다.
        if !isSourceMode, selectedRange().length > 0,
           let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           (raw.hasPrefix("https://") || raw.hasPrefix("http://") || raw.hasPrefix("mailto:")),
           !raw.contains(where: \.isWhitespace) {
            let sel = selectedRange()
            let ns = string as NSString
            let para = ns.paragraphRange(for: sel)
            if ![PurloryBlock.code, .math, .divider, .image].contains(blockInfo(in: para).block),
               sel.upperBound <= para.upperBound - (ns.substring(with: para).hasSuffix("\n") ? 1 : 0) {
                let selectedText = ns.substring(with: sel)
                let replacement = "[\(selectedText)](\(raw))"
                insertText(replacement, replacementRange: sel)
                decorateInlineLinks(in: (string as NSString).paragraphRange(for: NSRange(location: sel.location, length: 0)))
                return true
            }
        }
        return super.readSelection(from: pasteboard)
    }

    /// 툴바 버튼용 — 리스폰더 체인(NSApp.sendAction)으로 도달한다.
    @objc func insertImageFromMenu(_ sender: Any?) {
        presentImagePicker()
    }

    /// ⇧⌘I — 파일 선택 패널로 이미지를 고른다.
    func presentImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PurloryImageStore.imageExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return }
        insertImageFiles(panel.urls)
    }

    /// 파일 URL 하나를 읽어 images 폴더에 복사한 뒤 이미지 블록으로 삽입한다.
    /// 저장 실패는 조용히 무시하지 않는다 (이슈 #15).
    func insertImageFiles(_ urls: [URL]) {
        var images: [(data: Data, reference: String)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                alertAssetWriteFailure("파일을 읽지 못했어요: \(url.lastPathComponent)")
                return
            }
            if usesProjectAssets {
                images.append((data, "images/\(UUID().uuidString).\(url.pathExtension.lowercased())"))
            } else {
                saveAndInsertImage(data, ext: url.pathExtension)
            }
        }
        guard !images.isEmpty else { return }
        guard let context = try? captureProjectImageOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await insertProjectImages(images, context: context) }
            catch ProjectSessionError.staleRuntime {} catch is CancellationError {}
            catch { alertAssetWriteFailure(error.localizedDescription) }
        }
    }

    /// 페이스트보드에서 이미지(파일 URL 또는 비트맵)를 찾아 삽입한다. 하나라도 넣었으면 true.
    @discardableResult
    /// 페이스트보드에서 이미지를 찾아 삽입한다. 하나라도 넣었으면 true.
    /// internal — 객체 붙여넣기 우선순위의 회귀 테스트용 (이슈 #17).
    func insertImages(from pasteboard: NSPasteboard) -> Bool {
        // 0) Purlory 이미지 객체 — 메타데이터 전체를 보존하는 내부 붙여넣기 (#17).
        // 파일 URL 분기보다 먼저 본다: 자체 복사물엔 항상 객체가 함께 담겨 있고,
        // 같은 asset을 새 UUID로 복사하지 않는 것이 수명 정책상 정답이다.
        if pasteImageObject(from: pasteboard) { return true }
        // 1) 이미지 파일 URL — 원본 확장자를 유지해 복사한다.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter {
                PurloryImageStore.imageExtensions.contains($0.pathExtension.lowercased())
            }
            if !images.isEmpty {
                insertImageFiles(images)
                return true
            }
        }
        // 2) 비트맵 데이터(스크린샷·복사한 이미지) — PNG로 정규화해 저장한다.
        // 저장 실패도 조용히 넘기지 않는다 (이슈 #15).
        if let data = pasteboard.data(forType: .png) {
            saveAndInsertImage(data, ext: "png")
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff),
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) {
            saveAndInsertImage(png, ext: "png")
            return true
        }
        return false
    }

    /// 페이스트보드에 삽입 가능한 이미지가 있는지 (드래그 수락 판정용).
    func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: .purloryImageObject) != nil { return true }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            urls.contains(where: {
                PurloryImageStore.imageExtensions.contains($0.pathExtension.lowercased())
            }) {
            return true
        }
        return pasteboard.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
        ])
    }

    /// `![](상대경로)` 이미지 블록을 커서 위치에 새 문단으로 삽입한다 —
    /// 앞이 비어 있지 않으면 줄을 나누고, 뒤에는 일반 문단을 만들어 커서를 옮긴다
    /// (`consumeDivider`와 같은 흐름).
    func insertImageBlock(relativePath: String) {
        insertImageParagraph(markdown: "![](\(relativePath))")
    }

    /// 완성된 마크다운 한 줄을 이미지 문단으로 삽입하는 공용 코어 — 상대경로
    /// 삽입과 객체 붙여넣기(#17)가 공유한다. undo 이름을 "이미지 삽입"으로 남긴다.
    func insertImageParagraph(markdown: String) {
        // 스마트 따옴표·대시 치환은 마크다운 구문("title", --)을 망가뜨린다 —
        // 프로그램 삽입은 원문 그대로 들어가야 한다.
        let previousQuotes = isAutomaticQuoteSubstitutionEnabled
        let previousDashes = isAutomaticDashSubstitutionEnabled
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        defer {
            isAutomaticQuoteSubstitutionEnabled = previousQuotes
            isAutomaticDashSubstitutionEnabled = previousDashes
        }
        let ns = string as NSString
        let sel = selectedRange()
        let para = ns.paragraphRange(for: sel)
        let onEmptyLine = paragraphContent(para).isEmpty
        let prefix = onEmptyLine && sel.location == para.location ? "" : "\n"
        insertText(prefix + markdown + "\n", replacementRange: sel)
        nameCurrentUndo("이미지 삽입")

        // 방금 삽입한 이미지 문단(커서 바로 앞 줄)을 찾아 블록을 지정한다.
        let caret = selectedRange().location
        let imagePara = (string as NSString).paragraphRange(
            for: NSRange(location: max(0, caret - 1), length: 0))
        applyBlock(.image, to: imagePara)
        // 커서가 놓인 새 문단은 일반 문단으로.
        let caretPara = (string as NSString).paragraphRange(
            for: NSRange(location: selectedRange().location, length: 0))
        applyBlock(.p, to: caretPara)
        // 커서는 이미지 다음 문단에 있으므로 이미지가 곧바로 렌더된다.
        refreshRenderedBlocks()
    }

    /// 열려 있는 undo 그룹의 이름을 붙인다 — 편집 이력이 "무엇"이었는지 읽게
    /// 한다 (이슈 #17, 이름 있는 원자적 undo).
    func nameCurrentUndo(_ name: String) {
        undoManager?.setActionName(name)
    }

    // MARK: 이미지 객체 선택 (정렬·크기·줄바꿈)

    /// 렌더된 이미지를 객체로 선택한다 — 소스를 감춘 채 박스 오버레이와 툴바를 띄운다.
    func selectImageObject(at para: NSRange) {
        selectedImageLocation = para.location
        // 커서를 문단 시작에 두되(길이 0) 렌더는 유지된다(refresh의 objectSelected 예외).
        setSelectedRange(NSRange(location: para.location, length: 0))
        window?.makeFirstResponder(self)
        refreshRenderedBlocks()
        showImageBox(for: para.location)  // 박스를 먼저 얹고
        presentImageToolbar(for: para)  // 툴바를 그 위에 올린다
    }

    /// 이미지 박스 오버레이를 만들고(또는 갱신) 이미지 위에 얹는다.
    func showImageBox(for loc: Int) {
        let box: ImageBoxOverlay
        if let existing = imageBox {
            box = existing
            box.theme = palette  // 재사용 시에도 최신 팔레트 — stale 색 방지 (#34)
        } else {
            box = ImageBoxOverlay(textView: self, theme: palette)
            imageBox = box
        }
        box.paraLocation = loc
        if box.superview !== self { addSubview(box) }
        repositionImageBox()
    }

    /// 객체 선택 해제 — 툴바·박스·편집 카드를 감추고 다시 그린다.
    func clearImageSelection() {
        guard selectedImageLocation != nil else { return }
        selectedImageLocation = nil
        hideImageToolbar()
        hideImageAltEditor()
        imageBox?.removeFromSuperview()
        imageBox = nil
        imageDropIndicatorY = nil
        needsDisplay = true
    }

    /// 선택 변화에 맞춰 이미지 상태를 정리한다 (요구 1):
    /// - 객체 선택 이미지를 벗어나면 선택 해제
    /// - 커서가 이미지 안으로 들어오면 자동으로 객체 선택해, 내부를 커서로
    ///   편집하지 못하게 만든다 (이미지는 항상 렌더 — 소스는 절대 노출 안 됨).
    func syncImageSelection() {
        let ns = string as NSString
        let sel = selectedRange()
        let caretPara = ns.paragraphRange(
            for: NSRange(location: min(sel.location, ns.length), length: 0))

        if let loc = selectedImageLocation, sel.length != 0 || caretPara.location != loc {
            clearImageSelection()
        }
        // 이미지 문단에 커서가 놓였는데 객체 선택이 아니면 자동 선택.
        // (로드·프로그램적 변경 중인 isTransforming 때는 건너뛴다.)
        // 로드 실패 플레이스홀더도 선택 대상이다 — 찾기·Finder·제거 액션을
        // 제공하려면 (이슈 #15).
        guard sel.length == 0, !isTransforming, window?.firstResponder === self,
            caretPara.location < ns.length,
            selectedImageLocation != caretPara.location,
            blockInfo(in: caretPara).block == .image,
            let caretAttrs = Self.imageAttrs(
                from: paragraphContent(caretPara).trimmingCharacters(in: .whitespaces),
                definitions: currentImageDefinitions()),
            resolvedImage(for: caretAttrs.src) != nil
                || imageFailure(for: caretAttrs.src) != nil
        else { return }
        // 커서는 그대로 두고(어차피 숨김) 객체 선택만 채택 — setSelectedRange
        // 재귀를 피한다. refresh가 뒤이어 렌더를 유지한다.
        // 화살표로 스쳐 지날 때 툴바/박스를 띄우지 않는다 — 편집 조작은 클릭했을 때만
        // 시작하게 해, 이동 중 UI가 불쑥 튀어나오지 않게 한다 (M10). 클릭 경로
        // (selectImageObject)는 그대로 박스·툴바를 보여준다.
        selectedImageLocation = caretPara.location
        refreshRenderedBlocks()
        needsDisplay = true
    }

    /// 이미지가 객체로 선택된 동안엔 텍스트 입력을 막는다 — 내부는 편집 불가 (요구 1).
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard selectedImageLocation == nil else { return }
        // 텍스트가 드래그 선택된 상태에서 괄호·따옴표·서식 마커를 입력하면 선택 영역을 감싼다.
        let effectiveRange = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        if !isSourceMode, !hasMarkedText(), effectiveRange.length > 0,
           let typed = insertString as? String, typed.count == 1,
           wrapSelectionIfNeeded(with: typed, range: effectiveRange) {
            return
        }
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        super.insertText(insertString, replacementRange: replacementRange)
        let committed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        // Keep each word and its trailing whitespace together. Only committed text
        // ends a typing unit, so Hangul marked-text updates remain AppKit-owned.
        if !hasMarkedText(), committed?.last?.isWhitespace == true {
            breakUndoCoalescing()
        }
    }

    /// 선택 영역이 있을 때 마커(`~`, `=`, `` ` ``) 또는 괄호·따옴표(`(`, `[`, `"`, `“`)로 감싼다.
    func wrapSelectionIfNeeded(with typed: String, range: NSRange) -> Bool {
        let ns = string as NSString
        guard range.upperBound <= ns.length else { return false }
        let selected = ns.substring(with: range)
        guard !selected.contains("\n") else { return false }
        let para = ns.paragraphRange(for: range)
        guard ![PurloryBlock.code, .math, .divider, .image].contains(blockInfo(in: para).block) else {
            return false
        }
        switch typed {
        case "*", "_":
            setSelectedRange(range)
            toggleInlineStyle(.purloryItalic)
            return true
        case "~":
            setSelectedRange(range)
            toggleInlineStyle(.purloryStrikethrough)
            return true
        case "=":
            setSelectedRange(range)
            toggleInlineStyle(.purloryHighlight)
            return true
        case "`":
            setSelectedRange(range)
            toggleInlineStyle(.purloryCode)
            return true
        default:
            break
        }
        let pairs: [String: (String, String)] = [
            "(": ("(", ")"),
            "[": ("[", "]"),
            "\"": ("\"", "\""),
            "“": ("“", "”"),
        ]
        guard let (open, close) = pairs[typed], let storage = textStorage else { return false }
        let wrapped = open + selected + close
        guard shouldChangeText(in: range, replacementString: wrapped) else { return false }
        nativeTextUpdateDepth += 1
        defer { finishNativeTextUpdate() }
        let preserved = inlineSnapshot(in: range)
        let baseAttrs = storage.attributes(at: range.location, effectiveRange: nil)
        isTransforming = true
        storage.replaceCharacters(in: range, with: NSAttributedString(string: wrapped, attributes: baseAttrs))
        for (subRange, inlineAttrs) in preserved {
            let shifted = NSRange(location: subRange.location + open.utf16.count, length: subRange.length)
            storage.addAttributes(inlineAttrs, range: shifted)
        }
        redecorateParagraphs(in: NSRange(location: range.location, length: (wrapped as NSString).length))
        isTransforming = false
        setSelectedRange(NSRange(location: range.location + open.utf16.count, length: range.length))
        didChangeText()
        breakUndoCoalescing()
        return true
    }

    /// 이미지 객체 선택 중 Esc — 선택만 해제한다 (그림 블럭 완성도).
    override func cancelOperation(_ sender: Any?) {
        if selectedImageLocation != nil {
            clearImageSelection()
            return
        }
        super.cancelOperation(sender)
    }

    /// 이미지 객체 선택 중 ⌘C/⌘X — 이미지 비트맵을 클립보드로 (그림 블럭 완성도).
    /// 붙여넣기는 기존 insertImages의 TIFF 경로로 다시 이미지 블록이 된다.
    override func copy(_ sender: Any?) {
        if let loc = selectedImageLocation, copyImageObject(atParagraph: loc) { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let loc = selectedImageLocation {
            guard copyImageObject(atParagraph: loc) else { return }
            let para = (string as NSString).paragraphRange(
                for: NSRange(location: min(loc, (string as NSString).length), length: 0))
            deleteImageParagraph(para)
            return
        }
        super.cut(sender)
    }

    /// 선택된 이미지 문단을 클립보드에 기록한다 — Purlory 객체(JSON)·Markdown
    /// 소스·파일 URL·호환 비트맵을 함께 담아, 내부 붙여넣기는 메타데이터를
    /// 온전히 되살리고 외부 앱도 각자 알아볼 형태를 얻는다 (이슈 #17).
    @discardableResult
    func copyImageObject(atParagraph loc: Int) -> Bool {
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        guard let attrs = Self.imageAttrs(
                from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
                definitions: currentImageDefinitions()),
            let image = resolvedImage(for: attrs.src)
        else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // 1) Purlory 전용 객체 — 메타데이터 전체.
        let object = PurloryImageObject(attrs: attrs)
        if let payload = object.encoded() {
            pasteboard.setData(payload, forType: .purloryImageObject)
        }
        if usesProjectAssets, let bytes = projectAssetCatalog?.data(for: attrs.src) {
            pasteboard.setData(bytes, forType: Self.projectImageBytesType)
        }
        // 2) Markdown 소스 — 텍스트 편집기로 붙이면 구문째로.
        pasteboard.setString(attrs.markdown, forType: .string)
        // 3) 원본 파일 URL — 파일을 받아들이는 앱용.
        if !usesProjectAssets, let url = PurloryImageStore.url(for: attrs.src) {
            pasteboard.writeObjects([url as NSURL])
        }
        // 4) 호환 비트맵 — 이미지를 받는 모든 앱용 (기존 동작).
        pasteboard.writeObjects([image])
        return true
    }

    /// 클립보드의 Purlory 이미지 객체를 그대로 삽입한다 — src를 새로 만들지 않고
    /// alt/title/width/align까지 보존 (이슈 #17). 넣었으면 true.
    @discardableResult
    func pasteImageObject(from pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: .purloryImageObject),
            let object = PurloryImageObject(data: data)
        else { return false }
        if usesProjectAssets {
            // Project references cannot be reused across owners; import clipboard bytes instead.
            if let bytes = pasteboard.data(forType: Self.projectImageBytesType) {
                saveAndInsertImage(bytes, ext: (object.src as NSString).pathExtension, object: object)
            } else if let png = pasteboard.data(forType: .png) {
                saveAndInsertImage(png, ext: "png", object: object)
            } else if let tiff = pasteboard.data(forType: .tiff),
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
                saveAndInsertImage(png, ext: "png", object: object)
            } else { return false }
            return true
        }
        insertImageParagraph(markdown: object.markdown)
        return true
    }

    /// 렌더된 이미지 위에서는 포인터 커서 — 클릭(객체 선택) 대상임을 알린다.
    /// 렌더된 수식 위에서는 열린 손 — 끌어 옮길 수 있음을 알린다 (요구 6).
    override func resetCursorRects() {
        super.resetCursorRects()
        for render in imageRenders {
            if let rect = imageDrawnRect(forParagraphAt: render.range.location) {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
        for render in mathRenders {
            if let rect = mathDrawnRect(forParagraphAt: render.range.location) {
                addCursorRect(
                    rect.insetBy(dx: -Self.mathBoxMargin, dy: -Self.mathBoxMargin),
                    cursor: .openHand)
            }
        }
    }

    /// 이미지 툴바 액션 실행 (요구 3).
    func performImage(_ action: ImageObjectAction) {
        guard let loc = selectedImageLocation else { return }
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        switch action {
        case .align(let a): rewriteImage(para, setAlign: a)
        case .width(let w): rewriteImage(para, setWidth: w)
        case .editMetadata: presentImageAltEditor(for: para)
        case .locateFile: locateBrokenImage(para)
        case .revealInFinder: revealBrokenImage(para)
        case .metadata(let alt, let title):
            rewriteImage(para, setAlt: alt, setTitle: .some(title))
            hideImageAltEditor()  // 적용 후 카드를 닫는다 — 툴바 갱신은 rewrite가 한다
        case .lineBreak: imageLineBreak(after: para)
        case .delete: deleteImageParagraph(para)
        }
    }

    /// 깨진 이미지(플레이스홀더) 복구 — 새 파일을 골라 원래 참조가 가리키던
    /// 자리를 채운다 (이슈 #15). 관리 asset은 **상대경로 그대로** 심어 문서를
    /// 건드리지 않고, 외부 절대경로는 임의 경로에 쓰는 대신 새 관리 asset으로
    /// 옮겨 참조를 고친다.
    func locateBrokenImage(_ para: NSRange) {
        guard let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
            definitions: currentImageDefinitions())
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes =
            PurloryImageStore.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "'\(attrs.alt.isEmpty ? attrs.src : attrs.alt)' 이미지 파일을 찾아 복구"
        guard panel.runModal() == .OK, let url = panel.urls.first,
            let data = try? Data(contentsOf: url)
        else { return }
        if usesProjectAssets {
            let reference = (try? ProjectPaths.validateRelative(attrs.src)) != nil
                ? attrs.src : "images/\(UUID().uuidString).\(url.pathExtension)"
            guard let context = try? captureProjectImageOperation() else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await importProjectAsset(data: data, reference: reference, context: context) { view in
                        if reference != attrs.src { view.rewriteImage(para, setSrc: reference) }
                        view.refreshRenderedBlocks()
                    }
                } catch ProjectSessionError.staleRuntime {} catch is CancellationError {}
                catch { alertAssetWriteFailure(error.localizedDescription) }
            }
            return
        }
        switch ImageReferenceParser.classify(attrs.src) {
        case .managedRelative:
            guard let destination = PurloryImageStore.url(for: attrs.src) else {
                alertAssetWriteFailure("안전하지 않은 이미지 경로예요.")
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                alertAssetWriteFailure(error.localizedDescription)
                return
            }
            refreshRenderedBlocks()  // 플레이스홀더 → 정상 렌더 즉시 전환
        case .externalFile:
            guard let relative = PurloryImageStore.save(data, ext: url.pathExtension) else {
                alertAssetWriteFailure("images 폴더에 복사하지 못했어요.")
                return
            }
            rewriteImage(para, setSrc: relative)
        case .remote, .blocked:
            break
        }
    }

    /// 깨진 이미지가 참조하던 위치를 Finder에서 연다 — 파일이 없으면 그 부모 폴더.
    func revealBrokenImage(_ para: NSRange) {
        guard !usesProjectAssets else { return }
        guard let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
            definitions: currentImageDefinitions())
        else { return }
        guard let url = PurloryImageStore.url(for: attrs.src) else { return }
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// asset 저장 실패를 조용히 넘기지 않는다 (이슈 #15).
    func alertAssetWriteFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "이미지를 저장하지 못했어요"
        alert.informativeText = "\(detail)\n디스크 여유와 Purlory 폴더 권한을 확인해 주세요."
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// 이미지 소스 줄의 `{width align}`·alt/title 속성을 새 값으로 바꿔 다시 쓴다
    /// (undo 포함). `setTitle`: nil=무변화, .some(nil)=해제, .some(문자열)=지정.
    /// internal — 이름 있는 undo·왕복 보존의 회귀 테스트용 (이슈 #14·#17).
    func rewriteImage(
        _ para: NSRange, setAlign: String? = nil, setWidth: Int? = nil,
        setAlt: String? = nil, setTitle: String?? = nil, setSrc: String? = nil
    ) {
        guard let storage = textStorage else { return }
        let content = paragraphContent(para)
        guard var attrs = Self.imageAttrs(
            from: content.trimmingCharacters(in: .whitespaces),
            definitions: currentImageDefinitions())
        else { return }
        if let a = setAlign { attrs.align = a }
        if let w = setWidth { attrs.width = w }
        if let alt = setAlt { attrs.alt = alt }
        if let newSrc = setSrc {
            attrs.src = newSrc
            // destination을 다시 쓰는 것이므로 원문 스플라이스를 내린다 —
            // 합성 경로의 escape 규칙(#14)으로 새 src가 안전하게 직렬화된다.
            attrs.optionsPrefix = nil
        }
        if let newTitle = setTitle {
            attrs.title = newTitle
            // optionsPrefix 스플라이스 경로는 원문을 그대로 쓰므로, title이
            // 바뀌면 prefix를 내려 새로 합성해야 반영된다.
            attrs.optionsPrefix = nil
        }
        let newLine = attrs.markdown
        // 어떤 속성을 바꿨는지로 이력 이름을 정한다 — 이력 줄이 동작을 말하게.
        let actionName: String
        if setAlign != nil { actionName = "이미지 정렬" }
        else if setWidth != nil { actionName = "이미지 크기 조절" }
        else if setAlt != nil || setTitle != nil { actionName = "대체 텍스트 편집" }
        else if setSrc != nil { actionName = "이미지 경로 변경" }
        else { actionName = "이미지 서식" }
        let contentRange = NSRange(
            location: para.location, length: (content as NSString).length)
        guard newLine != content,
            shouldChangeText(in: contentRange, replacementString: newLine)
        else { return }
        nameCurrentUndo(actionName)
        isTransforming = true
        storage.replaceCharacters(in: contentRange, with: newLine)
        isTransforming = false
        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: para.location, length: 0))
        applyBlock(.image, to: newPara, registerUndo: false)
        selectedImageLocation = newPara.location
        setSelectedRange(NSRange(location: newPara.location, length: 0))
        didChangeText()
        refreshRenderedBlocks()
        presentImageToolbar(for: newPara)
    }

    /// 이미지 뒤에 빈 문단을 만들고 커서를 옮긴다 — "줄바꿈"(요구 3).
    func imageLineBreak(after para: NSRange) {
        clearImageSelection()
        let content = paragraphContent(para)
        let end = para.location + (content as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
        window?.makeFirstResponder(self)
        insertText("\n", replacementRange: selectedRange())
        let caret = selectedRange().location
        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: caret, length: 0))
        applyBlock(.p, to: newPara)
        refreshRenderedBlocks()
    }

    /// 이미지 문단을 개행째 지운다 (요구 3 · 백스페이스 공통).
    /// 이미지 문단을 개행째 지운다 (요구 3 · 백스페이스 공통).
    /// internal — 삭제 undo·asset 장부 등록의 회귀 테스트용 (이슈 #17).
    func deleteImageParagraph(_ para: NSRange) {
        deleteBlockParagraph(para, undoName: "이미지 삭제")
    }

    /// 수식 문단 삭제 — asset 장부 등록이 없을 뿐 구조는 이미지 삭제와 같다 (#22).
    func deleteMathParagraph(_ para: NSRange) {
        deleteBlockParagraph(para, undoName: "수식 삭제")
    }

    func deleteBlockParagraph(_ para: NSRange, undoName: String) {
        guard let storage = textStorage else { return }
        clearImageSelection()
        // 지워지는 asset을 장부에 적어 둔다 — undo/redo가 끝난 뒤 참조가 없으면
        // Janitor가 정리한다. 즉시 지우지 않는 것이 redo의 전제다 (이슈 #17).
        if let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
            definitions: currentImageDefinitions()),
            case .managedRelative = ImageReferenceParser.classify(attrs.src)
        {
            AssetJanitor.record(attrs.src)
        }
        guard shouldChangeText(in: para, replacementString: "") else { return }
        nameCurrentUndo(undoName)
        isTransforming = true
        storage.replaceCharacters(in: para, with: "")
        isTransforming = false
        let ns = string as NSString
        setSelectedRange(NSRange(location: min(para.location, ns.length), length: 0))
        didChangeText()
        refreshRenderedBlocks()
    }

    /// 선택된 이미지 위에 정렬·크기·줄바꿈 툴바를 띄운다.
    /// `overrideWidth`는 드래그 리사이즈 중 실시간 % 표시용.
    func presentImageToolbar(for para: NSRange, overrideWidth: Int? = nil) {
        guard imageRenders.contains(where: { $0.range.location == para.location }),
            let attrs = Self.imageAttrs(
                from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
                definitions: currentImageDefinitions()),
            let rect = paragraphRectInView(para)
        else { return }

        let view = ImageObjectToolbarView(
            theme: palette, width: overrideWidth ?? attrs.width, align: attrs.align,
            // 로드 실패 플레이스홀더면 찾기·Finder 복구 액션을 노출한다 (이슈 #15).
            isPlaceholder: imageFailure(for: attrs.src) != nil
        ) { [weak self] action in
            self?.performImage(action)
        }
        let host: NSHostingView<ImageObjectToolbarView>
        if let existing = imageToolbarHost {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            imageToolbarHost = host
        }
        let size = host.fittingSize
        // 이미지 위 중앙 — 위가 좁으면 아래로 내린다 (flipped 좌표).
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = rect.maxY + 8 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        host.frame = NSRect(origin: origin, size: size)
        if host.superview !== self { addSubview(host) }
    }

    func hideImageToolbar() {
        imageToolbarHost?.removeFromSuperview()
    }

    /// alt·title 편집 카드를 툴바 아래에 띄운다 — 현재 alt/title로 미리 채운다 (이슈 #14).
    func presentImageAltEditor(for para: NSRange) {
        guard let attrs = Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
            definitions: currentImageDefinitions()),
            let toolbarFrame = imageToolbarHost?.frame
        else { return }
        let view = ImageAltEditorView(
            theme: palette, initialAlt: attrs.alt, initialTitle: attrs.title,
            onApply: { [weak self] alt, title in
                self?.performImage(.metadata(alt: alt, title: title))
            },
            onCancel: { [weak self] in self?.hideImageAltEditor() })
        let host = NSHostingView(rootView: view)
        // 툴바 바로 아래 — 화면 위쪽에 붙으면 이미지 아래로 내린다.
        var origin = NSPoint(
            x: toolbarFrame.minX + 4, y: toolbarFrame.maxY + 6)
        if origin.y + host.fittingSize.height > bounds.height {
            origin = NSPoint(x: toolbarFrame.minX + 4, y: toolbarFrame.minY - host.fittingSize.height - 6)
        }
        origin.x = max(8, min(origin.x, bounds.width - host.fittingSize.width - 8))
        host.frame = NSRect(origin: origin, size: host.fittingSize)
        imageAltEditorHost?.removeFromSuperview()
        imageAltEditorHost = host
        addSubview(host)
    }

    func hideImageAltEditor() {
        imageAltEditorHost?.removeFromSuperview()
        imageAltEditorHost = nil
    }

    /// 문단이 차지하는 **전체 컬럼 폭** rect (뷰 좌표) — 레이아웃 매니저의
    /// `paragraphRect`(이미지를 그리는 기준)와 정확히 같은 규칙으로 만든다.
    /// 이게 어긋나 있어서 핸들 히트 존이 이미지와 따로 놀았다(리사이즈 불가 버그).
    func paragraphRectInView(_ para: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y
        // x·폭을 컬럼 전체로 맞춘다 (drawImage의 rect와 동일).
        rect.origin.x = textContainerOrigin.x + textContainer.lineFragmentPadding
        rect.size.width = textContainer.size.width - textContainer.lineFragmentPadding * 2
        return rect
    }

    // MARK: 이미지 크기 조절 (모서리 핸들 드래그, 요구 2)

    /// 렌더된 이미지가 실제로 그려지는 뷰 좌표 rect — `drawImage`와 같은 규칙.
    /// 핸들 히트 테스트·그리기의 기준.
    func imageDrawnRect(forParagraphAt loc: Int) -> NSRect? {
        guard let render = imageRenders.first(where: { $0.range.location == loc }),
            let row = paragraphRectInView(
                (string as NSString).paragraphRange(
                    for: NSRange(location: min(loc, (string as NSString).length), length: 0)))
        else { return nil }
        let box = row.insetBy(dx: 8, dy: 6)
        guard render.size.width > 0, render.size.height > 0 else { return nil }
        let scale = min(box.width / render.size.width, box.height / render.size.height, 1)
        let size = NSSize(width: render.size.width * scale, height: render.size.height * scale)
        let x: CGFloat
        switch render.align {
        case "left": x = box.minX
        case "right": x = box.maxX - size.width
        default: x = row.midX - size.width / 2
        }
        return NSRect(
            x: x, y: row.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 100% 표시 너비 — 드래그 델타를 %로 환산할 때의 기준.
    func imageFitWidth(forParagraphAt loc: Int) -> CGFloat? {
        guard let render = imageRenders.first(where: { $0.range.location == loc })
        else { return nil }
        return imageDisplaySize(render.image, widthPercent: 100).width
    }

    /// 이미지 소스에서 현재 너비(%)를 읽는다.
    func imageWidthPercent(at loc: Int) -> Int {
        let para = (string as NSString).paragraphRange(
            for: NSRange(location: min(loc, (string as NSString).length), length: 0))
        return Self.imageAttrs(
            from: paragraphContent(para).trimmingCharacters(in: .whitespaces),
            definitions: currentImageDefinitions())?.width ?? 100
    }

    // MARK: - 이미지 박스 오버레이 연동 (요구 A·B)

    /// 오버레이(있으면)를 이미지 위치에 맞춰 다시 배치한다.
    func repositionImageBox() {
        guard let box = imageBox, let loc = selectedImageLocation,
            let rect = imageDrawnRect(forParagraphAt: loc)
        else { return }
        box.frame = rect.insetBy(dx: -box.inset, dy: -box.inset)
        box.needsDisplay = true
    }

    /// 크기 조절 미리보기 — 시작 너비%에 드래그 델타(pt)를 더해 %로 환산해 반영한다.
    func previewImageResize(at loc: Int, startWidth: Int, deltaWidth: CGFloat) {
        guard let fitW = imageFitWidth(forParagraphAt: loc), fitW > 0 else { return }
        let startDisplayW = fitW * CGFloat(startWidth) / 100
        let pct = Int(((startDisplayW + deltaWidth) / fitW * 100).rounded())
        let clamped = min(100, max(10, pct))
        resizePreview = (loc, clamped)
        refreshRenderedBlocks()  // 끝에서 repositionImageBox 호출됨
        let para = (string as NSString).paragraphRange(
            for: NSRange(location: min(loc, (string as NSString).length), length: 0))
        presentImageToolbar(for: para, overrideWidth: clamped)
    }

    /// 크기 조절 확정 — 미리보기 너비%를 소스에 기록한다.
    func commitImageResize(at loc: Int) {
        let finalWidth = resizePreview?.width
        resizePreview = nil
        let para = (string as NSString).paragraphRange(
            for: NSRange(location: min(loc, (string as NSString).length), length: 0))
        if let finalWidth, finalWidth != imageWidthPercent(at: loc) {
            rewriteImage(para, setWidth: finalWidth)
        } else {
            refreshRenderedBlocks()
            presentImageToolbar(for: para)
        }
    }

    /// 이동 드래그 중 — 드롭될 문단 위쪽에 표시선을 그린다.
    func updateImageDropIndicator(toViewPoint p: NSPoint) {
        let idx = min(characterIndexForInsertion(at: p), (string as NSString).length)
        let dropPara = (string as NSString).paragraphRange(
            for: NSRange(location: idx, length: 0))
        imageDropIndicatorY = paragraphRectInView(dropPara)?.minY
        needsDisplay = true
    }

    /// 이미지 문단을 드롭 지점의 문단 앞으로 옮긴다 (요구 B).
    func moveImageParagraph(at loc: Int, toViewPoint p: NSPoint) {
        moveParagraph(at: loc, as: .image, toViewPoint: p)
    }

    /// 블록 문단(이미지·수식)을 통째로 드롭 지점의 문단 앞으로 옮긴다 (요구 B·6).
    /// 다중 행 수식 그룹이면 그룹 전체를 옮긴다 (이슈 #20).
    func moveParagraph(at loc: Int, as block: PurloryBlock, toViewPoint p: NSPoint) {
        imageDropIndicatorY = nil
        guard let storage = textStorage else { return }
        let ns = string as NSString
        var para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        // 수식 그룹 소속이면 이동 단위를 그룹 전체로 넓힌다.
        if block == .math, let group = mathGroup(containing: para.location) {
            para = group
        }
        let isMathGroup = block == .math && para.length > 0
            && ns.paragraphRange(for: NSRange(location: para.location, length: 0)).upperBound
                != para.upperBound
        let lineText = ns.substring(with: para).trimmingCharacters(in: CharacterSet(["\n"]))
        let dropIdx = min(characterIndexForInsertion(at: p), ns.length)
        let dropPara = ns.paragraphRange(for: NSRange(location: dropIdx, length: 0))
        guard dropPara.location < para.location || dropPara.location >= para.upperBound else {
            refreshRenderedBlocks(); return
        }
        clearImageSelection()

        // 지울 범위: 블록 문단(개행 포함). 마지막 줄이라 개행이 없으면 앞 개행을 지운다.
        var removeRange = para
        let endsNL =
            para.length > 0
            && ns.substring(
                with: NSRange(location: para.location + para.length - 1, length: 1)) == "\n"
        if !endsNL, para.location > 0 {
            removeRange = NSRange(location: para.location - 1, length: para.length + 1)
        }
        var insertLoc = dropPara.location

        guard shouldChangeText(
            in: NSRange(location: 0, length: ns.length), replacementString: nil)
        else { return }
        nameCurrentUndo("블록 이동")
        isTransforming = true
        storage.replaceCharacters(in: removeRange, with: "")
        // 삭제로 밀린 삽입 위치 보정.
        if insertLoc >= removeRange.location + removeRange.length {
            insertLoc -= removeRange.length
        } else if insertLoc > removeRange.location {
            insertLoc = removeRange.location
        }
        insertLoc = min(max(0, insertLoc), (string as NSString).length)
        storage.replaceCharacters(
            in: NSRange(location: insertLoc, length: 0), with: lineText + "\n")
        isTransforming = false

        let newPara = (string as NSString).paragraphRange(
            for: NSRange(location: insertLoc, length: 0))
        if !isMathGroup {
            // 단일 문단만 속성 재부여 — 그룹은 열기/닫기 구분자 속성이 문단마다
            // 다르므로 텍스트와 함께 이동한 속성을 건드리지 않는다 (이슈 #20).
            applyBlock(block, to: newPara, registerUndo: false)
        }
        if block == .image {
            setSelectedRange(NSRange(location: newPara.location, length: 0))
            didChangeText()
            // 옮긴 이미지를 다시 객체 선택해 박스를 이어서 보여준다.
            selectImageObject(at: newPara)
        } else {
            // 커서는 블록 **다음** 문단에 — 수식은 커서가 들어오면 소스로 풀리므로
            // 옮긴 직후에도 렌더 상태를 유지한다.
            setSelectedRange(NSRange(
                location: min(newPara.upperBound, (string as NSString).length), length: 0))
            didChangeText()
            refreshRenderedBlocks()
        }
    }

    // MARK: 수식 블록 드래그 이동 (요구 6)

    /// 렌더된 수식이 실제 그려지는 뷰 좌표 rect — `drawMath`와 같은 축소 규칙.
    /// 히트 판정·커서 rect의 기준. 다중 행 그룹은 그룹 전체 rect 기준 (이슈 #20).
    func mathDrawnRect(forParagraphAt loc: Int) -> NSRect? {
        guard let render = mathRenders.first(where: { NSLocationInRange(loc, $0.range) }),
            let row = paragraphRectInView(render.range)
        else { return nil }
        var size = render.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let maxWidth = max(40, row.width - 32)
        if size.width > maxWidth {
            let scale = maxWidth / size.width
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        return NSRect(
            x: row.midX - size.width / 2, y: row.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// 수식 클릭/드래그 판별 루프 — 3pt 이상 끌면 이동 모드(드롭 표시선 + 손 커서),
    /// 그 자리에서 떼면 평소처럼 커서를 넣어 소스 편집 모드로 들어간다.
    func trackMathDrag(from event: NSEvent, paragraph para: NSRange) {
        guard let window else { return }
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseDragged {
                if abs(next.locationInWindow.x - event.locationInWindow.x) > 3
                    || abs(next.locationInWindow.y - event.locationInWindow.y) > 3 {
                    moved = true
                }
                if moved {
                    NSCursor.closedHand.set()
                    updateImageDropIndicator(
                        toViewPoint: convert(next.locationInWindow, from: nil))
                }
                continue
            }
            // mouseUp — 이동 확정 또는 편집 진입.
            imageDropIndicatorY = nil
            if moved {
                moveParagraph(
                    at: para.location, as: .math,
                    toViewPoint: convert(next.locationInWindow, from: nil))
                NSCursor.arrow.set()
            } else {
                let p = convert(event.locationInWindow, from: nil)
                let idx = min(characterIndexForInsertion(at: p), (string as NSString).length)
                window.makeFirstResponder(self)
                setSelectedRange(NSRange(location: idx, length: 0))
                refreshRenderedBlocks()
            }
            needsDisplay = true
            return
        }
    }

    // MARK: 드래그 드롭 (이미지 파일)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasImage(sender.draggingPasteboard)
            ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasImage(sender.draggingPasteboard)
            ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pasteboardHasImage(sender.draggingPasteboard)
            ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard pasteboardHasImage(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        // 드롭 지점으로 커서를 옮긴 뒤 그 자리에 삽입한다.
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index != NSNotFound {
            setSelectedRange(NSRange(location: min(index, (string as NSString).length), length: 0))
        }
        return insertImages(from: sender.draggingPasteboard)
    }


    /// 수식 스캔 제외 범위(문단 상대) — 인라인 코드 스팬과 **이미 존재하는
    /// 수식 원자**. 원자를 끼고 `$`가 재결합하면 이중 변환으로 내용이 삼켜진다.
    func inlineCodeSkips(in paragraph: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var skips: [NSRange] = []
        storage.enumerateAttribute(.purloryCode, in: paragraph, options: []) { value, range, _ in
            if value as? Bool == true {
                skips.append(
                    NSRange(
                        location: range.location - paragraph.location, length: range.length))
            }
        }
        storage.enumerateAttribute(.purloryMath, in: paragraph, options: []) { value, range, _ in
            if value as? Bool == true {
                skips.append(
                    NSRange(
                        location: range.location - paragraph.location, length: range.length))
            }
        }
        return skips
    }

    /// 산문 문단의 `$…$` 스팬을 렌더 원자(attachment 한 글자)로 바꾼다.
    /// 변환한 스팬 수를 돌려준다. 코드 블록·수식/이미지/구분선 블록은 처음부터 건너뛴다.
    @discardableResult
    func convertInlineMath(in paragraph: NSRange, registersUndo: Bool = true) -> Int {
        guard let storage = textStorage,
            ![PurloryBlock.code, .math, .divider, .image].contains(blockInfo(in: paragraph).block)
        else { return 0 }
        let content = paragraphContent(paragraph)
        // 인라인 원자는 **inlineText**만 대상이다. 산문 한가운데의 `$$…$$`는
        // 단일-$ 복원으로 되돌릴 때 경계가 흔들려(파싱 비대칭) 원문 텍스트로
        // 남긴다 — 블록 렌더는 문단 단위 그룹이 담당한다 (이슈 #20).
        let regions = MathScanner.regions(
            in: content, skipping: inlineCodeSkips(in: paragraph)
        ).filter { $0.kind == .inlineText }
        guard !regions.isEmpty else { return 0 }

        if registersUndo { isTransforming = true }
        defer { if registersUndo { isTransforming = false } }
        for region in regions.reversed() {
            let span = NSRange(
                location: paragraph.location + region.range.location,
                length: region.range.length)
            // 원자 폰트 크기 — 문단에 저장된 인라인 크기 속성을 존중한다.
            let baseAttrs =
                storage.attributes(at: span.location, effectiveRange: nil)
            let size = (baseAttrs[.purloryFontSize] as? Double).map { CGFloat($0) }
                ?? baseFontSize
            let atom = MathAtomAttachment(latex: region.latex)
            atom.render(fontSize: size, color: palette.ink)

            if registersUndo {
                guard shouldChangeText(in: span, replacementString: "") else { continue }
            }
            // 주의: String(unichar)은 십진수 "65532"를 만든다 — 유니코드 스칼라로.
            storage.replaceCharacters(
                in: span, with: Self.attachmentCharacter)
            var atomAttrs = baseAttrs
            atomAttrs[.attachment] = atom
            atomAttrs[.purloryMath] = true
            // VoiceOver 읽기는 accessibilityString(for:)가 attachment를 문장으로
            // 바꿔 담당한다 (이슈 #22).
            storage.setAttributes(
                atomAttrs, range: NSRange(location: span.location, length: 1))
            if registersUndo {
                nameCurrentUndo("수식 원자 전환")
                didChangeText()
            }
        }
        return regions.count
    }

    /// 로드 직후 전 문서 1회 전환 — 로드는 undo 대상이 아니므로 storage를 곧장 고친다.
    func convertAllInlineMath() {
        // 남는 raw 스팬 여부는 syncInlineMathFlag가 실측으로 정리한다.
        guard (string as NSString).range(of: "$", options: .literal).location != NSNotFound else {
            mayHaveInlineMath = false
            return
        }
        var location = 0
        while location < (string as NSString).length {
            let ns = string as NSString
            let dollar = ns.range(of: "$", options: .literal, range: NSRange(location: location, length: ns.length - location))
            guard dollar.location != NSNotFound else { break }
            let para = ns.paragraphRange(for: NSRange(location: dollar.location, length: 0))
            let beforeLength = ns.length
            _ = convertInlineMath(in: para, registersUndo: false)
            let delta = (string as NSString).length - beforeLength
            location = max(dollar.location + 1, para.upperBound + delta)
        }
        syncInlineMathFlag()
    }

    /// 커서가 떠난 문단의 raw `$…$`를 원자로 접는다. 커서 문단은 편집 중일 수 있어
    /// 건드리지 않고 플래그만 유지한다 — 다음 커서 이동 때 접힌다.
    func collapseRawInlineMath(awayFrom sel: NSRange, in ranges: [NSRange]) {
        guard mayHaveInlineMath else { return }
        let paragraphs = ranges.flatMap { indexedMediaParagraphs(in: $0) }
        var seen = Set<Int>()
        for paragraph in paragraphs.sorted(by: { $0.range.location > $1.range.location }) {
            let para = paragraph.range
            guard seen.insert(para.location).inserted else { continue }
            let caretInside = NSIntersectionRange(sel, para).length > 0
                || (sel.location >= para.location && sel.location <= para.upperBound)
            if !caretInside, convertInlineMath(in: para) > 0 { needsDisplay = true }
        }
        // Keep the flag conservative until load/global restyle. A scoped pass cannot
        // prove that a distant raw span disappeared without scanning the document.
    }

    /// 문단에 지금 접을 수 있는 raw `$…$`가 있는가.
    func hasConvertibleRawMath(in paragraph: NSRange) -> Bool {
        !MathScanner.regions(
            in: paragraphContent(paragraph), skipping: inlineCodeSkips(in: paragraph)).isEmpty
    }

    /// 실측으로 플래그 정리 — 전체 경로를 한 번 탄 뒤 호출한다 (syncMarkerFlag 짝).
    func syncInlineMathFlag() {
        guard let storage = textStorage else {
            mayHaveInlineMath = false
            return
        }
        let ns = storage.string as NSString
        var found = false
        var location = 0
        while location < ns.length, !found {
            let dollar = ns.range(of: "$", options: .literal, range: NSRange(location: location, length: ns.length - location))
            guard dollar.location != NSNotFound else { break }
            let para = ns.paragraphRange(for: NSRange(location: dollar.location, length: 0))
            location = max(dollar.upperBound, para.upperBound)
            if hasConvertibleRawMath(in: para) { found = true }
        }
        mayHaveInlineMath = found
    }

    /// 테마·글자 크기 변경 — 원자 이미지를 새 잉크색·크기로 다시 렌더한다.
    func rerenderInlineAtoms() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.purloryMath, in: full, options: []) { value, range, _ in
            guard value as? Bool == true, range.length == 1 else { return }
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            guard let atom = attrs[.attachment] as? MathAtomAttachment else { return }
            let size = (attrs[.purloryFontSize] as? Double).map { CGFloat($0) } ?? baseFontSize
            atom.render(fontSize: size, color: palette.ink)
        }
        needsDisplay = true
    }

    /// 더블클릭한 원자를 `$latex$` 소스로 펼쳐 내용을 선택한다 — 편집 후 커서가
    /// 문단을 떠나면 다시 원자로 접힌다(collapseRawInlineMath).
    func revealInlineMathSource(at point: NSPoint) -> Bool {
        guard let layoutManager, let textContainer, let storage = textStorage else {
            return false
        }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(
            for: containerPoint, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil)
        let ns = string as NSString
        guard index < ns.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        guard attrs[.purloryMath] as? Bool == true,
            let atom = attrs[.attachment] as? MathAtomAttachment
        else { return false }
        // 원자는 한 글자다 — 소스 텍스트로 갈아끼운다.
        let source = "$\(atom.latex)$"
        let span = NSRange(location: index, length: 1)
        // 문단 속성은 교체 전에 채집 — 교체가 위치를 밀기 때문.
        let paraAttrs = storage.attributes(at: span.location, effectiveRange: nil)
        guard shouldChangeText(in: span, replacementString: source) else { return false }
        isTransforming = true
        storage.replaceCharacters(in: span, with: source)
        storage.setAttributes(
            paraAttrs, range: NSRange(location: index, length: (source as NSString).length))
        isTransforming = false
        nameCurrentUndo("수식 편집")
        didChangeText()
        setSelectedRange(
            NSRange(location: index + 1, length: (atom.latex as NSString).length))
        mayHaveInlineMath = true
        return true
    }

    // MARK: 수식·이미지 렌더

    /// 수식·이미지 문단 표시 갱신 — 커서가 밖에 있고 소스가 렌더되면 소스 글자를
    /// 투명 처리(temporary attribute — storage·undo·저장에 무해)하고, 레이아웃
    /// 매니저가 그 자리에 렌더 결과를 그린다. 커서가 들어오면 소스로 돌아온다.
    /// 연속 `.math` 문단에서 다중 행 display 그룹의 범위를 계산한다 (이슈 #20).
    /// 열기(`$$`) 속성 문단에서 시작해 닫기(`$$`) 속성 문단까지 — 닫힘이 없으면
    /// 수식이 끊기는 곳(문서 끝·다른 블록)까지가 그룹이다. 단독 완결 수식은
    /// 그룹이 아니라 결과에 없다 — 기존 단일 렌더 경로가 맡는다.
    static func mathGroupRanges(
        _ paragraphs: [(range: NSRange, block: PurloryBlock, open: Bool, close: Bool)],
        requireContiguousRanges: Bool = false
    ) -> [NSRange] {
        var groups: [NSRange] = []
        var index = 0
        while index < paragraphs.count {
            let para = paragraphs[index]
            if para.block == .math, para.open {
                var last = index
                while last + 1 < paragraphs.count,
                    paragraphs[last + 1].block == .math,
                    (!requireContiguousRanges || paragraphs[last].range.upperBound == paragraphs[last + 1].range.location),
                    !paragraphs[last].close
                { last += 1 }
                groups.append(NSRange(
                    location: para.range.location,
                    length: paragraphs[last].range.upperBound - para.range.location))
                index = last + 1
            } else {
                index += 1
            }
        }
        return groups
    }

    /// Scroll refresh retains persistent line heights and collects only indexed
    /// viewport/dirty/selection scopes. Ordinary edits use the same bounded lookup;
    /// load, recovery and global restyle explicitly own full construction.
    func refreshVisibleBlocks() {
        refreshRenderedBlocks(limitToVisible: true)
    }

    /// 가시 사각형(±버퍼 문단)이 덮는 본문 범위 — 스크롤 한정 렌더의 필터 (#18).
    func visibleTextRange(bufferParagraphs: Int = 4) -> NSRange? {
        guard let layoutManager, let textContainer,
            let scrollView = enclosingScrollView
        else { return nil }
        let visibleRect = scrollView.contentView.bounds
        guard visibleRect.height > 0 else { return nil }
        let origin = textContainerOrigin
        // 위아래로 버퍼 문단 높이만큼 넓힌다 — 스크롤 직후 가장자리 공백 방지.
        let lineHeight = max(12, layoutManager.defaultLineHeight(for: bodyFont))
        let inflated = visibleRect.insetBy(
            dx: 0, dy: -CGFloat(bufferParagraphs) * lineHeight)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: inflated.offsetBy(dx: -origin.x, dy: -origin.y),
            in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return nil }
        return charRange
    }

    /// Paragraph scan window for scroll-driven media refresh.
    ///
    /// The normal visible range is already buffered by a few paragraphs. If an edge lands
    /// inside a multi-line math group, expand only through that contiguous math group so
    /// grouping stays correct without walking unrelated paragraphs in the document.
    func mediaRenderScanRange(for visibleRange: NSRange) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }

        let startAnchor = min(max(0, visibleRange.location), ns.length - 1)
        let endAnchor = min(
            max(startAnchor, max(0, visibleRange.upperBound - 1)),
            ns.length - 1)

        var first = ns.paragraphRange(
            for: NSRange(location: startAnchor, length: 0))
        var last = ns.paragraphRange(
            for: NSRange(location: endAnchor, length: 0))

        func delimiter(_ para: NSRange) -> String {
            guard let storage = textStorage, para.location < storage.length else {
                return ""
            }
            return storage.attribute(
                .purloryMathDelim, at: para.location, effectiveRange: nil) as? String ?? ""
        }

        if blockInfo(in: first).block == .math {
            while first.location > 0, delimiter(first) != "open" {
                let previous = ns.paragraphRange(
                    for: NSRange(location: first.location - 1, length: 0))
                guard previous.location < first.location,
                    blockInfo(in: previous).block == .math
                else { break }
                first = previous
            }
        }

        if blockInfo(in: last).block == .math {
            while last.upperBound < ns.length, delimiter(last) != "close" {
                let next = ns.paragraphRange(
                    for: NSRange(location: last.upperBound, length: 0))
                guard next.location >= last.upperBound,
                    next.location < ns.length,
                    blockInfo(in: next).block == .math
                else { break }
                last = next
            }
        }

        return NSRange(
            location: first.location,
            length: max(0, last.upperBound - first.location))
    }

    /// Rebase published graphics and cleanup scopes before consuming the next edit.
    func rebaseRenderedMedia(replacing edit: NSRange, withLength length: Int) {
        func moved(_ range: NSRange) -> NSRange { rebaseMediaRange(range, replacing: edit, withLength: length) }
        func edited(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, edit).length > 0
                || (edit.length == 0 && edit.location >= range.location && edit.location <= range.upperBound)
        }
        mathRenders = mathRenders.compactMap { edited($0.range) ? nil : (moved($0.range), $0.image) }
        imageRenders = imageRenders.compactMap { item in
            guard !edited(item.range) else { return nil }
            return ImageRender(range: moved(item.range), image: item.image, size: item.size,
                align: item.align, selected: item.selected, failure: item.failure)
        }
        mathRenderErrors = Dictionary(mathRenderErrors.map {
            (moved(NSRange(location: $0.key, length: 0)).location, $0.value)
        }, uniquingKeysWith: { _, latest in latest })
        previousClearRanges = previousClearRanges.map(moved).filter { $0.length > 0 }
        previousMathGroups = previousMathGroups.map(moved).filter { $0.length > 0 }
        mediaLastSelectionRange = mediaLastSelectionRange.map(moved)
        if let location = selectedImageLocation {
            selectedImageLocation = NSLocationInRange(location, edit) ? nil
                : moved(NSRange(location: location, length: 0)).location
        }
    }

    func mediaRenderWorkRanges(full: Bool) -> [NSRange] {
        let total = textStorage?.length ?? 0
        if full { return [NSRange(location: 0, length: total)] }
        var requests = mediaDirtyRanges + [selectedRange()]
        if let visible = visibleTextRange() { requests.append(visible) }
        if let prior = mediaLastSelectionRange { requests.append(prior) }
        if let image = selectedImageLocation { requests.append(NSRange(location: image, length: 0)) }
        var ranges: [NSRange] = []
        for request in requests {
            let location = min(max(0, request.location), total)
            let length = min(max(0, request.length), total - location)
            let paragraphs = indexedMediaParagraphs(in: NSRange(location: location, length: length))
            guard let first = paragraphs.first, let last = paragraphs.last else { continue }
            var range = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
            for edge in [first.range.location, last.range.location] {
                if let run = mediaParagraphIndex?.mathRun(containing: edge) { range = NSUnionRange(range, run) }
            }
            ranges.append(range)
        }
        // A removed opening/closing delimiter may leave former members outside the
        // current run; include the prior group to restore every persistent line height.
        for old in previousMathGroups where ranges.contains(where: { NSIntersectionRange($0, old).length > 0 }) {
            ranges.append(old)
        }
        return mergedMediaRanges(ranges)
    }

    func refreshRenderedBlocks(
        forceRender: Bool = false, limitToVisible: Bool = false
    ) {
        guard let layoutManager, let storage = textStorage else { return }
        lastMediaRenderParagraphCount = 0
        let fullRefresh = forceRender || mediaParagraphIndex?.utf16Length != storage.length
        _ = indexedMediaParagraphs(in: NSRange(location: 0, length: 0))

        // 빠른 경로: 렌더 중인 블록도, 이미 렌더된 것도, 이미지 선택도 없고 소스에
        // 수식/이미지 마커("$$"·"![")와 raw 인라인 수식("$")조차 없으면 — 즉 대다수의
        // 평문 저널이면 — 문단 순회·임시속성 조작·전체 재그리기를 통째로 건너뛴다
        // (키 입력마다 O(n) 낭비 제거). 마커 검사는 NSString range 검색이라 문단
        // 순회보다 훨씬 싸다.
        // 주의: 수식/이미지 블록은 마커("$$"·"![")가 이미 **소비**돼 storage 텍스트에
        // 남아 있지 않다 — 커서 문단이 수식/이미지면 마커 검사와 무관하게 전체
        // 경로를 타야 한다 (안 그러면 편집 후 렌더로 영영 못 돌아가는 버그).
        if mathRenders.isEmpty, imageRenders.isEmpty, previousMathGroups.isEmpty,
            previousClearRanges.isEmpty, selectedImageLocation == nil, !mayHaveMarkers, !mayHaveInlineMath {
            let source = storage.string as NSString
            let caretPara = source.paragraphRange(
                for: NSRange(location: min(selectedRange().location, source.length), length: 0))
            let caretBlock = blockInfo(in: caretPara).block
            let previousBlock = mediaLastSelectionRange.map {
                blockInfo(in: source.paragraphRange(for: NSRange(
                    location: min($0.location, source.length), length: 0))).block
            }
            // Leaving source mode must render the prior math block even after
            // its consumed markers and temporary graphics have disappeared.
            if caretBlock != .math, caretBlock != .image, previousBlock != .math {
                cancelMathPreview()
                hideMathPreview()
                _ = takeMediaDirtyRanges()
                mediaLastSelectionRange = selectedRange()
                return
            }
        }
        if !limitToVisible {
            collapseRawInlineMath(awayFrom: selectedRange(), in: mediaRenderWorkRanges(full: fullRefresh))
        }
        let scanRanges = mediaRenderWorkRanges(full: fullRefresh)
        _ = takeMediaDirtyRanges()
        func affected(_ range: NSRange) -> Bool {
            fullRefresh || scanRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        for old in previousClearRanges where affected(old) || limitToVisible {
            let location = min(old.location, storage.length)
            let length = min(old.length, storage.length - location)
            if length > 0 {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange:
                    (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: length)))
            }
        }
        previousClearRanges = fullRefresh || limitToVisible ? [] : previousClearRanges.filter { !affected($0) }
        var maths = fullRefresh || limitToVisible ? [] : mathRenders.filter { !affected($0.range) }
        var collectedMathErrors = fullRefresh || limitToVisible ? [:] : mathRenderErrors.filter {
            !affected(NSRange(location: $0.key, length: 1))
        }
        var images: [ImageRender] = fullRefresh || limitToVisible ? [] : imageRenders.filter { !affected($0.range) }
        // 편집 모드인 수식 그룹 — 루프 뒤 라이브 미리보기 패널을 붙인다.
        var editingMath: (para: NSRange, source: String)?
        let sel = selectedRange()
        // 포커스가 사이드바 등 밖에 있으면 커서가 문단에 남아 있어도 렌더한다 —
        // 수식·이미지가 문서 마지막 문단일 때 소스가 계속 보이는 문제 방지.
        let focused = window?.firstResponder === self

        var indexed: [Int: ParagraphRenderIndex.Paragraph] = [:]
        for range in scanRanges {
            for paragraph in indexedMediaParagraphs(in: range) { indexed[paragraph.range.location] = paragraph }
        }
        let paras = indexed.values.sorted { $0.range.location < $1.range.location }.map {
            (range: $0.range, block: $0.record.block, open: $0.record.open, close: $0.record.close)
        }
        lastMediaRenderParagraphCount = paras.count
        let groups = Self.mathGroupRanges(paras, requireContiguousRanges: true)
        // Restore old group layout before rendering replacement singles/images.
        // Every scoped group is complete, including on a scroll-driven dirty pass.
        for old in previousMathGroups where affected(old) {
            for member in indexedMediaParagraphs(in: old) {
                if !groups.contains(where: { NSIntersectionRange($0, member.range).length > 0 }) {
                    updateGroupLineHeight(nil, in: member.range)
                }
            }
        }
        previousMathGroups = previousMathGroups.filter { !affected($0) } + groups

        // 2단계 — 다중 행 display 그룹 렌더. 커서가 그룹 어느 줄에든 들어오면
        // 그룹 전체가 소스 편집 모드가 되고, 나가면 하나의 이미지로 합쳐 그린다.
        for group in groups {
            let members = paras.filter {
                $0.block == .math && NSIntersectionRange($0.range, group).length > 0
            }
            guard let lastMember = members.last else {
                continue
            }
            // 그룹 문단은 원문($$ 포함)이 저장돼 있다 — 렌더할 LaTeX만 추출한다.
            let latex = members.map { member -> String in
                var source =
                    paragraphContent(member.range).trimmingCharacters(in: .whitespaces)
                if member.open, source.hasPrefix("$$") {
                    source = String(source.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                if member.close, source.hasSuffix("$$"), source.count >= 2 {
                    source = String(source.dropLast(2)).trimmingCharacters(in: .whitespaces)
                }
                return source
            }
            .joined(separator: "\n")
            let contentEnd = lastMember.range.location
                + (paragraphContent(lastMember.range) as NSString).length
            let editing =
                !forceRender && focused
                && ((sel.length == 0 && sel.location >= group.location
                    && sel.location <= contentEnd)
                    || (sel.length > 0 && NSIntersectionRange(sel, group).length > 0))
            if editing {
                editingMath = (group, latex)
                continue
            }
            guard let image = MathRenderer.image(
                latex: latex, color: palette.ink, fontSize: mathFontSize)
            else { continue }  // 파싱 불가 — 직전 높이 유지 (기존 정책)
            maths.append((group, image))
            previousClearRanges.append(group)
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: NSColor.clear, forCharacterRange: group)
            // 그룹 박스 총높이(렌더±마진+틈)를 문단 수로 나눠 배분한다 — 표시
            // 전용 속성이라 저장·undo에 흔적이 없다.
            let total = displayHeight(of: image) + Self.mathBoxMargin * 2 + 4
            let share = max(28, total / CGFloat(max(members.count, 1)))
            for member in members { updateGroupLineHeight(share, in: member.range) }
        }

        // 3단계 — 단독 완결 수식·이미지.
        // `paras` is already the exact scan window; do not restart at document 0.
        for info in paras {
            let para = info.range
            let block = info.block
            if block == .math,
                groups.contains(where: { NSLocationInRange(para.location, $0) })
            {
                continue  // 그룹 소속은 2단계에서 처리됐다
            }
            guard block == .math || block == .image else { continue }

            let content = paragraphContent(para)
            let contentEnd = para.location + (content as NSString).length
            let objectSelected = block == .image && selectedImageLocation == para.location
            // 이미지는 소스를 **절대** 보여주지 않는다 — 항상 렌더(요구 1).
            // 수식만 커서가 닿으면 편집 모드(소스)로 전환한다.
            let editing =
                block == .math && !forceRender && focused
                && ((sel.length == 0 && sel.location >= para.location
                    && sel.location <= contentEnd)
                    || (sel.length > 0 && NSIntersectionRange(sel, para).length > 0))
            let source = content.trimmingCharacters(in: .whitespaces)

            let rendered: NSImage?
            var attrs: ImageAttrs?
            var mathError: String?
            switch block {
            case .math:
                if source.isEmpty {
                    rendered = nil
                } else {
                    let status = MathRenderer.render(
                        latex: source, color: palette.ink, fontSize: mathFontSize)
                    rendered = status.image
                    mathError = status.error
                }
            case .image:
                attrs = Self.imageAttrs(from: source, definitions: currentImageDefinitions())
                // 표시용 다운샘플 (#53) — 그리기엔 컬럼 폭×배율이면 충분하다.
                // 전체 해상도 디코딩은 복사·내보내기 경로만 남는다.
                rendered = attrs.flatMap {
                    resolvedImage(
                        for: $0.src,
                        maxPixelWidth: Self.imageDecodePixelWidth(
                            containerWidth: textContainer?.size.width,
                            backingScale: window?.backingScaleFactor ?? 2))
                }
            default:
                rendered = nil
            }

            switch block {
            case .math:
                if editing { editingMath = (para, source) }
                if let image = rendered {
                    // 렌더되는 한 줄 높이(마진)를 **항상** 유지한다 — 커서가 들어와도,
                    // 다른 곳 갔다 와도 풀리지 않게 (요구 2). 편집 모드면 소스만 보인다.
                    updateRenderedLineHeight(displayHeight(of: image), block: .math, in: para)
                    if !editing {
                        maths.append((para, image))
                        previousClearRanges.append(para)
                        layoutManager.addTemporaryAttribute(
                            .foregroundColor, value: NSColor.clear, forCharacterRange: para)
                    }
                } else if let error = mathError {
                    // 유효→무효 전환 — 직전 높이·플로팅 미리보기 잔상을 끊고
                    // 원인 표시 placeholder로 갈아끼운다 (이슈 #22).
                    hideMathPreview()
                    let placeholder = MathRenderer.failurePlaceholder(
                        message: error, latex: source, color: palette.ink)
                    updateRenderedLineHeight(
                        displayHeight(of: placeholder), block: .math, in: para)
                    if !editing {
                        maths.append((para, placeholder))
                        collectedMathErrors[para.location] = error
                        previousClearRanges.append(para)
                        layoutManager.addTemporaryAttribute(
                            .foregroundColor, value: NSColor.clear, forCharacterRange: para)
                    }
                } else if source.isEmpty {
                    updateRenderedLineHeight(nil, block: .math, in: para)  // 빈 수식만 기본
                }
            case .image:
                guard let image = rendered else {
                    // 로드 실패 — 소스로 빠지는 대신 원인·alt·경로를 적은
                    // 플레이스홀더를 렌더한다 (이슈 #15). 소스 노출 금지 불변식 유지.
                    if let a = attrs, let failure = imageFailure(for: a.src) {
                        let placeholder = ImageFailure.placeholder(
                            reason: failure, alt: a.alt, path: a.src, theme: palette)
                        let size = imageDisplaySize(placeholder, widthPercent: a.width)
                        images.append(
                            ImageRender(
                                range: para, image: placeholder, size: size,
                                align: a.align, selected: objectSelected, failure: failure))
                        updateRenderedLineHeight(size.height, block: .image, in: para)
                        previousClearRanges.append(para)
                        layoutManager.addTemporaryAttribute(
                            .foregroundColor, value: NSColor.clear, forCharacterRange: para)
                    } else {
                        // attrs가 없다면 이미지 문단 표식만 남은 빈 줄 — 높이만 복원.
                        updateRenderedLineHeight(nil, block: .image, in: para)
                    }
                    continue
                }
                let a = attrs ?? ImageAttrs(src: "")
                // 드래그 리사이즈 중이면 미리보기 너비를 우선한다.
                let width = resizePreview?.loc == para.location
                    ? resizePreview!.width : a.width
                let size = imageDisplaySize(image, widthPercent: width)
                images.append(
                    ImageRender(
                        range: para, image: image, size: size, align: a.align,
                        selected: objectSelected))
                updateRenderedLineHeight(size.height, block: .image, in: para)
                previousClearRanges.append(para)
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: NSColor.clear, forCharacterRange: para)
            default:
                break
            }
        }
        mathRenders = maths.sorted { $0.range.location < $1.range.location }
        self.mathRenderErrors = collectedMathErrors
        imageRenders = images.sorted { $0.range.location < $1.range.location }
        if fullRefresh { syncMarkerFlag() }
        mediaLastSelectionRange = selectedRange()
        repositionImageBox()  // 렌더/줄 높이 변화에 박스 위치를 맞춘다.
        // Keep live preview beside its source inside the same math block. Retain
        // the existing debounce so typing does not add a render on every key.
        if let (para, source) = editingMath {
            scheduleMathPreview(source: source, in: para)
        } else {
            cancelMathPreview()
            hideMathPreview()
        }
        // 렌더된 이미지 위 포인터 커서 rect를 새 위치로 갱신한다.
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// 미리보기 렌더 예약 — 이미 예약이 있으면 소스만 교체한다 (타이머 리셋 없음,
    /// 연속 타이핑에서 최대 한 번의 조판).
    func scheduleMathPreview(source: String, in para: NSRange) {
        mathPreviewPending = (source, para)
        guard mathPreviewTask == nil else { return }
        mathPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.mathPreviewTask = nil
            guard let pending = self.mathPreviewPending else { return }
            self.mathPreviewPending = nil
            self.presentMathPreview(source: pending.source, in: pending.para)
        }
    }

    func cancelMathPreview() {
        mathPreviewTask?.cancel()
        mathPreviewTask = nil
        mathPreviewPending = nil
    }

    /// Source and preview occupy one block; preview never covers the next prose row.
    func presentMathPreview(source: String, in para: NSRange) {
        guard isEditingMath, let rect = paragraphRectInView(para),
            let layoutManager, let textContainer else {
            hideMathPreview()
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let ns = string as NSString
        var sourceRight = rect.midX
        var location = para.location
        while location < min(para.upperBound, ns.length) {
            let member = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let content = NSRange(location: member.location, length: (paragraphContent(member) as NSString).length)
            if content.length > 0 {
                let glyphs = layoutManager.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
                let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                sourceRight = max(sourceRight, bounds.maxX + textContainerOrigin.x)
            }
            location = member.upperBound
        }
        let availableWidth = rect.maxX - sourceRight - 16 - 48
        guard availableWidth >= 64 else { hideMathPreview(); return }
        let image = source.isEmpty
            ? nil
            : MathRenderer.image(latex: source, color: palette.ink, fontSize: mathFontSize)
        let message: String?
        let isError: Bool
        if image != nil {
            message = nil
            isError = false
        } else if source.isEmpty {
            message = "LaTeX 입력 — 예: E = mc^2"
            isError = false
        } else {
            message = "수식을 해석할 수 없어요 — LaTeX 문법을 확인하세요"
            isError = true
        }
        let view = MathPreviewView(
            theme: palette, image: image, message: message, isError: isError,
            maxWidth: availableWidth)
        let host: NSHostingView<MathPreviewView>
        if let existing = mathPreviewHost {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            mathPreviewHost = host
        }
        let size = host.fittingSize
        // SwiftUI rounds intrinsic sizes to whole points. The reserved trailing
        // margin already protects the source; fractional rounding must not hide it.
        guard size.width <= ceil(availableWidth), size.height <= rect.height else {
            hideMathPreview()
            return
        }
        host.frame = NSRect(x: sourceRight + 16, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        if host.superview !== self { addSubview(host) }
    }

    func hideMathPreview() {
        mathPreviewHost?.removeFromSuperview()
    }

    func currentImageDefinitions() -> [String: ImageReferenceParser.Definition] {
        if imageDefinitionsDirty {
            imageDefinitions = ImageReferenceParser.collectDefinitions(in: string)
            imageDefinitionsDirty = false
        }
        return imageDefinitions
    }

    /// `![alt](src)` 한 줄에서 src(상대경로)만 뽑는다. 형식이 아니면 nil.
    static func imageSource(
        from line: String,
        definitions: [String: ImageReferenceParser.Definition] = [:]
    ) -> String? {
        imageAttrs(from: line, definitions: definitions)?.src
    }

    /// `![](src){width=NN align=X}` 한 줄에서 소스·너비·정렬을 파싱한다. 형식이 아니면 nil.
    /// 이미지 문단 한 줄 해석 — 공용 파서(ImageReferenceParser, 이슈 #12)의
    /// 결과만 쓴다. 옛 한 줄 정규식은 title·angle·괄호·reference를 놓쳤다.
    /// 원격·차단 소스는 렌더 대상에서 제외한다 (완전 로컬 원칙).
    /// 비격리 순수 파서 — 백그라운드 EPUB 내보내기가 같은 규칙을 쓴다 (#33).
    nonisolated static func imageAttrs(
        from line: String,
        definitions: [String: ImageReferenceParser.Definition] = [:]
    ) -> ImageAttrs? {
        guard let ref = ImageReferenceParser.parse(line, definitions: definitions) else { return nil }
        switch ref.destinationKind {
        case .managedRelative, .externalFile:
            break
        case .remote, .blocked:
            return nil
        }
        var attrs = ImageAttrs(src: ref.destinationRaw)
        attrs.alt = ref.alt
        attrs.title = ref.title
        // {width align} 확장 적용 — splitOptions가 검증토큰만 남겨 두었다.
        if let trimmed = line.trimmingCharacters(in: .whitespaces) as String?,
           let open = trimmed.lastIndex(of: "{"),
           trimmed.hasSuffix("}") {
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            for token in inner.split(separator: " ") where !token.isEmpty {
                let kv = token.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch String(kv[0]) {
                case "width": if let w = Int(kv[1]) { attrs.width = min(100, max(10, w)) }
                case "align" where ["left", "center", "right"].contains(String(kv[1])):
                    attrs.align = String(kv[1])
                default:
                    // 미지 확장 속성 — 원문 토큰을 순서대로 보관해 재작성 시 되살린다 (이슈 #14).
                    attrs.extraOptions.append(String(token))
                }
            }
            // 재합성 대신 스플라이스 — alt·title을 보존한 채 속성만 바꾼다.
            attrs.optionsPrefix = String(trimmed[..<open])
        } else {
            attrs.optionsPrefix = nil
        }
        return attrs
    }

    /// 표시용 이미지 디코딩 상한 픽셀 — 컬럼 폭 × 배율 × 여유(1.5), 800–2400 클램프.
    /// 이 이상은 화면에서 구분할 수 없다 — 디코딩·메모리만 늘어난다 (#53).
    nonisolated static func imageDecodePixelWidth(
        containerWidth: CGFloat?, backingScale: CGFloat
    ) -> CGFloat {
        let target = (containerWidth ?? 800) * max(1, backingScale) * 1.5
        return min(2400, max(800, target))
    }

    /// drawMath와 같은 규칙(폭 초과 시 축소)으로 실제 그려질 수식 높이를 구한다.
    func displayHeight(of image: NSImage) -> CGFloat {
        guard let container = textContainer, image.size.width > 0 else {
            return image.size.height
        }
        let rectWidth = container.size.width - container.lineFragmentPadding * 2
        // 컬럼 폭이 아직 안 잡혔으면(레이아웃 전·저널 전환 순간) 축소하지 않는다 —
        // 예전엔 max(40,…) 바닥값이 수식을 40pt로 줄여 줄 높이를 붕괴시켰다.
        guard rectWidth > 120 else { return image.size.height }
        let scale = min(1, (rectWidth - 32) / image.size.width)
        return image.size.height * scale
    }

    /// 이미지가 실제로 그려질 크기 — 컬럼 폭에 맞추고 세로는 480pt로 제한한 뒤,
    /// 사용자 지정 너비 %(요구 3)를 곱한다. (레이아웃 매니저와 같은 규칙.)
    func imageDisplaySize(_ image: NSImage, widthPercent: Int = 100) -> NSSize {
        guard image.size.width > 0, image.size.height > 0 else { return image.size }
        let rectWidth =
            (textContainer.map { $0.size.width - $0.lineFragmentPadding * 2 })
            ?? bounds.width
        let maxHeight: CGFloat = 480
        let pct = CGFloat(min(100, max(10, widthPercent))) / 100
        // 컬럼 폭이 아직 안 잡혔으면(레이아웃 전·전환 순간) 세로 상한만 적용 — 폭
        // 축소로 크기가 붕괴하지 않게.
        let fit: CGFloat
        if rectWidth > 120 {
            fit = min(1, min((rectWidth - 16) / image.size.width, maxHeight / image.size.height))
        } else {
            fit = min(1, maxHeight / image.size.height)
        }
        let scale = fit * pct
        return NSSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// 수식·이미지 문단의 줄 높이를 렌더 크기에 맞춘다 (nil이면 기본 스타일로 복원).
    /// 표시 전용 속성 변경 — 저장 텍스트·undo에 흔적이 없다.
    func updateRenderedLineHeight(
        _ height: CGFloat?, block: PurloryBlock, in paragraph: NSRange
    ) {
        guard let storage = textStorage, paragraph.length > 0,
            paragraph.location < storage.length,
            let ps = (styleAttributes(for: block, checked: false)[.paragraphStyle]
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        if let height {
            switch block {
            case .math:
                // 수식 박스(렌더 ±mathBoxMargin)가 이웃 줄과 겹치지 않도록,
                // 박스 높이에 숨 쉴 틈 4pt를 더한 줄 높이 (요구 5).
                ps.minimumLineHeight = height + Self.mathBoxMargin * 2 + 4
            default:
                // 위아래 여유 12pt — 배경 박스(-6 inset)와 시각적으로 맞는 값.
                ps.minimumLineHeight = height + 12
            }
        }
        let current =
            storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle
        guard current?.minimumLineHeight != ps.minimumLineHeight else { return }
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    /// 다중 행 수식 그룹용 — 문단별 최소 줄 높이를 **직접** 지정한다 (이슈 #20).
    /// 그룹 총 박스 높이를 문단 수로 나눈 값을 호출부가 계산해 넣는다.
    func updateGroupLineHeight(_ raw: CGFloat?, in paragraph: NSRange) {
        guard let storage = textStorage, paragraph.length > 0,
            paragraph.location < storage.length,
            let ps = (styleAttributes(for: raw == nil ? blockInfo(in: paragraph).block : .math,
                checked: blockInfo(in: paragraph).checked)[.paragraphStyle]
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        if let raw { ps.minimumLineHeight = raw }
        if raw == nil {
            if let align = storage.attribute(.purloryAlign, at: paragraph.location, effectiveRange: nil) as? String {
                ps.alignment = align == "right" ? .right : .center
            }
            if let spacing = storage.attribute(.purloryLineSpacing, at: paragraph.location, effectiveRange: nil) as? Double {
                ps.minimumLineHeight = 0; ps.maximumLineHeight = 0
                ps.lineSpacing = CGFloat(spacing)
            }
        }
        let current =
            storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle
        guard current?.isEqual(ps) != true else { return }
        storage.addAttribute(.paragraphStyle, value: ps, range: paragraph)
    }

    /// loc가 속한 다중 행 수식 그룹의 storage 범위 — 드래그 이동·히트 판정용.
    /// 단독 완결 수식이면 nil (그룹 이동 대상이 아니다).
    func mathGroup(containing loc: Int) -> NSRange? {
        _ = indexedMediaParagraphs(in: NSRange(location: 0, length: 0))
        guard let run = mediaParagraphIndex?.mathRun(containing: loc) else { return nil }
        let paragraphs = indexedMediaParagraphs(in: run).map {
            (range: $0.range, block: $0.record.block, open: $0.record.open, close: $0.record.close)
        }
        return Self.mathGroupRanges(paragraphs, requireContiguousRanges: true).first { NSLocationInRange(loc, $0) }
    }

    /// loc의 수식 LaTeX 원문 — 단독 완결은 문단 내용이고, 그룹이면 구분자 줄을
    /// 걷어내고 내용 줄만 개행으로 합친다 (#22).
    func mathSource(at loc: Int) -> String? {
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let para = ns.paragraphRange(
            for: NSRange(location: min(loc, ns.length), length: 0))
        guard blockInfo(in: para).block == .math else { return nil }
        if let group = mathGroup(containing: para.location) {
            var lines: [String] = []
            var scanLoc = group.location
            while scanLoc < min(group.upperBound, ns.length) {
                let p = ns.paragraphRange(for: NSRange(location: scanLoc, length: 0))
                scanLoc = p.upperBound
                guard blockInfo(in: p).block == .math else { continue }
                var line = paragraphContent(p)
                if line == "$$" { continue }  // 열기/닫기 구분자 줄
                if line.hasSuffix("$$") { line.removeLast(2) }  // 닫기가 붙어 있는 줄
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
        // 단독 완결 수식 — 저장 내용이 곧 LaTeX (직렬화 때 $$를 덧입힌다).
        return paragraphContent(para)
    }

    func renderedMathImage(at loc: Int, latex: String) -> NSImage? {
        mathRenders.first { $0.range.location <= loc && $0.range.upperBound > loc }?.image
            ?? MathRenderer.image(latex: latex, color: palette.ink, fontSize: mathFontSize)
    }

    @objc func copyMathLatex(_ sender: AnyObject?) {
        guard let loc = mathActionLocation, let latex = mathSource(at: loc) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latex, forType: .string)
    }

    @objc func copyMathImage(_ sender: AnyObject?) {
        guard let loc = mathActionLocation,
            let latex = mathSource(at: loc),
            let image = renderedMathImage(at: loc, latex: latex)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc func copyMathPDF(_ sender: AnyObject?) {
        guard let loc = mathActionLocation,
            let latex = mathSource(at: loc),
            let image = renderedMathImage(at: loc, latex: latex),
            let pdf = MathRenderer.pdfData(from: image)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pdf, forType: .pdf)
    }
}
