import AppKit
import SwiftMath
import UniformTypeIdentifiers

/// 소설을 EPUB 3으로 내보낸다 (요구 7 — 파일 메뉴·사이드바 문맥 메뉴).
///
/// 외부 의존성 없이 최소 규격만 직접 조립한다:
/// - `mimetype`(무압축·첫 항목) + `META-INF/container.xml` + `OEBPS/`(opf·nav·css·본문)
/// - 본문 마크다운은 단순 변환기로 XHTML이 된다 — `# `(제목 1)마다 챕터를 나눠
///   목차(nav)와 spine에 올린다. 소설 본문(문단·제목·인용·목록·이미지) 중심이고,
///   수식·코드는 고정폭 소스로 남는다.
/// - 압축은 시스템 `/usr/bin/zip` — mimetype은 규격상 무압축(-0) 첫 항목이어야
///   해서 두 번에 나눠 담는다.
public enum EpubExporter {

    public enum ExportError: LocalizedError {
        case zipFailed(String)
        case missingAssets([String])

        public var errorDescription: String? {
            switch self {
            case .zipFailed(let message):
                return "EPUB 압축에 실패했어요 — \(message)"
            case .missingAssets(let references):
                return "이미지 파일을 찾을 수 없어 내보내지 못했어요: \(references.joined(separator: ", "))"
            }
        }
    }

    // MARK: - 진입점

