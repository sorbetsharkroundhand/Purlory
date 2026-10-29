@testable import PurloryDocumentEngine
@testable import PurloryStorage
import AppKit
import XCTest

@testable import PurloryCore

/// 수식 왕복 무결성 (이슈 #20) — load→edit→serialize→reload에서 source가
/// 한 글자도 변하지 않는다는 것을 golden으로 고정한다. 직렬화는 저장 경로다.
final class MathRoundTripTests: XCTestCase {
    @MainActor
    func testProjectExportPreservesMathSource() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.documents[0].body = "![그림](images/a.png){width=60}\n\n$x^2$\n\n$$\ny=2x\n$$\n"
        try await store.save(project)
        let catalog = try await store.assetCatalog(id: project.id)
        let view = makeEditor()
        view.projectAssetCatalog = catalog
        view.load(markdown: project.documents[0].body)
        XCTAssertEqual(view.serialize(), "![그림](images/a.png){width=60}\n\n$x^2$\n\n$$\ny=2x\n$$\n")
        let destination = root.appendingPathComponent("math.md")
        try MarkdownExporter.export(project.documents[0], assets: catalog, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "![그림](images/a.png){width=60}\n\n$x^2$\n\n$$\ny=2x\n$$\n")
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    @MainActor
    private func makeEditor() -> BlockTextView {
        let storage = NSTextStorage()
        let layoutManager = PurloryLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: container)
        storage.delegate = view
        view.allowsUndo = true

