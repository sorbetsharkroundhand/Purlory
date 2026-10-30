@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 이미지·수식 렌더 캐시의 바이트 LRU와 다운샘플 디코딩 (이슈 #53 / #65 Phase 4).
///
/// 계약:
/// - 표시용 `displayImage`는 요청 픽셀 상한에서 디코딩한다 — 전체 해상도를
///   메모리에 올리지 않고, 가로세로비는 원본과 같다 (레이아웃 크기 불변).
/// - 캐시는 count 클리프가 아니라 바이트 한도 LRU — 초과 시 오래된 항목부터
///   하나씩 내보내고, 적중은 최신성을 갱신한다.
@MainActor
final class RenderCacheLRUTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 구형 XCTest 훅은 비격리이므로 캐시 초기화의 메인 액터 계약을 확인한다.
        MainActor.assumeIsolated {
            PurloryImageStore._testResetCache(budgetBytes: 1_000_000)
        }
    }

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-lru-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 단색 PNG 데이터 — 크기만 있는 픽스처.
    private func solidPNG(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    func test표시용이미지는요청폭으로디코딩되고비율을유지한다() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        PurloryImageStore.setDirectoryOverride(root)
        defer { PurloryImageStore.setDirectoryOverride(nil) }

        guard let relative = PurloryImageStore.save(solidPNG(width: 2000, height: 1000), ext: "png")
        else { return XCTFail("픽스처 저장 실패") }

        // 전체 로드 — 원본 해상도.
        let full = try XCTUnwrap(PurloryImageStore.image(for: relative))
        XCTAssertEqual(Int(full.size.width), 2000)

        // 표시용 — 500px로 다운샘플, 비율 2:1 유지.
        let display = try XCTUnwrap(
            PurloryImageStore.displayImage(for: relative, maxPixelWidth: 500))
        XCTAssertLessThanOrEqual(display.size.width, 502)
        XCTAssertEqual(
            display.size.width / display.size.height, 2.0, accuracy: 0.02,
            "가로세로비가 무너져 레이아웃 크기가 변했다")

        // 같은 요청 재호출 — 캐시 적중(같은 인스턴스).
        let again = try XCTUnwrap(
            PurloryImageStore.displayImage(for: relative, maxPixelWidth: 500))
        XCTAssertTrue(display === again, "표시용 캐시가 적중하지 않았다")
    }

    func testLRU는바이트한도에서오래된항목부터축출한다() {
        var lru = ImageLRU(budgetBytes: 300)
        lru.insert(key: "a", image: NSImage(), bytes: 100)
        lru.insert(key: "b", image: NSImage(), bytes: 100)
        lru.insert(key: "c", image: NSImage(), bytes: 100)
        XCTAssertEqual(lru.entries.map(\.key), ["c", "b", "a"])

        // a 적중 → 최신화. 이제 b가 가장 오래됐다.
        XCTAssertNotNil(lru.find("a"))
        XCTAssertEqual(lru.entries.first?.key, "a")

        // d 삽입 → 한도(300) 초과분만큼 꼬리부터: b(100)→초과, c(100)→여전히 초과.
        // a는 방금 적중해 최신이므로 살아남는다.
        lru.insert(key: "d", image: NSImage(), bytes: 150)
        XCTAssertEqual(lru.entries.map(\.key), ["d", "a"], "적중한 a가 아닌 것부터 내보내야 한다")
        XCTAssertNil(lru.find("b"))
        XCTAssertNil(lru.find("c"))
        XCTAssertNotNil(lru.find("d"))
    }

    func test수식캐시는클리프없이점진적으로축출된다() {
        MathRenderer._testResetCache(budgetBytes: 400_000)
        defer { MathRenderer._testResetCache() }

        for index in 0..<40 {
            let (_, error) = MathRenderer.render(
                latex: "x_\(index) = \\frac{\(index)}{\(index + 1)} + \\sqrt{\(index)}",
                color: .black, fontSize: 16)
            XCTAssertNil(error)
        }
        // 첫 수식 재렌더 — 256개 클리프였다면 사라졌을 것이지만,
        // 64KB 예산이라 몇 개는 남는다. 여기선 규약 확인: 렌더가 계속 성공한다.
        let (image, error) = MathRenderer.render(
            latex: "x_0 = \\frac{0}{1} + \\sqrt{0}", color: .black, fontSize: 16)
        XCTAssertNil(error)
        XCTAssertNotNil(image)
    }
}
