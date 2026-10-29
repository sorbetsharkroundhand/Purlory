@testable import PurloryDocumentEngine
import Foundation
import XCTest
@testable import PurloryCore

final class ParagraphRenderIndexTests: XCTestCase {
    private typealias Record = ParagraphRenderIndex.Record

    func testUTF16LookupAndMathRunCrossingWindowEdges() {
        let records = [Record(length: "한글🙂\n".utf16.count, block: .p),
                       Record(length: 5, block: .math, open: true),
                       Record(length: 4, block: .math, close: true),
                       Record(length: 2, block: .image)]
        let index = ParagraphRenderIndex(records: records)
        let start = records[0].length
        let queried = index.paragraphs(in: NSRange(location: start + 1, length: 5))
        XCTAssertEqual(queried.map(\.record), Array(records[1...2]))
        XCTAssertEqual(queried.map(\.range), [NSRange(location: start, length: 5), NSRange(location: start + 5, length: 4)])
        XCTAssertEqual(index.mathRun(containing: start + 6), NSRange(location: start, length: 9))
        XCTAssertNil(index.mathRun(containing: 0))
        XCTAssertEqual(index.paragraphs(in: NSRange(location: start + 9, length: 0)).first?.record.block, .image)
    }

    func testLocalReplacementRebasesLaterLocationsAndRejectsUnalignedRange() {
        let index = ParagraphRenderIndex(records: [.init(length: 3, block: .p), .init(length: 5, block: .math), .init(length: 2, block: .image)])
        XCTAssertFalse(index.replace(NSRange(location: 4, length: 1), with: [.init(length: 9, block: .code)]))
        XCTAssertTrue(index.replace(NSRange(location: 3, length: 5), with: [.init(length: 2, block: .code), .init(length: 4, block: .p)]))
        XCTAssertEqual(index.utf16Length, 11)
        XCTAssertEqual(index.paragraphCount, 4)
        XCTAssertEqual(index.paragraphs(in: NSRange(location: 9, length: 2)).first?.range, NSRange(location: 9, length: 2))
        XCTAssertEqual(index.paragraphs(in: NSRange(location: 11, length: 0)).first?.record.block, .image)
        XCTAssertTrue(index.replace(NSRange(location: 0, length: 11), with: []))
        XCTAssertTrue(index.paragraphs(in: NSRange(location: 0, length: 0)).isEmpty)
        XCTAssertTrue(index.replace(NSRange(location: 0, length: 0), with: [.init(length: 7, block: .p)]))
        XCTAssertTrue(index.replace(NSRange(location: 7, length: 0), with: [.init(length: 3, block: .image)]))
        XCTAssertEqual(index.utf16Length, 10)
    }

    func testRepeatedInsertDeleteMoveMatchesFlatParagraphOracle() {
        var oracle = (0..<80).map { Record(length: $0 % 7 + 1, block: $0 % 9 == 0 ? .image : .p) }
        let index = ParagraphRenderIndex(records: oracle)
        for step in 0..<160 {
            let first = step * 13 % oracle.count
            let removed = min(3, oracle.count - first)
            let start = oracle.prefix(first).reduce(0) { $0 + $1.length }
            let length = oracle[first..<(first + removed)].reduce(0) { $0 + $1.length }
            var replacement = Array(oracle[first..<(first + removed)].reversed())
            replacement[0].length += step % 3
            if step % 4 == 0 { replacement.append(.init(length: 4, block: .math, open: true)) }
            if step % 5 == 0, replacement.count > 1 { replacement.removeLast() }
            XCTAssertTrue(index.replace(NSRange(location: start, length: length), with: replacement))
            oracle.replaceSubrange(first..<(first + removed), with: replacement)
            let all = index.paragraphs(in: NSRange(location: 0, length: index.utf16Length))
            XCTAssertEqual(all.map(\.record), oracle)
            var offset = 0
            for paragraph in all {
                XCTAssertEqual(paragraph.range, NSRange(location: offset, length: paragraph.record.length))
                offset += paragraph.record.length
            }
        }
    }

    func testLongDocumentLookupAndSpliceDoNotWalkEveryLaterParagraph() {
        let index = ParagraphRenderIndex(records: (0..<20_000).map { _ in .init(length: 16, block: .p) })
        XCTAssertTrue(index.replace(NSRange(location: 16, length: 16), with: [.init(length: 18, block: .p)]))
        XCTAssertLessThan(index.lastMutationVisits, 200, "An early edit must not shift 20k later records")
        let result = index.paragraphs(in: NSRange(location: 250_002, length: 20))
        XCTAssertEqual(result.count, 2)
        XCTAssertLessThan(index.lastLookupVisits, 150, "Viewport query must not walk all paragraphs")
        XCTAssertEqual(index.utf16Length, 320_002)
    }
}
