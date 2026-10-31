import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import PurloryInference

final class PromptCachePinTests: XCTestCase {
    private func prepareTensors() throws {
        guard let path = ProcessInfo.processInfo.environment["PURLORY_TEST_METALLIB"] else {
            throw XCTSkip("Opt-in tensor isolation check: set PURLORY_TEST_METALLIB to the prepared library; policy tests run without Metal.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        GPU.metallib = URL(fileURLWithPath: path)
    }

    func testPinnedPrefixSurvivesLivePrefixReplacementWithoutArrayAliasing() throws {
        try prepareTensors()
        try Device.withDefaultDevice(.cpu) {
            let model = NSObject()
            let owner = PromptCacheBox.Owner(modelID: "fixture", modelIdentity: ObjectIdentifier(model), parameters: .init())
            let box = PromptCacheBox(), live = KVCacheSimple()
            let first = try XCTUnwrap(box.begin(owner: owner, tokens: [1, 2, 3, 4], pinTokens: [1, 2, 3], makeCache: { [live] }))
            let original = MLXArray([Float(10), 20, 30, 40], [1, 1, 4, 1])
            _ = live.update(keys: original, values: original)
            eval(live.state)
            box.commit(lease: first.lease)

            let intervening = try XCTUnwrap(box.begin(owner: owner, tokens: [1, 2, 99, 100], makeCache: { [KVCacheSimple()] }))
            XCTAssertEqual(intervening.reusedTokens, 2)
            let replacement = MLXArray([Float(99), 100], [1, 1, 2, 1])
            _ = intervening.cache[0].update(keys: replacement, values: replacement)
            eval(intervening.cache[0].state)
            box.commit(lease: intervening.lease)

            let restored = try XCTUnwrap(box.begin(owner: owner, tokens: [1, 2, 3, 8], pinTokens: [1, 2, 3], makeCache: { [KVCacheSimple()] }))
            XCTAssertEqual(restored.reusedTokens, 3)
            XCTAssertEqual(restored.suffix, [8])
            XCTAssertFalse((restored.cache[0] as? KVCacheSimple) === live)
            XCTAssertEqual(restored.cache[0].state[0].asArray(Float.self), [10, 20, 30])
            box.abandon(lease: restored.lease)
            let again = try XCTUnwrap(box.begin(owner: owner, tokens: [1, 2, 3, 7], makeCache: { [KVCacheSimple()] }))
            XCTAssertEqual(again.reusedTokens, 3)
            if again.reusedTokens > 0 { XCTAssertEqual(again.cache[0].state[0].asArray(Float.self), [10, 20, 30]) }
            box.abandon(lease: again.lease)
        }
    }

    func testClonesEnforceByteCapAndPreserveQuantizedConfiguration() throws {
        try prepareTensors()
        try Device.withDefaultDevice(.cpu) {
            let simple = KVCacheSimple()
            let values = MLXArray([Float(10), 20, 30, 40], [1, 1, 4, 1])
            _ = simple.update(keys: values, values: values); eval(simple.state)
            XCTAssertNil(PromptCacheCapability.independentPrefix([simple], count: 3, maxBytes: 23))
            let bounded = try XCTUnwrap(PromptCacheCapability.independentPrefix([simple], count: 3, maxBytes: 24))
            XCTAssertEqual(bounded.flatMap(\.state).reduce(0) { $0 + $1.nbytes }, 24)
            let quantized = QuantizedKVCache(groupSize: 64, bits: 4)
            let original = MLXArray(Array(repeating: Float(2), count: 4 * 64), [1, 1, 4, 64])
            _ = quantized.updateQuantized(keys: original, values: original); eval(quantized.state)
            let clone = try XCTUnwrap(PromptCacheCapability.independentPrefix([quantized], count: 3, maxBytes: 4096)?.first as? QuantizedKVCache)
            XCTAssertEqual(clone.offset, 3); XCTAssertEqual(clone.groupSize, 64); XCTAssertEqual(clone.bits, 4)
            _ = quantized.trim(3)
            let changed = MLXArray(Array(repeating: Float(9), count: 3 * 64), [1, 1, 3, 64])
            _ = quantized.updateQuantized(keys: changed, values: changed); eval(quantized.state)
            let restored = clone.toUnquantized()
            XCTAssertEqual(restored.state[0].shape, [1, 1, 3, 64])
            XCTAssertTrue(restored.state[0].asArray(Float.self).allSatisfy { abs($0 - 2) < 0.01 })
        }
    }
}
