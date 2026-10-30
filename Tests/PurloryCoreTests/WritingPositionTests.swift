@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 문서별 집필 위치 영속·재안착 (이슈 #36 / #65 Phase 6).
///
/// 계약:
/// - 위치는 **주변 문맥 앵커**와 함께 저장되고, 본문이 밀려도 앵커로 재안착한다.
/// - IME 조합(marked) 중 기록은 무시된다 — 확정되지 않은 조합 자리 금지.
/// - 재실행 시뮬레이션(새 스토어 인스턴스)에서 같은 UserDefaults로 복원된다.
final class WritingPositionTests: XCTestCase {

    private struct LegacyPosition: Codable {
        let location: Int
        let before: String
        let after: String
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "Purlory-pos-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeBody(paragraphs: Int = 200) -> String {
        (0..<paragraphs)
            .map { index in "\(index)번째 문단이다. 여기에 이야기가 이어진다. 다음 문장도 붙는다." }
            .joined(separator: "\n\n")
    }

    @MainActor
    func test저장과복원_본문불변이면같은위치다() {
        let store = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        store._testReset()
        let id = UUID()
        let body = makeBody()
        let ns = body as NSString
        let caret = 1_500

        store.record(
            entryID: id, location: caret,
            before: ns.substring(with: NSRange(location: caret - 20, length: 20)),
            after: ns.substring(with: NSRange(location: caret, length: 20)),
            marked: false)

        XCTAssertEqual(store.resolve(for: id, in: body), caret)
    }

    @MainActor
    func test본문이밀리면앵커로재안착한다() {
        let store = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        store._testReset()
        let id = UUID()
        let body = makeBody()

        let ns = body as NSString
        // 3장 중간 어딘가 — 앞 문맥 "여기에 이야기가" 직후를 커서로 기록.
        let anchorRange = (body as NSString).range(of: "여기에 이야기가 이어진다")
        XCTAssertNotEqual(anchorRange.location, NSNotFound)
        let caret = anchorRange.upperBound
        store.record(
            entryID: id, location: caret,
            before: ns.substring(with: NSRange(location: caret - 16, length: 16)),
            after: ns.substring(with: NSRange(location: caret, length: 16)),
            marked: false)

        // 나중에 앞부분에 문단 하나가 추가돼 모든 오프셋이 밀렸다.
        let edited = "새 머리말 문단이다. 길이는 충분히 길게 유지한다.\n\n" + body
        let resolved = store.resolve(for: id, in: edited)
        XCTAssertNotNil(resolved)
        // 재안착된 자리의 주변 문맥이 원래 커서 문맥과 같다.
        let editedNS = edited as NSString
        let contextStart = max(0, resolved! - 10)
        let contextLength = min(24, editedNS.length - contextStart)
        let context = editedNS.substring(with: NSRange(location: contextStart, length: contextLength))
        XCTAssertTrue(context.contains("이야기가"), "재안착이 엉뚱한 자리를 가리켰다: \(context)")
    }

    @MainActor
    func test조합중기록은무시된다() {
        let store = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        store._testReset()
        let id = UUID()
        store.record(entryID: id, location: 42, before: "", after: "", marked: true)
        XCTAssertNil(store.position(for: id), "IME 조합 중 기록이 남았다")
    }

    @MainActor
    func test재실행시뮬레이션_디스크라운드트립() throws {
        // 첫 세션 — 기록 + 즉시 반영.
        let first = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        first._testReset()
        let id = UUID()
        first.record(entryID: id, location: 777, before: "직전 문맥 아홉글자아홉", after: "이후 문맥 열두글자열두", marked: false)
        first.persistNow()

        // 두 번째 세션 — 새 인스턴스가 UserDefaults에서 읽는다.
        let second = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        XCTAssertEqual(second.position(for: id)?.location, 777)
    }

    /// A UUID alone is not a document identity: imported projects can legitimately carry the
    /// same durable document UUID without sharing editor state.
    @MainActor
    func testSameDocumentUUIDInDifferentProjectsKeepsSeparatePositions() {
        let store = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        store._testReset()
        let documentID = WritingDocumentID(rawValue: UUID())
        let a = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)
        let b = ProjectDocumentKey(projectID: WritingProjectID(), documentID: documentID)

        store.record(location: 4, selectionLength: 0, body: "AAAA", for: a)
        store.record(location: 9, selectionLength: 0, body: "BBBBBBBBB", for: b)

        XCTAssertEqual(store.restore(in: "AAAA", for: a)?.location, 4)
        XCTAssertEqual(store.restore(in: "BBBBBBBBB", for: b)?.location, 9)
    }

    @MainActor
    func testLegacyUUIDFallbackReadDoesNotRewriteStoredBytes() throws {
        let documentID = UUID()
        let original = try JSONEncoder().encode([
            documentID: LegacyPosition(location: 4, before: "AAAA", after: "BBBB")
        ])
        defaults.set(original, forKey: "purlory.writingPositions")
        let store = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        let key = ProjectDocumentKey(
            projectID: WritingProjectID(),
            documentID: WritingDocumentID(rawValue: documentID))

        XCTAssertEqual(store.restore(in: "AAAABBBB", for: key)?.location, 4)
        store.persistNow()
        XCTAssertEqual(defaults.data(forKey: "purlory.writingPositions"), original)
    }

    @MainActor
    func testCompositeSelectionPersistsAcrossRestart() {
        let key = ProjectDocumentKey(
            projectID: WritingProjectID(), documentID: WritingDocumentID())
        let first = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        first.record(location: 2, selectionLength: 3, body: "abcdefgh", for: key)
        first.persistNow()

        let second = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        let restored = second.restore(in: "abcdefgh", for: key)
        XCTAssertEqual(restored?.location, 2)
        XCTAssertEqual(restored?.selectionLength, 3)
    }

    /// The shared cap must not evict one identity category wholesale merely because project and
    /// legacy positions are held in separate dictionaries.
    @MainActor
    func testCombinedCapTrimsLegacyAndProjectPositionsEvenly() {
        let store = WritingPositionStore(defaults: defaults, persistDelay: .seconds(3600))
        store._testReset()
        let legacyIDs = (0..<100).map { _ in UUID() }
        let projectKeys = (0..<100).map { _ in
            ProjectDocumentKey(
                projectID: WritingProjectID(), documentID: WritingDocumentID())
        }

        for id in legacyIDs {
            store.record(
                entryID: id, location: 0, before: "", after: "", marked: false)
        }
        for key in projectKeys {
            store.record(location: 0, selectionLength: 0, body: "", for: key)
        }
        store.record(
            location: 0, selectionLength: 0, body: "",
            for: ProjectDocumentKey(
                projectID: WritingProjectID(), documentID: WritingDocumentID()))

        let remainingLegacy = legacyIDs.filter { store.position(for: $0) != nil }.count
        let remainingProject = projectKeys.filter { store.restore(in: "", for: $0) != nil }.count
        XCTAssertEqual(remainingLegacy, 50)
        XCTAssertEqual(remainingProject, 50)
    }
}
