@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 원문 저장 안전장치 — 손상 보존·일일 백업 로테이션.
///
/// 원문(entries.json)은 유일한 진실이다(AGENTS.md §1-3). 디코딩 실패를
/// "파일 없음"과 뭉개면 첫 autosave가 유일한 원본을 빈 내용으로 덮어버리므로,
/// 이 테스트는 다음 불변조건을 고정한다:
///  1. 손상 파일은 반드시 .corrupt-* 사본으로 남는다 (조용한 전멸 금지)
///  2. 손상 후에도 스토어는 정상 시작한다 (빈 저널 1개)
///  3. 하루 첫 저장 직전 상태가 backups/에 남고, 세대 상한을 넘으면 오래된 것부터 사라진다
final class EntryStoreSafetyTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var entriesURL: URL { dir.appendingPathComponent("entries.json") }
    private var backupsURL: URL { dir.appendingPathComponent("backups", isDirectory: true) }

    @MainActor
    func makeStore() -> EntryStore {
        EntryStore(directory: dir, autosaveDelay: .milliseconds(50))
    }

    // MARK: - 손상 보존

    @MainActor
    func testCorruptFileIsPreservedAndStoreStartsFresh() throws {
        try Data("{\"entries\": [{ 깨진".utf8).write(to: entriesURL)

        let store = makeStore()

        let preserved = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("entries.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(preserved.count, 1, "손상 원본의 사본이 정확히 하나 남아야 한다")
        // 사본 내용이 원본과 동일한지 — 복구 가능성의 실질 보장.
        let original = try Data(contentsOf: dir.appendingPathComponent(preserved[0]))
        XCTAssertEqual(original, Data("{\"entries\": [{ 깨진".utf8))

        XCTAssertEqual(store.entries.count, 1, "손상 후에도 빈 저널 하나로 정상 시작")
        XCTAssertEqual(store.entries[0].body, "")
    }

    @MainActor
    func testMissingFileStartsWithoutCorruptCopy() throws {
        let store = makeStore()

        XCTAssertEqual(store.entries.count, 1)
        let preserved = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("entries.corrupt-") }
        XCTAssertTrue(preserved.isEmpty, "첫 실행엔 손상 사본이 없어야 한다")
    }

    @MainActor
    func testValidFileRoundTripsThroughReload() throws {
        let first = makeStore()
        first.updateActiveBody("# 서연의 귀환\n\n첫 문단.")
        first.flush()

        let second = makeStore()
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries[0].body, "# 서연의 귀환\n\n첫 문단.")
    }

    // MARK: - 전용 저장 라이터 (이슈 #44)

    /// ⌘Q 직전에 친 마지막 문장 보존 (AGENTS §6). flush는 "반환 시점 = 디스크
    /// 반영 시점" 계약이라 입력 직후 종료해도 그 문장이 다음 실행에 있어야 한다.
    @MainActor
    func testFlushPreservesLastSentenceTypedBeforeQuit() throws {
        let store = makeStore()
        store.updateActiveBody("앞 문단.\n\n방금 친 마지막 문장.")
        store.flush()

        let reloaded = makeStore()
        XCTAssertEqual(
            reloaded.entries[0].body,
            "앞 문단.\n\n방금 친 마지막 문장.",
            "flush가 돌아왔는데 내용이 디스크에 없으면 계약 위반이다")
    }

    /// 장편 원고(~30만 자)도 라이터 액터 경로에서 무손실 왕복해야 한다.
    /// 인코딩+쓰기가 메인에서 도는 옛 구조로 돌아가면 이 크기에서 프리즈가 재발한다.
    @MainActor
    func testLargeManuscriptRoundTripsLosslesslyThroughWriter() throws {
        let paragraph = "한강을 따라 오래 걸었다. 바람이 차가웠지만 기분은 좋았다. "
        let longBody = String(repeating: paragraph, count: 10_000)
        XCTAssertGreaterThanOrEqual(longBody.count, 300_000)

        let store = makeStore()
        store.updateActiveBody(longBody)
        store.flush()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries[0].body, longBody)
    }

    /// 손으로 flush하지 않아도 디바운스 autosave가 스스로 디스크에 반영된다 —
    /// 라이터 액터로 hop하는 새 경로가 취소·hop 실수로 쓰기를 유실하지 않게 고정.
    @MainActor
    func testDebouncedAutosaveLandsOnDiskWithoutManualFlush() async throws {
        let store = makeStore()
        store.updateActiveBody("디바운스 뒤 자동 저장되는 문장.")

        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if FileManager.default.fileExists(atPath: entriesURL.path),
               (try String(contentsOf: entriesURL, encoding: .utf8))
                   .contains("디바운스 뒤 자동 저장되는 문장.") {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("디바운스 시간이 지났는데도 자동 저장이 디스크에 반영되지 않았다")
    }

    // MARK: - 일일 백업

    /// 어제 수정된 파일 기준 — 백업 이름이 되어야 할 날짜 문자열.
    private var yesterdayStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        return formatter.string(from: yesterday)
    }

    @MainActor
    func testFirstSaveOfDayBacksUpPreviousState() throws {
        try Data("{\"entries\": [], \"activeID\": null}".utf8).write(to: entriesURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-86_400)],
            ofItemAtPath: entriesURL.path)

        let store = makeStore()
        store.rename(store.activeID, to: "변경")  // saveNow 경로

        let backup = backupsURL.appendingPathComponent("entries-\(yesterdayStamp).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        // 사본은 변경 전 상태여야 한다 — 방금 저장한 내용이 아니다.
        let content = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertFalse(content.contains("변경"))
    }

    @MainActor
    func testSecondSaveSameDayDoesNotDuplicateBackup() throws {
        try Data("{\"entries\": [], \"activeID\": null}".utf8).write(to: entriesURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-86_400)],
            ofItemAtPath: entriesURL.path)

        let store = makeStore()
        store.rename(store.activeID, to: "변경")   // 첫 저장 — 백업 생성
        store.rename(store.activeID, to: "재변경") // 두 번째 저장 — mtime이 오늘

        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsURL.path)
        XCTAssertEqual(backups.count, 1, "같은 날 여러 번 저장해도 사본은 하나")
    }

    @MainActor
    func testSaveWithTodayMtimeSkipsBackup() throws {
        try Data("{\"entries\": [], \"activeID\": null}".utf8).write(to: entriesURL)
        // mtime = 지금(오늘) — 그날 첫 저장이 아니다.

        let store = makeStore()
        store.rename(store.activeID, to: "변경")

        let exists = FileManager.default.fileExists(atPath: backupsURL.path)
        XCTAssertFalse(exists, "오늘 이미 저장한 파일엔 백업을 만들지 않는다")
    }

    @MainActor
    func testRotationKeepsNewestSevenGenerations() throws {
        try backupsURL.ensureDirectory()
        // 8세대 준비 — 어제 날짜의 새 사본이 사전순으로 그 사이에 끼면 총 9개가 되고,
        // 상한 7을 맞추려면 가장 오래된 2개(2020·2021)가 사라져야 한다.
        let years = (2020...2027).map(String.init)
        for year in years {
            try Data("{}".utf8).write(
                to: backupsURL.appendingPathComponent("entries-\(year)-01-01.json"))
        }
        try Data("{\"entries\": [], \"activeID\": null}".utf8).write(to: entriesURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-86_400)],
            ofItemAtPath: entriesURL.path)

        let store = makeStore()
        store.rename(store.activeID, to: "변경")

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: backupsURL.path).sorted(),
            [
                "entries-2022-01-01.json",
                "entries-2023-01-01.json",
                "entries-2024-01-01.json",
                "entries-2025-01-01.json",
                "entries-2026-01-01.json",
                "entries-\(yesterdayStamp).json",   // 새 사본 — 시간순 위치에 낀다
                "entries-2027-01-01.json",
            ],
            "오래된 것부터 삭제되고, 새 사본은 사전순(=시간순) 자리를 지킨다")
    }
}

private extension URL {
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: self, withIntermediateDirectories: true)
    }
}
