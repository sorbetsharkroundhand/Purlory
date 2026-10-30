import Foundation

/// 문서별 마지막 집필 위치 (이슈 #36) — **UI 상태**다. 원문(entries.json)이 아니라
/// UserDefaults에 산다: 파생 캐시는 아니지만 사용자 저작도 아닌 창 상태이고,
/// 지워져도 원문은 무사하다.
///
/// 저장 값은 커서 위치만이 아니라 **주변 문맥 앵커**(직전·이후 최대 24자)를 함께
/// 담는다 — 편집으로 위치가 밀렸을 때 정확한 clamp 대신 앵커로 재안착(re-anchor)
/// 하기 위해서다. "3장 중간을 고치던 자리"는 문자 오프셋보다 문맥으로 찾는 게 맞다.
///
/// 확정된 선택 범위는 복원하되 IME 조합(marked text) 중 위치는 저장하지 않는다 —
/// 확정되지 않은 한글 조합 자리를 복원하면 깨진 글자 자리로 뛰는 꼴이 된다.
@MainActor
public final class WritingPositionStore {

    public struct Position: Codable, Equatable, Sendable {
        /// 커서 UTF-16 위치 — 저장 시점 기준.
        public var location: Int
        /// 선택 범위 길이. 기존 저장값에는 없으므로 디코드 시 0으로 간주한다.
        public var selectionLength: Int
        /// 커서 직전 본문 조각(≤24자) — 재안착 키.
        public var before: String
        /// 커서 위치부터의 본문 조각(≤24자) — 재안착 검증.
        public var after: String

        public init(
            location: Int, selectionLength: Int = 0, before: String, after: String
        ) {
            self.location = location
            self.selectionLength = selectionLength
            self.before = before
            self.after = after
        }

        private enum CodingKeys: String, CodingKey {
            case location
            case selectionLength
            case before
            case after
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            location = try container.decode(Int.self, forKey: .location)
            selectionLength = try container.decodeIfPresent(Int.self, forKey: .selectionLength) ?? 0
            before = try container.decode(String.self, forKey: .before)
            after = try container.decode(String.self, forKey: .after)
        }
    }

    public static let shared = WritingPositionStore()

    static let maxEntries = 200

    private let defaults: UserDefaults
    private let key = "purlory.writingPositions"
    private(set) var positions: [UUID: Position] = [:]
    private var projectPositions: [ProjectDocumentKey: Position] = [:]
    private var persistTask: Task<Void, Never>?
    private var needsPersistence = false
    /// 디스크 쓰기 디바운스 — 타이핑마다 UserDefaults를 치지 않게.
    private let persistDelay: Duration

    init(defaults: UserDefaults = .standard, persistDelay: Duration = .seconds(2)) {
        self.defaults = defaults
        self.persistDelay = persistDelay
        if let data = defaults.data(forKey: key) {
            if let decoded = try? JSONDecoder().decode([String: Position].self, from: data) {
                for (rawKey, position) in decoded {
                    if let projectKey = Self.projectKey(from: rawKey) {
                        projectPositions[projectKey] = position
                    } else if let legacyID = UUID(uuidString: rawKey) {
                        positions[legacyID] = position
                    }
                }
            } else if let decoded = try? JSONDecoder().decode([UUID: Position].self, from: data) {
                positions = decoded
            }
        }
    }

    func position(for entryID: UUID) -> Position? {
        positions[entryID]
    }

    /// 프로젝트 문서는 복합 키를 우선하고, 해당 키가 없을 때만 UUID-only legacy
    /// 위치를 읽는다. 읽기는 저장 형식을 바꾸거나 legacy 값을 지우지 않는다.
    func position(for key: ProjectDocumentKey) -> Position? {
        projectPositions[key] ?? positions[key.documentID.rawValue]
    }

    /// 현재 위치를 기록한다. `marked`가 true면(IME 조합 중) 무시한다 (#36).
    func record(
        entryID: UUID, location: Int, before: String, after: String,
        marked: Bool
    ) {
        guard !marked else { return }
        trimIfNeeded(isNew: positions[entryID] == nil)
        positions[entryID] = Position(
            location: location, selectionLength: 0,
            before: String(before.suffix(24)),
            after: String(after.prefix(24)))
        needsPersistence = true
        schedulePersist()
    }

    /// 프로젝트/문서 복합 키로 현재 선택 위치를 기록한다.
    func record(
        location: Int, selectionLength: Int, body: String, for key: ProjectDocumentKey,
        marked: Bool = false
    ) {
        guard !marked else { return }
        trimIfNeeded(isNew: projectPositions[key] == nil)
        let ns = body as NSString
        let safeLocation = max(0, min(location, ns.length))
        let safeSelectionLength = max(0, min(selectionLength, ns.length - safeLocation))
        let beforeStart = max(0, safeLocation - 24)
        let selectionEnd = safeLocation + safeSelectionLength
        let afterEnd = min(ns.length, selectionEnd + 24)
        projectPositions[key] = Position(
            location: safeLocation,
            selectionLength: safeSelectionLength,
            before: ns.substring(
                with: NSRange(location: beforeStart, length: safeLocation - beforeStart)),
            after: ns.substring(
                with: NSRange(location: selectionEnd, length: afterEnd - selectionEnd)))
        needsPersistence = true
        schedulePersist()
    }

