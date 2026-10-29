@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore

final class OriginalNameAnchorTests: XCTestCase {
    func testOversizedLatestOccurrenceCannotFallBackToAnOlderClaim() throws {
        let id = UUID(), card = CharacterCard(name: "유정")
        let body = "유정은 열쇠를 받았다.\n유정은 " + String(repeating: "긴 이야기 ", count: 90) + "끝났다.\n유정은"
        let index = try OriginalNameAnchorIndex.make(body: body, documentID: id, characters: [card])
        XCTAssertNil(index.latest(in: "유정은", startingAt: body.utf16.count - 3))
    }

    func testLatestPriorOriginalSentenceIsExactAndCursorBounded() throws {
        let id = UUID(), card = CharacterCard(name: "유정")
        let body = "👩🏽‍💻 유정은 열쇠를 받았다. 유정에게 문을 맡겼다.\n유정은 기다린다.\n유정은 미래의 비밀을 안다."
        let start = (body as NSString).range(of: "유정은 기다린다.").location
        let window = "유정은 기다린다."
        let index = try OriginalNameAnchorIndex.make(body: body, documentID: id, characters: [card])
        let result = ContextAssembler.assembleWithReport(prefix: window,
            document: DocumentContext(title: "Hidden", kind: .novel, characters: [card], entryID: id),
            prefixStartUTF16: start, style: .continuation, contextMode: .rawWithNameAnchor,
            originalNameAnchors: index)
        let item = try XCTUnwrap(result.report.items.first)
        XCTAssertEqual(item.text, "유정에게 문을 맡겼다.")
        XCTAssertEqual(item.evidence?.quote, item.text)
        XCTAssertEqual(item.evidence?.documentID.rawValue, id)
        XCTAssertEqual(item.jumpUTF16, (body as NSString).range(of: item.text).location)
        XCTAssertEqual(result.report.items.count, 1)
        guard case .continuation(let prompt) = result.prompt else { return XCTFail() }
        XCTAssertFalse(prompt.contains("비밀"))
        XCTAssertFalse(prompt.contains("열쇠"))
        XCTAssertTrue(prompt.hasSuffix(window))
    }

    func testAmbiguousAliasesAndSubstringNamesRemainQuiet() throws {
        let id = UUID()
        var a = CharacterCard(name: "민", aliases: "공유"), b = CharacterCard(name: "민준", aliases: "공유")
        let body = "민은 돌아왔다. 민준은 떠났다. 공유는 문을 닫았다.\n민준은"
        let index = try OriginalNameAnchorIndex.make(body: body, documentID: id, characters: [a, b])
        let start = body.utf16.count - "민준은".utf16.count
        XCTAssertEqual(index.latest(in: "민준은", startingAt: start)?.evidence.quote, "민준은 떠났다.")
        XCTAssertNil(index.latest(in: "공유는", startingAt: start))
        XCTAssertNil(index.latest(in: "국민은", startingAt: start))
        a.aliases = "민준"; b.aliases = ""
        let ambiguous = try OriginalNameAnchorIndex.make(body: body, documentID: id, characters: [a, b])
        XCTAssertNil(ambiguous.latest(in: "민준은", startingAt: start))
    }

    func testPartialSentenceAndWrongDocumentCannotSupplyEvidence() throws {
        let id = UUID(), card = CharacterCard(name: "유정")
        let body = "유정은 돌아왔다. 유정은 긴 말을 하면서 끝났다."
        let index = try OriginalNameAnchorIndex.make(body: body, documentID: id, characters: [card])
        let start = (body as NSString).range(of: "긴 말을").location
        XCTAssertNil(index.latest(in: "유정은", startingAt: start), "The latest occurrence crosses the raw window")
        let result = ContextAssembler.assembleWithReport(prefix: "유정은",
            document: DocumentContext(title: "Other", kind: .novel, characters: [card], entryID: UUID()),
            prefixStartUTF16: body.utf16.count, style: .continuation,
            contextMode: .rawWithNameAnchor, originalNameAnchors: index)
        XCTAssertTrue(result.report.items.isEmpty)
    }

    func testExclusionAndBudgetDropQuoteBeforeShrinkingRaw() throws {
        let id = UUID(), card = CharacterCard(name: "유정")
        let body = "유정은 열쇠를 받았다.\n유정은 문을"
        let window = "유정은 문을", start = body.utf16.count - window.utf16.count
        let index = try OriginalNameAnchorIndex.make(body: body, documentID: id, characters: [card])
        let anchor = try XCTUnwrap(index.latest(in: window, startingAt: start))
        let document = DocumentContext(title: "", kind: .novel, characters: [card], entryID: id)
        let excluded = KnowledgeSnapshot(entryID: id, outline: .parse(body), summariesByHash: [:],
            overrides: NarrativeOverrides([NarrativeOverride(kind: .contextExclude, key: anchor.stableKey, value: "1")]))
        for knowledge in [excluded, nil] {
            let result = ContextAssembler.assembleWithReport(prefix: window, document: document,
                knowledge: knowledge, prefixStartUTF16: start, style: .continuation,
                tokenCounter: TokenCounter { $0.utf16.count }, tokenBudget: window.utf16.count,
                contextMode: .rawWithNameAnchor, originalNameAnchors: index)
            XCTAssertEqual(result.prompt, .continuation(window))
            XCTAssertTrue(result.report.items.isEmpty)
        }
    }

    func testUnchangedScenesReuseExtractionAndMovingScenesUpdateOffsets() throws {
        let id = UUID(), card = CharacterCard(name: "유정")
        let original = "# First\n유정은 열쇠를 받았다.\n# Second\n유정은 떠났다.\n# Third\n유정은"
        let index = try OriginalNameAnchorIndex.make(body: original, documentID: id, characters: [card])
        let edited = original.replacingOccurrences(of: "열쇠를", with: "작은 열쇠를")
        let reused = try OriginalNameAnchorIndex.make(body: edited, documentID: id, characters: [card], previous: index)
        XCTAssertEqual(reused.extractedSceneCount, 1)
        let anchor = try XCTUnwrap(reused.latest(in: "유정은", startingAt: edited.utf16.count - 3))
        XCTAssertEqual(anchor.evidence.utf16Hint, (edited as NSString).range(of: "유정은 떠났다.").location)
        let other = try OriginalNameAnchorIndex.make(body: edited, documentID: UUID(), characters: [card], previous: index)
        XCTAssertEqual(other.extractedSceneCount, 3)
        var renamed = card; renamed.name = "서연"
        let changed = try OriginalNameAnchorIndex.make(body: edited, documentID: id, characters: [renamed], previous: reused)
        XCTAssertEqual(changed.extractedSceneCount, 3)
        XCTAssertNil(changed.latest(in: "유정은", startingAt: edited.utf16.count))
    }
}
