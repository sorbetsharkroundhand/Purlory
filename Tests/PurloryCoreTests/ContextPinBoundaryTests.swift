import XCTest
@testable import PurloryCore

final class ContextPinBoundaryTests: XCTestCase {
    func testFixedPrefixEndsBeforeManuscriptAndIsAbsentForRawAndInstruct() throws {
        let document = DocumentContext(title: "고정 제목", kind: .novel, genre: "추리")
        let result = ContextAssembler.assembleWithReport(prefix: "바뀌는 원고", document: document, style: .continuation)
        let prefix = try XCTUnwrap(result.report.fixedPrefix)
        guard case .continuation(let text) = result.prompt else { return XCTFail() }
        XCTAssertTrue(text.utf8.starts(with: prefix.utf8))
        XCTAssertTrue(prefix.contains("고정 제목"))
        XCTAssertFalse(prefix.contains("바뀌는 원고"))
        let changed = ContextAssembler.assembleWithReport(prefix: "다음 원고", document: document, style: .continuation)
        XCTAssertEqual(changed.report.fixedPrefix, prefix)
        XCTAssertNil(ContextAssembler.assembleWithReport(prefix: "원고", document: document, style: .instruct).report.fixedPrefix)
        XCTAssertNil(ContextAssembler.assembleWithReport(prefix: "원고", document: document, style: .continuation, contextMode: .raw).report.fixedPrefix)
    }
}
