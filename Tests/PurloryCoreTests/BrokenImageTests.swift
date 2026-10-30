@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 깨진 이미지 플레이스홀더와 export 누락 보고 (이슈 #15).
///
/// 계약: 로드 실패는 원인(누락·손상·지원 불가)으로 분류돼 표면화되고,
/// export 전에 누락 목록이 검증되며, 원격 소스를 포함해 **어떤 콘텐츠도
/// 경고 없이 결과물에서 사라지지 않는다**.
final class BrokenImageTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let isolatedRoot = root
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(isolatedRoot) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(nil) }
        try? FileManager.default.removeItem(at: root)
    }

    private func writeAsset(_ name: String, _ data: Data) throws {
        try data.write(to: root.appendingPathComponent("images").appendingPathComponent(name))
    }

    // MARK: - 실패 분류

    @MainActor
    func test누락_손상_지원불가를구분한다() throws {
        // 누락 — 파일이 없다.
        XCTAssertEqual(ImageFailure.classify("images/gone.png"), .missing)
        // 손상 — 파일은 있지만 이미지로 해석되지 않는다.
        try writeAsset("junk.png", Data([0x00, 0x01, 0x02]))
        XCTAssertEqual(ImageFailure.classify("images/junk.png"), .corrupt)
        // 지원 불가 — 확장자가 목록 밖.
        try writeAsset("vector.svg", Data("<svg/>".utf8))
        XCTAssertEqual(ImageFailure.classify("images/vector.svg"), .unsupported)
    }

    @MainActor
    func test정상파일과원격소스는실패가아니다() throws {
        // 1×1 PNG — NSImage가 실제로 해석하는 최소 바이트.
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
        try writeAsset("ok.png", png)
        XCTAssertNil(ImageFailure.classify("images/ok.png"))
        // 원격·차단은 로드 판정 대상이 아니다 (#12).
        XCTAssertNil(ImageFailure.classify("https://example.com/x.png"))
        XCTAssertNil(ImageFailure.classify(""))
    }

    @MainActor
    func test플레이스홀더는렌더가능한이미지를만든다() {
        let image = ImageFailure.placeholder(
            reason: .missing, alt: "주인공 초상", path: "images/gone.png", theme: .light)
        XCTAssertTrue(image.size.width > 100)
        XCTAssertTrue(image.size.height > 50)
        // TIFF로 렌더링 가능해야 화면에 그려진다.
        XCTAssertNotNil(image.tiffRepresentation)
    }

    // MARK: - export 전 누락 검증

    @MainActor
    func test누락스캔은인라인과정의줄을모두잡고펜스와원격은제외한다() throws {
        try writeAsset("have.png", Data([0x89]))
        let body = """
        ![있음](images/have.png)

        ![없음](images/lost.png)

        ![축약][g]

        [g]: images/gone-ref.png

        ```
        ![펜스](images/fenced.png)
        ```

        ![웹](https://example.com/w.png)

        ![없음2](images/lost.png)
        """
        XCTAssertEqual(
            ImageAssetScanner.missingSources(in: body),
            ["images/lost.png", "images/gone-ref.png"])
    }

    @MainActor
    func test모두있으면누락목록이비어게이트를통과한다() throws {
        try writeAsset("a.png", Data([0x89]))
        let body = "![a](images/a.png)\n\n![웹](https://example.com/x.png)"
        XCTAssertEqual(ImageAssetScanner.missingSources(in: body), [])
        // UI 없이 게이트 논리만 — 빈 목록이면 true.
        XCTAssertTrue(ImageAssetScanner.confirmContinueDespiteMissing(in: body))
    }

    // MARK: - EPUB에서 조용한 생략 금지

    @MainActor
    func testEPUB누락은보고되고원격은주소그대로살아남는다() throws {
        let oebps = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-epub-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        let entry = JournalEntry(
            title: "소설",
            body: """
            ![없는 그림](images/gone.png)

            ![웹 그림](https://example.com/web.png)
            """)
        var collected: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: entry, copyingImagesInto: oebps, collected: &collected, missing: &missing, assetURLs: EpubExporter.resolveAssetURLs(in: entry.body))

        XCTAssertEqual(missing, ["images/gone.png"], "누락이 조용히 생략됐다")
        let html = chapters[0].html
        // 원격은 주소 그대로 — 결과물에서 사라지지 않는다.
        XCTAssertTrue(html.contains(#"src="https://example.com/web.png""#), html)
        XCTAssertTrue(html.contains(#"alt="웹 그림""#), html)
        // 누락 파일의 태그는 없다 — 제외됐으나 위 missing으로 보고됐다.
        XCTAssertFalse(html.contains("gone.png"), html)
    }
}