    /// 저장 패널을 띄워 내보낸다 — 파일 메뉴와 사이드바 문맥 메뉴가 공유한다.
    /// 누락 이미지가 있으면 **미리** 알리고 명시적 계속을 요구한다 (이슈 #15).
    /// 변환·복사·압축은 백그라운드에서 돌고 완료 위치를 알린다 (이슈 #33).
    @MainActor
    public static func exportWithPanel(_ entry: JournalEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .zip]
        panel.nameFieldStringValue = sanitizedFileName(entry.title) + ".epub"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 설정의 저자 이름은 값 스냅샷으로만 넘긴다 (CLAUDE.md §4 격리 경계).
        guard ImageAssetScanner.confirmContinueDespiteMissing(in: entry.body) else {
            return
        }
        let author = CompletionSettings.shared.authorName
        Task {
            do {
                try await exportAsync(entry, to: url, author: author)
                let done = NSAlert()
                done.messageText = "EPUB 내보내기 완료"
                done.informativeText = url.path
                done.alertStyle = .informational
                done.runModal()
            } catch is CancellationError {
                return  // 사용자 취소 — 조용히.
            } catch {
                let alert = NSAlert()
                alert.messageText = "EPUB 내보내기 실패"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// 저널 한 편을 EPUB 파일로 만든다. UI 없이 파일만 쓴다.
    /// `author`는 설정의 저자 이름(필명) — 비어 있으면 저자 메타데이터를 생략한다.
    ///
    /// 이미지 URL 해석(메인 격리 PurloryImageStore)만 메인에서 끝내고, 변환·파일
    /// 쓰기·압축은 호출 스레드에서 돈다 (#33). 비동기가 필요하면 `exportAsync`.
    @MainActor
    public static func export(
        _ entry: JournalEntry, to destination: URL, author: String = ""
    ) throws {
        try buildEPUB(
            document(from: entry), assetURLs: resolveAssetURLs(in: entry.body),
            to: destination, author: author)
    }

    /// 백그라운드 내보내기 — 자산 해석만 메인, 나머지는 유틸리티 우선순위
    /// 분리 작업으로 (#33). 진행률(0…1)과 취소를 지원한다. 분리 작업은 취소를
    /// 물려받지 않으므로 onCancel로 명시 전파한다.
    @MainActor
    public static func exportAsync(
        _ entry: JournalEntry, to destination: URL, author: String = "",
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let assetURLs = resolveAssetURLs(in: entry.body)
        let work = Task.detached(priority: .userInitiated) {
            try Self.buildEPUB(
                document(from: entry), assetURLs: assetURLs, to: destination, author: author,
                progress: progress)
        }
        return try await withTaskCancellationHandler(operation: {
            try await work.value
        }, onCancel: {
            work.cancel()
        })
    }

    public static func export(
        _ document: WritingDocument, assets: ProjectAssetCatalog,
        to destination: URL, author: String = ""
    ) throws {
        try buildEPUB(document, assetURLs: [:], assets: assets, to: destination, author: author)
    }

    public static func exportAsync(
        _ document: WritingDocument, assets: ProjectAssetCatalog,
        to destination: URL, author: String = "",
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try buildEPUB(document, assetURLs: [:], assets: assets,
                to: destination, author: author, progress: progress)
        }
        try await withTaskCancellationHandler(operation: {
            try await work.value
        }, onCancel: { work.cancel() })
    }

    private static func document(from entry: JournalEntry) -> WritingDocument {
        WritingDocument(id: WritingDocumentID(rawValue: entry.id),
            title: entry.title, body: entry.body, kind: .manuscript)
    }

    /// 본문의 로컬 이미지 src를 실제 파일 URL로 풀어 둔다 — 메인 격리
    /// PurloryImageStore 접근은 여기서 끝난다. 이후 단계는 격리 없이 순수하다 (#33).
    @MainActor
    static func resolveAssetURLs(in body: String) -> [String: URL] {
        var map: [String: URL] = [:]
        for rawLine in body.components(separatedBy: "\n") {
            guard let attrs = BlockTextView.imageAttrs(
                from: rawLine.trimmingCharacters(in: .whitespaces))
            else { continue }
            switch ImageReferenceParser.classify(attrs.src) {
            case .managedRelative, .externalFile:
                if map[attrs.src] == nil {
                    map[attrs.src] = PurloryImageStore.url(for: attrs.src)
                }
            case .remote, .blocked:
                break
            }
        }
        return map
    }

    /// EPUB 조립 본체 — 메인 격리 의존이 없다 (자산은 미리 풀어 받는다).
    /// 진행률 콜백과 취소 협조를 갖춘다 (백그라운드 3요건, AGENTS §4).
    private static func buildEPUB(
        _ entry: WritingDocument, assetURLs: [String: URL], assets: ProjectAssetCatalog? = nil, to destination: URL,
        author: String, progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let destination = try ExportDestination.validatedFile(destination)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("purlory-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let metaInf = staging.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = staging.appendingPathComponent("OEBPS", isDirectory: true)
        try fm.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)

        // mimetype — 개행 없이. zip의 첫 항목으로 무압축 저장돼야 리더가 알아본다.
        try Data("application/epub+zip".utf8)
            .write(to: staging.appendingPathComponent("mimetype"))
        try containerXML.write(
            to: metaInf.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)

        var images: [String] = []
        // 누락 asset은 exportWithPanel에서 미리 검증됐지만, API 직접 호출 경로에서도
        // 조용히 사라지지 않게 목록을 유지한다 (이슈 #15).
        var missingAssets: [String] = []
        let chapters = makeChapters(
            from: entry, copyingImagesInto: oebps, collected: &images,
            missing: &missingAssets, assetURLs: assetURLs, assets: assets,
            progress: progress)
        if assets != nil, !missingAssets.isEmpty { throw ExportError.missingAssets(missingAssets) }
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            try chapterXHTML(chapter).write(
                to: oebps.appendingPathComponent(chapterFile(index)),
                atomically: true, encoding: .utf8)
            progress?(0.3 + 0.4 * Double(index + 1) / Double(max(chapters.count, 1)))
        }
        try styleCSS.write(
            to: oebps.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try navXHTML(bookTitle: entry.title, chapters: chapters).write(
            to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try packageOPF(entry: entry, chapters: chapters, images: images, author: author).write(
            to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try Task.checkCancellation()
        progress?(0.75)
        try runZip(["-X", "-0", "book.epub", "mimetype"], in: staging)
        try runZip(["-rX", "book.epub", "META-INF", "OEBPS"], in: staging)
        progress?(0.95)

        try ExportDestination.replaceCompletedFile(staging.appendingPathComponent("book.epub"), to: destination)
        progress?(1)
    }

    // MARK: - 마크다운 → 챕터 XHTML

    struct Chapter {
        var title: String
        var html: String
    }

    /// 본문을 `# ` 제목마다 챕터로 나누고, 각 챕터를 XHTML 조각으로 변환한다.
    /// 이미지(`![](images/…)`)는 OEBPS/images/로 복사해 참조를 살린다.
    /// 메인 격리가 없다 — 이미지 URL은 `resolveAssetURLs`가 미리 풀어 준다 (#33).
    /// private가 아닌 이유는 alt/title 반영을 단위 테스트로 고정하기 위해서다
    /// (packageOPF와 같은 선례).
    static func makeChapters(
        from entry: JournalEntry, copyingImagesInto oebps: URL,
        collected images: inout [String], missing: inout [String],
        assetURLs: [String: URL] = [:],
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [Chapter] {
        makeChapters(from: document(from: entry), copyingImagesInto: oebps,
            collected: &images, missing: &missing, assetURLs: assetURLs, progress: progress)
    }

    private static func makeChapters(
        from entry: WritingDocument, copyingImagesInto oebps: URL,
        collected images: inout [String], missing: inout [String],
        assetURLs: [String: URL], assets: ProjectAssetCatalog? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [Chapter] {
        var chapters: [Chapter] = []
        var title = plainTitle(entry.title)
        var html = ""
        // 첫 h1 앞에 본문이 없으면 그 "빈 서문 챕터"는 만들지 않는다.
        var started = false
        var inCode = false
        var listTag: String?
        func closeList() {
            if let tag = listTag {
                html += "</\(tag)>\n"
                listTag = nil
            }
        }
        // 다중 행 display 수식 그룹 — 에디터 로드와 같은 상태기계 (이슈 #20).
        // "$$"로 열리고 "$$"로 닫히며, 그룹 안의 줄은 다른 블록으로 오독하지 않는다.
        var inMathGroup = false
        var mathLines: [String] = []

        func flushMath() {
            closeList()
            let source = mathLines.joined(separator: "\n")
            let result = Self.mathHTML(source, into: oebps)
            html += result.html
            if let asset = result.asset, !images.contains(asset) {
                images.append(asset)  // OPF manifest 등록 (#22)
            }
            mathLines = []
            progress?(0.1)
        }
        func openList(_ tag: String) {
            if listTag != tag {
                closeList()
                html += "<\(tag)>\n"
                listTag = tag
            }
        }

        for rawLine in entry.body.components(separatedBy: "\n") {
            var line = rawLine
            if inMathGroup {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "$$" {
                    inMathGroup = false
                    flushMath()
                } else if trimmed.hasSuffix("$$"), trimmed.count >= 3 {
                    mathLines.append((line as NSString).substring(
                        with: NSRange(location: 0, length: (line as NSString).length - 2)))
                    inMathGroup = false
                    flushMath()
                } else {
                    mathLines.append(line)
                }
                continue
            }
            let trimmedFence = line.trimmingCharacters(in: .whitespaces)
            if !inCode, trimmedFence.hasPrefix("```"), !trimmedFence.dropFirst(3).contains("`") {
                closeList()
                inCode = true
                let lang = String(trimmedFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let classAttr = lang.isEmpty ? "" : " class=\"language-\(attrEscape(lang))\""
                html += "<pre><code\(classAttr)>"
                continue
            } else if inCode, trimmedFence == "```" {
                closeList()
                inCode = false
                html += "</code></pre>\n"
                continue
            }
            if inCode {
                html += escape(line).replacingOccurrences(of: "\u{2028}", with: "\n") + "\n"
                continue
            }
            // 정렬 래퍼는 스타일로 옮긴다.
            var align: String?
            if let match = alignWrapper.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                align = (line as NSString).substring(with: match.range(at: 1))
                line = (line as NSString).substring(with: match.range(at: 2))
            }

            if line.hasPrefix("# ") {
                closeList()
                if started || !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chapters.append(Chapter(title: title, html: html))
                }
                title = plainTitle(String(line.dropFirst(2)))
                html = ""
                started = true
            } else if line.hasPrefix("###### ") {
                closeList()
                html += "<h6>\(inline(String(line.dropFirst(7))))</h6>\n"
            } else if line.hasPrefix("##### ") {
                closeList()
                html += "<h5>\(inline(String(line.dropFirst(6))))</h5>\n"
            } else if line.hasPrefix("#### ") {
                closeList()
                html += "<h4>\(inline(String(line.dropFirst(5))))</h4>\n"
            } else if line.hasPrefix("### ") {
                closeList()
                html += "<h3>\(inline(String(line.dropFirst(4))))</h3>\n"
            } else if line.hasPrefix("## ") {
                closeList()
                html += "<h2>\(inline(String(line.dropFirst(3))))</h2>\n"
            } else if let quoteMatch = BlockTextView.parseQuotePrefix(line) {
                closeList()
                html += "<blockquote><p>\(inline(quoteMatch.body))</p></blockquote>\n"
            } else if let listMatch = BlockTextView.parseListPrefix(line) {
                switch listMatch.block {
                case .todo:
                    openList("ul")
                    let mark = listMatch.checked ? "☑" : "☐"
                    html += "<li>\(mark) \(inline(listMatch.body))</li>\n"
                case .bullet:
                    openList("ul")
                    html += "<li>\(inline(listMatch.body))</li>\n"
                case .number:
                    openList("ol")
                    html += "<li>\(inline(listMatch.body))</li>\n"
                default:
                    break
                }
            } else if line.range(of: #"^---+\s*$"#, options: .regularExpression) != nil {
                closeList()
                html += "<hr/>\n"
            } else if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count >= 4 {
                closeList()
                let source = String(line.dropFirst(2).dropLast(2))
                let result = Self.mathHTML(source, into: oebps)
                html += result.html
                if let asset = result.asset, !images.contains(asset) {
                    images.append(asset)
                }
            } else if line.trimmingCharacters(in: .whitespaces) == "$$"
                || (line.hasPrefix("$$") && !line.dropFirst(2).hasPrefix("$")) {
                // 다중 행 display의 열기 — 이후 줄들이 닫는 $$를 만날 때까지 수식.
                closeList()
                inMathGroup = true
                let rest = String(line.dropFirst(2))
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    mathLines.append(rest)
                }
            } else if let attrs = BlockTextView.imageAttrs(
                from: line.trimmingCharacters(in: .whitespaces)) {
                closeList()
                if let relative = copyImage(
                    attrs.src, into: oebps, missing: &missing, assetURLs: assetURLs, assets: assets)
                {
                    if !images.contains(relative) { images.append(relative) }
                    html += imageTag(src: relative, attrs: attrs)
                }
                // 누락 로컬 파일은 missing에 기록됐고 exportWithPanel이 계속
                // 여부를 물었다. 차단 소스는 에디터에서도 렌더 대상이 아니므로
                // 사라진 것이 아니다.
            } else if let ref = ImageReferenceParser.parse(line.trimmingCharacters(in: .whitespaces)),
                case .remote(let url) = ref.destinationKind {
                // 원격 이미지는 로컬 복사 대상이 아니지만 주소 그대로 남긴다 —
                // 콘텐츠가 경고 없이 사라지지 않게 (#12·#15).
                closeList()
                var attrs = ImageAttrs(src: url.absoluteString)
                attrs.alt = ref.alt
                attrs.title = ref.title
                html += imageTag(src: attrs.src, attrs: attrs)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                closeList()
            } else {
                closeList()
                let style = align.map { " style=\"text-align:\($0)\"" } ?? ""
                html += "<p\(style)>\(inline(line))</p>\n"
            }
        }
        // 파일 끝에서 닫히지 않은 그룹 — 열려 있는 만큼은 수식으로 남긴다.
        if inMathGroup || !mathLines.isEmpty { flushMath() }
        closeList()
        chapters.append(Chapter(title: title, html: html))
        return chapters
    }

    /// 수식을 EPUB 3 네이티브 MathML(`<math>`) 벡터 태그로 변환해 돌려준다.
    /// LaTeX 원문은 `alttext` 속성에 남겨 접근성·의미 fallback을 제공하고,
    /// 렌더 실패 시엔 code 소스를 남긴다 (이슈 #22).
    ///
    /// 메인 격리가 없다 — 내보내기 경로는 공유 캐시를 거치지 않는 순수 AST 변환으로
    /// 백그라운드에서 돈다 (#33).
    static func mathHTML(
        _ source: String, into oebps: URL
    ) -> (html: String, asset: String?) {
        _ = oebps
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let math = Self.mathML(source, display: true)
        else {
            // 렌더 실패 — 소스를 남겨 의미가 완전히 사라지지 않게 한다 (#15 승계).
            return ("<p class=\"math\"><code>\(escape(source))</code></p>\n", nil)
        }
        return ("<p class=\"math\">\(math)</p>\n", nil)
    }

    /// LaTeX → EPUB 3 MathML 문자열 (`<math xmlns="http://www.w3.org/1998/Math/MathML">`).
    static func mathML(_ source: String, display: Bool = true) -> String? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let list = MathRenderer.parsedMathList(
                latex: source, labelMode: display ? .display : .text)
        else { return nil }
        let body = renderMathList(list)
        guard !body.isEmpty else { return nil }
        let mode = display ? "block" : "inline"
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(mode)\""
            + " alttext=\"LaTeX: \(attrEscape(source))\">\(body)</math>"
    }

    private static func renderMathList(_ list: MTMathList?) -> String {
        guard let list else { return "" }
        return list.finalized.atoms.map(renderMathAtom).joined()
    }

    private static func renderMathRow(_ list: MTMathList?) -> String {
        guard let list else { return "<mrow/>" }
        let finalized = list.finalized
        let rendered = finalized.atoms.map(renderMathAtom).filter { !$0.isEmpty }
        if rendered.isEmpty { return "<mrow/>" }
        if rendered.count == 1 { return rendered[0] }
        return "<mrow>\(rendered.joined())</mrow>"
    }

    private static func mathVariantAttr(for atom: MTMathAtom) -> String {
        let probe: MTMathAtom = atom.copy()
        probe.subScript = nil
        probe.superScript = nil
        let tex = MTMathListBuilder.mathListToString(MTMathList(atom: probe))
        if tex.hasPrefix("\\mathrm{") { return " mathvariant=\"normal\"" }
        if tex.hasPrefix("\\mathbf{") { return " mathvariant=\"bold\"" }
        if tex.hasPrefix("\\mathfrak{") { return " mathvariant=\"fraktur\"" }
        if tex.hasPrefix("\\mathcal{") { return " mathvariant=\"script\"" }
        if tex.hasPrefix("\\mathit{") { return " mathvariant=\"italic\"" }
        if tex.hasPrefix("\\mathsf{") { return " mathvariant=\"sans-serif\"" }
        if tex.hasPrefix("\\mathbb{") { return " mathvariant=\"double-struck\"" }
        if tex.hasPrefix("\\mathtt{") { return " mathvariant=\"monospace\"" }
        if tex.hasPrefix("\\bm{") { return " mathvariant=\"bold-italic\"" }
        return ""
    }

    private static func renderMathAtom(_ atom: MTMathAtom) -> String {
        let base: String
        switch atom.type {
        case .number:
            base = "<mn\(mathVariantAttr(for: atom))>\(escape(atom.nucleus))</mn>"
        case .variable:
            base = "<mi\(mathVariantAttr(for: atom))>\(escape(atom.nucleus))</mi>"
        case .ordinary, .placeholder:
            if atom.nucleus.isEmpty {
                base = (atom.subScript != nil || atom.superScript != nil) ? "<mrow/>" : ""
            } else if atom.nucleus.allSatisfy(\.isNumber) {
                base = "<mn\(mathVariantAttr(for: atom))>\(escape(atom.nucleus))</mn>"
            } else {
                base = "<mi\(mathVariantAttr(for: atom))>\(escape(atom.nucleus))</mi>"
            }
        case .largeOperator, .binaryOperator, .unaryOperator, .relation, .open, .close, .punctuation, .boundary:
            base = "<mo\(mathVariantAttr(for: atom))>\(escape(atom.nucleus))</mo>"
        case .fraction:
            let frac = atom as? MTFraction
            let ruleAttr = (frac?.hasRule == false) ? " linethickness=\"0\"" : ""
            let core = "<mfrac\(ruleAttr)>\(renderMathRow(frac?.numerator))\(renderMathRow(frac?.denominator))</mfrac>"
            let left = frac?.leftDelimiter ?? ""
            let right = frac?.rightDelimiter ?? ""
            if !left.isEmpty || !right.isEmpty {
                let lTag = left.isEmpty ? "" : "<mo>\(escape(left))</mo>"
                let rTag = right.isEmpty ? "" : "<mo>\(escape(right))</mo>"
                base = "<mrow>\(lTag)\(core)\(rTag)</mrow>"
            } else {
                base = core
            }
        case .radical:
            let rad = atom as? MTRadical
            if let degree = rad?.degree {
                base = "<mroot>\(renderMathRow(rad?.radicand))\(renderMathRow(degree))</mroot>"
            } else {
                base = "<msqrt>\(renderMathRow(rad?.radicand))</msqrt>"
            }
        case .inner:
            let inner = atom as? MTInner
            let left = (inner?.leftBoundary?.nucleus).flatMap { $0.isEmpty ? nil : "<mo>\(escape($0))</mo>" } ?? ""
            let right = (inner?.rightBoundary?.nucleus).flatMap { $0.isEmpty ? nil : "<mo>\(escape($0))</mo>" } ?? ""
            base = "<mrow>\(left)\(renderMathList(inner?.innerList))\(right)</mrow>"
        case .overline:
            let over = atom as? MTOverLine
            base = "<mover>\(renderMathRow(over?.innerList))<mo>&#xAF;</mo></mover>"
        case .underline:
            let under = atom as? MTUnderLine
            base = "<munder>\(renderMathRow(under?.innerList))<mo>&#x332;</mo></munder>"
        case .accent:
            let acc = atom as? MTAccent
            base = "<mover accent=\"true\">\(renderMathRow(acc?.innerList))<mo>\(escape(acc?.nucleus ?? ""))</mo></mover>"
        case .space:
            if let mu = (atom as? MTMathSpace)?.space, mu > 0 {
                base = "<mspace width=\"\(String(format: "%.3g", Double(mu) / 18.0))em\"/>"
            } else {
                base = ""
            }
        case .style:
            base = ""
        case .color, .textcolor:
            let color = (atom as? MTMathColor)?.colorString ?? (atom as? MTMathTextColor)?.colorString ?? ""
            let inner = (atom as? MTMathColor)?.innerList ?? (atom as? MTMathTextColor)?.innerList
            base = "<mstyle mathcolor=\"\(attrEscape(color))\">\(renderMathList(inner))</mstyle>"
        case .colorBox:
            let box = atom as? MTMathColorbox
            base = "<mstyle mathbackground=\"\(attrEscape(box?.colorString ?? ""))\">\(renderMathList(box?.innerList))</mstyle>"
        case .table:
            guard let table = atom as? MTMathTable else { base = ""; break }
            var rows = ""
            for row in table.cells {
                var cols = ""
                for (colIdx, cell) in row.enumerated() {
                    let align: String
                    switch table.get(alignmentForColumn: colIdx) {
                    case .left: align = " columnalign=\"left\""
                    case .right: align = " columnalign=\"right\""
                    case .center: align = ""
                    }
                    cols += "<mtd\(align)>\(renderMathList(cell))</mtd>"
                }
                rows += "<mtr>\(cols)</mtr>"
            }
            base = "<mtable>\(rows)</mtable>"
        }

        guard !base.isEmpty else { return "" }
        let isLimitsOp = (atom as? MTLargeOperator)?.limits == true
        if let sub = atom.subScript, let sup = atom.superScript {
            let tag = isLimitsOp ? "munderover" : "msubsup"
            return "<\(tag)>\(base)\(renderMathRow(sub))\(renderMathRow(sup))</\(tag)>"
        } else if let sub = atom.subScript {
            let tag = isLimitsOp ? "munder" : "msub"
            return "<\(tag)>\(base)\(renderMathRow(sub))</\(tag)>"
        } else if let sup = atom.superScript {
            let tag = isLimitsOp ? "mover" : "msup"
            return "<\(tag)>\(base)\(renderMathRow(sup))</\(tag)>"
        }
        return base
    }

    /// LaTeX → PNG 데이터 — 메인 격리 밖의 순수 렌더. MathRenderer와 같은
    /// SwiftMath 파이프라인이지만 공유 캐시(NSImage 보관, 메인 전용)를 쓰지
    /// 않아 백그라운드 내보내기에서 안전하다 (#33).
    static func mathPNG(_ source: String) -> Data? {
        let (error, nsImage) = MathRenderer.uncachedImage(latex: source, color: .black, fontSize: 16)
        guard error == nil, let nsImage, nsImage.size.width > 0,
            let tiff = nsImage.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 실행마다 달라지는 HashValue 대신 안정 해시 — 같은 수식은 같은 파일명.
    static func stableHash(_ source: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 {
            h = (h ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// 원본 이미지를 OEBPS/images/로 복사하고 EPUB 내 상대경로를 돌려준다.
    /// 원격·차단 소스는 nil — 호출부가 주소 통과로 처리한다 (#12).
    /// 파일 위치는 반드시 미리 풀린 지도(`resolveAssetURLs`)에서만 읽는다 —
    /// 메인 격리 접근이 없어야 백그라운드 조립이 안전하다 (#33). 지도에 없는
    /// 로컬 소스는 누락으로 기록한다 (이슈 #15).
    private static func copyImage(
        _ src: String, into oebps: URL, missing: inout [String],
        assetURLs: [String: URL], assets: ProjectAssetCatalog?
    ) -> String? {
        let kind = ImageReferenceParser.classify(src)
        switch kind {
        case .managedRelative, .externalFile: break
        case .remote, .blocked: return nil
        }
        if let assets {
            guard let bytes = assets.data(for: src) else {
                if !missing.contains(src) { missing.append(src) }
                return nil
            }
            do {
                let dir = oebps.appendingPathComponent("images", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let source = URL(fileURLWithPath: src)
                var name = source.lastPathComponent
                var suffix = 1
                while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                    if try Data(contentsOf: dir.appendingPathComponent(name)) == bytes { return "images/\(name)" }
                    name = "\(source.deletingPathExtension().lastPathComponent)-\(suffix).\(source.pathExtension)"
                    suffix += 1
                }
                try bytes.write(to: ProjectPaths.checked(name, under: dir), options: .atomic)
                return "images/\(name)"
            } catch {
                if !missing.contains(src) { missing.append(src) }
                return nil
            }
        }
        guard let sourceURL = assetURLs[src] else {
            if !missing.contains(src) { missing.append(src) }
            return nil
        }
        if case .managedRelative(let path) = kind {
            // Recover the managed root from the trusted, pre-resolved map. A
            // background export must not follow links introduced after resolution.
            var root = sourceURL
            for _ in path.split(separator: "/") { root.deleteLastPathComponent() }
            guard let checked = PurloryImageStore.resolveURL(for: path, under: root),
                checked == sourceURL
            else {
                if !missing.contains(src) { missing.append(src) }
                return nil
            }
        }
        return copyFile(sourceURL, src: src, into: oebps, missing: &missing)
    }

    private static func copyFile(
        _ sourceURL: URL, src: String, into oebps: URL, missing: inout [String]
    ) -> String? {
        let dir = oebps.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = sourceURL.lastPathComponent
        let dest = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            guard (try? FileManager.default.copyItem(at: sourceURL, to: dest)) != nil else {
                if !missing.contains(src) { missing.append(src) }
                return nil
            }
        }
        return "images/\(name)"
    }

    /// `<img>` 한 줄 — alt는 리더·VoiceOver의 유일한 이미지 설명이고 title도
    /// 살린다 (이슈 #14). 속성값은 attrEscape 필수.
    private static func imageTag(src: String, attrs: ImageAttrs) -> String {
        let titlePart = attrs.title.map { " title=\"\(attrEscape($0))\"" } ?? ""
        return "<p class=\"image\"><img src=\"\(attrEscape(src))\""
            + " alt=\"\(attrEscape(attrs.alt))\"\(titlePart)/></p>\n"
    }

    // MARK: - 인라인 변환

    /// `&`·`<`·`>`만 이스케이프한다 — 따옴표를 남겨야 이스케이프 뒤에도
    /// `<font color="#…">` 태그를 알아볼 수 있다 (inline이 이어서 처리).
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 속성값용 — escape()와 달리 따옴표도 막는다 (alt·title 속성, 이슈 #14).
    private static func attrEscape(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 인라인 마크다운(굵게·기울임·코드·인라인 수식·`<font>` 색/크기)을 XHTML로 바꾼다.
    private static func inline(_ text: String) -> String {
        var working = text
        var fragments: [String] = []
        let tokenPrefix = "\u{E000}" + UUID().uuidString + ":"
        func reserve(_ html: String) -> String {
            let token = tokenPrefix + String(fragments.count) + "\u{E001}"
            fragments.append(html)
            return token
        }
        // Protect literal code and URL attributes before applying prose markers.
        // Replacements run backwards so source coordinates stay valid.
        var source = working as NSString
        for match in codeSpan.matches(in: working, range: fullRange(working)).reversed() {
            let html = "<code>" + escape(source.substring(with: match.range(at: 1))) + "</code>"
            working = (working as NSString).replacingCharacters(in: match.range, with: reserve(html))
        }
        source = working as NSString
        for match in inlineLink.matches(in: working, range: fullRange(working)).reversed() {
            let label = source.substring(with: match.range(at: 1))
            let destination = source.substring(with: match.range(at: 2))
            let html = "<a href=\"" + attrEscape(destination) + "\">" + inline(label) + "</a>"
            working = (working as NSString).replacingCharacters(in: match.range, with: reserve(html))
        }
        if working.contains("$") {
            let skipRanges = codeSpan.matches(in: working, range: fullRange(working)).map(\.range)
            let regions = MathScanner.regions(in: working, skipping: skipRanges)
            if !regions.isEmpty {
                let nsWorking = working as NSString
                var rebuilt = ""
                var cursor = 0
                for region in regions {
                    guard let math = mathML(region.latex, display: region.kind == .displayLine) else {
                        continue
                    }
                    rebuilt += nsWorking.substring(
                        with: NSRange(location: cursor, length: region.range.location - cursor))
                    rebuilt += reserve(math)
                    cursor = region.range.upperBound
                }
                rebuilt += nsWorking.substring(from: cursor)
                working = rebuilt
            }
        }
        var s = escape(working)
        // <font color size> → span style (이스케이프된 형태를 매칭).
        let ns = s as NSString
        var result = ""
        var cursor = 0
        for match in fontTag.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(
                location: cursor, length: match.range.location - cursor))
            let attrs = ns.substring(with: match.range(at: 1))
            let content = ns.substring(with: match.range(at: 2))
            var styles: [String] = []
            if let color = firstGroup(fontColorAttr, in: attrs) {
                styles.append("color:#\(color)")
            }
            if let size = firstGroup(fontSizeAttr, in: attrs) {
                styles.append("font-size:\(size)px")
            }
            result += "<span style=\"\(styles.joined(separator: ";"))\">\(content)</span>"
            cursor = match.range.upperBound
        }
        result += ns.substring(from: cursor)
        s = result
        // 마커 → 태그. 순서 중요: *** > ** > *.
        s = boldItalic.stringByReplacingMatches(
            in: s, range: fullRange(s), withTemplate: "<strong><em>$1</em></strong>")
        s = bold.stringByReplacingMatches(
            in: s, range: fullRange(s), withTemplate: "<strong>$1</strong>")
        s = italic.stringByReplacingMatches(
            in: s, range: fullRange(s), withTemplate: "<em>$1</em>")
        s = strikethrough.stringByReplacingMatches(
            in: s, range: fullRange(s), withTemplate: "<del>$1</del>")
        s = highlight.stringByReplacingMatches(
            in: s, range: fullRange(s), withTemplate: "<mark>$1</mark>")
        for (index, fragment) in fragments.enumerated().reversed() {
            s = s.replacingOccurrences(of: tokenPrefix + String(index) + "\u{E001}", with: fragment)
        }
        // Preserve native soft breaks without creating another XHTML paragraph.
        return s.replacingOccurrences(of: "\u{2028}", with: "<br />")
    }

    /// 제목용 — 마커·태그를 벗겨 순수 글자만 남긴다 (nav·opf에 들어간다).
    /// EntryStore의 태그 스트리퍼(비격리 순수 정규식)를 재사용한다.
    private static func plainTitle(_ text: String) -> String {
        let stripped = EntryStore.strippedInlineTags(text)
            .replacingOccurrences(of: #"[*`~=#]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "제목 없음" : stripped
    }

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(location: 0, length: (s as NSString).length)
    }

    private static func firstGroup(_ rx: NSRegularExpression, in text: String) -> String? {
        guard let match = rx.firstMatch(in: text, range: fullRange(text)) else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static let alignWrapper = try! NSRegularExpression(
        pattern: #"^<p align="(center|right)">([^\n]*)</p>$"#)
    private static let fontTag = try! NSRegularExpression(
        pattern: #"&lt;font ([^&]*)&gt;([^\n]*?)&lt;/font&gt;"#)
    private static let fontColorAttr = try! NSRegularExpression(
        pattern: ##"color="#([0-9A-Fa-f]{6})""##)
    private static let fontSizeAttr = try! NSRegularExpression(
        pattern: #"size="([0-9.]+)""#)
    private static let boldItalic = try! NSRegularExpression(
        pattern: #"(?<!\*)\*\*\*([^*\n]+)\*\*\*(?!\*)"#)
    private static let bold = try! NSRegularExpression(
        pattern: #"(?<!\*)\*\*([^*\n]+)\*\*(?!\*)"#)
    private static let italic = try! NSRegularExpression(
        pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
    private static let strikethrough = try! NSRegularExpression(
        pattern: #"(?<!~)~~([^~\n]+)~~(?!~)"#)
    private static let highlight = try! NSRegularExpression(
        pattern: #"(?<!=)==([^=\n]+)==(?!=)"#)
    private static let codeSpan = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`"#)
    private static let inlineLink = try! NSRegularExpression(
        pattern: #"(?<!\!)\[([^\[\]\n]+)\]\(([^)\s]+)\)"#)

    // MARK: - 패키지 문서들

    private static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    /// 소설다운 기본 조판 — 세리프·넉넉한 행간·들여쓰기 없는 문단 간격.
    private static let styleCSS = """
        html, body { margin: 0; padding: 0; }
        body { font-family: "Noto Serif KR", serif; line-height: 1.75; margin: 1em; overflow-wrap: break-word; }
        section { margin: 0; padding: 0; }
        h1 { font-size: 1.5em; margin: 0 0 1em; }
        h2 { font-size: 1.25em; margin: 1.4em 0 0.8em; }
        h3 { font-size: 1.1em; margin: 1.2em 0 0.6em; }
        h4, h5, h6 { font-size: 1em; margin: 1em 0 0.5em; }
        p { margin: 0 0 0.75em; }
        blockquote { color: #666; border-left: 3px solid #999; margin: 1em 0; padding-left: 1em; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.85em; }
        pre { background: #f2f2f2; padding: 0.8em; border-radius: 8px; overflow-x: auto; }
        hr { border: none; border-top: 1px solid #ccc; margin: 2em auto; width: 40%; }
        .math { text-align: center; margin: 1.2em 0; overflow-x: auto; }
        .image { text-align: center; margin: 1.2em 0; }
        img { max-width: 100%; height: auto; }
        """

    private static func chapterFile(_ index: Int) -> String { "chapter\(index).xhtml" }

    private static func chapterXHTML(_ chapter: Chapter) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ko" lang="ko">
        <head>
          <title>\(escape(chapter.title))</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
          <section epub:type="chapter">
            <h1>\(escape(chapter.title))</h1>
        \(chapter.html)
          </section>
        </body>
        </html>
        """
    }

    private static func navXHTML(bookTitle: String, chapters: [Chapter]) -> String {
        let items = chapters.enumerated()
            .map { "      <li><a href=\"\(chapterFile($0.offset))\">\(escape($0.element.title))</a></li>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ko" lang="ko">
            <head><title>\(escape(bookTitle))</title></head>
            <body>
              <nav epub:type="toc">
                <h1>목차</h1>
                <ol>
            \(items)
                </ol>
              </nav>
            </body>
            </html>
            """
    }

    /// OPF 패키지 문서. `private`가 아닌 이유는 저자 메타데이터를 zip 없이
    /// 단위 테스트로 고정하기 위해서다 (EpubMetadataTests). 순수 문자열 조립이라
    /// 비격리 — 백그라운드 내보내기에서도 안전하다 (#33).
    static func packageOPF(
        entry: JournalEntry, chapters: [Chapter], images: [String], author: String = ""
    ) -> String {
        packageOPF(entry: document(from: entry), chapters: chapters, images: images, author: author)
    }

    private static func packageOPF(
        entry: WritingDocument, chapters: [Chapter], images: [String], author: String = ""
    ) -> String {
        let modified: String = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: .now)
        }()
        // 저자 이름이 비면 `<dc:creator>` 자체를 넣지 않는다 — 빈 저자명은
        // 리더 서가에 "이름 없음"으로 남아 없는 것만 못하다.
        let creatorXML: String = {
            let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "" }
            return "\n    <dc:creator id=\"creator\">\(escape(name))</dc:creator>"
                + "\n    <meta refines=\"#creator\" property=\"role\""
                + " scheme=\"marc:relators\">aut</meta>"
        }()
        var manifest = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="css" href="style.css" media-type="text/css"/>"#,
        ]
        var spine: [String] = []
        for index in chapters.indices {
            let properties = chapters[index].html.contains("<math") ? " properties=\"mathml\"" : ""
            manifest.append(
                "<item id=\"ch\(index)\" href=\"\(chapterFile(index))\" media-type=\"application/xhtml+xml\"\(properties)/>")
            spine.append("<itemref idref=\"ch\(index)\"/>")
        }
        for (index, image) in images.enumerated() {
            manifest.append(
                "<item id=\"img\(index)\" href=\"\(image)\" media-type=\"\(mediaType(of: image))\"/>")
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="ko">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="pub-id">urn:uuid:\(entry.id.rawValue.uuidString.lowercased())</dc:identifier>
                <dc:title>\(escape(plainTitle(entry.title)))</dc:title>\(creatorXML)
                <dc:language>ko</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
              </metadata>
              <manifest>
                \(manifest.joined(separator: "\n    "))
              </manifest>
              <spine>
                \(spine.joined(separator: "\n    "))
              </spine>
            </package>
            """
    }

    private static func mediaType(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "tiff", "tif": "image/tiff"
        case "bmp": "image/bmp"
        default: "image/png"
        }
    }

    // MARK: - zip

    /// Thread-safe handoff for pipe data produced by a @Sendable drain closure.
    /// Both stdout and stderr must continue draining concurrently (#33).
    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static func runZip(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw ExportError.zipFailed(error.localizedDescription)
        }
        // 파이프를 **동시에 흡수**한다 — 장편(챕터 수천 개)의 zip 목록 출력이
        // 버퍼(64KB)를 채우면 zip은 쓰기가 막히고 waitUntilExit는 영원히 안 끝난다.
        // 과거 동기 readDataToEndOfFile 순서(대기→읽기)가 이 데드락을 품고 있었다 (#33).
        let stderrCapture = PipeCapture()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            stderrCapture.store(errPipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        process.waitUntilExit()
        drained.wait()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderrCapture.snapshot(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "zip 종료 코드 \(process.terminationStatus)"
            throw ExportError.zipFailed(message)
        }
    }

    /// 파일 이름에 쓸 수 없는 문자를 정리한다 (AppCommands와 같은 규칙).
    private static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "소설" : String(cleaned.prefix(60))
    }
}
