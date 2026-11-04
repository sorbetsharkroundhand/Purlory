@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// CharacterBible 글자당 동기 전체 저장 회귀 (이슈 #49 / #65 H1).
///
/// 계약: 기존 카드의 연속 필드 편집(이름·별칭·소개 타이핑)은 **디바운스 저장**이고,
/// 새 카드 추가·잠금 토글 같은 이산적 구조 변경만 즉시 저장이다. 타이핑 한 글자마다
/// 메인 액터에서 entries.json 전체를 쓰면 안 된다.
final class CharacterSavePolicyTests: XCTestCase {

    private var root: URL!
    private var store: EntryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-cardsave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root!
        store = MainActor.assumeIsolated {
            EntryStore(directory: directory, autosaveDelay: .seconds(3600))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func test기존카드연속편집은즉시저장을하지않는다() throws {
        let id = store.newEntry()
        let base = CharacterCard(name: "한", note: "")
        store.upsertCharacter(base, in: id)
        let baseline = store.immediateSaveCount  // 신규 추가는 이산 변경 — 즉시 허용

        // 이름 타이핑 세 글자 시뮬레이션 — 매 글자가 바인딩 set을 유발한다.
        for name in ["한결", "한결수", "한결수정"] {
            var typing = store.entries.first { $0.id == id }?
                .characters?.first { $0.id == base.id } ?? base
            typing.name = name
            store.upsertCharacter(typing, in: id)
        }

        XCTAssertEqual(
            store.immediateSaveCount, baseline,
            "연속 편집 중 즉시 저장이 \(store.immediateSaveCount - baseline)번 발생했다")

        // 최종 값은 디바운스 플러시로 반영된다.
        store.flush()
        XCTAssertEqual(
            store.entries.first { $0.id == id }?.characters?.first?.name, "한결수정")
    }

    @MainActor
    func test소개수정은잠금규칙을유지한다() throws {
        let id = store.newEntry()
        let base = CharacterCard(name: "세라", note: "")
        store.upsertCharacter(base, in: id)

        var editing = base
        editing.note = "신중하고 직설적"
        store.upsertCharacter(editing, in: id)
        store.flush()

        let saved = store.entries.first { $0.id == id }?.characters?.first { $0.id == base.id }
        XCTAssertEqual(saved?.locked, true, "소개 직접 수정 → 잠금 규칙 보존")
    }

    @MainActor
    func test이산구조변경은즉시저장을유지한다() throws {
        let id = store.newEntry()
        let before = store.immediateSaveCount

        // 새 카드 추가 — 이산 구조 변경.
        store.upsertCharacter(CharacterCard(name: "신규"), in: id)
        XCTAssertGreaterThan(store.immediateSaveCount, before)

        // 삭제 — 이산 구조 변경.
        let cardID = store.entries.first { $0.id == id }?.characters?.first!.id
        store.removeCharacter(try XCTUnwrap(cardID), from: id)
        XCTAssertGreaterThan(store.immediateSaveCount, before + 1)
    }

    func testLegacyCharacterCardJSONDecodesWithoutNarrativeArcFields() throws {
        let cardID = UUID()
        let legacyJSON = """
        {
          "id": "\(cardID.uuidString)",
          "name": "한도경",
          "aliases": "도경, 등대지기",
          "note": "과묵하고 손놀림이 정확하다."
        }
        """
        let decoded = try JSONDecoder().decode(CharacterCard.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.id, cardID)
        XCTAssertEqual(decoded.name, "한도경")
        XCTAssertNil(decoded.motivation)
        XCTAssertNil(decoded.goal)
        XCTAssertNil(decoded.conflict)
        XCTAssertNil(decoded.epiphany)
        XCTAssertFalse(decoded.hasNarrativeArc)
    }

    @MainActor
    func testNarrativeArcEditsLockCharacterCardAndIncludeInContextHeader() throws {
        let id = store.newEntry()
        let base = CharacterCard(name: "한도경", note: "과묵한 등대지기", autoRegistered: true)
        store.upsertCharacter(base, in: id)

        var editing = base
        editing.motivation = "동생에 대한 부채감을 씻고 싶다"
        editing.goal = "폭풍이 오기 전에 등대 렌즈를 수리한다"
        editing.conflict = "부식된 회전축과 고립된 섬"
        editing.epiphany = "혼자 짊어지는 것이 속죄가 아님을 깨닫는다"
        store.upsertCharacter(editing, in: id)
        store.flush()

        let saved = try XCTUnwrap(
            store.entries.first { $0.id == id }?.characters?.first { $0.id == base.id }
        )
        XCTAssertEqual(saved.locked, true, "서사 동학 필드 수정 시 카드 잠금 보호 규칙이 유지되어야 한다")
        XCTAssertNil(saved.autoRegistered, "서사 동학 필드 수정 시 자동 등록 표식이 해제되어야 한다")
        XCTAssertTrue(saved.hasNarrativeArc)

        var report: [ContextReport.Item] = []
        let header = ContextAssembler.headerText(
            document: DocumentContext(
                title: "등대",
                kind: .novel,
                genre: nil,
                characters: [saved]
            ),
            window: "한도경은 렌즈를 닦았다.",
            report: &report
        )
        XCTAssertTrue(header.contains("동기: 동생에 대한 부채감을 씻고 싶다"))
        XCTAssertTrue(header.contains("목표: 폭풍이 오기 전에 등대 렌즈를 수리한다"))
    }
}
