@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 이미지 alt·title·확장 속성의 편집·EPUB 왕복 보존 (이슈 #14).
///
/// 계약: `![alt](src "title"){width=NN custom=x}` 형태에서 정렬·리사이즈로
/// 속성을 다시 써도 alt/title/미지 속성이 살아남고, 신규 합성은 CommonMark
/// 규칙으로 이스케이프되며, EPUB `<img>`에 alt·title이 실린다.
final class ImageMetadataTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(
            to: root.appendingPathComponent("images").appendingPathComponent("a.png"))
        let isolatedRoot = root
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(isolatedRoot) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(nil) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 파싱 (미지 확장 속성)

    @MainActor
    func test이슈재현_미지속성줄도이미지로파싱된다() throws {
        // 과거 splitOptions는 모르는 토큰이 있으면 옵션 블록째 거부해 이 줄이
        // 아예 일반 문장이 됐다.
        let attrs = BlockTextView.imageAttrs(
            from: #"![주인공 초상](images/a.png "설명"){width=80 custom=x}"#)
        XCTAssertNotNil(attrs)
        XCTAssertEqual(attrs?.src, "images/a.png")
        XCTAssertEqual(attrs?.alt, "주인공 초상")
        XCTAssertEqual(attrs?.title, "설명")
        XCTAssertEqual(attrs?.width, 80)
        XCTAssertEqual(attrs?.extraOptions, ["custom=x"])
    }

    @MainActor
    func test미지속성여러개는원래순서대로보관된다() {
        let attrs = BlockTextView.imageAttrs(
            from: "![a](images/a.png){custom=z foo=bar width=50}")
        XCTAssertEqual(attrs?.extraOptions, ["custom=z", "foo=bar"])
    }

    @MainActor
    func test문장뒤중괄호꾸미기는여전히이미지가아니다() {
        // 옵션 검증을 늦추면서 문단 규칙(뒤 텍스트 금지)이 무너졌는지 확인.
        XCTAssertNil(BlockTextView.imageAttrs(from: "![a](images/x.png) 각주 {note=1}"))
        // 값에 공백·형용 불능 토큰은 확장으로 인정하지 않는다.
        XCTAssertNil(BlockTextView.imageAttrs(from: "![a](images/x.png){각주}"))
        XCTAssertNil(BlockTextView.imageAttrs(from: "![a](images/x.png){bad key=1}"))
    }

    // MARK: - 재작성 왕복 (정렬·리사이즈 후 정보 유지)

    @MainActor
    func test정렬바꿔도미지속성과타이틀이살아남는다() throws {
        let original = #"![주인공 초상](images/a.png "설명"){width=80 custom=x}"#
        var attrs = try XCTUnwrap(BlockTextView.imageAttrs(from: original))
        attrs.align = "right"
        let rewritten = attrs.markdown

        let again = try XCTUnwrap(BlockTextView.imageAttrs(from: rewritten))
        XCTAssertEqual(again.alt, "주인공 초상")
        XCTAssertEqual(again.title, "설명")
        XCTAssertEqual(again.width, 80)
        XCTAssertEqual(again.align, "right")
        XCTAssertEqual(again.extraOptions, ["custom=x"])
        XCTAssertTrue(rewritten.contains("custom=x"))
    }

    @MainActor
    func test리사이즈와재작성을거듭해도왕복이무손실이다() throws {
        let original = #"![표지](<images/my photo.png> "첫 장면"){align=left tag=1}"#
        var attrs = try XCTUnwrap(BlockTextView.imageAttrs(from: original))
        attrs.width = 40  // 리사이즈
        var second = try XCTUnwrap(BlockTextView.imageAttrs(from: attrs.markdown))
        second.align = "center"  // 다시 정렬
        let final = second.markdown

        let parsed = try XCTUnwrap(BlockTextView.imageAttrs(from: final))
        XCTAssertEqual(parsed.alt, "표지")
        XCTAssertEqual(parsed.title, "첫 장면")
        XCTAssertEqual(parsed.src, "images/my photo.png")
        XCTAssertEqual(parsed.width, 40)
        XCTAssertEqual(parsed.align, "center")
        XCTAssertEqual(parsed.extraOptions, ["tag=1"])
    }

    // MARK: - 신규 합성 이스케이프

    @MainActor
    func test신규합성은특수문자를이스케이프해파서로돌아온다() throws {
        var attrs = ImageAttrs(src: "my x]y.png", alt: "a]b 그림", title: #"he said "hi""#)
        attrs.width = 60
        let line = attrs.markdown  // optionsPrefix 없음 — 합성 경로

        let parsed = try XCTUnwrap(BlockTextView.imageAttrs(from: line))
        XCTAssertEqual(parsed.alt, "a]b 그림")
        XCTAssertEqual(parsed.src, "my x]y.png")
        XCTAssertEqual(parsed.title, #"he said "hi""#)
        XCTAssertEqual(parsed.width, 60)
    }

    @MainActor
    func test합성경로에공백있으면꺾쇠destination으로감쌌다가풀린다() throws {
        let attrs = ImageAttrs(src: "images/spaced name.png", alt: "사진")
        let line = attrs.markdown
        XCTAssertTrue(line.contains("<images/spaced name.png>"))

        let parsed = try XCTUnwrap(BlockTextView.imageAttrs(from: line))
        XCTAssertEqual(parsed.src, "images/spaced name.png")
        XCTAssertEqual(parsed.alt, "사진")
    }

    // MARK: - EPUB 반영

    @MainActor
    func testEPUB이미지태그에alt와title이실린다() throws {
        let oebps = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-epub-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        let entry = JournalEntry(
            title: "소설",
            body: #"![주인공 <초상>](images/a.png "설명"){width=80}"#)
        var collected: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: entry, copyingImagesInto: oebps, collected: &collected, missing: &missing, assetURLs: EpubExporter.resolveAssetURLs(in: entry.body))

        let html = chapters[0].html
        XCTAssertTrue(html.contains(#"alt="주인공 &lt;초상&gt;""#), html)
        XCTAssertTrue(html.contains(#"title="설명""#), html)
    }
}
