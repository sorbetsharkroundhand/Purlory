@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 문서 아웃라인 파서 회귀 테스트 (PLAN §5·docs/m6-scene-split.md).
/// 아웃라인은 타임라인 골격(§8)과 증분 키(§9)의 원천이라 — 헤딩 경로·범위
/// 타일링·시점 차단 질의가 어긋나면 지식 전체가 잘못된 자리에 묶인다.
final class DocumentOutlineTests: XCTestCase {

    // MARK: - 헤딩 트리

    func test헤딩_트리를_장절씬으로_읽는다() {
        let body = """
        # 1부
        ## 1장
        첫 문단이다. 두 번째 문장.
        ## 2장
        둘째 장이다.
        # 2부
        마지막이다.
        """
        let outline = DocumentOutline.parse(body)

        XCTAssertEqual(outline.scenes.map(\.level), [1, 2, 2, 1])
        XCTAssertEqual(outline.scenes[0].headingPath, ["1부"])
        XCTAssertEqual(outline.scenes[1].headingPath, ["1부", "1장"])
        XCTAssertEqual(outline.scenes[2].headingPath, ["1부", "2장"])
        XCTAssertEqual(outline.scenes[3].headingPath, ["2부"])
    }

    func test레벨을_건너뛴_헤딩은_빈_제목으로_채운다() {
        let outline = DocumentOutline.parse("# A\n### B\n본문이다.\n")

        XCTAssertEqual(outline.scenes.count, 2)
        XCTAssertEqual(outline.scenes[1].level, 3)
        XCTAssertEqual(outline.scenes[1].headingPath, ["A", "", "B"])
    }

    func test헤딩이_아닌_줄은_본문으로_남는다() {
        // #### 는 레벨 상한 밖, #태그 는 공백 없음 — 둘 다 본문.
        let body = "# 진짜\n#### 네개샵\n#태그없음 ## 이건 본문\n내용이다.\n"
        let outline = DocumentOutline.parse(body)

        XCTAssertEqual(outline.scenes.count, 1)
        XCTAssertEqual(outline.scenes[0].utf16Range, 0..<body.utf16.count)
    }

    // MARK: - 서두

    func test서두가_있으면_레벨0_씬이_된다() {
        let outline = DocumentOutline.parse("먼저 나오는 서두다.\n\n# 1장\n본문\n")

        XCTAssertEqual(outline.scenes.map(\.level), [0, 1])
        XCTAssertEqual(outline.scenes[0].headingPath, [])
    }

    func test공백뿐인_서두와_빈_문서는_버린다() {
        XCTAssertEqual(DocumentOutline.parse("\n\n \n# 1장\n본문").scenes.count, 1)
        XCTAssertTrue(DocumentOutline.parse("").scenes.isEmpty)
        XCTAssertTrue(DocumentOutline.parse("  \n\t \n").scenes.isEmpty)
    }

    // MARK: - 시점 차단 질의 (CLAUDE.md §2-4)

    private func threeScenes() -> (DocumentOutline, Int) {
        // "# A\n"=4, "가.\n"=3 → A: 0..<7, B: 7..<14, C: 14..<21
        let body = "# A\n가.\n# B\n나.\n# C\n다.\n"
        return (.parse(body), body.utf16.count)
    }

    func test커서가_속한_씬부터_이전만_조회한다() {
        let (outline, total) = threeScenes()

        XCTAssertEqual(outline.sceneIndex(at: 10), 1)          // B 안
        XCTAssertEqual(outline.scenes(upTo: 10).count, 2)      // A·B — C(미래) 제외
        XCTAssertEqual(outline.scenes(upTo: 0).count, 1)
        XCTAssertEqual(outline.scenes(upTo: total + 100).count, 3)
        XCTAssertNil(DocumentOutline.parse("").sceneIndex(at: 0))
    }

    func test씬_경계_커서는_새_씬에_속한다() {
        // 커서 7 = "# B" 시작 — lastIndex(lowerBound <= offset) 규약.
        let (outline, _) = threeScenes()
        XCTAssertEqual(outline.sceneIndex(at: 7), 1)
    }

    // MARK: - 세그먼트 분할 (docs/m6-scene-split.md)

    /// 씬 범위들이 원문을 빈틈없이 타일링하는가 — 유실 금지 불변식.
    private func assertTilingCovers(_ outline: DocumentOutline, _ body: String) {
        var cursor = 0
        for scene in outline.scenes {
            XCTAssertEqual(scene.utf16Range.lowerBound, cursor, "씬 사이 빈틈")
            cursor = scene.utf16Range.upperBound
        }
        if !outline.scenes.isEmpty {
            XCTAssertEqual(cursor, body.utf16.count, "꼬리 유실")
        }
    }

