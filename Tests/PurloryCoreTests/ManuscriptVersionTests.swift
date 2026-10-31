import XCTest
@testable import PurloryCore

final class ManuscriptVersionTests: XCTestCase {
    private let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
    private func source(_ body: String, generation: UInt64 = 1) -> ProjectDocumentSnapshot {
        .init(identity: .init(key: key, generation: generation), title: "원고", body: body, kind: .manuscript, mode: .general)
    }
    func testDurableRoundTripAndParagraphChangesPreserveOriginalUnicodeAndMarkup() throws {
        let original = "첫 문단🙂\n\n**이전 문장** $x$\n\n![](images/a.png)\n"
        let version = try ManuscriptVersion.capture(source(original), label: "첫 초고")
        let loaded = try ManuscriptVersion.list(in: [version.userDataKey: JSONEncoder().encode(version)], documentID: key.documentID)
        XCTAssertEqual(loaded, [version]); XCTAssertEqual(version.text, original)
        let current = "새 문단\n\n첫 문단🙂\n\n**바꾼 문장** $x$\n\n![](images/a.png)\n"
        let comparison = try version.comparison(with: source(current, generation: 2))
        XCTAssertEqual(comparison.changes.count, 2)
        let changed = try XCTUnwrap(comparison.changes.firstIndex { $0.saved.contains("이전 문장") })
        XCTAssertEqual(try comparison.restoredBody(change: changed), current.replacingOccurrences(of: "바꾼 문장", with: "이전 문장"))
        XCTAssertEqual(try comparison.restoredBody(), original)
    }
    func testSceneReanchorsByUniqueOriginalHeadingAndPreservesOtherScenes() throws {
        let version = try ManuscriptVersion.capture(source("# 시작\n처음\n\n# 밤\n이전 장면🙂\n"), sceneAt: 17)
        XCTAssertTrue(version.text.hasPrefix("# 밤"))
        let current = "# 앞\n삽입\n\n# 시작\n수정\n\n# 밤\n바뀐 장면\n"
        let comparison = try version.comparison(with: source(current, generation: 2))
        XCTAssertEqual(try comparison.restoredBody(), current.replacingOccurrences(of: "# 밤\n바뀐 장면\n", with: version.text))
        XCTAssertThrowsError(try version.comparison(with: source(current + "\n# 밤\n다른 밤\n")))
        XCTAssertThrowsError(try version.comparison(with: source(current.replacingOccurrences(of: "# 밤", with: "# 낮"))))
    }
    func testParagraphDiffHandlesInsertDeleteDuplicatesAndCanonicalUnicodeExactly() throws {
        let samples = ["", "가\n\n나\n", "나\n\n가\n", "가\n\n가\n", "é\n", "e\u{301}\n", "가\n\n새 문단\n\n나\n"]
        for saved in samples {
            let version = try ManuscriptVersion.capture(source(saved))
            for current in samples {
                let comparison = try version.comparison(with: source(current))
                var merged = current
                for change in comparison.changes.reversed() {
                    merged = (merged as NSString).replacingCharacters(in: change.currentRange, with: change.saved)
                }
                XCTAssertTrue(merged.utf8.elementsEqual(saved.utf8))
            }
        }
    }
    func testLongSceneSnapshotUsesSemanticHeadingSectionRatherThanIndexerChunks() throws {
        let section = "# 긴 장면\n" + String(repeating: "긴 원고가 이어졌다. ", count: 400) + "\n"
        let body = section + "# 다음\n보존\n"
        let version = try ManuscriptVersion.capture(source(body), sceneAt: 1800)
        XCTAssertEqual(version.text, section)
        let current = body.replacingOccurrences(of: "이어졌다", with: "바뀌었다")
        XCTAssertEqual(try version.comparison(with: source(current)).restoredBody(), body)
    }
    func testInvalidRecordAndForeignDocumentRefuseWithoutReplacingOriginalBytes() throws {
        let version = try ManuscriptVersion.capture(source("원문"))
        XCTAssertThrowsError(try ManuscriptVersion.list(in: [version.userDataKey: Data("broken".utf8)], documentID: key.documentID))
        let foreign = ProjectDocumentSnapshot(identity: .init(key: .init(projectID: key.projectID, documentID: WritingDocumentID()), generation: 1), title: "다른 원고", body: "원문", kind: .manuscript, mode: .general)
        XCTAssertThrowsError(try version.comparison(with: foreign))
    }
}
