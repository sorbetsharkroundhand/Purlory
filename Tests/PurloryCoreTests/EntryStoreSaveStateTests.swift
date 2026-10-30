@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 저장 상태 모델 회귀 (이슈 #10).
///
/// 디스크 부족·권한 오류는 실제로 일어난다. 옛 `try?` 경로는 그런 실패를
/// 삼키고 "저장됨"을 표시해 사용자가 원고가 안전하다고 오인하게 했다 —
/// 거짓 안심이 곧 데이터 손실이다. 이 테스트는 다음을 고정한다:
///  1. 쓰기 불가 환경에서는 반드시 `.failed`이고 절대 `.saved`가 아니다.
///  2. 원인이 복구되면 재시도로 `.saved`로 돌아온다.
final class EntryStoreSaveStateTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-savestate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 권한을 되돌려야 임시 디렉터리 정리가 가능하다.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func test쓰기불가환경에서는실패상태이지저장됨이아니다() throws {
        let store = EntryStore(directory: dir, autosaveDelay: .seconds(3600))
        store.updateActiveBody("디스크에 닿아야 하는 문장")

        // 저장 대상 파일의 존재하는 디렉터리를 읽기 전용으로 — atomic 교체가 실패한다.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dir.path)

        store.flush()

        guard case .failed(let message, _) = store.savePhase else {
            XCTFail("쓰기 불가인데 실패로 보고하지 않았다: \(store.savePhase)")
            return
        }
        XCTAssertFalse(message.isEmpty, "실패 이유가 비어 있으면 사용자가 원인을 모른다")
        if case .saved = store.savePhase {
            XCTFail("도달할 수 없음 — 위 가드에서 반환된다")
        }
    }

    @MainActor
    func test원인복구후재시도하면저장성공으로돌아온다() throws {
        let store = EntryStore(directory: dir, autosaveDelay: .seconds(3600))
        store.updateActiveBody("첫 시도")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: dir.path)
        store.flush()
        guard case .failed = store.savePhase else {
            return XCTFail("전제 실패 — 실패 상태가 아니다")
        }

        // 사용자가 디스크 공간을 비우거나 권한을 고친 뒤 재시도.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        store.retrySave()

        guard case .saved = store.savePhase else {
            XCTFail("재시도 후에도 성공으로 돌아오지 않았다: \(store.savePhase)")
            return
        }
        let onDisk = try String(
            contentsOf: dir.appendingPathComponent("entries.json"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("첫 시도"))
    }

    @MainActor
    func test정상flush는저장됨상태를남긴다() {
        let store = EntryStore(directory: dir, autosaveDelay: .seconds(3600))
        store.updateActiveBody("무사히 기록")
        store.flush()

        if case .saved = store.savePhase {} else {
            XCTFail("정상 flush 후 성공 상태여야 한다: \(store.savePhase)")
        }
    }
}
