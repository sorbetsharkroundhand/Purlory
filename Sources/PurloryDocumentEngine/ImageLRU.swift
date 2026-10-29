import AppKit

/// 바이트 상한 LRU — 이미지·수식 렌더 캐시 공용 (#53).
///
/// 배열 앞쪽이 최근 항목. 적중 시 맨 앞으로 옮기고, 삽입 때 한도를 넘기면
/// 꼬리부터 내보낸다. `removeAll()` 클리프가 만드는 재디코딩 스파이크(스크롤
/// 버벅임의 정체)가 이 구조에서는 구조적으로 불가능하다. 메인 스레드 전용 —
/// 소유자(PurloryImageStore·MathRenderer)가 모두 메인 격리다.
package struct ImageLRU {
    package struct Entry {
        package let key: String
        package let image: NSImage
        package let bytes: Int
    }

    package let budgetBytes: Int
    package private(set) var entries: [Entry] = []
    package private(set) var totalBytes = 0

    package init(budgetBytes: Int) {
        self.budgetBytes = budgetBytes
    }

    /// 적중 — 최근 표시로 옮기고 이미지를 돌려준다.
    package mutating func find(_ key: String) -> NSImage? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
        return entry.image
    }

    /// 삽입 — 한도 초과분은 오래된 순서로 내보낸다. 항목 하나가 한도보다 크면
    /// 그 항목만 남는다(전체 비움 대신 최소 보유).
    package mutating func insert(key: String, image: NSImage, bytes: Int) {
        if let existing = entries.firstIndex(where: { $0.key == key }) {
            totalBytes -= entries[existing].bytes
            entries.remove(at: existing)
        }
        entries.insert(Entry(key: key, image: image, bytes: bytes), at: 0)
        totalBytes += bytes
        while totalBytes > budgetBytes, entries.count > 1 {
            let evicted = entries.removeLast()
            totalBytes -= evicted.bytes
        }
    }

    package mutating func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }
}
