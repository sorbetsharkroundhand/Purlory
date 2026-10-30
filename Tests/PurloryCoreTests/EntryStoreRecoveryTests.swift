@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 손상 복구 모드 회귀 (이슈 #6).
///
/// "원문이 유일한 진실"(AGENTS §1)의 마지막 방어선. 손상을 발견하면:
///  1. 원본(또는 그 사본)은 절대 덮이지 않고,
///  2. 이번 세션 입력은 복구 파일로 우회 기록되며,
///  3. 다음 실행은 복구 파일에서 작업을 이어받는다.
/// 이 세 가지가 깨지면 복구 가능한 원고가 조용히 증발한다.
final class EntryStoreRecoveryTests: XCTestCase {

    private var dir: URL!
    private var entriesURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        entriesURL = dir.appendingPathComponent("entries.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 잘라낸 JSON — 부분쓰기 재현.
    private func writeTruncatedLibrary() throws {
        let full = """
            {"entries":[{"title":"1장","createdAt":"2026-08-23T00:00:00Z",\
            "body":"오늘의 문장.","id":"00000000-0000-0000-0000-000000000001"}],\
            "activeID":"00000000-0000-0000-0000-000000000001"}
            """
        try Data(full.utf8).write(to: entriesURL)
        var data = try Data(contentsOf: entriesURL)
        data.removeLast(30)  // 끝을 자른다
        try data.write(to: entriesURL)
    }

    @MainActor
    func test손상원본은복구모드에서덮이지않는다() throws {
        try writeTruncatedLibrary()
        let originalBytes = try Data(contentsOf: entriesURL)

        let store = EntryStore(directory: dir, autosaveDelay: .milliseconds(20))
        guard let recovery = store.pendingRecovery else {
            return XCTFail("손상 파일인데 복구 모드로 진입하지 않았다")
        }
        if case .corrupted = recovery.cause {} else {
            XCTFail("디코딩 실패는 .corrupted여야 한다")
        }
        XCTAssertNotNil(recovery.preservedCopyURL, "읽힌 손상 파일은 사본으로 보존돼야 한다")

        // 복구 모드에서 아무리 저장해도 원본 바이트는 그대로여야 한다.
        store.updateActiveBody("복구 모드에서 친 새 문장")
        store.flush()

        XCTAssertEqual(
            try Data(contentsOf: entriesURL), originalBytes,
            "복구 모드의 저장이 손상 원본을 덮었다 — 데이터 손실 재발")

        // 대신 세션 편집은 복구 파일에 살아 있어야 한다.
        let sessionText = try String(contentsOf: recovery.sessionURL, encoding: .utf8)
        XCTAssertTrue(sessionText.contains("복구 모드에서 친 새 문장"))
    }

    @MainActor
    func test다음실행은복구파일에서작업을이어받는다() throws {
        try writeTruncatedLibrary()
        let first = EntryStore(directory: dir, autosaveDelay: .milliseconds(20))
        first.updateActiveBody("이어받아야 할 문장")
        first.flush()

        // 다음 실행 — 손상 원본 위에서 복구 파일을 승계해 정상 모드로 돌아간다.
        let second = EntryStore(directory: dir, autosaveDelay: .milliseconds(20))
        XCTAssertNil(second.pendingRecovery, "승계에 성공했으면 복구 모드가 아니어야 한다")
        XCTAssertEqual(second.entries[0].body, "이어받아야 할 문장")

        // 승계된 라이브러리는 정상 경로로 저장된다.
        second.rename(second.activeID, to: "승계 확인")  // saveNow 경로
        let onDisk = try String(contentsOf: entriesURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("승계 확인"))
        // 남은 복구 파일이 없어야 훗날 낡은 상태 되살림이 불가능하다.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("entries-recovered-") }
        XCTAssertTrue(leftovers.isEmpty, "승계 후 세션 파일이 남으면 재발 경로가 된다")
    }

    @MainActor
    func test권한오류도원본보존과복구모드로간다() throws {
        try Data("{\"entries\": []}".utf8).write(to: entriesURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: entriesURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entriesURL.path) }

        let store = EntryStore(directory: dir, autosaveDelay: .milliseconds(20))
        guard let recovery = store.pendingRecovery else {
            return XCTFail("읽기 실패인데 복구 모드로 진입하지 않았다")
        }
        if case .unreadable = recovery.cause {} else {
            XCTFail("권한 오류는 .unreadable이어야 한다 — 손상과 구분돼야 한다")
        }
        XCTAssertNil(recovery.preservedCopyURL, "못 읽은 파일의 사본은 만들 수 없다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entriesURL.path), "원본은 제자리에 남아야 한다")

        // 권한이 돌아온 뒤 사용자가 다시 열면 정상 라이브러리로 돌아갈 수 있어야 한다.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entriesURL.path)
        let reloaded = EntryStore(directory: dir, autosaveDelay: .milliseconds(20))
        XCTAssertNil(reloaded.pendingRecovery)
    }

    @MainActor
    func test안전내보내기는지정위치에세션전체를기록한다() throws {
        let store = EntryStore(directory: dir, autosaveDelay: .seconds(3600))
        store.updateActiveBody("내보낼 문장")

        let target = dir.appendingPathComponent("수동-백업.json")
        XCTAssertTrue(store.exportSessionCopy(to: target))

        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("내보낼 문장"))
    }
}
