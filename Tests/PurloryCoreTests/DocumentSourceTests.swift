import Foundation
import XCTest
@testable import PurloryFoundation

final class DocumentSourceTests: XCTestCase {
    func testSnapshotsPreserveExactUnicodeAndLineEndings() throws {
        let original = "첫 줄\r\ne\u{301} 👩🏽‍💻 끝\n"
        let source = DocumentSource(original)
        let range = (original as NSString).range(of: "끝")
        let edited = try source.replacing(range, with: "새 끝")
        XCTAssertEqual(edited.utf16Length, original.utf16.count + 2)
        XCTAssertEqual(edited.materializationCount, 0)
        XCTAssertEqual(Array(edited.string.utf8), Array(original.replacingOccurrences(of: "끝", with: "새 끝").utf8))
        XCTAssertEqual(Array(source.string.utf8), Array(original.utf8))
        XCTAssertFalse(source.isSameVersion(as: edited))
        XCTAssertTrue(source.isSameVersion(as: source))
    }

    func testInvalidAndSurrogateInteriorEditsAreRejectedWithoutChangingSource() throws {
        let source = DocumentSource("a😀z")
        for range in [NSRange(location: -1, length: 0), NSRange(location: 9, length: 0),
                      NSRange(location: 1, length: Int.max), NSRange(location: 2, length: 0),
                      NSRange(location: 1, length: 1)] {
            XCTAssertThrowsError(try source.replacing(range, with: "x"))
        }
        XCTAssertEqual(source.string, "a😀z")
        XCTAssertEqual(try source.replacing(NSRange(location: 1, length: 2), with: "").string, "az")
    }

    func testLocalEditsShareSnapshotsWithoutMaterializingTheDocument() throws {
        let source = DocumentSource(chunks: (0..<20_000).map { "line \($0)\n" })
        let first = try source.replacingChunk(at: 3, with: "changed\n")
        let second = try first.replacingChunk(at: 19_998, with: "last change\n")
        XCTAssertLessThan(first.lastMutationVisits, 256)
        XCTAssertLessThan(second.lastMutationVisits, 256)
        XCTAssertEqual(source.materializationCount, 0)
        XCTAssertEqual(first.materializationCount, 0)
        XCTAssertEqual(second.materializationCount, 0)
        XCTAssertTrue(second.string.hasPrefix("line 0\nline 1\nline 2\nchanged\n"))
        XCTAssertTrue(second.string.hasSuffix("last change\nline 19999\n"))
        XCTAssertEqual(second.materializationCount, 1)
        _ = second.string
        XCTAssertEqual(second.materializationCount, 1)
        XCTAssertEqual(first.materializationCount, 0)
        XCTAssertTrue(source.string.contains("line 3\n"))
        XCTAssertTrue(first.string.hasSuffix("line 19998\nline 19999\n"))
    }

    func testRangeEditsAcrossChunksMatchExactUTF16Oracle() throws {
        var source = DocumentSource(chunks: ["한글\r", "\ne", "\u{301}😀", "\n끝"])
        var oracle = source.string
        var seed: UInt64 = 31
        let insertions = ["", "x", "한", "\r\n", "e\u{301}", "😀", "👩🏽‍💻"]
        for step in 0..<400 {
            seed = seed &* 6364136223846793005 &+ 1
            var offsets = [0], length = 0
            for scalar in oracle.unicodeScalars {
                length += scalar.utf16.count; offsets.append(length)
            }
            let a = Int(seed % UInt64(offsets.count))
            let b = min(offsets.count - 1, a + step % 7)
            let range = NSRange(location: offsets[a], length: offsets[b] - offsets[a])
            let text = insertions[step % insertions.count]
            let prior = source
            source = try source.replacing(range, with: text)
            let expected = (oracle as NSString).replacingCharacters(in: range, with: text)
            XCTAssertEqual(Array(source.string.utf16), Array(expected.utf16), "step \(step)")
            XCTAssertEqual(Array(prior.string.utf16), Array(oracle.utf16))
            oracle = expected
        }
    }

    func testConcurrentReadersShareOneMaterialization() async throws {
        let source = try DocumentSource(chunks: Array(repeating: "원고😀\n", count: 10_000))
            .replacingChunk(at: 0, with: "수정\n")
        let lengths = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<24 { group.addTask { source.string.utf16.count } }
            var values: [Int] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(lengths), [source.utf16Length])
        XCTAssertEqual(source.materializationCount, 1)
    }
}
