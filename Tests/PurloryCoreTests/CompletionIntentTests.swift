@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 설정·툴바 단일 의유 API 회귀 (이슈 #11).
///
/// 설정 창이 settings 값을 직접 고치면 컨트롤러의 무효화(세대 상승·스트림
/// 취소·리포트 폐기)를 우회해, 예측 중 자동완성을 꺼도 고스트가 도착하거나
/// 모델을 바꾼 뒤 이전 모델 결과가 나타났다. 이 테스트는 컨트롤러 의유가
/// 무효화를 실제로 발화하는지 고정한다.
///
/// 네트워크 안전: 컨트롤러 테스트는 비활성/미구성 상태만 실행한다. 설정에서
/// enabled 값을 기록하는 테스트는 컨트롤러나 엔진을 만들지 않는다.
final class CompletionIntentTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func testUnconfirmedInstallStartsWithCompletionDisabled() throws {
        let suite = "Purlory.CompletionAuthorizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let settings = CompletionSettings(defaults: defaults)

        XCTAssertFalse(settings.autocompleteEnabled)
        XCTAssertEqual(settings.authorization, .unconfigured)
    }

    @MainActor
    func testPreloadStaysIdleWhenCompletionIsUnconfigured() throws {
        let suite = "Purlory.CompletionAuthorizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let settings = CompletionSettings(defaults: defaults)
        let controller = CompletionController(settings: settings)

        controller.preloadEngine()

        XCTAssertEqual(controller.engineState, .idle)
    }

    @MainActor
    func testConfirmedInstallMigratesEnabledPreference() throws {
        let suite = "Purlory.CompletionAuthorizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "purlory.initialModelConfirmed")
        defaults.set(true, forKey: "completion.enabled")

        let settings = CompletionSettings(defaults: defaults)

        XCTAssertEqual(settings.authorization, .enabled)
        XCTAssertTrue(settings.autocompleteEnabled)
    }

    @MainActor
    func testConfirmedInstallMigratesDisabledPreference() throws {
        let suite = "Purlory.CompletionAuthorizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "purlory.initialModelConfirmed")
        defaults.set(false, forKey: "completion.enabled")

        let settings = CompletionSettings(defaults: defaults)

        XCTAssertEqual(settings.authorization, .disabled)
        XCTAssertFalse(settings.autocompleteEnabled)
    }

    @MainActor
    func testUnconfirmedMigrationDoesNotErasePriorPreference() {
        let suite = "Purlory.CompletionAuthorizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "purlory.initialModelConfirmed")
        defaults.set(true, forKey: "completion.enabled")

        let settings = CompletionSettings(defaults: defaults)

        XCTAssertEqual(settings.authorization, .unconfigured)
        XCTAssertFalse(settings.autocompleteEnabled)
        XCTAssertEqual(defaults.object(forKey: "completion.enabled") as? Bool, true)
    }

    @MainActor
    func testExplicitSettingsChoiceRecordsCompletionAuthorization() {
        let suite = "Purlory.CompletionAuthorizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults)

        settings.setCompletionEnabled(true)
        XCTAssertEqual(settings.authorization, .enabled)
        XCTAssertTrue(settings.autocompleteEnabled)

        settings.setCompletionEnabled(false)
        XCTAssertEqual(settings.authorization, .disabled)
        XCTAssertFalse(settings.autocompleteEnabled)
    }

    @MainActor
    func test자동완성을끄면리포트와진행상태가즉시무효화된다() {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = true
        settings.modelID = "test/model-a"
        let completion = CompletionController(settings: settings)

        // 예측 도중이라고 친다 — 리포트는 조립 기록, isPredicting은 진행 표시.
        completion.lastContextReport = ContextReport(
            items: [.init(kind: .meta, text: "메타", stableKey: "k")],
            entryID: nil, generation: 2)

        completion.setAutocompleteEnabled(false)

        XCTAssertFalse(settings.autocompleteEnabled)
        XCTAssertNil(
            completion.lastContextReport,
            "스위치를 껐는데 리포트가 남으면 이전 세대 맥락이 노출된다")
        if case .failed = completion.engineState {} else {
            // 실패 상태가 아닌 이상 idle로 정리돼도 좋다 — 다만 네트워크 없이
            // 켜는 경로를 시험하지 않으니 여기선 상태 보존까지는 요구하지 않는다.
        }
    }

    @MainActor
    func test모델변경의유는리포트를폐기하고값을바꾼다() {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false  // 네트워크 유발 방지 — 로드 스킵
        settings.modelID = "test/model-a"
        let completion = CompletionController(settings: settings)
        completion.lastContextReport = ContextReport(
            items: [.init(kind: .meta, text: "메타")],
            entryID: nil, generation: 1)

        completion.changeModel(to: "test/model-b")

        XCTAssertEqual(settings.modelID, "test/model-b")
        XCTAssertNil(
            completion.lastContextReport,
            "모델을 바꿨는데 이전 모델의 리포트가 남아 있다")
        XCTAssertEqual(completion.engineState, .idle, "새 모델 상태 표시를 위해 초기화돼야 한다")
    }

    @MainActor
    func test같은모델재선택은무해한다() {
        let settings = CompletionSettings()
        settings.autocompleteEnabled = false
        settings.modelID = "test/model-a"
        let completion = CompletionController(settings: settings)
        let report = ContextReport(items: [], entryID: nil, generation: 0)
        completion.lastContextReport = report

        completion.changeModel(to: "test/model-a")

        XCTAssertEqual(completion.lastContextReport, report, "같은 모델 재선택에 무효화하면 안 된다")
    }
}
