@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 모델 ID 커밋 경계 검증 (이슈 #25 / #65 H2).
///
/// 계약: TextField는 초안만 편집하고, `namespace/model` 형식을 통과한 값만
/// changeModel로 간다 — 불완전한 입력이 취소·다운로드·preload를 시작하지 않는다.
final class ModelIDCommitTests: XCTestCase {

    func test정상ID는공백제거후통과한다() throws {
        let id = try XCTUnwrap(try? ModelIDCommit.validate("  mlx-community/Qwen2.5-1.5B  ").get())
        XCTAssertEqual(id, "mlx-community/Qwen2.5-1.5B")
    }

    func test빈입력은empty다() {
        XCTAssertThrowsError(try ModelIDCommit.validate("").get())
        XCTAssertThrowsError(try ModelIDCommit.validate("   \t ").get())
    }

    func test형식오류는malformed다() {
        // 슬래시 누락
        XCTAssertThrowsError(try ModelIDCommit.validate("mlx-community").get())
        // 슬래시 과잉
        XCTAssertThrowsError(try ModelIDCommit.validate("a/b/c").get())
        // 슬라이스 빈 절반
        XCTAssertThrowsError(try ModelIDCommit.validate("/model").get())
        XCTAssertThrowsError(try ModelIDCommit.validate("ns/").get())
        // 내부 공백 — 타이핑 중 공백이 끼면 네트워크를 시작하지 않는다
        XCTAssertThrowsError(try ModelIDCommit.validate("mlx commu/model").get())
    }

    @MainActor
    func test같은ID커밋은모델을건드리지않는다() {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        settings.modelID = "test/model-a"
        let completion = CompletionController(settings: settings)
        let report = ContextReport(items: [], entryID: nil, generation: 0)
        completion.lastContextReport = report

        // 뷰의 적용 버튼은 동일 ID에서 disabled 되지만, 이중 방어로 컨트롤러 가드도 확인.
        completion.changeModel(to: "test/model-a")

        XCTAssertEqual(settings.modelID, "test/model-a")
        XCTAssertEqual(completion.lastContextReport, report, "동일 ID 커밋에 무효화하면 안 된다")
    }
}
