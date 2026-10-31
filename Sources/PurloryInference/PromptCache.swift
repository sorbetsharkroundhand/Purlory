import Foundation
import MLX
import MLXLMCommon

/// Longest-common-prefix math for exact prompt state. The recorded prompt bounds
/// reusable input; generated tails never become prompt authority. A complete match
/// leaves at least one token for generation input. Lease/capability checks below keep
/// concurrent, retired or unsupported cache state out of this calculation.
enum PromptCacheMath {

    /// 캐시 상태에서 새 프롬프트로 재사용 가능한 접두 토큰 수.
    ///
    /// - `offset`: 캐시에 실제로 들어있는 토큰 수 (생성·중단된 프리필 포함 — 진실).
    /// - `recorded`: 마지막 `commit`이 기록한 프롬프트 토큰.
    ///   `min(offset, recorded.count)`까지는 기록과 일치가 항상 성립한다 —
    ///   프리필이 토큰 순서대로 진행하기 때문. 생성 토큰은 기록 밖이라 재사용에 안 센다.
    /// - 요청이 통째로 접두와 같으면 최소 1토큰을 남긴다 — 빈 입력으론 생성을
    ///   시작할 수 없다 (뒤로 지우기 직후).
    static func reusablePrefix(offset: Int, recorded: [Int], requested: [Int]) -> Int {
        let known = min(offset, recorded.count)
        var lcp = 0
        while lcp < known, lcp < requested.count, recorded[lcp] == requested[lcp] {
            lcp += 1
        }
        if lcp == requested.count { lcp -= 1 }
        return max(lcp, 0)
    }

    /// 재사용분을 뺀 trim 양 — 생성 토큰이든 중단된 프리필이든 이 값으로 몰아 정리된다.
    static func trimAmount(offset: Int, reused: Int) -> Int { offset - reused }

    /// Tokenization can merge at the boundary after A+B. Only the actual matching
    /// token prefix is reusable; text equality or an estimated token count is not proof.
    static func pinTokens(text: String, prefix: String?, tokens: [Int], encode: (String) -> [Int]) -> [Int]? {
        guard let prefix, !prefix.isEmpty, text.utf8.starts(with: prefix.utf8) else { return nil }
        let encoded = encode(prefix)
        let count = zip(encoded, tokens).prefix { $0 == $1 }.count
        return count > 0 ? Array(tokens.prefix(count)) : nil
    }
}

