import XCTest
@testable import PurloryCore

final class ManuscriptVersionTests: XCTestCase {
    private let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
    private func source(_ body: String, generation: UInt64 = 1, kind: WritingDocument.Kind = .manuscript) -> ProjectDocumentSnapshot {
        .init(identity: .init(key: key, generation: generation), title: "원고", body: body, kind: kind, mode: .general)
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
    func testNoteAndReferenceDocumentsRefuseVersionCapture() throws {
        XCTAssertThrowsError(try ManuscriptVersion.capture(source("단순 메모", kind: .note))) { error in
            XCTAssertEqual(error as? ManuscriptVersionError, .unsupportedDocumentKind)
        }
        XCTAssertThrowsError(try ManuscriptVersion.capture(source("참고 자료", kind: .reference))) { error in
            XCTAssertEqual(error as? ManuscriptVersionError, .unsupportedDocumentKind)
        }
    }
    func testLowestCommonAncestorAndThreeWayParagraphMerge() throws {
        let root = try ManuscriptVersion.capture(source("1문단\n\n2문단\n\n3문단\n"), label: "루트")
        let mainNext = try ManuscriptVersion.capture(
            source("1문단 수정(본편)\n\n2문단\n\n3문단\n"),
            label: "본편 수정",
            parentIDs: [root.id],
            branchName: "본편"
        )
        let altNext = try ManuscriptVersion.capture(
            source("1문단\n\n2문단\n\n3문단 수정(갈림길)\n"),
            label: "갈림길 수정",
            parentIDs: [root.id],
            branchName: "다른 결말"
        )
        let all = [root, mainNext, altNext]
        let lca = ManuscriptVersion.lowestCommonAncestor(of: mainNext.id, and: altNext.id, in: all)
        XCTAssertEqual(lca?.id, root.id)

        let cleanMerge = ManuscriptThreeWayMerge.merge(base: lca?.text, ours: mainNext.text, theirs: altNext.text)
        XCTAssertFalse(cleanMerge.hasConflicts)
        XCTAssertEqual(cleanMerge.resolvedText(), "1문단 수정(본편)\n\n2문단\n\n3문단 수정(갈림길)\n")

        let conflictingAlt = "1문단 수정(갈림길)\n\n2문단\n\n3문단\n"
        let conflictMerge = ManuscriptThreeWayMerge.merge(base: lca?.text, ours: mainNext.text, theirs: conflictingAlt)
        XCTAssertEqual(conflictMerge.conflicts.count, 1)
        XCTAssertEqual(conflictMerge.resolvedText(using: [0: .theirs]), "1문단 수정(갈림길)\n\n2문단\n\n3문단\n")
        XCTAssertEqual(conflictMerge.resolvedText(using: [0: .both]), "1문단 수정(본편)\n\n1문단 수정(갈림길)\n\n2문단\n\n3문단\n")
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
    func testResumeBriefExtractsSceneHeadingExcerptAndLinkedQuickNotes() throws {
        let docID = WritingDocumentID()
        let noteID = WritingDocumentID()
        let project = WritingProject(
            id: WritingProjectID(),
            title: "소설 프로젝트",
            mode: .fiction,
            documents: [
                WritingDocument(id: docID, title: "1장", body: "# 새벽 역\n\n기차가 도착했다.\n\n# 밤의 골목\n\n발소리가 멀어졌다.\n", kind: .manuscript),
                WritingDocument(id: noteID, title: "빠른 메모", body: "- [1장] 시계탑 복선 추가\n- [2장] 다른 장 메모\n- [1장] 마지막 대사 톤 낮추기\n", kind: .note)
            ]
        )
        let brief = try XCTUnwrap(ManuscriptResumeBrief.build(for: docID, in: project))
        XCTAssertEqual(brief.currentSceneHeading, "밤의 골목")
        XCTAssertEqual(brief.trailingExcerpt, "발소리가 멀어졌다.")
        XCTAssertEqual(brief.linkedNotes, ["마지막 대사 톤 낮추기", "시계탑 복선 추가"])
        XCTAssertNil(ManuscriptResumeBrief.build(for: noteID, in: project))
    }
}
