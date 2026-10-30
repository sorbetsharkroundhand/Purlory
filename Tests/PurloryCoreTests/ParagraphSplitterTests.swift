@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 긴 문단 나누기의 결정적 로직 검증 (docs/editor-paragraph-split.md).
/// **최우선은 텍스트 보존** — 원고 유실은 되돌릴 수 없다.
final class ParagraphSplitterTests: XCTestCase {

    /// 문장들을 이어 목표 길이의 문단을 만든다.
    private func paragraph(sentenceCount: Int) -> String {
        (1...sentenceCount)
            .map { "이것은 \($0)번째 문장이며 대략 스물다섯 자 안팎의 길이를 가진다. " }
            .joined()
    }

    // MARK: - 텍스트 보존 (개행만 추가, 글자 불변)

    /// 조각을 `\n\n`으로 이으면 원문에 개행만 더한 것 — 개행을 빼면 원문과 동일.
    private func assertOnlyNewlinesAdded(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let joined = ParagraphSplitter.chunks(text).joined(separator: "\n\n")
        XCTAssertEqual(
            joined.replacingOccurrences(of: "\n", with: ""),
            text.replacingOccurrences(of: "\n", with: ""),
            "개행 외의 글자가 바뀌었다 — 원고 손상", file: file, line: line)
    }

    func testLongParagraphPreservesText() {
        assertOnlyNewlinesAdded(paragraph(sentenceCount: 400))  // ~10k자
    }

    func testExactlyAtTriggerBoundary() {
        // trigger 근처 여러 길이에서 글자 보존
        for count in [230, 240, 250, 300, 500] {
            assertOnlyNewlinesAdded(paragraph(sentenceCount: count))
        }
    }

    func testRealGatsbyParagraphPreservesText() throws {
        guard let path = ProcessInfo.processInfo.environment["PURLORY_TEST_JOURNAL_FIXTURE"] else {
            throw XCTSkip("No explicit synthetic journal fixture")
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = json["entries"] as? [[String: Any]],
            let gatsby = entries.first(where: { ($0["title"] as? String) == "위대한 개츠비" }),
            let body = gatsby["body"] as? String
        else { throw XCTSkip("로컬 저널 없음") }

        // 각 문단(단일 개행 줄)을 나눠도 개행만 추가되는지.
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            assertOnlyNewlinesAdded(String(line))
        }
    }

    // MARK: - 나누는 조건과 위치

    func testShortParagraphUntouched() {
        let short = paragraph(sentenceCount: 5)  // ~130자
        XCTAssertEqual(ParagraphSplitter.breakOffsetsUTF16(in: short), [])
        XCTAssertEqual(ParagraphSplitter.chunks(short), [short])
    }

    func testOversizedParagraphIsSplit() {
        let long = paragraph(sentenceCount: 400)
        let chunks = ParagraphSplitter.chunks(long)
        XCTAssertGreaterThan(chunks.count, 1)
        // 각 조각은 target 근처 — 마지막을 빼고 target 이상.
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThanOrEqual((chunk as NSString).length, ParagraphSplitter.target)
        }
    }

    /// 문장 중간은 절대 자르지 않는다 — 모든 조각이 종결부호로 끝나거나(공백 포함)
    /// 마지막 조각이다.
    func testNeverCutsMidSentence() {
        let chunks = ParagraphSplitter.chunks(paragraph(sentenceCount: 400))
        for chunk in chunks.dropLast() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(
                trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
                    || trimmed.hasSuffix("…"),
                "조각이 문장 중간에서 끊겼다: …\(String(trimmed.suffix(20)))")
        }
    }

    /// 경계가 없는 병적 초장문장은 자르지 않는다(문장 중간 절단 금지).
    func testPathologicalNoBoundary() {
        let noBoundary = String(repeating: "가", count: 10_000)  // 종결부호 없음
        XCTAssertEqual(ParagraphSplitter.breakOffsetsUTF16(in: noBoundary), [])
    }

    /// 마지막 토막이 minTail보다 작으면 앞 조각에 합쳐 토막 문단을 만들지 않는다.
    func testTinyTailMergedBack() {
        // target 배수 + 아주 짧은 꼬리가 되도록 문장 수 조정
        let chunks = ParagraphSplitter.chunks(paragraph(sentenceCount: 205))
        if let last = chunks.last {
            XCTAssertGreaterThanOrEqual(
                (last as NSString).length, ParagraphSplitter.minTail,
                "마지막 조각이 minTail보다 작다(토막)")
        }
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(ParagraphSplitter.chunks(""), [""])
        XCTAssertEqual(ParagraphSplitter.chunks("   "), ["   "])
    }
}
