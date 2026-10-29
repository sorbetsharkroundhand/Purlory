@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore

final class GhostContextModeTests: XCTestCase {
    func testRawInstructBudgetIncludesSelectedChatTemplateOverhead() {
        let counter = TokenCounter({ $0.count }, promptCost: { prompt in
            switch prompt {
            case .continuation(let text): return text.count
            case .instruct(let system, let user): return system.count + user.count + 90
            }
        })
        let result = ContextAssembler.assembleWithReport(prefix: String(repeating: "원문 ", count: 100),
            document: nil, style: .instruct, tokenCounter: counter, tokenBudget: 260, contextMode: .raw)
        XCTAssertLessThanOrEqual(counter.count(result.prompt), 260)
    }

    func testRawModesExcludeAllDerivedHeadersAndCurrentRemainsDefault() {
        let document = DocumentContext(title: "Secret title", kind: .novel,
            genre: "Secret genre", characters: [CharacterCard(name: "유정", note: "Secret note")])
        let prefix = "유정은 창문을 열었다."
        let legacy = ContextAssembler.assembleWithReport(prefix: prefix,
            document: document, style: .continuation)
        let explicit = ContextAssembler.assembleWithReport(prefix: prefix,
            document: document, style: .continuation, contextMode: .current)
        XCTAssertEqual(legacy.prompt, explicit.prompt)
        XCTAssertEqual(legacy.report.items, explicit.report.items)
        XCTAssertEqual(legacy.report.contextMode, .current)
        for mode in [GhostContextMode.raw, .rawWithNameAnchor] {
            let result = ContextAssembler.assembleWithReport(prefix: prefix,
                document: document, style: .continuation, contextMode: mode)
            XCTAssertEqual(result.prompt, .continuation(prefix))
            XCTAssertTrue(result.report.items.isEmpty)
            XCTAssertEqual(result.report.contextMode, mode)
        }
    }

    func testRawBudgetPreservesUnicodeSuffixIncludingUnbrokenWords() {
        let prefix = String(repeating: "앞👩🏽‍💻", count: 80) + "마지막🇰🇷"
        let counter = TokenCounter { $0.utf16.count }
        let result = ContextAssembler.assembleWithReport(prefix: prefix,
            document: nil, prefixStartUTF16: 900, style: .continuation, tokenCounter: counter,
            tokenBudget: 80, contextMode: .raw)
        guard case .continuation(let text) = result.prompt else { return XCTFail() }
        XCTAssertLessThanOrEqual(counter.count(text), 80)
        XCTAssertTrue(text.hasSuffix("마지막🇰🇷"))
        XCTAssertTrue(prefix.hasSuffix(text))
        XCTAssertFalse(text.contains("�"))
        let end = 900 + prefix.utf16.count
        XCTAssertEqual(result.report.rawUTF16Range, (end - text.utf16.count)..<end)
    }

    func testRawInstructCountsSystemAndUserTogether() {
        let prefix = String(repeating: "이전 문장입니다. ", count: 80) + "유정은 문을"
        let counter = TokenCounter { $0.count }
        let result = ContextAssembler.assembleWithReport(prefix: prefix,
            document: DocumentContext(title: "Hidden", kind: .novel),
            style: .instruct, tokenCounter: counter, tokenBudget: 200,
            contextMode: .raw)
        guard case .instruct(let system, let user) = result.prompt else { return XCTFail() }
        XCTAssertEqual(system, ContextAssembler.instructSystem)
        XCTAssertLessThanOrEqual(counter.count(system) + counter.count(user), 200)
        XCTAssertTrue(user.hasSuffix("유정은 문을"))
        XCTAssertFalse(system.contains("Hidden"))
    }
}