/// Shared generation state is leased until the engine has drained its generation task.
final class PromptCacheBox: @unchecked Sendable {
    struct Owner: Equatable, Sendable {
        let modelID: String
        let modelIdentity: ObjectIdentifier
        let maxKVSize: Int?
        let kvBits: Int?
        let kvGroupSize: Int
        let quantizedKVStart: Int
        let kvScheme: String?
        let kvConfiguration: KVCacheConfiguration?
        init(modelID: String, modelIdentity: ObjectIdentifier, parameters: GenerateParameters) {
            self.modelID = modelID; self.modelIdentity = modelIdentity
            maxKVSize = parameters.maxKVSize; kvBits = parameters.kvBits
            kvGroupSize = parameters.kvGroupSize; quantizedKVStart = parameters.quantizedKVStart
            kvScheme = parameters.kvScheme; kvConfiguration = parameters.kvCache
        }
    }
    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate init() { id = UUID() }
    }
    struct Reuse {
        let cache: [KVCache]
        let suffix: [Int]
        let reusedTokens: Int
        let lease: Lease
    }

    private let lock = NSLock()
    private var cache: [KVCache]?
    private var promptTokens: [Int] = []
    private var owner: Owner?
    private var active: (lease: Lease, tokens: [Int], pinTokens: [Int]?)?
    private struct Pin {
        let owner: Owner
        let tokens: [Int]
        let cache: [KVCache]
    }
    private var pinned: Pin?
    private let maxPinnedTokens: Int
    private let maxPinnedBytes: Int
    private let copyPrefix: ([KVCache], Int, Int) -> [KVCache]?

    // The copy seam keeps ownership and retirement tests independent of Metal.
    init(maxPinnedTokens: Int = 4096, maxPinnedBytes: Int = 128 * 1024 * 1024,
         copyPrefix: @escaping ([KVCache], Int, Int) -> [KVCache]? = PromptCacheCapability.independentPrefix) {
        self.maxPinnedTokens = max(0, maxPinnedTokens)
        self.maxPinnedBytes = max(0, maxPinnedBytes)
        self.copyPrefix = copyPrefix
    }

    func begin(modelID: String, tokens: [Int], pinTokens: [Int]? = nil, model: any LanguageModel, parameters: GenerateParameters) throws -> Reuse? {
        try begin(owner: Owner(modelID: modelID, modelIdentity: ObjectIdentifier(model), parameters: parameters), tokens: tokens, pinTokens: pinTokens) {
            try makePromptCache(model: model, parameters: parameters)
        }
    }

    /// The factory seam shares production ownership logic without requiring a loaded model in tests.
    func begin(owner: Owner, tokens: [Int], pinTokens: [Int]? = nil, makeCache: () throws -> [KVCache]) rethrows -> Reuse? {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, !tokens.isEmpty else { return nil }
        let lease = Lease()
        let requestedPin = pinTokens.flatMap {
            !$0.isEmpty && $0.count <= maxPinnedTokens && tokens.starts(with: $0) ? $0 : nil
        }
        if pinned?.owner != owner { pinned = nil }
        var livePrefix = 0
        if self.owner == owner, let cache, !promptTokens.isEmpty,
           case .exactPrefix(let offset) = PromptCacheCapability.inspect(cache) {
            livePrefix = PromptCacheMath.reusablePrefix(offset: offset, recorded: promptTokens, requested: tokens)
        }
        let pinnedPrefix = pinned.map { tokens.starts(with: $0.tokens) ? min($0.tokens.count, tokens.count - 1) : 0 } ?? 0
        if pinnedPrefix > livePrefix,
           let reuse = restorePin(prefix: pinnedPrefix, owner: owner, tokens: tokens, pinTokens: requestedPin, lease: lease) { return reuse }
        if livePrefix > 0, let cache, PromptCacheCapability.trim(cache, to: livePrefix) {
            active = (lease, tokens, requestedPin)
            return Reuse(cache: cache, suffix: Array(tokens[livePrefix...]), reusedTokens: livePrefix, lease: lease)
        }
        if pinnedPrefix > 0,
           let reuse = restorePin(prefix: pinnedPrefix, owner: owner, tokens: tokens, pinTokens: requestedPin, lease: lease) { return reuse }
        cache = nil; promptTokens = []; self.owner = nil
        let fresh = try makeCache()
        cache = fresh; promptTokens = []; self.owner = owner
        active = (lease, tokens, requestedPin)
        return Reuse(cache: fresh, suffix: tokens, reusedTokens: 0, lease: lease)
    }

    private func restorePin(prefix: Int, owner: Owner, tokens: [Int], pinTokens: [Int]?, lease: Lease) -> Reuse? {
        guard let pinned, pinned.owner == owner,
              let restored = snapshot(pinned.cache, count: prefix) else { return nil }
        cache = restored; promptTokens = pinned.tokens; self.owner = owner
        active = (lease, tokens, pinTokens)
        return Reuse(cache: restored, suffix: Array(tokens[prefix...]), reusedTokens: prefix, lease: lease)
    }

    private func snapshot(_ source: [KVCache], count: Int) -> [KVCache]? {
        guard maxPinnedBytes > 0, count > 0, count <= maxPinnedTokens,
              case .exactPrefix(let offset) = PromptCacheCapability.inspect(source), count <= offset,
              let result = copyPrefix(source, count, maxPinnedBytes), result.count == source.count,
              PromptCacheCapability.inspect(result) == .exactPrefix(offset: count),
              !result.contains(where: { candidate in source.contains { (candidate as AnyObject) === ($0 as AnyObject) } })
        else { return nil }
        return result
    }

    /// Captured tokens are committed only by the current lease after generation drains.
    func commit(lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard let active, active.lease == lease else { return }
        if let cache, case .exactPrefix = PromptCacheCapability.inspect(cache) {
            promptTokens = active.tokens
            if !Task<Never, Never>.isCancelled, let tokens = active.pinTokens, let owner,
               pinned?.tokens != tokens || pinned?.owner != owner,
               let snapshot = snapshot(cache, count: tokens.count) {
                pinned = Pin(owner: owner, tokens: tokens, cache: snapshot)
            }
        } else {
            cache = nil; promptTokens = []; owner = nil; pinned = nil
        }
        self.active = nil
    }

    func abandon(lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard active?.lease == lease else { return }
        // A failed live request cannot mutate the independently owned pin.
        cache = nil; promptTokens = []; owner = nil; active = nil
    }

    /// Retired leases may still finish, but cannot modify any subsequent owner or state.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cache = nil; promptTokens = []; owner = nil; active = nil; pinned = nil
    }
}

