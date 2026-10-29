@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore

/// "지금 읽기" 패스의 단계·취소·게이트 차단 사유 (이슈 #35 / #65 Phase 6).
///
/// 계약:
/// - 열(.serious 이상)·저전력(깊은 패스) 차단에는 사람이 을 수 있는 사유가 붙는다.
/// - cancelManualPass는 진행 표시를 끊고 취소 상태를 남긴다(체크포인트 보존 문구).
@MainActor
final class ManualPassPhaseTests: XCTestCase {

    func test게이트차단사유는열과저전력을구분한다() {
        // 열 — 깊은 패스든 아니든 차단.
        XCTAssertNotNil(BackgroundIndexer.gateBlockReason(
            deep: true, thermalState: .serious, lowPowerModeEnabled: false))
        XCTAssertNotNil(BackgroundIndexer.gateBlockReason(
            deep: false, thermalState: .critical, lowPowerModeEnabled: false))
        XCTAssertTrue(
            BackgroundIndexer.gateBlockReason(
                deep: true, thermalState: .serious, lowPowerModeEnabled: false
            )!.contains("뜨거워"))

        // 저전력 — 깊은 패스만 차단, 사유에 저전력이 명시된다.
        let reason = BackgroundIndexer.gateBlockReason(
            deep: true, thermalState: .nominal, lowPowerModeEnabled: true)
        XCTAssertEqual(reason?.contains("저전력"), true)

        // 여유 상태 — 차단 아님.
        XCTAssertNil(BackgroundIndexer.gateBlockReason(
            deep: true, thermalState: .nominal, lowPowerModeEnabled: false))
        // 슬라이드(저전력+얕은 패스)는 허용.
        XCTAssertNil(BackgroundIndexer.gateBlockReason(
            deep: false, thermalState: .nominal, lowPowerModeEnabled: true))
    }

    func test취소는토큰을정리하고취소상태를남긴다() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EntryStore(directory: root, autosaveDelay: .seconds(3600))
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let indexer = BackgroundIndexer(engine: CompletionEngine(), settings: settings)
        indexer.attachLegacy(store: store)

        // 사용자 요청 없이는 취소 대상이 없다.
        indexer.cancelManualPass()
        XCTAssertEqual(indexer.manualPhase, .idle)

        // 진행 중인 사용자 패스 시뮬레이션 — 소유권 주입 후 취소.
        let entryID = store.newEntry(kind: .novel)
        store.updateActiveBody("첫 장면. 내용이 충분히 길어야 요약 대상이 된다. 추가 문장도 넣는다.")
        _ = indexer._testBeginPassForOwnership(entryID: entryID, body: "본문")
        indexer._testSetManualPhase(.reading(done: 1, total: 3), token: indexer.passGeneration)

        indexer.cancelManualPass()
        XCTAssertEqual(indexer.manualPhase, .cancelled, "취소 상태가 남아야 한다")
        XCTAssertFalse(indexer.isIndexing)
    }

    func test일시단계는전이규약을간직한다() {
        // 완료·무변경·취소만 일시적 — 진행·차단은 사용자가 볼 때까지 유지된다.
        XCTAssertTrue(BackgroundIndexer.PassPhase.completedNew.isTransient)
        XCTAssertTrue(BackgroundIndexer.PassPhase.completedNoChange.isTransient)
        XCTAssertTrue(BackgroundIndexer.PassPhase.cancelled.isTransient)
        XCTAssertFalse(BackgroundIndexer.PassPhase.reading(done: 0, total: 5).isTransient)
        XCTAssertFalse(
            BackgroundIndexer.PassPhase.blocked(reason: "저전력").isTransient)
    }
}
