@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class AskAnswerDecoderTests: XCTestCase {
    private func record(_ text: String = "**Answer** [S1]", id: String = "S1", quote: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["text": text, "citations": [["source": id, "quote": quote]]], options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testFragmentedJSONPublishesOnlyCompleteGroundedRecords() throws {
        let packet = try AskTestFixture().packet(), quote = packet.sources[0].hit.evidence.quote
        let line = try record(quote: quote)
        var decoder = AskAnswerDecoder(packet: packet)
        for scalar in line.unicodeScalars { XCTAssertTrue(try decoder.append(String(scalar)).isEmpty) }
        let blocks = try decoder.append("\n")
        XCTAssertEqual(blocks.count, 1); XCTAssertEqual(blocks.first?.text, "**Answer** [S1]")
        XCTAssertEqual(blocks.first?.packetID, packet.id)
        XCTAssertTrue(try XCTUnwrap(blocks.first?.citations.first?.quote).utf16.elementsEqual(quote.utf16))
        XCTAssertEqual(blocks.first?.citations.first?.evidence, packet.sources[0].hit.evidence)
        XCTAssertTrue(try decoder.finish().isEmpty)
        XCTAssertThrowsError(try decoder.append(line + "\n"), "Closed decoders cannot resume an old request")
    }

    func testUnknownCitationsAndCanonicallyEqualDifferentQuotesNeverBecomeBlocks() throws {
        let packet = try AskTestFixture().packet(), quote = packet.sources[0].hit.evidence.quote
        let composed = quote.replacingOccurrences(of: "한", with: "한")
        XCTAssertEqual(quote, composed); XCTAssertFalse(quote.utf16.elementsEqual(composed.utf16))
        for line in [try record(id: "S9", quote: quote), try record(quote: composed),
                     try record("Unregistered [S9]", quote: quote), try record(" ", quote: quote)] {
            var decoder = AskAnswerDecoder(packet: packet)
            XCTAssertThrowsError(try decoder.append(line + "\n"))
            XCTAssertTrue(decoder.blocks.isEmpty)
        }
        var duplicate = AskAnswerDecoder(packet: packet)
        let citation = ["source": "S1", "quote": quote]
        let data = try JSONSerialization.data(withJSONObject: ["text": "Duplicate", "citations": [citation, citation]])
        XCTAssertThrowsError(try duplicate.append(String(decoding: data, as: UTF8.self) + "\n"))
    }

    func testMalformedTrailingOutputRetainsOnlyPreviouslyValidatedPartialBlocks() throws {
        let packet = try AskTestFixture().packet()
        var decoder = AskAnswerDecoder(packet: packet)
        let line = try record(quote: packet.sources[0].hit.evidence.quote)
        XCTAssertThrowsError(try decoder.append(line + "\nnot a grounded record\n"))
        XCTAssertEqual(decoder.blocks.count, 1)
        XCTAssertThrowsError(try decoder.append(line + "\n"))
        var trailing = AskAnswerDecoder(packet: packet)
        _ = try trailing.append(line + "\n{")
        XCTAssertThrowsError(try trailing.finish()); XCTAssertEqual(trailing.blocks.count, 1)
    }

    func testBufferAndAcceptedRecordLimitsStayBounded() throws {
        let packet = try AskTestFixture().packet()
        var oversized = AskAnswerDecoder(packet: packet)
        XCTAssertThrowsError(try oversized.append(String(repeating: "x", count: 8193)))
        XCTAssertTrue(oversized.blocks.isEmpty)
        var decoder = AskAnswerDecoder(packet: packet)
        for index in 0..<20 {
            XCTAssertEqual(try decoder.append(record("Answer \(index)", quote: packet.sources[0].hit.evidence.quote) + "\n").count, 1)
        }
        XCTAssertThrowsError(try decoder.append(record("Extra", quote: packet.sources[0].hit.evidence.quote) + "\n"))
        XCTAssertEqual(decoder.blocks.count, 20)
    }

    func testExplicitInsufficientEvidenceMakesNoUncitedClaim() throws {
        let packet = try AskTestFixture().packet()
        var decoder = AskAnswerDecoder(packet: packet)
        XCTAssertTrue(try decoder.append("{\"status\":\"insufficient\"}\n").isEmpty)
        _ = try decoder.finish(); XCTAssertTrue(decoder.isInsufficient); XCTAssertTrue(decoder.blocks.isEmpty)
        var invalid = AskAnswerDecoder(packet: packet)
        XCTAssertThrowsError(try invalid.append("{\"status\":\"insufficient\",\"text\":\"Unsupported claim\"}\n"))
    }
}