/// Exact prefix support is stronger than a topology's trim flag or its first-layer offset.
enum PromptCacheCapability: Equatable {
    case exactPrefix(offset: Int), unsupported

    static func inspect(_ cache: [KVCache]) -> Self {
        guard let offset = cache.first?.offset, offset >= 0, cache.allSatisfy({ layer in
            let supported = type(of: layer) == KVCacheSimple.self || type(of: layer) == QuantizedKVCache.self
            return supported && layer.maxSize == nil && layer.isTrimmable && layer.offset == offset
        }) else { return .unsupported }
        return .exactPrefix(offset: offset)
    }

    /// A caller must discard the entire state on partial failure; rollback is not assumed.
    static func trim(_ cache: [KVCache], to prefix: Int) -> Bool {
        guard let offset = cache.first?.offset, prefix >= 0, prefix <= offset,
              cache.allSatisfy({ $0.isTrimmable && $0.offset == offset }) else { return false }
        let count = PromptCacheMath.trimAmount(offset: offset, reused: prefix)
        for layer in cache {
            guard layer.trim(count) == count, layer.offset == prefix else { return false }
        }
        return true
    }

    /// copy() alone creates array views in the pinned MLX version. Gather and
    /// evaluate the bounded prefix into owned storage so a pin neither aliases live
    /// updates nor retains an entire long prompt through a slice's backing buffer.
    static func independentPrefix(_ cache: [KVCache], count: Int, maxBytes: Int) -> [KVCache]? {
        guard count > 0, case .exactPrefix(let offset) = inspect(cache), count <= offset else { return nil }
        var bytes = 0
        for layer in cache {
            let state = layer.state
            let validCount = type(of: layer) == KVCacheSimple.self ? state.count == 2 : (state.count == 4 || state.count == 6)
            guard validCount else { return nil }
            for array in state {
                guard array.ndim == 4, array.dim(2) == offset, array.shape.allSatisfy({ $0 > 0 }) else { return nil }
                let (size, overflow) = (array.nbytes / offset).multipliedReportingOverflow(by: count)
                guard !overflow, size <= maxBytes - bytes else { return nil }
                bytes += size
            }
        }
        let snapshot = cache.map { $0.copy() }
        guard trim(snapshot, to: count) else { return nil }
        let indices = MLXArray(0..<count)
        for var layer in snapshot {
            let owned = layer.state.map { take($0, indices, axis: 2) }
            eval(owned)
            layer.state = owned
        }
        guard inspect(snapshot) == .exactPrefix(offset: count) else { return nil }
        return snapshot
    }
}