        // 창에 넣어야 undoManager가 생긴다 (앱과 같은 조건).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        windows.append(window)
        return view
    }

    @MainActor
    private func assertRoundTrip(
        _ markdown: String, _ message: String = "", file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let view = makeEditor()
        view.load(markdown: markdown)
        XCTAssertEqual(view.serialize(), markdown, message, file: file, line: line)
        // reload → 재직렬화도 동일해야 한다 (2차 왕복).
        view.load(markdown: view.serialize())
        XCTAssertEqual(view.serialize(), markdown, "재적재 후에도 동일", file: file, line: line)
    }

    // MARK: 다중 행 display 그룹

    @MainActor func testComplexPastedMathRendersWithoutChangingSavedSource() throws {
        let markdown = "# Formula\n\n$$\n" + ComplexMathFixture.pasted + "\n$$\n\nBody"
        let view = makeEditor()
        view.load(markdown: markdown)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.refreshRenderedBlocks(forceRender: true)
        XCTAssertEqual(view.mathRenders.count, 1, "Nested environments form one displayed equation")
        XCTAssertTrue(view.mathRenderErrors.isEmpty)
        XCTAssertEqual(view.serialize(), markdown)
        view.load(markdown: view.serialize())
        XCTAssertEqual(view.serialize(), markdown)
        XCTAssertEqual(view.mathRenders.count, 1)
    }

    @MainActor func testComplexPastedMathExportsAnImageWithOriginalLatexFallback() throws {
        let latex = ComplexMathFixture.pasted
        let entry = JournalEntry(title: "Formula", body: "$$\n" + latex + "\n$$")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("purlory-complex-math-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var images: [String] = [], missing: [String] = []
        let chapters = EpubExporter.makeChapters(from: entry, copyingImagesInto: directory,
            collected: &images, missing: &missing, assetURLs: [:])
        let html = chapters.map(\.html).joined(separator: "\n")
        XCTAssertTrue(html.contains(#"<p class="math"><math xmlns="http://www.w3.org/1998/Math/MathML" display="block""#))
        XCTAssertTrue(html.contains("<mtable>"))
        XCTAssertTrue(html.contains("<mfrac>"))
        XCTAssertTrue(html.contains(latex.replacingOccurrences(of: "&", with: "&amp;")), "The fallback must preserve every original backslash")
        XCTAssertTrue(images.isEmpty)
        XCTAssertTrue(missing.isEmpty)
    }

    @MainActor func test다중행_aligned_왕복() {
        assertRoundTrip(
            """
            # 3장

            $$
            \\begin{aligned}
            a &= b \\\\
            c &= d
            \\end{aligned}
            $$

            본문이 이어진다.
            """)
    }

    @MainActor func test다중행_cases_왕복() {
        assertRoundTrip(
            """
            $$
            f(x)=
            \\begin{cases}
            x & x \\geq 0 \\\\
            -x & x < 0
            \\end{cases}
            $$
            """)
    }

    @MainActor func test다중행_여는줄에_내용이_붙은_형태() {
        assertRoundTrip("$$x\ny\n$$")
    }

    @MainActor func test다중행_닫는줄에_내용이_붙은_형태() {
        assertRoundTrip("$$\nx\ny$$")
    }

    @MainActor func test다중행_빈_그룹() {
        assertRoundTrip("$$\n$$")
    }

    @MainActor func test다중행_그룹속성_위치() throws {
        let view = makeEditor()
        view.load(markdown: "$$\na\nb\nc\n$$")
        let ns = view.string as NSString
        var locations: [(Int, String?)] = []
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = para.upperBound
            guard para.location < ns.length else { break }
            let attrs = view.textStorage?.attributes(at: para.location, effectiveRange: nil)
            locations.append((para.location, attrs?[.purloryMathDelim] as? String))
        }
        XCTAssertEqual(locations.count, 5, "$$·a·b·c·$$는 문단 다섯")
        XCTAssertEqual(locations[0].1, "open", "첫 문단이 열기")
        XCTAssertEqual(locations[1].1, "mid")
        XCTAssertEqual(locations[3].1, "mid")
        XCTAssertEqual(locations[4].1, "close", "마지막 문단이 닫기")
    }

    @MainActor func test파일끝에서_닫히지않은_그룹도_그대로다() {
        let view = makeEditor()
        view.load(markdown: "머리말\n$$\na\nb")
        let serialized = view.serialize()
        XCTAssertEqual(
            serialized, "머리말\n$$\na\nb",
            "미종결 그룹도 원문이 그대로 보존된다 — 정규화로 글자를 만들지 않는다")
        // 재왕복 안정.
        view.load(markdown: serialized)
        XCTAssertEqual(view.serialize(), serialized)
    }

    // MARK: 단독 완결 수식 — 기존 동작 유지 + 그룹 미병합

    @MainActor func test단독수식_두줄은_서로_독립이다() throws {
        let markdown = "$$a$$\n$$b$$"
        assertRoundTrip(markdown)
        let view = makeEditor()
        view.load(markdown: markdown)
        // 인접한 단독 수식은 하나의 그룹으로 묶이면 안 된다 — 시각적으로도
        // 두 박스가 유지되고 serialize도 두 줄을 유지한다.
        let ns = view.string as NSString
        var paras: [(range: NSRange, block: PurloryBlock, open: Bool, close: Bool)] = []
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = para.upperBound
            let attrs = view.textStorage?.attributes(at: para.location, effectiveRange: nil)
            let block = (attrs?[.purloryBlock] as? String).flatMap(PurloryBlock.init(rawValue:)) ?? .p
            let delim = attrs?[.purloryMathDelim] as? String ?? ""
            paras.append((para, block, delim == "open", delim == "close"))
        }
        XCTAssertEqual(BlockTextView.mathGroupRanges(paras), [])
    }

    @MainActor func test수식과_헤딩사이_그룹() {
        assertRoundTrip("# 장\n$$\nmatrix\n$$\n# 다음 장")
    }

    // MARK: 인라인 수식 원자

    @MainActor func test인라인수식_원자전환후_왕복() {
        let markdown = "힘은 $E=mc^2$이라고 썼다."
        let view = makeEditor()
        view.load(markdown: markdown)
        // storage엔 attachment 글자(U+FFFC)로 존재한다.
        XCTAssertEqual(view.string.reduce(0) { $0 + ($1 == "\u{FFFC}" ? 1 : 0) }, 1)
        // 저장은 원문 그대로.
        XCTAssertEqual(view.serialize(), markdown)
    }

    @MainActor func test인라인수식_한글주변_복수() {
        let markdown = "값 $a_1$과 $b_2$를 비교"
        let view = makeEditor()
        view.load(markdown: markdown)
        XCTAssertEqual(view.serialize(), markdown)
        let count = view.string.reduce(0) { $0 + ($1 == "\u{FFFC}" ? 1 : 0) }
        XCTAssertEqual(count, 2)
    }

    @MainActor func test통화와_이스케이프는_원자가_아니다() {
        let markdown = #"5달러($5)와 \$10, 공식은 $x$다."#
        let view = makeEditor()
        view.load(markdown: markdown)
        let count = view.string.reduce(0) { $0 + ($1 == "\u{FFFC}" ? 1 : 0) }
        XCTAssertEqual(count, 1, "통화·이스케이프가 아닌 $x$ 하나만 원자다")
        XCTAssertEqual(view.serialize(), markdown)
    }

    @MainActor func test코드펜스안의_달러는_건드리지않는다() {
        // 문서 끝 코드펜스의 후행 개행 추가는 기존 직렬화 관습
        // (SerializationTests.testCodeBlock_knownTrailingNewline)을 따른다.
        let view = makeEditor()
        view.load(markdown: "```\n$x$와 $$y$$\n```")
        let count = view.string.reduce(0) { $0 + ($1 == "\u{FFFC}" ? 1 : 0) }
        XCTAssertEqual(count, 0, "코드 블록은 문자 그대로다")
        XCTAssertEqual(view.serialize(), "```\n$x$와 $$y$$\n```\n")
    }

    @MainActor func test목록과_인용안의_인라인수식() {
        let markdown = "- 값은 $v$다.\n> 속도 $s=vt$ 공식."
        let view = makeEditor()
        view.load(markdown: markdown)
        XCTAssertEqual(view.serialize(), markdown)
    }

    @MainActor func test커서가떠나면_raw스팬이_원자로_접힌다() {
        let view = makeEditor()
        view.load(markdown: "첫 문단\n둘째 문단")
        // 붙여넣기를 흉내 — 마지막 문단 **안**에 raw `$y^2$`를 넣고 커서는 맨 앞에 둔다.
        let ns = view.string as NSString
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.textStorage?.replaceCharacters(
            in: NSRange(location: ns.length, length: 0), with: "값 $y^2$임")
        view.mayHaveInlineMathForTesting = true
        view.refreshRenderedBlocks()
        XCTAssertEqual(
            view.serialize(),
            "첫 문단\n둘째 문단값 $y^2$임",
            "원자로 접혀도 저장 텍스트는 동일하다")
        let count = view.string.reduce(0) { $0 + ($1 == "\u{FFFC}" ? 1 : 0) }
        XCTAssertEqual(count, 1)
    }

    // MARK: 그룹 판정 순수 헬퍼

    @MainActor func test그룹판정_열기없는_연속수식은_그룹이아니다() {
        let p = NSRange(location: 0, length: 3)
        let q = NSRange(location: 4, length: 3)
        let groups = BlockTextView.mathGroupRanges([
            (p, .math, false, false),
            (q, .math, false, false),
        ])
        XCTAssertEqual(groups, [])
    }

    @MainActor func test그룹판정_미종결_그룹은_수식이_끊길때까지() {
        let a = NSRange(location: 0, length: 3)
        let b = NSRange(location: 4, length: 3)
        let c = NSRange(location: 8, length: 5)
        let groups = BlockTextView.mathGroupRanges([
            (a, .math, true, false),
            (b, .math, false, false),
            (c, .p, false, false),
        ])
        XCTAssertEqual(groups, [NSRange(location: 0, length: 7)])
    }

    // MARK: Fuzz

    /// 무작위 문서 퍼즈 — 첫 직렬화 이후 문서가 **고정점**에 도달하고(재왕복 안정),
    /// 크래시가 없으며, `$`가 아닌 글자는 순서 그대로 보존된다는 약한 불변식을
    /// 검증한다 (이슈 #20 완료 조건 — golden/fuzz). 결정적 시드라 재현 가능.
    @MainActor func test수식_퍼즈_고정점과_글자보존() {
        let tokens = [
            "본문", "한글문장", " ", "\n", "\n\n", "$", "$$", "$x$", "$E=mc^2$",
            #"\$"#, "$5와", "$10", "$$\na\n$$", "```\n$x$\n```\n", "# 장\n",
            "- 목록 $v$\n", "> 인용 $q$\n", "---\n", "값 $a_1$과 $b_2$다\n",
        ]
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let view = makeEditor()
        for iteration in 0..<300 {
            var doc = ""
            for _ in 0..<(1 + next(14)) { doc += tokens[next(tokens.count)] }
            // 펜스가 홀수 개면 직렬화가 닫는 펜스를 보태 **정규화**한다 — 기존
            // 코드블록 관습(SerializationTests 후행 개행 비대칭)과 같은 계열이라
            // 이 경우엔 한 번 정규화된 뒤의 안정성만 요구한다.
            let standaloneFences = doc.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) == "```" }.count
            let balanced = standaloneFences % 2 == 0

            view.load(markdown: doc)
            let first = view.serialize()
            view.load(markdown: first)
            let second = view.serialize()
            if balanced {
                XCTAssertEqual(
                    second, first,
                    "iteration \(iteration): 재왕복이 흔들린다\n원문: \(doc.debugDescription)\n1차: \(first.debugDescription)\n2차: \(second.debugDescription)")
            } else {
                view.load(markdown: second)
                let third = view.serialize()
                XCTAssertEqual(
                    third, second,
                    "iteration \(iteration): 정규화 1회 뒤 고정점이 아니다\n원문: \(doc.debugDescription)\n2차: \(second.debugDescription)\n3차: \(third.debugDescription)")
            }
            // `$` 외 글자의 순서 보존 — 원자 전환·그룹 구분자 처리가 내용을
            // 지우거나 재배열하지 않는다는 약한 불변식.
            func letters(_ s: String) -> String {
                s.filter { !$0.isWhitespace && $0 != "$" && !"\\`#->-[](){}!".contains($0) }
                    .map(String.init).joined()
            }
            XCTAssertEqual(
                letters(second), letters(doc),
                "iteration \(iteration): 글자 손실·재배열\n원문: \(doc.debugDescription)\n결과: \(second.debugDescription)")
        }
    }

    // MARK: EPUB

    /// 이슈 #22 — 수식은 EPUB 3 네이티브 MathML로 변환되고 LaTeX 원문은 alttext fallback으로 남는다.
    @MainActor func testEPUB_다중행수식_PNG와altfallback() throws {
        let entry = JournalEntry(
            title: "소설",
            body: "# 1장\n$$\n\\begin{aligned}\na &= b\n\\end{aligned}\n$$\n본문")
        let oebps = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-math-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: oebps) }
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        var images: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: entry, copyingImagesInto: oebps,
            collected: &images, missing: &missing, assetURLs: EpubExporter.resolveAssetURLs(in: entry.body))
        let html = chapters.map(\.html).joined(separator: "\n")

        // 네이티브 MathML + LaTeX alttext fallback
        XCTAssertTrue(html.contains(#"<p class="math"><math xmlns="http://www.w3.org/1998/Math/MathML" display="block""#), html)
        XCTAssertTrue(html.contains("<mtable>"), html)
        XCTAssertTrue(html.contains("LaTeX: "), html)
        XCTAssertTrue(html.contains("\\begin{aligned}"), html)
        XCTAssertTrue(html.contains("a &amp;= b"), "줄이 alttext에서 보존된다")
        XCTAssertFalse(html.contains("<pre><code>$$"), "구분자 줄이 코드블록으로 새면 안 된다")
        XCTAssertTrue(images.isEmpty)
        let opf = EpubExporter.packageOPF(entry: entry, chapters: chapters, images: images)
        XCTAssertTrue(opf.contains(#"properties="mathml""#), opf)
    }

    @MainActor func testEPUB_한줄수식도PNG로() throws {
        let entry = JournalEntry(title: "소설", body: "# 1장\n$$E=mc^2$$\n인라인 $x^2$ 수식")
        let oebps = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-math-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: oebps) }
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        var images: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: entry, copyingImagesInto: oebps,
            collected: &images, missing: &missing, assetURLs: EpubExporter.resolveAssetURLs(in: entry.body))
        let html = chapters.map(\.html).joined(separator: "\n")

        XCTAssertTrue(html.contains(#"alttext="LaTeX: E=mc^2""#), html)
        XCTAssertTrue(html.contains(#"display="inline" alttext="LaTeX: x^2""#), html)
        XCTAssertTrue(html.contains("<msup><mi>c</mi><mn>2</mn></msup>"), html)
        XCTAssertTrue(html.contains("<msup><mi>x</mi><mn>2</mn></msup>"), html)
        XCTAssertTrue(images.isEmpty)
    }

    /// 렌더가 불가능한 LaTeX는 code 소스로 남아 의미가 사라지지 않는다 (#15 승계).
    @MainActor func testEPUB_렌더불가수식은code소스보존() throws {
        let entry = JournalEntry(title: "소설", body: "# 1장\n$$\\frac{1{$$")
        let oebps = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-math-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: oebps) }
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        var images: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: entry, copyingImagesInto: oebps,
            collected: &images, missing: &missing, assetURLs: EpubExporter.resolveAssetURLs(in: entry.body))
        let html = chapters.map(\.html).joined(separator: "\n")

        XCTAssertTrue(html.contains("<p class=\"math\"><code>"), html)
        XCTAssertTrue(images.isEmpty)
    }
}