    func test상한_초과_본문은_세그먼트로_분할된다() {
        // 13자 문장 ×170 = 2,210 UTF-16 — 상한 1,500 초과.
        let text = String(repeating: "문장이 계속 이어진다. ", count: 170)
        let outline = DocumentOutline.parse(text)

        XCTAssertGreaterThanOrEqual(outline.scenes.count, 2)
        for scene in outline.scenes {
            XCTAssertLessThanOrEqual(scene.utf16Range.count, DocumentOutline.maxSegmentUTF16)
            XCTAssertEqual(scene.level, 0)
            XCTAssertEqual(scene.segmentIndex, outline.scenes.firstIndex(of: scene) ?? -1)
        }
        assertTilingCovers(outline, text)
    }

    func test장면_구분자는_CDC보다_우선해_끊긴다() {
        // 요구사항 §32 — 작가가 그은 "***" 경계는 의미 경계다.
        let half = String(repeating: "밤이 깊어갔다. ", count: 25) // 225 UTF-16 ≥ 하한 200
        let body = "# 장\n" + half + "\n***\n" + half + "\n"
        let outline = DocumentOutline.parse(body)

        XCTAssertEqual(outline.scenes.count, 2)
        XCTAssertEqual(outline.scenes.map(\.segmentIndex), [0, 1])
        XCTAssertEqual(outline.scenes.map(\.headingPath), [["장"], ["장"]])
        assertTilingCovers(outline, body)
    }

    func test구분자가_있어도_토막_씬은_만들지_않는다() {
        // 명시 경계라도 최소 크기 미달이면 하나로 둔다 — 토막 방지.
        let body = "# 장\n짧았다.\n***\n또 짧았다.\n"
        let outline = DocumentOutline.parse(body)

        XCTAssertEqual(outline.scenes.count, 1)
        XCTAssertEqual(outline.scenes[0].segmentIndex, 0)
    }

    // MARK: - 문장·경계 판정 단위

    func test숫자_소수점은_문장_경계가_아니다() {
        let text = "3.5초가 걸렸다. 그리고 끝."
        let pieces = DocumentOutline.sentencePieces(in: text[...])

        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map { String(text[$0]) }.joined(), text)
    }

    func test연속_종결부호와_닫는따옴표는_붙인다() {
        let text = "\"뭐?!\" 그렇다. \"대답했다.\" 끝."
        let pieces = DocumentOutline.sentencePieces(in: text[...])

        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces.map { String(text[$0]) }.joined(), text)
    }

    func test장면_구분자_줄_판정() {
        XCTAssertTrue(DocumentOutline.isSceneBreakLine("***"))
        XCTAssertTrue(DocumentOutline.isSceneBreakLine("* * *"))
        XCTAssertTrue(DocumentOutline.isSceneBreakLine("⁂"))
        XCTAssertTrue(DocumentOutline.isSceneBreakLine("§"))
        XCTAssertTrue(DocumentOutline.isSceneBreakLine("---"))
        XCTAssertFalse(DocumentOutline.isSceneBreakLine(""))
        XCTAssertFalse(DocumentOutline.isSceneBreakLine("안녕하세요"))
        XCTAssertFalse(DocumentOutline.isSceneBreakLine("* * * * * * * * *")) // 8자 초과
        XCTAssertFalse(DocumentOutline.isSceneBreakLine("***별"))             // 산문 섞임
    }

    // MARK: - 해시 안정성 (CLAUDE.md §4 콘텐츠 해시 메모이제이션의 전제)

    func testfnv1a는_공개_테스트_벡터와_일치한다() {
        // Swift Hasher는 실행마다 시드가 달라 못 쓴다 — FNV-1a 표준 벡터로 고정.
        XCTAssertEqual(DocumentOutline.fnv1a(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(DocumentOutline.fnv1a("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(DocumentOutline.fnv1a("foobar"), 0x8594_4171_f739_67e8)
    }

    func test안정해시는_16자_16진수다() {
        let hash = DocumentOutline.stableHash("어떤 본문")
        XCTAssertEqual(hash.count, 16)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertNotEqual(hash, DocumentOutline.stableHash("다른 본문"))
        XCTAssertEqual(hash, DocumentOutline.stableHash("어떤 본문"))
    }
}
