import Foundation

/// asset 수명 장부 — 저장된 asset을 후보로 적어 두고, 유예 기간이 지난 뒤
/// **참조가 없는 것만** 지운다 (이슈 #17, 완료 조건 4).
///
/// 왜 삭제 시점이 아니라 **저장 시점**에 적어 두나: 삽입 취소(undo), 잘라내기 후
/// 재붙여넣기 실패, 드래그 중단 등 고아가 되는 경로는 여럿이라 원인별 훅이
/// 필요 없다. 판정은 "지금 참조되는가" 하나고, redo·재삽입은 유예 기간 안에서
/// 일어나므로 저장 시각 기록으로 충분하다. 참조 판정은 #12 파서 단일 진실 —
/// title·angle·괄호·참조형 문법을 전부 인정한다 (#7 교훈).
@MainActor
public enum AssetJanitor {

    /// redo·재삽입이 끝나는 데 충분한 유예. 이 안의 후보는 참조가 없어도 살린다.
    public static let graceInterval: TimeInterval = 60 * 60

    struct Ledger: Codable {
        var version = 1
        /// relPath("images/x.png") → 후보 등록(저장) 시각
        var candidates: [String: Date] = [:]
    }

    /// Use the explicit root when supplied; otherwise preserve the image-store test override.
    public static func ledgerURL(storageLocation: PurloryStorageLocation? = nil) -> URL? {
        url(for: "images/.purlory-janitor.json", storageLocation: storageLocation)
    }

    /// 장부에 유예 중인 후보가 있는가 — 시작 청소의 조기 탈출용.
    public static func hasPendingCandidates(storageLocation: PurloryStorageLocation? = nil) -> Bool {
        !load(storageLocation: storageLocation).candidates.isEmpty
    }

    // MARK: 등록

    /// asset 저장 시 후보 등록. 같은 키 재등록은 최초 시각을 유지한다 —
    /// 잦은 저장이 유예를 무한 리셋하지 않게. `at`은 회귀 테스트의 시간 주입용.
    public static func record(
        _ relativePath: String, at date: Date = .now, storageLocation: PurloryStorageLocation? = nil
    ) {
        guard relativePath.hasPrefix("images/"),
            case .managedRelative = ImageReferenceParser.classify(relativePath)
        else { return }
        var ledger = load(storageLocation: storageLocation)
        guard ledger.candidates[relativePath] == nil else { return }
        ledger.candidates[relativePath] = date
        save(ledger, storageLocation: storageLocation)
    }

    // MARK: 청소

    /// 유예가 지났고 어디에도 참조되지 않는 후보를 지우고 목록을 돌려준다.
    /// - Parameters:
    ///   - isReferenced: 전체 문서 파싱으로 만든 참조 집합 조회.
    ///   - performDelete: 실제 삭제 (호출자가 실패 정책 소유).
    @discardableResult
    public static func sweep(
        now: Date = .now,
        storageLocation: PurloryStorageLocation? = nil,
        isReferenced: (String) -> Bool,
        performDelete: (String) -> Void
    ) -> [String] {
        var ledger = load(storageLocation: storageLocation)
        var removed: [String] = []
        for (path, registeredAt) in ledger.candidates.sorted(by: { $0.value < $1.value }) {
            if Task.isCancelled { break }
            defer { ledger.candidates.removeValue(forKey: path) }
            guard now.timeIntervalSince(registeredAt) >= graceInterval else { continue }
            if isReferenced(path) { continue }  // 살아난 참조 — 장부에서만 내린다
            performDelete(path)
            removed.append(path)
        }
        save(ledger, storageLocation: storageLocation)
        return removed
    }

    /// 앱 시작 청소 — 모든 저널 본문에서 참조 집합을 만들어 한 번 튼다.
    /// 저전력·과열에선 다음 시작으로 미룬다 (백그라운드 3요건).
    @discardableResult
    public static func sweepAll(
        bodies: [String], now: Date = .now, storageLocation: PurloryStorageLocation? = nil
    ) -> [String] {
        let info = ProcessInfo.processInfo
        guard info.thermalState != .critical, !info.isLowPowerModeEnabled else { return [] }
        let referenced = collectReferenced(in: bodies)
        return sweep(now: now, storageLocation: storageLocation) { path in
            referenced.contains(path)
        } performDelete: { path in
            guard path.hasPrefix("images/"),
                case .managedRelative = ImageReferenceParser.classify(path),
                let url = url(for: path, storageLocation: storageLocation)
            else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 본문들에 나오는 관리·외부 이미지 소스 전체 — 펜스 밖만, 참조형 정의 줄 포함.
    static func collectReferenced(in bodies: [String]) -> Set<String> {
        var result = Set<String>()
        for body in bodies {
            let definitions = ImageReferenceParser.collectDefinitions(in: body)
            var inFence = false
            for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    inFence.toggle()
                    continue
                }
                guard !inFence else { continue }
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if let ref = ImageReferenceParser.parse(line, definitions: definitions) {
                    switch ref.destinationKind {
                    case .managedRelative(let p), .externalFile(let p):
                        result.insert(p)
                    case .remote, .blocked:
                        break
                    }
                } else if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                    line.index(after: close) < line.endIndex,
                    line[line.index(after: close)] == ":"
                {
                    let label = String(line[line.index(after: line.startIndex)..<close])
                    if let def = definitions[
                        label.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .joined(separator: " ")]
                    {
                        switch ImageReferenceParser.classify(def.destinationRaw) {
                        case .managedRelative(let p), .externalFile(let p):
                            result.insert(p)
                        case .remote, .blocked:
                            break
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: 장부 입출력 — 깨지면 버리고 새로 시작하는 캐시다.

    private static func url(for path: String, storageLocation: PurloryStorageLocation?) -> URL? {
        if let storageLocation {
            return PurloryImageStore.resolveURL(for: path, under: storageLocation.rootDirectory)
        }
        return PurloryImageStore.url(for: path)
    }

    private static func load(storageLocation: PurloryStorageLocation?) -> Ledger {
        guard let url = ledgerURL(storageLocation: storageLocation), let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(Ledger.self, from: data)
        else { return Ledger() }
        return ledger
    }

    private static func save(_ ledger: Ledger, storageLocation: PurloryStorageLocation?) {
        guard let url = ledgerURL(storageLocation: storageLocation), let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
