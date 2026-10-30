@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
@testable import PurloryStorage
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// Markdown 내보내기의 asset 복사·경로 재작성 회귀 (이슈 #13).
///
/// 계약: load→export→(외부 도구 규칙으로 재해석) 왕복에서 이미지 내용과
/// 메타데이터(title·{옵션})가 무손실이고, 충돌 없는 상대경로로 재작성되며,
/// 원격·차단 소스는 로컬 파일로 오해되지 않는다(#12 정책 승계).
final class MarkdownExporterTests: XCTestCase {
    // Catches global-root reads, lost literal markup/newlines, and missing copied project bytes.
    @MainActor
    func testProjectResolverExportsImageBytes() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        var project = projectFixture()
        project.documents[0].body = "![그림](images/a.png){width=60}\n"
        try await store.save(project)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        let catalog = try await store.assetCatalog(id: project.id)
        try seedAsset("a.png", Data([9]))
        let destination = exportDir.appendingPathComponent("project.md")
        let report = try MarkdownExporter.export(project.documents[0], assets: catalog, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "![그림](images/a.png){width=60}\n")
        XCTAssertEqual(try Data(contentsOf: exportDir.appendingPathComponent("images/a.png")), Data([1, 2, 3]))
        XCTAssertEqual(report.copiedAssets, 1)
    }

    private var purloryRoot: URL!        // Purlory 폴더 대역 (override)
    private var exportDir: URL!       // 임의 목적지 대역

    /// 내용 비교용 바이트 — asset마다 다르게 쓴다.
    private let pngA = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    private let pngB = Data([0x89, 0x50, 0x4E, 0x47, 0x02])

    override func setUpWithError() throws {
        purloryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-mdexp-src-\(UUID().uuidString)", isDirectory: true)
        exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-mdexp-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: purloryRoot.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        // XCTest setup은 메인 스레드에서 실행된다.
        let isolatedRoot = purloryRoot
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(isolatedRoot) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(nil) }
        try? FileManager.default.removeItem(at: purloryRoot)
        try? FileManager.default.removeItem(at: exportDir)
    }

    private func seedAsset(_ name: String, _ data: Data) throws {
        try data.write(to: purloryRoot.appendingPathComponent("images").appendingPathComponent(name))
    }

    /// 목적지 쪽에 미리 심어 둘 파일 (충돌 시나리오용).
    private func seedDestAsset(_ name: String, _ data: Data) throws {
        try FileManager.default.createDirectory(
            at: exportDir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try data.write(to: exportDir.appendingPathComponent("images").appendingPathComponent(name))
    }

    @MainActor
    private func export(_ body: String, fileName: String = "소설.md") throws ->
        (url: URL, report: MarkdownExporter.Report, text: String) {
            let entry = JournalEntry(title: "테스트 소설", body: body)
            let url = exportDir.appendingPathComponent(fileName)
            let report = try MarkdownExporter.export(entry, to: url)
            let text = try String(contentsOf: url, encoding: .utf8)
            return (url, report, text)
    }

    // MARK: - 관리 asset 복사

    @MainActor
    func test관리이미지를복사해참조를살린다() throws {
        try seedAsset("a.png", pngA)
        let result = try export("# 1장\n\n![표지](images/a.png)\n\n본문")

        XCTAssertEqual(result.report.copiedAssets, 1)
        XCTAssertEqual(result.report.rewrittenReferences, 0)
        // 복사된 바이트가 원본과 동일하다.
        let copied = try Data(contentsOf: exportDir.appendingPathComponent("images/a.png"))
        XCTAssertEqual(copied, pngA)
        // 참조 텍스트는 그대로 — images/ 접두가 이미 목적지 기준 상대경로다.
        XCTAssertTrue(result.text.contains("![표지](images/a.png)"))
    }

    @MainActor
    func test이름충돌은접미사로피하고참조를재작성한다() throws {
        try seedAsset("a.png", pngA)
        // 목적지에 같은 이름·다른 내용의 파일을 심어 둔다.
        try seedDestAsset("a.png", pngB)

        let result = try export("![표지](images/a.png)")

        XCTAssertEqual(result.report.copiedAssets, 1)
        XCTAssertEqual(result.report.rewrittenReferences, 1)
        XCTAssertTrue(result.text.contains("](images/a-1.png)"))
        // 기존 파일은 덮어쓰지 않는다 — 목적지의 원래 자산 보존.
        XCTAssertEqual(try Data(contentsOf: exportDir.appendingPathComponent("images/a.png")), pngB)
        XCTAssertEqual(
            try Data(contentsOf: exportDir.appendingPathComponent("images/a-1.png")), pngA)
    }

    @MainActor
    func test같은내용충돌은복사없이재사용한다() throws {
        try seedAsset("a.png", pngA)
        try seedDestAsset("a.png", pngA)

        let first = try export("![표지](images/a.png)")
        XCTAssertEqual(first.report.copiedAssets, 0)
        XCTAssertEqual(first.report.reusedAssets, 1)
        XCTAssertTrue(first.text.contains("](images/a.png)"))

        // 재내보내기 멱등성 — 같은 입력은 같은 출력.
        let again = try export("![표지](images/a.png)")
        XCTAssertEqual(again.text, first.text)
    }

    @MainActor
    func test같은소스여러참조는한번만복사한다() throws {
        try seedAsset("a.png", pngA)
        let result = try export("""
        ![첫](images/a.png)

        ![둘](images/a.png)
        """)
        XCTAssertEqual(result.report.copiedAssets, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: exportDir.appendingPathComponent("images"), includingPropertiesForKeys: nil
            ).count, 1)
    }

    // MARK: - 누락·원격·차단 정책

    @MainActor
    func test누락원본은경고하고참조와목적지를보존한다() throws {
        let result = try export("![유령](images/gone.png)")

        XCTAssertEqual(result.report.missingSources, ["images/gone.png"])
        XCTAssertTrue(result.text.contains("![유령](images/gone.png)"))
        // 복사할 게 없으면 images/ 폴더를 만들지 않는다 — 임의 목적지 보호.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("images").path))
    }

    @MainActor
    func test원격과차단소스는주소그대로둔다() throws {
        try seedAsset("a.png", pngA)
        let result = try export("""
        ![웹](https://example.com/x.png)

        ![데이터](data:image/png;base64,AAAA)

        ![관리](images/a.png)
        """)
        XCTAssertTrue(result.text.contains("(https://example.com/x.png)"))
        XCTAssertTrue(result.text.contains("(data:image/png;base64,AAAA)"))
        XCTAssertEqual(result.report.remoteCount, 1)
        XCTAssertEqual(result.report.blockedCount, 1)
        XCTAssertEqual(result.report.copiedAssets, 1)  // 관리 것만
    }

    @MainActor
    func test외부절대경로파일도함께복사한다() throws {
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-ext-\(UUID().uuidString).png")
        try pngB.write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }

        let result = try export("![바깥](\(external.path))")

        XCTAssertEqual(result.report.copiedAssets, 1)
        XCTAssertEqual(result.report.rewrittenReferences, 1)
        let newName = external.lastPathComponent
        XCTAssertEqual(
            try Data(contentsOf: exportDir.appendingPathComponent("images").appendingPathComponent(newName)),
            pngB)
        XCTAssertTrue(result.text.contains("](images/\(newName))"))
    }

    // MARK: - 문법별 왕복 보존

    @MainActor
    func test타이틀과중괄호옵션과꺾쇠가보존된다() throws {
        try seedAsset("spaced y.png", pngA)
        try seedDestAsset("spaced y.png", pngB)

        let result = try export(#"![표지](<images/spaced y.png> "제목"){width=50 align=left}"#)

        XCTAssertEqual(result.report.rewrittenReferences, 1)
        XCTAssertEqual(
            result.text,
            #"![표지](<images/spaced y-1.png> "제목"){width=50 align=left}"#)
    }

    @MainActor
    func test참조형정의줄을재작성하고파서로왕복된다() throws {
        try seedAsset("ref.png", pngA)
        try seedDestAsset("ref.png", pngB)

        let result = try export("""
        ![표지][r1]

        [r1]: images/ref.png
        """)

        XCTAssertEqual(result.report.copiedAssets, 1)
        XCTAssertEqual(result.report.rewrittenReferences, 1)
        XCTAssertTrue(result.text.contains("[r1]: images/ref-1.png"))
        XCTAssertTrue(result.text.contains("![표지][r1]"))
        // 외부 도구처럼 다시 읽었을 때 참조가 실제 파일로 해석된다.
        let defs = ImageReferenceParser.collectDefinitions(in: result.text)
        let parsed = ImageReferenceParser.parse("![표지][r1]", definitions: defs)
        XCTAssertEqual(parsed?.destinationKind, .managedRelative("images/ref-1.png"))
    }

    @MainActor
    func test코드펜스안의이미지구문은건드리지않는다() throws {
        try seedAsset("fence.png", pngA)
        let body = """
        프롤로그

        ```
        ![펜스](images/fence.png)
        ```

        에필로그
        """
        let result = try export(body)

        XCTAssertEqual(result.report.copiedAssets, 0)
        XCTAssertEqual(result.report.missingSources, [])
        XCTAssertTrue(result.text.contains("![펜스](images/fence.png)"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("images").path))
    }

    // MARK: - Gate 3 E2E — 일반 Markdown 도구 해석 규칙 시뮬레이션

    @MainActor
    func test내보낸문서를상대경로규칙으로다시읽으면모든이미지가존재한다() throws {
        try seedAsset("cover.png", pngA)
        try seedAsset("scene.png", pngB)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-\(UUID().uuidString).jpg")
        try pngB.write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }

        let body = """
        # 1장

        ![표지](images/cover.png)

        ![장면](images/scene.png "오후 장면")

        ![바깥](\(external.path))

        ![웹](https://example.com/web.png)

        ![축약][s]

        [s]: images/scene.png
        """
        let result = try export(body, fileName: "novel.md")

        // Typora/VS Code 규칙: md 파일 위치 기준 상대경로 해석.
        let fm = FileManager.default
        let defs = ImageReferenceParser.collectDefinitions(in: result.text)
        for rawLine in result.text.split(separator: "\n") {
            let line = String(rawLine)
            guard let ref = ImageReferenceParser.parse(line, definitions: defs) else { continue }
            switch ref.destinationKind {
            case .managedRelative(let path):
                let resolved = exportDir.appendingPathComponent(path)
                XCTAssertTrue(
                    fm.fileExists(atPath: resolved.path),
                    "외부 도구가 \(path)를 못 찾는다 — 재작성 누락")
                // 복사본은 원본과 동일 바이트다 (무손실).
                if path == "images/scene.png",
                    let original = try? Data(contentsOf: purloryRoot.appendingPathComponent(path)) {
                    XCTAssertEqual(try? Data(contentsOf: resolved), original)
                }
            case .externalFile, .remote, .blocked:
                break  // 원격은 주소 그대로 — 해석 대상 아님 (#12 정책)
            }
        }
        XCTAssertEqual(result.report.missingSources, [])
    }
}
