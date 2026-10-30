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
}
