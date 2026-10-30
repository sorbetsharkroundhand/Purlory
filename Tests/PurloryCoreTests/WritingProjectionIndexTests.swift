@testable import PurloryIntelligence
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class WritingProjectionIndexTests: XCTestCase {
    func testHugeParagraphSpliceVisitsBoundedInput() throws {
        for source in [String(repeating: "긴 문장이다.\n", count: 12_500),
                       String(repeating: "긴 문장이다.\n", count: 37_500),
                       String(repeating: "가", count: 300_000)] {
            let index = WritingProjectionIndex()
            index.reset(source: source)
            let piece = try XCTUnwrap(index.sourcePiece(containing: 3))
            let suffixID = index.sourcePiece(containing: source.utf16.count)?.block.id
            let replacement = (piece.block.sourceText as NSString).replacingCharacters(in: NSRange(location: 3 - piece.range.location, length: 0), with: "나")
            let resets = index.resetCount
            XCTAssertTrue(index.apply(.init(oldSourceRange: piece.range,
                                           replacement: WritingProseProjection.blocks(source: replacement))))
            XCTAssertEqual(index.resetCount, resets)
            XCTAssertLessThanOrEqual(index.lastMutationSourceUTF16, 4096)
            XCTAssertLessThan(index.lastMutationVisits, 100)
            XCTAssertEqual(index.sourcePiece(containing: index.sourceLength)?.block.id, suffixID)
            let updated = (source as NSString).replacingCharacters(in: NSRange(location: 3, length: 0), with: "나")
            let reference = WritingProjectionIndex()
            reference.reset(source: updated)
            let suffix = WritingDiagnosticRange(location: updated.utf16.count - 8, length: 4)
            XCTAssertEqual(index.sourceRanges(forProse: suffix), reference.sourceRanges(forProse: suffix))
            let local = Array(index.windows(intersecting: .init(location: 3, length: 1)))
            XCTAssertLessThanOrEqual(local.count, 3)
            XCTAssertTrue(local.allSatisfy { $0.text.utf16.count <= 4096 })
        }
    }

    func testLazyWindowsStayFrozenAndRespectGraphemeOverlap() throws {
        let source = String(repeating: "🙂한 가족👨‍👩‍👧‍👦. ", count: 15_000)
        let index = WritingProjectionIndex()
        index.reset(source: source)
        let frozen = index.windows(intersecting: .init(location: 0, length: source.utf16.count))
        let piece = try XCTUnwrap(index.sourcePiece(containing: 0))
        XCTAssertTrue(index.apply(.init(oldSourceRange: piece.range,
                                       replacement: WritingProseProjection.blocks(source: "바뀐 문장. "))))
        var previousEnd = 0, count = 0
        let ns = source as NSString
        for window in frozen {
            let range = window.coveredRange.nsRange
            XCTAssertLessThanOrEqual(range.length, 4096)
            XCTAssertLessThanOrEqual(max(0, previousEnd - range.location), 256)
            XCTAssertEqual(ns.rangeOfComposedCharacterSequences(for: range), range)
            XCTAssertEqual(ns.substring(with: range), window.text)
            previousEnd = NSMaxRange(range)
            count += 1
        }
        XCTAssertGreaterThan(count, 50)
        XCTAssertEqual(previousEnd, ns.length)
    }

    func testUnalignedPatchIsRejectedAndEmptyResetIsValid() {
        let index = WritingProjectionIndex()
        index.reset(source: "원문")
        XCTAssertFalse(index.apply(.init(oldSourceRange: .init(location: 1, length: 1), replacement: [])))
        XCTAssertEqual(index.sourceLength, 2)
        index.reset(source: "")
        XCTAssertTrue(Array(index.windows(intersecting: .init(location: 0, length: 0))).isEmpty)
    }

    func testRequestSplitterIsLazyBoundedAndPreservesClusters() {
        let text = String(repeating: "🙂한. ", count: 30_000)
        let ns = text as NSString
        var previousEnd = 0
        for item in WritingWindowSplitter.ranges(in: text) {
            let range = item.nsRange
            XCTAssertLessThanOrEqual(range.length, 4096)
            XCTAssertLessThanOrEqual(max(0, previousEnd - range.location), 256)
            XCTAssertEqual(ns.rangeOfComposedCharacterSequences(for: range), range)
            previousEnd = NSMaxRange(range)
        }
        XCTAssertEqual(previousEnd, ns.length)
    }

    func testUnprovedReplacementMapsAreRejected() {
        let index = WritingProjectionIndex()
        index.reset(source: "원문")
        let changed = WritingProseBlock(sourceText: "원문", proseText: "다른",
            segments: [.init(source: NSRange(location: 0, length: 2), prose: NSRange(location: 0, length: 2))])
        XCTAssertFalse(index.apply(.init(oldSourceRange: .init(location: 0, length: 2), replacement: [changed])))
        let outOfBounds = WritingProseBlock(sourceText: "원문", proseText: "문",
            segments: [.init(source: NSRange(location: 100, length: 1), prose: NSRange(location: 0, length: 1))])
        XCTAssertFalse(index.apply(.init(oldSourceRange: .init(location: 0, length: 2), replacement: [outOfBounds])))
        XCTAssertEqual(index.sourceLength, 2)
    }

    func testOversizedGraphemeIsExcludedWithoutDroppingFollowingProse() {
        let source = "가" + String(repeating: "\u{0301}", count: 5000) + " 정상 문장"
        let index = WritingProjectionIndex()
        index.reset(source: source)
        let windows = Array(index.windows(intersecting: .init(location: 0, length: source.utf16.count)))
        XCTAssertTrue(windows.map(\.text).joined().contains("정상 문장"))
        XCTAssertTrue(windows.allSatisfy { $0.text.utf16.count <= 4096 })
        XCTAssertTrue(windows.contains { $0.segments.contains { $0.unsupported } })
        XCTAssertEqual(index.sourceLength, source.utf16.count)
        XCTAssertNil(index.sourceRanges(forProse: .init(location: 0, length: 1)))
    }

    func testCancelledMultiPieceEditKeepsPreviousIndex() {
        let index = WritingProjectionIndex()
        index.reset(source: "원문")
        let blocks = WritingProseProjection.blocks(source: String(repeating: "가", count: 100_000))
        let patch = WritingProjectionPatch(oldSourceRange: .init(location: 0, length: 2), replacement: blocks)
        let admission = ProjectionAdmission(limit: 2)
        XCTAssertFalse(index.apply(patch, admission: { admission.next() }))
        XCTAssertGreaterThan(index.lastMutationSourceUTF16, 0)
        XCTAssertLessThanOrEqual(index.lastMutationSourceUTF16, 4096)
        XCTAssertEqual(index.sourceLength, 2)
        XCTAssertEqual(index.sourceRanges(forProse: .init(location: 0, length: 2)), [.init(location: 0, length: 2)])
        XCTAssertTrue(index.apply(patch, admission: { true }))
        XCTAssertEqual(index.sourceLength, 100_000)
    }
}

private final class ProjectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func next() -> Bool { lock.withLock { calls += 1; return calls <= limit } }
}
