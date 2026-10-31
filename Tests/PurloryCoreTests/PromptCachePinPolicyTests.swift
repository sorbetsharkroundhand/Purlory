import Foundation
import MLXLMCommon
import XCTest
@testable import PurloryInference

final class PromptCachePinPolicyTests: XCTestCase {
    private let model = NSObject(), other = NSObject()
    private func owner(otherModel: Bool = false) -> PromptCacheBox.Owner {
        .init(modelID: "fixture", modelIdentity: ObjectIdentifier(otherModel ? other : model), parameters: .init())
    }
    private func box(limit: Int = 3, bytes: Int = 100) -> PromptCacheBox {
        PromptCacheBox(maxPinnedTokens: limit, maxPinnedBytes: bytes) { layers, count, _ in
            layers.map { _ in let layer = KVCacheSimple(); layer.offset = count; return layer }
        }
    }
    private func seed(_ box: PromptCacheBox, pin: [Int]? = [1, 2, 3]) throws {
        let cache = KVCacheSimple()
        let request = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 4], pinTokens: pin) { [cache] })
        cache.offset = 5
        box.commit(lease: request.lease)
        let interruption = try XCTUnwrap(box.begin(owner: owner(), tokens: [9, 8]) { [KVCacheSimple()] })
        box.abandon(lease: interruption.lease)
    }
    func testPinSurvivesUnrelatedAbandonedRequestAndAlwaysLeavesOneInputToken() throws {
        let box = box(); try seed(box)
        let restored = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3]) { XCTFail("Must restore pin"); return [] })
        XCTAssertEqual(restored.reusedTokens, 2); XCTAssertEqual(restored.suffix, [3])
        box.abandon(lease: restored.lease)
        let again = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 7]) { [] })
        XCTAssertEqual(again.reusedTokens, 3)
        XCTAssertFalse((restored.cache[0] as AnyObject) === (again.cache[0] as AnyObject))
    }
    func testOwnerRetirementAndInvalidationErasePin() throws {
        for changeOwner in [false, true] {
            let box = box(); try seed(box)
            if !changeOwner { box.invalidate() }
            let request = try XCTUnwrap(box.begin(owner: owner(otherModel: changeOwner), tokens: [1, 2, 3, 8]) { [KVCacheSimple()] })
            XCTAssertEqual(request.reusedTokens, 0)
        }
    }
    func testInvalidEmptyOversizedAndDisabledPinsAreNotRetained() throws {
        for (box, pin) in [(box(), [1, 9]), (box(), []), (box(limit: 2), [1, 2, 3]), (box(bytes: 0), [1, 2, 3])] {
            try seed(box, pin: pin)
            let request = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 8]) { [KVCacheSimple()] })
            XCTAssertEqual(request.reusedTokens, 0)
        }
    }
    func testUnsafeCopyCannotBecomePinAndPartialPrefillCannotInventState() throws {
        for makeBox in [
            { PromptCacheBox(copyPrefix: { source, _, _ in source }) },
            { PromptCacheBox(copyPrefix: { _, _, _ in nil }) }
        ] {
            let box = makeBox(); try seed(box)
            let request = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 8]) { [KVCacheSimple()] })
            XCTAssertEqual(request.reusedTokens, 0)
        }
        let box = box(), cache = KVCacheSimple()
        let request = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 4], pinTokens: [1, 2, 3]) { [cache] })
        cache.offset = 2; box.commit(lease: request.lease)
        let replaced = try XCTUnwrap(box.begin(owner: owner(), tokens: [9, 8]) { [KVCacheSimple()] })
        box.abandon(lease: replaced.lease)
        XCTAssertEqual(box.begin(owner: owner(), tokens: [1, 2, 3, 8]) { [KVCacheSimple()] }?.reusedTokens, 0)
    }
    func testTokenProofRequiresExactTextAndAccountsForBoundaryMerge() {
        XCTAssertEqual(PromptCacheMath.pinTokens(text: "abcD", prefix: "abc", tokens: [1, 2, 99], encode: { _ in [1, 2, 3] }), [1, 2])
        XCTAssertNil(PromptCacheMath.pinTokens(text: "abcD", prefix: "xyz", tokens: [1, 2], encode: { _ in XCTFail(); return [] }))
        XCTAssertNil(PromptCacheMath.pinTokens(text: "é!", prefix: "e\u{301}", tokens: [1], encode: { _ in XCTFail(); return [] }))
        XCTAssertNil(PromptCacheMath.pinTokens(text: "abcD", prefix: "abc", tokens: [9], encode: { _ in [1, 2, 3] }))
    }
}
