@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 폴더 이름 생성 태스크 수명주기 (이슈 #47).
///
/// 계약: 이름 생성 요청은 폴더별 태스크로 추적되고, 행 소멸/종료 경로의
/// 취소는 스피너(namingFolderIDs)를 즉시 해제하며, 취소된 태스크는 스스로
/// 물러나 stale 결과를 적용하지 않는다.
@MainActor
final class FolderNamingLifecycleTests: XCTestCase {

    func test취소시스피너를즉시해제하고태스크를끝낸다() async throws {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false  // 실제 네트워크 유발 방지
        let completion = CompletionController(settings: settings)
        let folderID = UUID()

        let task = completion._testInjectNamingTask(folderID: folderID)
        // 주입 직후 진행 표시가 켜져 있는 상태에서 취소 경로를 검증한다.
        completion.cancelFolderName(for: folderID)

        XCTAssertTrue(task.isCancelled, "행 소멸 취소가 태스크에 전파되지 않았다")
        XCTAssertFalse(
            completion.namingFolderIDs.contains(folderID),
            "취소 후에도 스피너가 남아 있다")

        // 취소된 태스크는 스스로 물러난다 — 결과 적용 없이 종료 대기.
        _ = await task.result
        XCTAssertTrue(completion.namingFolderIDs.isEmpty)
    }

    func test자동완성이꺼지면요청자체가스피너를켜지않는다() {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        let completion = CompletionController(settings: settings)

        // store 없이도 조기 반환 경로(스위치 가드)를 검증한다.
        completion.requestFolderName(for: UUID(), in: EntryStore())

        XCTAssertTrue(completion.namingFolderIDs.isEmpty)
    }
}
