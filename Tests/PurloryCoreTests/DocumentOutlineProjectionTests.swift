@testable import PurloryDocumentEngine
import Foundation
import XCTest
@testable import PurloryCore

@MainActor
final class DocumentOutlineProjectionTests: XCTestCase {
    func testLongHeadingWhitespaceKeepsFullGrammarAndBoundedOriginalEvidence() async throws {
        let line = "## " + String(repeating: " \t", count: 5_000) + "한🙂 제목" + String(repeating: " ", count: 5_000)
        let source = line + "\n# Next"
        let result = try await DocumentOutlineProjection.build(source)
        XCTAssertEqual(result.headings.map(\.title), ["한🙂 제목", "Next"])
        XCTAssertEqual(result.headings.map(\.level), [2, 1])
        let first = try XCTUnwrap(result.headings.first)
        XCTAssertEqual(first.sourceRange, 0..<line.utf16.count)
        XCTAssertLessThanOrEqual(first.quote.utf16.count, 256)
        XCTAssertTrue(source.utf16.starts(with: first.quote.utf16))
    }

    func testOrderedDuplicateHeadingsRetainOriginalUnicodeOffsets() async throws {
        let source = "서두🙂\r\n# 한 제목\r\n본문\n## 같은 제목\n내용\n## 같은 제목\n끝"
        let result = try await DocumentOutlineProjection.build(source)
        XCTAssertEqual(result.revision, DocumentOutline.stableHash(source))
        XCTAssertEqual(result.headings.map(\.level), [1, 2, 2])
        XCTAssertEqual(result.headings.map(\.title), ["한 제목", "같은 제목", "같은 제목"])
        XCTAssertEqual(Set(result.headings.map(\.id)).count, 3)
        guard result.headings.count == 3 else { return }
        for heading in result.headings {
            let original = (source as NSString).substring(with: NSRange(location: heading.sourceRange.lowerBound,
                length: heading.quote.utf16.count))
            XCTAssertTrue(original.utf16.elementsEqual(heading.quote.utf16))
            XCTAssertEqual(heading.id, heading.sourceRange.lowerBound)
        }
        XCTAssertNil(result.currentHeading(at: 0))
        XCTAssertEqual(result.currentHeading(at: source.utf16.count)?.id, result.headings.last?.id)
        XCTAssertEqual(result.currentHeading(at: result.headings[1].id)?.id, result.headings[1].id)
    }

    func testCodeMathAndLongSceneSegmentsDoNotInventHeadings() async throws {
        let source = "# Actual\n" + String(repeating: "긴 원고. ", count: 900)
            + "\n```swift\n# Code\n```\n~~~\n## More code\n~~~\n$$\n# Math\n$$\n$$x$$\n### Last\n끝"
        let result = try await DocumentOutlineProjection.build(source)
        XCTAssertGreaterThan(DocumentOutline.parse(source).scenes.count, 2)
        XCTAssertEqual(result.headings.map(\.title), ["Actual", "Last"])
        XCTAssertTrue(result.headings.last?.quote.hasPrefix("### Last") == true)
    }

    func testEmptyUnstructuredAndOversizedTitlesStayQuietAndBounded() async throws {
        for source in ["", "🙂 아무 제목 없는 원고\n본문", "#### Unsupported"] {
            let result = try await DocumentOutlineProjection.build(source)
            XCTAssertTrue(result.headings.isEmpty)
            XCTAssertNil(result.currentHeading(at: Int.max))
        }
        let source = "# " + String(repeating: "🙂한", count: 60_000)
        let result = try await DocumentOutlineProjection.build(source)
        let heading = try XCTUnwrap(result.headings.first)
        XCTAssertLessThanOrEqual(heading.title.utf16.count, 256)
        XCTAssertLessThanOrEqual(heading.quote.utf16.count, 256)
        XCTAssertEqual(heading.sourceRange, 0..<source.utf16.count)
        XCTAssertTrue(source.utf16.starts(with: heading.quote.utf16))
    }

    func testCancelledLargeProjectionDoesNotReturnPartialHeadings() async throws {
        let source = String(repeating: "# Heading\n본문🙂\n", count: 100_000)
        let task = Task { try await DocumentOutlineProjection.build(source) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation must not publish a partial outline") }
        catch is CancellationError { }
    }

    func testAdmittedLargeWorkerCancellationCannotCachePartialPreparation() async throws {
        let worker = DocumentOutlineProjector()
        let snapshot = outlineSnapshot(body: String(repeating: "# Large\n원고🙂\n", count: 300_000))
        let task = Task { try await worker.project(snapshot) }
        while await worker.buildCount == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Retire an admitted scan before publishing or caching it") }
        catch is CancellationError { }
        let retained = await worker.retainedCount
        XCTAssertEqual(retained, 0)
    }

    func testMemoizationReusesOnlyExactDocumentSourceAndBoundsRetention() async throws {
        let worker = DocumentOutlineProjector()
        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let first = outlineSnapshot(key: key, generation: 1, body: "# 한")
        let a = try await worker.project(first)
        let metadata = outlineSnapshot(key: key, generation: 2, body: first.body)
        let b = try await worker.project(metadata)
        XCTAssertEqual(a, b)
        let count = await worker.buildCount
        XCTAssertEqual(count, 1)
        _ = try await worker.project(outlineSnapshot(key: key, generation: 3, body: "# 한"))
        let afterUnicodeChange = await worker.buildCount
        XCTAssertEqual(afterUnicodeChange, 2, "Canonical String equality is insufficient for original evidence")
        for _ in 0..<4 { _ = try await worker.project(outlineSnapshot(body: "# Other")) }
        let retained = await worker.retainedCount
        XCTAssertLessThanOrEqual(retained, 2)
    }
}

func outlineSnapshot(key: ProjectDocumentKey = .init(projectID: WritingProjectID(), documentID: WritingDocumentID()),
                     generation: UInt64 = 1, body: String = "# 원고\n본문") -> ProjectDocumentSnapshot {
    .init(identity: .init(key: key, generation: generation), title: "Synthetic", body: body, kind: .manuscript, mode: .general)
}
