@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore

@MainActor
final class ModelMemoryIntegrationTests: XCTestCase {
    private var pin: ModelInstallManifest { PinnedModelCatalog.manifest(for: ModelPresets.qwen2_5_1_5B)! }
    private func policy(peak: UInt64 = 2 << 30, approved: Bool = true) -> ModelMemoryPolicy {
        let entry = ModelReleaseEntry(id: pin.id, revision: pin.revision, peakBytes: peak,
                                      tiers: [.gb8], defaultTiers: [.gb8], name: "Fixture")
        return .init(hardware: .init(physicalBytes: 8 << 30, recommendedWorkingSetBytes: 8 << 30, hasUnifiedMemory: true),
                     entries: approved ? [entry] : [])
    }
    func testEngineRefusesUnapprovedAndOversizedModelBeforeMLXSetup() async throws {
        for (policy, reason) in [(policy(approved: false), ModelMemoryError.unapproved), (policy(peak: 6 << 30), .budgetExceeded)] {
            do {
                try await CompletionEngine(memoryPolicy: policy).preload(parameters: .init(modelID: pin.id))
                XCTFail("Expected memory refusal before MLX setup")
            } catch { XCTAssertEqual(error as? ModelMemoryError, reason) }
        }
    }
    func testDownloadRefusalCreatesNoInstallationData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-MemoryDownload-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = policy(approved: false), pin = pin
        let manager = ModelDownloadManager(store: ModelInstallationStore(root: root), manifestForID: { _ in pin },
            download: { _, _, destination in try Data("abc".utf8).write(to: destination) }, startBlock: { nil },
            admit: { try policy.requireLoad(manifest: $0) })
        defer { manager.cancel(pin.id) }
        manager.download(pin.id)
        guard case .failed(let reason) = manager.states[pin.id] else { return XCTFail("Must refuse synchronously before transfer") }
        XCTAssertEqual(reason, ModelMemoryError.unapproved.localizedDescription)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testNewSelectionAndChoicesUseApprovedPolicyData() throws {
        let suite = "Purlory.MemoryDefaults.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CompletionSettings(defaults: defaults, memoryPolicy: policy())
        XCTAssertEqual(settings.modelID, pin.id)
        XCTAssertFalse(settings.autocompleteEnabled)
        let choices = ModelChoice.available(using: policy())
        XCTAssertEqual(choices.map(\.id), [pin.id])
        XCTAssertEqual(choices.map(\.name), ["Fixture"])
        XCTAssertTrue(ModelChoice.all.isEmpty)
        XCTAssertEqual(CompletionParameters().modelID, "")
    }
    func testUnavailableSavedIDAndUnrelatedPreferencesArePreserved() throws {
        let suite = "Purlory.MemoryPreservation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ModelPresets.glm4_7_flash, forKey: "completion.modelID")
        defaults.set("Writer", forKey: "authorName")
        defaults.set(28, forKey: "completion.maxTokens")
        let settings = CompletionSettings(defaults: defaults, memoryPolicy: policy(approved: false))
        XCTAssertEqual(settings.modelID, ModelPresets.glm4_7_flash)
        XCTAssertEqual(defaults.string(forKey: "completion.modelID"), ModelPresets.glm4_7_flash)
        XCTAssertEqual(defaults.string(forKey: "authorName"), "Writer")
        XCTAssertEqual(settings.maxTokens, 28)
    }
    func testUnapprovedLegacyChoiceIsNeverCalledTheDefault() {
        XCTAssertEqual(ModelChip.userFacingSummary(for: .basil), "검증 대기")
        XCTAssertEqual(ModelChip.userFacingSummary(for: .purlory), "검증 대기")
        XCTAssertEqual(ModelChip.userFacingSummary(for: .qwenMoE), "검증 대기")
    }
}
