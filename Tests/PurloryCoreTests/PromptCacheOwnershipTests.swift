@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import Foundation
import MLX
import MLXLMCommon
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class PromptCacheOwnershipTests: XCTestCase {
    private let model = NSObject(), otherModel = NSObject()
    private func owner(_ parameters: GenerateParameters = .init(), other: Bool = false) -> PromptCacheBox.Owner {
        .init(modelID: "same-model-name", modelIdentity: ObjectIdentifier(other ? otherModel : model), parameters: parameters)
    }

    func testOnlyKnownFullPrefixLayersWithUniformOffsetsAreAdmitted() {
        let a = KVCacheSimple(), b = QuantizedKVCache()
        a.offset = 8; b.offset = 8
        XCTAssertEqual(PromptCacheCapability.inspect([a, b]), .exactPrefix(offset: 8))
        b.offset = 7
        XCTAssertEqual(PromptCacheCapability.inspect([a, b]), .unsupported)
        a.offset = -1
        XCTAssertEqual(PromptCacheCapability.inspect([a]), .unsupported)
        XCTAssertEqual(PromptCacheCapability.inspect([]), .unsupported)
        for cache: KVCache in [RotatingKVCache(maxSize: 32), ArraysCache(size: 2), CacheList(KVCacheSimple()), MetadataTrimCache()] {
            XCTAssertEqual(PromptCacheCapability.inspect([cache]), .unsupported)
        }
    }

    func testEveryLayerMustReturnExactTrimAndReachTheSamePrefix() {
        let first = MetadataTrimCache(), second = MetadataTrimCache()
        first.offset = 8; second.offset = 8; second.refuse = true
        XCTAssertFalse(PromptCacheCapability.trim([first, second], to: 4), "First-layer success cannot hide another failure")
        first.offset = 8; second.offset = 8; second.refuse = false; second.lie = true
        XCTAssertFalse(PromptCacheCapability.trim([first, second], to: 4), "A reported trim alone cannot prove final state")
        first.offset = 8; second.offset = 8; second.lie = false
        XCTAssertTrue(PromptCacheCapability.trim([first, second], to: 4))
        XCTAssertEqual(first.offset, 4); XCTAssertEqual(second.offset, 4)
    }

    func testGenerationTailIsTrimmedAndOnlyExactRequestedTokensAreCommitted() throws {
        let box = PromptCacheBox(), a = KVCacheSimple(), b = KVCacheSimple()
        let first = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 4], makeCache: { [a, b] }))
        XCTAssertEqual(first.reusedTokens, 0)
        a.offset = 7; b.offset = 7
        box.commit(lease: first.lease)
        let next = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 4, 5], makeCache: { XCTFail("Must reuse proven prefix"); return [] }))
        XCTAssertEqual(next.reusedTokens, 4); XCTAssertEqual(next.suffix, [5])
        XCTAssertTrue((next.cache.first as? KVCacheSimple) === a); XCTAssertEqual(a.offset, 4); XCTAssertEqual(b.offset, 4)
        box.abandon(lease: next.lease)
    }

    func testPartialPrefillAndIdenticalRequestKeepAtLeastOneInputToken() throws {
        let box = PromptCacheBox(), cache = KVCacheSimple(), tokens = Array(0..<10)
        let first = try XCTUnwrap(box.begin(owner: owner(), tokens: tokens, makeCache: { [cache] }))
        cache.offset = 4; box.commit(lease: first.lease)
        let partial = try XCTUnwrap(box.begin(owner: owner(), tokens: tokens, makeCache: { [] }))
        XCTAssertEqual(partial.reusedTokens, 4); XCTAssertEqual(partial.suffix, Array(4..<10))
        cache.offset = 10; box.commit(lease: partial.lease)
        let identical = try XCTUnwrap(box.begin(owner: owner(), tokens: tokens, makeCache: { [] }))
        XCTAssertEqual(identical.reusedTokens, 9); XCTAssertEqual(identical.suffix, [9])
        box.abandon(lease: identical.lease)
    }

    func testOldCommitAndAbandonAfterResetCannotReleaseOrOverwriteNewLease() throws {
        let box = PromptCacheBox(), oldCache = KVCacheSimple(), current = KVCacheSimple()
        let old = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3, 4], makeCache: { [oldCache] }))
        oldCache.offset = 4
        box.invalidate()
        let fresh = try XCTUnwrap(box.begin(owner: owner(), tokens: [9, 8], makeCache: { [current] }))
        current.offset = 2
        box.commit(lease: old.lease)
        XCTAssertNil(box.begin(owner: owner(), tokens: [9, 8, 7], makeCache: { XCTFail("Current lease is still busy"); return [] }))
        box.abandon(lease: old.lease)
        box.commit(lease: fresh.lease)
        let reused = try XCTUnwrap(box.begin(owner: owner(), tokens: [9, 8, 7], makeCache: { XCTFail("Stale abandon must preserve new state"); return [] }))
        XCTAssertEqual(reused.reusedTokens, 2); XCTAssertTrue((reused.cache.first as? KVCacheSimple) === current)
        box.abandon(lease: reused.lease)
    }

    func testFailedCacheCreationDoesNotLeaveTheNextRequestBusy() throws {
        enum Failure: Error { case unavailable }
        let box = PromptCacheBox()
        XCTAssertThrowsError(try box.begin(owner: owner(), tokens: [1, 2], makeCache: {
            throw Failure.unavailable
        }))
        let next = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2], makeCache: { [KVCacheSimple()] }))
        XCTAssertEqual(next.reusedTokens, 0)
        XCTAssertEqual(next.suffix, [1, 2])
        box.abandon(lease: next.lease)
    }

    func testActualModelIdentityAndAllCacheShapingParametersOwnSeparateStates() throws {
        var variants = [owner(other: true)]
        var parameters = GenerateParameters(); parameters.maxKVSize = 32; variants.append(owner(parameters))
        parameters = .init(); parameters.kvBits = 4; variants.append(owner(parameters))
        parameters = .init(); parameters.kvGroupSize = 128; variants.append(owner(parameters))
        parameters = .init(); parameters.quantizedKVStart = 64; variants.append(owner(parameters))
        parameters = .init(); parameters.kvScheme = "affine4"; variants.append(owner(parameters))
        parameters = .init(); parameters.kvCache = .init(capacity: try .init(maxTokens: 32)); variants.append(owner(parameters))
        for changed in variants {
            let box = PromptCacheBox(), cache = KVCacheSimple()
            let first = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2], makeCache: { [cache] }))
            cache.offset = 2; box.commit(lease: first.lease)
            var created = false
            let next = try XCTUnwrap(box.begin(owner: changed, tokens: [1, 2, 3], makeCache: { created = true; return [KVCacheSimple()] }))
            XCTAssertTrue(created); XCTAssertEqual(next.reusedTokens, 0)
            box.abandon(lease: next.lease)
        }
    }

    func testUnsupportedOrDivergentCommittedStateUsesFreshFallbackAndErrorsRetireOnlyOwnLease() throws {
        for unsupported: [KVCache] in [[ArraysCache(size: 2)], [CacheList(KVCacheSimple())], [RotatingKVCache(maxSize: 32)]] {
            let box = PromptCacheBox()
            let first = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2], makeCache: { unsupported }))
            box.commit(lease: first.lease)
            var created = false
            let next = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3], makeCache: { created = true; return [KVCacheSimple()] }))
            XCTAssertTrue(created); XCTAssertEqual(next.reusedTokens, 0)
            box.abandon(lease: next.lease)
        }
        let box = PromptCacheBox(), a = KVCacheSimple(), b = KVCacheSimple()
        let first = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2], makeCache: { [a, b] }))
        a.offset = 2; b.offset = 1; box.commit(lease: first.lease)
        let next = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3], makeCache: { [KVCacheSimple()] }))
        XCTAssertEqual(next.reusedTokens, 0)
        box.abandon(lease: next.lease)
        let afterError = try XCTUnwrap(box.begin(owner: owner(), tokens: [1, 2, 3], makeCache: { [KVCacheSimple()] }))
        XCTAssertEqual(afterError.reusedTokens, 0)
        box.abandon(lease: afterError.lease)
    }
}

private final class MetadataTrimCache: KVCache {
    var offset = 0
    var maxSize: Int? { nil }
    var state: [MLXArray] = []
    var metaState: [String] = []
    var refuse = false, lie = false
    var isTrimmable: Bool { true }
    func trim(_ n: Int) -> Int {
        if refuse { return 0 }
        if lie { return n }
        offset -= n; return n
    }
    func innerState() -> [MLXArray] { [] }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) { fatalError("Metadata fixture never evaluates tensors") }
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        fatalError("Metadata fixture never evaluates tensors")
    }
    func copy() -> any KVCache { fatalError("Metadata fixture never copies tensors") }
}
