@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 동일 값 `@Published` 쓰기 가드 (이슈 #51 / #65 Phase 4).
///
/// 계약: 값이 실제로 바뀌지 않으면 objectWillChange가 발생하지 않는다 — 특히
/// noteChange(키 입력당)의 isIndexing 해제와 타이핑 중 isPredicting 토글이
/// ModelChip 애니메이션을 잘못 진동시키지 않게 한다.
@MainActor
final class PublishedWriteGuardTests: XCTestCase {

    func test유휴상태선점은published변화를만들지않는다() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-pub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EntryStore(directory: root, autosaveDelay: .seconds(3600))
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        indexer.attachLegacy(store: store)

        var willChangeCount = 0
        let token = indexer.objectWillChange.sink { willChangeCount += 1 }

        // 패스가 도는 중이 아닐 때의 연속 선점 — 상태 변화가 없어야 한다.
        let id = store.newEntry(kind: .novel)
        indexer.noteChange(entryID: id)
        indexer.noteChange(entryID: id)

        XCTAssertEqual(willChangeCount, 0, "동일 값 쓰기가 \(willChangeCount)번 발행됐다")
        XCTAssertFalse(indexer.isIndexing)
        token.cancel()
    }
}

/// PurloryTheme Equatable과 팔레트 파생 캐시 (이슈 #54).
@MainActor
final class ThemeEquatabilityTests: XCTestCase {

    func test같은입력은동등하고다른팔레트는비동등이다() {
        XCTAssertEqual(PurloryTheme.of(.light), PurloryTheme.of(.light))
        XCTAssertNotEqual(PurloryTheme.of(.light), PurloryTheme.of(.dark))

        var hexes = PaletteSettings.shared.light.hexes
        let original = hexes[3]
        hexes[3] = 0x123456
        defer { PaletteSettings.shared.light.hexes[3] = original }
        XCTAssertNotEqual(
            PurloryTheme.of(.light, palette: PurloryPalette(hexes: hexes)),
            PurloryTheme.of(.light))
    }

    func test팔레트캐시는hex변화에즉시무효화된다() {
        let settings = PaletteSettings.shared
        settings.enabled = true
        let originalHex = settings.light.hexes[3]
        let original = settings.theme(for: .light)

        // 같은 입력 — 캐시가 같은 결과를 준다.
        XCTAssertEqual(settings.theme(for: .light), original)

        // hex 변경 — 캐시가 무효화돼 새 색이 반영된다.
        settings.light.hexes[3] = 0x123456 &+ 0x000001
        let changed = settings.theme(for: .light)
        XCTAssertNotEqual(changed, original, "hex 변경이 캐시에 묻혔다")

        settings.light.hexes[3] = originalHex
        _ = settings.theme(for: .light)
    }
}

/// 강조 배경 위 접근 가능한 전경색 (이슈 #57).
final class AccessibleForegroundTests: XCTestCase {

    func test밝은라임에는검정_어두운남색에는흰색() {
        // 기본 액센트 시드(밝은 라임 0xE9FF7A) → 검정이어야 4.5:1 확장
        let lime = NSColor(hex: 0xE9FF7A)
        XCTAssertEqual(lime.accessibleForeground(), NSColor.black)

        let navy = NSColor(hex: 0x10143C)
        XCTAssertEqual(navy.accessibleForeground(), NSColor.white)
    }
}
