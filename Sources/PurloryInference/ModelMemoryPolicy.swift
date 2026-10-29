import Foundation
import Metal

public enum MemoryTier: Int, CaseIterable, Codable, Sendable {
    case gb8 = 8, gb16 = 16, gb24 = 24, gb32 = 32
}
public struct HardwareMemory: Sendable {
    public let physicalBytes: UInt64
    public let recommendedWorkingSetBytes: UInt64
    public let hasUnifiedMemory: Bool
    public init(physicalBytes: UInt64, recommendedWorkingSetBytes: UInt64, hasUnifiedMemory: Bool) {
        self.physicalBytes = physicalBytes; self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.hasUnifiedMemory = hasUnifiedMemory
    }
    public var tier: MemoryTier? {
        guard hasUnifiedMemory, recommendedWorkingSetBytes > 0 else { return nil }
        return MemoryTier.allCases.last { UInt64($0.rawValue) * (1 << 30) <= physicalBytes }
    }
    /// #180's peak target: 60% of the smaller physical/Metal recommended working set.
    public var budgetBytes: UInt64? {
        guard tier != nil else { return nil }
        let bytes = min(physicalBytes, recommendedWorkingSetBytes)
        return bytes / 5 * 3 + bytes % 5 * 3 / 5
    }
    public static let current: HardwareMemory = {
        let device = MTLCreateSystemDefaultDevice()
        return .init(physicalBytes: ProcessInfo.processInfo.physicalMemory,
                     recommendedWorkingSetBytes: device?.recommendedMaxWorkingSetSize ?? 0,
                     hasUnifiedMemory: device?.hasUnifiedMemory ?? false)
    }()
}
public struct ModelReleaseEntry: Codable, Equatable, Sendable {
    public var id: String
    public var revision: String
    public var peakBytes: UInt64
    public var tiers: Set<MemoryTier>
    public var defaultTiers: Set<MemoryTier>
    public var name: String
    public init(id: String, revision: String, peakBytes: UInt64, tiers: Set<MemoryTier>, defaultTiers: Set<MemoryTier>, name: String) {
        self.id = id; self.revision = revision; self.peakBytes = peakBytes
        self.tiers = tiers; self.defaultTiers = defaultTiers; self.name = name
    }
}
public enum ModelMemoryError: LocalizedError, Equatable {
    case unsupportedHardware, unapproved, invalidCatalog, budgetExceeded
    public var errorDescription: String? {
        let reason = switch self {
        case .unsupportedHardware: "이 Mac에서는 지원되는 통합 메모리 용량을 확인할 수 없습니다."
        case .unapproved: "이 Mac에서 사용할 수 있는 모델로 아직 검증되지 않았습니다."
        case .invalidCatalog: "모델의 메모리 설정을 확인할 수 없습니다."
        case .budgetExceeded: "모델에 필요한 메모리가 이 Mac의 사용 가능 용량을 초과합니다."
        }
        return reason + " 원고 편집은 계속할 수 있습니다."
    }
}
public struct ModelMemoryPolicy: Sendable {
    public let hardware: HardwareMemory
    public let entries: [ModelReleaseEntry]
    private var candidatePeakBytes: UInt64?
    // Populated only from owner-approved #180 measurements and #155 license evidence.
    public static let approvedEntries: [ModelReleaseEntry] = []
    public static let current = ModelMemoryPolicy(hardware: .current, entries: approvedEntries)
    public init(hardware: HardwareMemory, entries: [ModelReleaseEntry]) {
        self.hardware = hardware; self.entries = entries
    }
    public var availableEntries: [ModelReleaseEntry] {
        guard candidatePeakBytes == nil, validCatalog else { return [] }
        return entries.filter { entry in
            guard let manifest = PinnedModelCatalog.manifest(for: entry.id) else { return false }
            return (try? requireLoad(manifest: manifest)) != nil
        }
    }
    public var defaultModelID: String? {
        guard let tier = hardware.tier else { return nil }
        return availableEntries.first { $0.defaultTiers.contains(tier) }?.id
    }
    public func requireLoad(manifest: ModelInstallManifest) throws {
        try manifest.validate()
        guard PinnedModelCatalog.manifest(for: manifest.id) == manifest else { throw ModelMemoryError.unapproved }
        guard let tier = hardware.tier, let budget = hardware.budgetBytes else { throw ModelMemoryError.unsupportedHardware }
        let peak: UInt64
        if let candidatePeakBytes {
            guard candidatePeakBytes >= weightBytes(manifest) else { throw ModelMemoryError.invalidCatalog }
            peak = candidatePeakBytes
        } else {
            guard validCatalog else { throw ModelMemoryError.invalidCatalog }
            guard let entry = entries.first(where: { $0.id == manifest.id && $0.revision == manifest.revision }),
                  entry.tiers.contains(tier) else { throw ModelMemoryError.unapproved }
            peak = entry.peakBytes
        }
        guard peak <= budget else { throw ModelMemoryError.budgetExceeded }
    }
    /// Explicit measurement intent; never makes a candidate a normal release option.
    public func evaluatingCandidates(peakBytes: UInt64) -> ModelMemoryPolicy {
        var policy = ModelMemoryPolicy(hardware: hardware, entries: [])
        policy.candidatePeakBytes = peakBytes
        return policy
    }
    private var validCatalog: Bool {
        var ids = Set<String>(), defaults = Set<MemoryTier>()
        for entry in entries {
            guard ids.insert(entry.id).inserted, !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let pin = PinnedModelCatalog.manifest(for: entry.id), pin.revision == entry.revision,
                  entry.peakBytes >= weightBytes(pin), !entry.tiers.isEmpty,
                  entry.defaultTiers.isSubset(of: entry.tiers), defaults.isDisjoint(with: entry.defaultTiers)
            else { return false }
            defaults.formUnion(entry.defaultTiers)
        }
        return true
    }
    private func weightBytes(_ manifest: ModelInstallManifest) -> UInt64 {
        // A lower bound only; approval must supply measured peak, never infer fit from file size.
        manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(0) { $0 + UInt64($1.size) }
    }
}
