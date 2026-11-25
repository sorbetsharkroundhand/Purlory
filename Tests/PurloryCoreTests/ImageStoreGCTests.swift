@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 이미지 GC 금지 회귀 (이슈 #7).
///
/// 과거 정규식 기반 `pruneUnreferenced`는 title·angle destination·괄호·
/// reference 문법을 참조로 인정하지 않아, 다른 저널을 삭제하는 것만으로
/// 실제 사용 중인 asset을 영구 삭제했다. 파서 기반 참조 모델(#12)과 지연
/// GC(#17)가 오기 전까지 **자동 삭제 자체가 없어야 한다** — 이 테스트는
/// 그 불변조건을 모든 지원 문법에 대해 고정해, 삭제 로직의 재도입을 막는다.
final class ImageStoreGCTests: XCTestCase {
    // Catches project render fallback to the global root and cached images crossing projects.
    @MainActor
    func testProjectEditorResolvesOnlyItsCatalogAndRetainsBlobs() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = ProjectStore(root: projectRoot)
        let project = projectFixture()
        let other = projectFixture()
        try await store.save(project)
        try await store.save(other)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1EAAAAASUVORK5CYII="))
        try png.write(to: root.appendingPathComponent("images/global.png"))
        try await store.addAsset(png, reference: "images/a.png", to: project.id)
        let view = BlockTextView(frame: .zero)
        view.projectAssetCatalog = try await store.assetCatalog(id: project.id)
        XCTAssertNotNil(view.resolvedImage(for: "images/a.png"))
        XCTAssertNil(view.resolvedImage(for: "images/global.png"))
        view.load(markdown: "![Global](images/global.png)")
        XCTAssertTrue(view.accessibilityString(for: NSRange(location: 0, length: view.string.utf16.count)).contains("표시 불가"))
        view.projectAssetCatalog = try await store.assetCatalog(id: other.id)
        XCTAssertNil(view.resolvedImage(for: "images/a.png"))
        let surviving = try await store.assetData(reference: "images/a.png", in: project.id)
        XCTAssertEqual(surviving, png)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/global.png")), png)
    }

    @MainActor
    func testProjectClipboardImportPreservesMetadataAndUsesCopiedBytes() async throws {
        let projectRoot = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = ProjectStore(root: projectRoot)
        let project = projectFixture()
        try await store.save(project)
        let view = BlockTextView(frame: .zero)
        view.projectAssetCatalog = try await store.assetCatalog(id: project.id)
        view.projectAssetImporter = { data, reference in
            try await store.addAsset(data, reference: reference, to: project.id)
            return try await store.assetCatalog(id: project.id)
        }
        let object = PurloryImageObject(src: "images/old.png", alt: "그림", title: "Cover", width: 60, align: "left")
        try await view.insertProjectImage(data: Data([1, 2, 3]), reference: "images/new.png", object: object)
        XCTAssertTrue(view.serialize().contains("![그림](images/new.png \"Cover\"){width=60 align=left}"))
        let copied = try await store.assetData(reference: "images/new.png", in: project.id)
        XCTAssertEqual(copied, Data([1, 2, 3]))
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-gc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        // XCTest setup/teardown은 메인 스레드에서 실행된다.
        let isolatedRoot = root
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(isolatedRoot) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(nil) }
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func test삭제후유예기간에는asset이살아있다() throws {
        let imagesDir = root.appendingPathComponent("images")
        try Data([0x89]).write(to: imagesDir.appendingPathComponent("cover.png"))
        AssetJanitor.record("images/cover.png")

        // Grace-period sweep must not delete recently orphaned assets.
        let removedNow = AssetJanitor.sweepAll(bodies: [])
        XCTAssertTrue(removedNow.isEmpty, "유예 중인데 지웠다: \(removedNow)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("cover.png").path))
    }
}
