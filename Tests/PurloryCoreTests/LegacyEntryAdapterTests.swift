@testable import PurloryIntelligence
import XCTest
import PurloryCore

final class LegacyEntryAdapterTests: XCTestCase {
    func testProjectionPreservesLiteralContentAndPopulatedLegacyValue() {
        let bodies = [
            "# 한글\n**강** \u{1100}\u{1161}\u{11BC} 👩🏽‍💻\n![그림](assets/a.png)\n$E=mc^2$\n",
            "첫 줄\r\n둘째 줄\r마지막\n", " \t\r\n\r ", ""
        ]
        for kind: EntryKind? in [nil, .journal, .novel] {
            for body in bodies {
                let character = CharacterCard(
                    name: "강", aliases: "주인공", note: "사용자 기록",
                    locked: true, autoRegistered: false)
                let entry = JournalEntry(
                    title: " \t\u{1100}\u{1161}\u{11BC} 원고\r\n", createdAt: Date(timeIntervalSince1970: 123),
                    body: body, folderID: UUID(), titleIsCustom: true, kind: kind,
                    genre: "문학", characters: [character], rejectedCharacterNames: ["바람"],
                    sortOrder: 2.5,
                    narrativeOverrides: [NarrativeOverride(kind: .sceneTitle, key: "장면", value: "사용자 제목")],
                    recordedConversations: [RecordedConversation(
                        participants: [character.id], utf16Start: 0, utf16End: 2,
                        firstLine: "안녕", lastLine: "잘 가", contentHash: "기존 해시")])
                let before = entry
                let document = LegacyEntryAdapter.document(from: entry)
                XCTAssertEqual(document.id.rawValue, entry.id)
                XCTAssertEqual(document.title, entry.title)
                XCTAssertEqual(Array(document.title.utf8), Array(entry.title.utf8))
                XCTAssertEqual(document.body, body)
                XCTAssertEqual(Array(document.body.utf8), Array(body.utf8))
                XCTAssertEqual(document.kind, .manuscript)
                XCTAssertEqual(entry, before)
                XCTAssertEqual(Array(entry.body.utf8), Array(before.body.utf8))
            }
        }
    }

    func testRepeatedAdaptationAndContentEditsRetainLegacyIdentity() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        var entry = JournalEntry(id: id, title: "초안", body: "처음")
        let first = LegacyEntryAdapter.document(from: entry)
        let repeated = LegacyEntryAdapter.document(from: entry)
        XCTAssertEqual(first.id.rawValue, id)
        XCTAssertEqual(repeated.id, first.id)
        entry.title = "고친 제목"
        entry.body = "수정\r\n\u{1100}\u{1161}\u{11BC}"
        let edited = LegacyEntryAdapter.document(from: entry)
        XCTAssertEqual(edited.id, first.id)
        XCTAssertEqual(edited.title, entry.title)
        XCTAssertEqual(edited.body, entry.body)
        XCTAssertEqual(Array(edited.body.utf8), Array(entry.body.utf8))
    }
}
