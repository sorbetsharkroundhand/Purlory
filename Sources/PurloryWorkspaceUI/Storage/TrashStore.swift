import Foundation

/// 앱 휴지통 — 구조 삭제(저널·폴더)의 **내구 복제본** (이슈 #9).
///
/// ⌘Z는 즉시 복원이고 앱을 다시 열면 사라지지만, 휴지통은 디스크에 남는다:
/// "undo 가능 기간이 지난 실수"도 여기서 복구할 수 있어야 한다는 요구다.
/// 영구 삭제(비우기·개별 purge)만 확인 Alert의 대상이다 — 일반 삭제는
/// 묻지 않고 바로 휴지통으로 가며 ⌘Z를 안내한다.
@MainActor
public final class TrashStore: ObservableObject {

    public struct Item: Codable, Identifiable, Equatable {
        public var id = UUID()
        /// 폴더 삭제면 하위 폴더·저널 전체가 함께 들어간다.
        public var folders: [JournalFolder]
        public var entries: [JournalEntry]
        public var deletedAt: Date

        public var title: String {
            if let first = entries.first, !entries.isEmpty {
                return entries.count == 1
                    ? first.title
                    : "\(first.title) 외 \(entries.count - 1)개"
            }
            return folders.first?.name ?? "빈 항목"
        }

        public var isFolderBundle: Bool { !folders.isEmpty }
    }

    @Published public private(set) var items: [Item] = []

    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("trash.json", isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
            let loaded = try? JSONDecoder().decode([Item].self, from: data)
        {
            items = loaded
        }
    }

    /// 최신 항목이 앞에 오도록 넣는다.
    public func add(folders: [JournalFolder], entries: [JournalEntry]) {
        guard !folders.isEmpty || !entries.isEmpty else { return }
        items.insert(
            Item(folders: folders, entries: entries, deletedAt: .now), at: 0)
        persist()
    }

    /// 항목을 복원해 돌려준다 — 호출자(EntryStore)가 문서 구조로 되살린다.
    public func take(id: UUID) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        persist()
        return item
    }

    /// 영구 삭제 — 이 동작만이 되돌릴 수 없으므로 UI가 확인을 묻는다.
    public func purge(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func purgeAll() {
        items.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