    /// 텍스트가 바뀐 뒤의 복원 위치를 푼다 — 재안착 사다리 (#36):
    /// 1. 저장 위치 그대로 유효하고 문맥이 일치 → 그대로.
    /// 2. 위치가 어긋났으면 `before` 꼬리(최근 12자)를 본문에서 찾아 그 끝으로.
    /// 3. 못 찾으면 nil — 문서 맨 위 규칙(load 기본 동작)을 따른다.
    func resolve(for entryID: UUID, in text: String) -> Int? {
        guard let position = positions[entryID] else { return nil }
        return Self.resolve(position, in: text)
    }

    /// 프로젝트 위치를 현재 본문에 재안착한다. 복합 레코드가 있으면 그것만 사용하고,
    /// 없을 때에만 동일 UUID의 legacy 레코드를 fallback으로 읽는다.
    func restore(in text: String, for key: ProjectDocumentKey) -> Position? {
        guard let stored = projectPositions[key] ?? positions[key.documentID.rawValue],
            let location = Self.resolve(stored, in: text)
        else { return nil }
        let length = (text as NSString).length
        return Position(
            location: location,
            selectionLength: max(
                0, min(stored.selectionLength, max(0, length - location))),
            before: stored.before,
            after: stored.after)
    }

    private static func resolve(_ p: Position, in text: String) -> Int? {
        let ns = text as NSString
        let length = ns.length
        if p.location >= 0, p.selectionLength >= 0, p.location <= length,
            p.selectionLength <= length - p.location
        {
            let selectionEnd = p.location + p.selectionLength
            let beforeStart = max(0, p.location - p.before.utf16.count)
            let beforeMatches =
                ns.substring(with: NSRange(location: beforeStart, length: p.location - beforeStart))
                .hasSuffix(p.before)
            let afterEnd = min(length, selectionEnd + p.after.utf16.count)
            let afterMatches =
                ns.substring(with: NSRange(location: selectionEnd, length: afterEnd - selectionEnd))
                .hasPrefix(p.after)
            if beforeMatches && afterMatches { return p.location }
        }
        // 재안착 — before 꼬리로. 짧은 앵커일수록 허위 적중이 늘지만, 12자 연속
        // 일치가 허위일 확률은 한국어 장편에서 무시할 수준이다.
        let anchor = String(p.before.suffix(12))
        if anchor.utf16.count >= 4 {
            var searchRange = NSRange(location: 0, length: length)
            var best: Int?
            while searchRange.location < length {
                let found = ns.range(of: anchor, range: searchRange)
                guard found.location != NSNotFound else { break }
                best = found.upperBound  // 마지막 등장 — 최근에 쓴 자리일 가능성.
                searchRange.location = found.upperBound
                searchRange.length = length - found.upperBound
            }
            if let restored = best { return restored }
        }
        return nil
    }

    private func trimIfNeeded(isNew: Bool) {
        let totalCount = projectPositions.count + positions.count
        guard isNew, totalCount >= Self.maxEntries else { return }
        let targetCount = Self.maxEntries / 2
        // There is no persisted recency metadata in the legacy schema. Retain the same
        // proportion of each identity category and choose evictions by stable key order so the
        // combined cap is deterministic without pretending to provide LRU semantics.
        let projectTarget = targetCount * projectPositions.count / totalCount
        let legacyTarget = targetCount - projectTarget
        let projectRemovalCount = projectPositions.count - projectTarget
        let legacyRemovalCount = positions.count - legacyTarget
        let projectKeys = projectPositions.keys.sorted {
            Self.storageKey(for: $0) < Self.storageKey(for: $1)
        }
        let legacyIDs = positions.keys.sorted { $0.uuidString < $1.uuidString }
        for projectKey in projectKeys.prefix(projectRemovalCount) {
            projectPositions.removeValue(forKey: projectKey)
        }
        for legacyID in legacyIDs.prefix(legacyRemovalCount) {
            positions.removeValue(forKey: legacyID)
        }
    }

    private static func storageKey(for key: ProjectDocumentKey) -> String {
        "\(key.projectID.rawValue.uuidString)/\(key.documentID.rawValue.uuidString)"
    }

    private static func projectKey(from rawValue: String) -> ProjectDocumentKey? {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let projectID = UUID(uuidString: String(parts[0])),
            let documentID = UUID(uuidString: String(parts[1]))
        else { return nil }
        return ProjectDocumentKey(
            projectID: WritingProjectID(rawValue: projectID),
            documentID: WritingDocumentID(rawValue: documentID))
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: self?.persistDelay ?? .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// 즉시 디스크 반영 — 앱 종료 훅(AppDelegate flush 경로)에서 호출.
    public func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        guard needsPersistence else { return }
        var encoded = Dictionary(uniqueKeysWithValues: positions.map {
            ($0.key.uuidString, $0.value)
        })
        for (projectKey, position) in projectPositions {
            encoded[Self.storageKey(for: projectKey)] = position
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(encoded) else { return }
        defaults.set(data, forKey: key)
        needsPersistence = false
    }

    /// 테스트 격리 — 사용자 실제 UserDefaults를 건드리지 않게.
    func _testReset() {
        positions = [:]
        projectPositions = [:]
        needsPersistence = false
        defaults.removeObject(forKey: key)
    }
}
