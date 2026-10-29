import Foundation
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
    private var active: (lease: Lease, tokens: [Int])?

    func begin(modelID: String, tokens: [Int], model: any LanguageModel, parameters: GenerateParameters) throws -> Reuse? {
        try begin(owner: Owner(modelID: modelID, modelIdentity: ObjectIdentifier(model), parameters: parameters), tokens: tokens) {
            try makePromptCache(model: model, parameters: parameters)
        }
    }

    /// The factory seam shares production ownership logic without requiring a loaded model in tests.
    func begin(owner: Owner, tokens: [Int], makeCache: () throws -> [KVCache]) rethrows -> Reuse? {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, !tokens.isEmpty else { return nil }
        let lease = Lease()
        if self.owner == owner, let cache, !promptTokens.isEmpty,
           case .exactPrefix(let offset) = PromptCacheCapability.inspect(cache) {
            let prefix = PromptCacheMath.reusablePrefix(offset: offset, recorded: promptTokens, requested: tokens)
            if prefix > 0, PromptCacheCapability.trim(cache, to: prefix) {
                active = (lease, tokens)
                return Reuse(cache: cache, suffix: Array(tokens[prefix...]), reusedTokens: prefix, lease: lease)
            }
        }
        cache = nil; promptTokens = []; self.owner = nil
        let fresh = try makeCache()
        cache = fresh; promptTokens = []; self.owner = owner
        active = (lease, tokens)
        return Reuse(cache: fresh, suffix: tokens, reusedTokens: 0, lease: lease)
    }

    /// Captured tokens are committed only by the current lease after generation drains.
    func commit(lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard let active, active.lease == lease else { return }
        if let cache, case .exactPrefix = PromptCacheCapability.inspect(cache) {
            promptTokens = active.tokens
        } else {
            cache = nil; promptTokens = []; owner = nil
        }
        self.active = nil
    }

    func abandon(lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard active?.lease == lease else { return }
        cache = nil; promptTokens = []; owner = nil; active = nil
    }

    /// Retired leases may still finish, but cannot modify any subsequent owner or state.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cache = nil; promptTokens = []; owner = nil; active = nil
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
}
