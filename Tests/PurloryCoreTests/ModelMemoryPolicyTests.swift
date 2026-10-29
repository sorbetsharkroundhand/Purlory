@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore

final class ModelMemoryPolicyTests: XCTestCase {
    private let gib: UInt64 = 1 << 30
    private var pin: ModelInstallManifest { PinnedModelCatalog.manifest(for: ModelPresets.qwen2_5_1_5B)! }
    private func hardware(_ gb: UInt64, recommended: UInt64? = nil, unified: Bool = true) -> HardwareMemory {
        .init(physicalBytes: gb * gib, recommendedWorkingSetBytes: (recommended ?? gb) * gib, hasUnifiedMemory: unified)
    }
    private func entry(peak: UInt64 = 2 << 30, tiers: Set<MemoryTier> = [.gb8, .gb16], defaults: Set<MemoryTier> = [.gb8]) -> ModelReleaseEntry {
        .init(id: pin.id, revision: pin.revision, peakBytes: peak, tiers: tiers, defaultTiers: defaults, name: "Fixture")
    }
    func testDeterministicExactAndFloorMemoryTiers() {
        for (gb, tier) in [(8, MemoryTier.gb8), (16, .gb16), (24, .gb24), (32, .gb32)] {
            XCTAssertEqual(hardware(UInt64(gb)).tier, tier)
        }
        XCTAssertEqual(hardware(12).tier, .gb8)
        XCTAssertEqual(hardware(64).tier, .gb32)
        XCTAssertNil(hardware(7).tier)
        XCTAssertNil(hardware(32, unified: false).tier)
        XCTAssertNil(hardware(16, recommended: 0).tier)
    }
    func testSmallerWorkingSetDeterminesBudget() {
        XCTAssertEqual(hardware(32, recommended: 10).budgetBytes, 6 * gib)
        XCTAssertEqual(hardware(16, recommended: 32).budgetBytes, 16 * gib * 3 / 5)
        XCTAssertNil(hardware(4).budgetBytes)
    }
    func testCatalogAndDefaultAreExplicitData() throws {
        let model = entry()
        let eight = ModelMemoryPolicy(hardware: hardware(8), entries: [model])
        XCTAssertEqual(eight.availableEntries, [model])
        XCTAssertEqual(eight.defaultModelID, pin.id)
        XCTAssertNoThrow(try eight.requireLoad(manifest: pin))
        XCTAssertNil(ModelMemoryPolicy(hardware: hardware(16), entries: [model]).defaultModelID)
        let twentyFour = ModelMemoryPolicy(hardware: hardware(24), entries: [model])
        XCTAssertTrue(twentyFour.availableEntries.isEmpty)
        XCTAssertThrowsError(try twentyFour.requireLoad(manifest: pin))
    }
    func testUnapprovedAndChangedRevisionAreRefused() {
        XCTAssertThrowsError(try ModelMemoryPolicy(hardware: hardware(32), entries: []).requireLoad(manifest: pin)) {
            XCTAssertEqual($0 as? ModelMemoryError, .unapproved)
        }
        var changed = pin; changed.revision = String(repeating: "f", count: 40)
        XCTAssertThrowsError(try ModelMemoryPolicy(hardware: hardware(8), entries: [entry()]).requireLoad(manifest: changed)) {
            XCTAssertEqual($0 as? ModelMemoryError, .unapproved)
        }
        XCTAssertTrue(ModelMemoryPolicy.current.availableEntries.isEmpty)
        XCTAssertNil(ModelMemoryPolicy.current.defaultModelID)
    }
    func testOversizedPeakIsHiddenAndRefused() {
        let policy = ModelMemoryPolicy(hardware: hardware(32, recommended: 10), entries: [entry(peak: 7 * gib, tiers: [.gb32], defaults: [.gb32])])
        XCTAssertTrue(policy.availableEntries.isEmpty)
        XCTAssertNil(policy.defaultModelID)
        XCTAssertThrowsError(try policy.requireLoad(manifest: pin)) { XCTAssertEqual($0 as? ModelMemoryError, .budgetExceeded) }
    }
    func testInvalidAndConflictingDeclarationsNeverSelectADefault() {
        for entries in [[entry(peak: 0)], [entry(peak: 1)], [entry(defaults: [.gb32])], [entry(), entry()]] {
            let policy = ModelMemoryPolicy(hardware: hardware(8), entries: entries)
            XCTAssertTrue(policy.availableEntries.isEmpty)
            XCTAssertNil(policy.defaultModelID)
            XCTAssertThrowsError(try policy.requireLoad(manifest: pin)) { XCTAssertEqual($0 as? ModelMemoryError, .invalidCatalog) }
        }
        var other = entry(); other.id = ModelPresets.qwen2_5_3B
        other.revision = PinnedModelCatalog.manifest(for: other.id)!.revision
        let conflict = ModelMemoryPolicy(hardware: hardware(8), entries: [entry(), other])
        XCTAssertNil(conflict.defaultModelID)
        XCTAssertThrowsError(try conflict.requireLoad(manifest: pin)) { XCTAssertEqual($0 as? ModelMemoryError, .invalidCatalog) }
    }
    func testExplicitCandidateEvaluationDoesNotCreateReleaseChoices() throws {
        let release = ModelMemoryPolicy(hardware: hardware(8), entries: [])
        let evaluation = release.evaluatingCandidates(peakBytes: 2 * gib)
        XCTAssertNoThrow(try evaluation.requireLoad(manifest: pin))
        XCTAssertTrue(evaluation.availableEntries.isEmpty)
        XCTAssertNil(evaluation.defaultModelID)
        XCTAssertThrowsError(try release.requireLoad(manifest: pin))
        XCTAssertThrowsError(try release.evaluatingCandidates(peakBytes: 1).requireLoad(manifest: pin))
        XCTAssertThrowsError(try release.evaluatingCandidates(peakBytes: 6 * gib).requireLoad(manifest: pin))
        var unknown = pin; unknown.id = "fixture/unregistered"
        XCTAssertThrowsError(try evaluation.requireLoad(manifest: unknown))
        XCTAssertThrowsError(try ModelMemoryPolicy(hardware: hardware(4), entries: []).evaluatingCandidates(peakBytes: 2 * gib).requireLoad(manifest: pin)) {
            XCTAssertEqual($0 as? ModelMemoryError, .unsupportedHardware)
        }
    }
}
