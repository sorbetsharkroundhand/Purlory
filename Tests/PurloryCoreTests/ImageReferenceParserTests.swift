@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore

/// 이미지 참조 파서 회귀 (이슈 #12) — CommonMark spec §592–616의 이미지
/// 사례를 코퍼스로 쓴다. 옛 한 줄 정규식이 놓치던 angle destination·공백·
/// 균형 괄호·title 세 형식·reference 정의가 전부 여기 고정된다.
final class ImageReferenceParserTests: XCTestCase {

    private func parse(
        _ line: String, definitions: [String: ImageReferenceParser.Definition] = [:]
    ) -> ImageReference? {
        ImageReferenceParser.parse(line, definitions: definitions)
    }

    // MARK: - 인라인 형태

    func test기본인라인이미지를파싱한다() throws {
        let ref = try XCTUnwrap(parse(#"![표지](images/cover.png)"#))
        XCTAssertEqual(ref.alt, "표지")
        XCTAssertEqual(ref.destinationRaw, "images/cover.png")
        XCTAssertNil(ref.title)
        if case .managedRelative = ref.destinationKind {} else {
            XCTFail("상대경로는 managedRelative여야 한다")
        }
    }

    func test공백있는title을파싱한다() throws {
        let ref = try XCTUnwrap(parse(#"![foo](images/a.png "첫 번째 장면")"#))
        XCTAssertEqual(ref.title, "첫 번째 장면")
        XCTAssertEqual(ref.destinationRaw, "images/a.png")
    }

    func test작은따옴표와괄호title형식을파싱한다() {
        for line in [#"![a](i.png 't1')"#, #"![a](i.png (t2))"#] {
            let ref = parse(line)
            XCTAssertNotNil(ref, "\(line) — title 세 형식 중 하나")
            XCTAssertEqual(ref?.title?.hasPrefix("t"), true)
        }
    }

    func testAngleDestination의공백을허용한다() throws {
        let ref = try XCTUnwrap(parse("![사진](<images/my photo.png>)"))
        XCTAssertEqual(ref.destinationRaw, "images/my photo.png")
    }

    func test균형잡힌괄호destination을파싱한다() throws {
        let ref = try XCTUnwrap(parse("![프레임](images/frame(1).png)"))
        XCTAssertEqual(ref.destinationRaw, "images/frame(1).png")
    }

    func test백슬래시이스케이프를제거한다() throws {
        let ref = try XCTUnwrap(parse(#"![foo](images/foo\)bar.png)"#))
        XCTAssertEqual(ref.destinationRaw, "images/foo)bar.png")

        let escapedAlt = try XCTUnwrap(parse(#"![\]닫히지 않음](images/x.png)"#))
        XCTAssertEqual(escapedAlt.alt, "]닫히지 않음")
    }

    func test빈destination은차단분류이다() throws {
        let ref = try XCTUnwrap(parse("![]()"))
        if case .blocked = ref.destinationKind {} else {
            XCTFail("빈 destination은 blocked여야 한다")
        }
    }

    // MARK: - 참조 형태

    func test전체참조형태를정의와함께해석한다() throws {
        let defs: [String: ImageReferenceParser.Definition] = [
            "r1": .init(destinationRaw: "images/ref.png", title: nil)
        ]
        let ref = try XCTUnwrap(parse("![표지][r1]", definitions: defs))
        XCTAssertEqual(ref.destinationRaw, "images/ref.png")
        XCTAssertEqual(ref.label, "r1")
    }

    func test정의없는참조는이미지가아니다() {
        XCTAssertNil(parse("![표지][r1]"), "정의 없는 라벨은 그냥 텍스트다 (CommonMark)")
    }

    func test라벨정규화로대소문자공백을무시한다() {
        let defs: [String: ImageReferenceParser.Definition] = [
            "my label": .init(destinationRaw: "images/x.png", title: nil)
        ]
        XCTAssertNotNil(parse("![a][MY  LABEL]", definitions: defs), "대소문자·연속 공백 무시")
        XCTAssertNotNil(parse("![그림][My Label]", definitions: defs), "축약 형태도 정의를 찾는다")
        XCTAssertNil(parse("![a][없는라벨]", definitions: defs))
    }

    func test문서에서참조정의를수집한다() throws {
        let doc = """
            # 머리말

            [ref1]: images/one.png "하나"
              [ref-2]: <images/two word.png>

            본문 ![그림][ref1]
            """
        let defs = ImageReferenceParser.collectDefinitions(in: doc)
        XCTAssertEqual(defs["ref1"]?.destinationRaw, "images/one.png")
        XCTAssertEqual(defs["ref1"]?.title, "하나")
        XCTAssertEqual(defs["ref-2"]?.destinationRaw, "images/two word.png")
    }

    // MARK: - source 유형 분류

    func test소스유형분류() throws {
        func kind(_ raw: String) -> ImageSourceKind {
            ImageReferenceParser.classify(raw)
        }
        if case .remote(let url) = kind("https://example.com/a.png") {
            XCTAssertEqual(url.absoluteString, "https://example.com/a.png")
        } else { XCTFail("https는 remote") }
        if case .remote = kind("http://x.test/i.jpg") {} else { XCTFail("http도 remote") }
        if case .externalFile = kind("/Users/me/pic.png") {} else { XCTFail("절대경로는 externalFile") }
        if case .externalFile = kind("~/pic.png") {} else { XCTFail("~ 경로는 externalFile") }
        if case .externalFile = kind("file:///tmp/a.png") {} else { XCTFail("file://은 externalFile") }
        if case .managedRelative = kind("images/x.png") {} else { XCTFail("상대경로는 managedRelative") }
        for bad in ["mailto:a@b.c", "javascript:void(0)", "data:image/png;base64,x", ""] {
            if case .blocked = kind(bad) {} else { XCTFail("\(bad)은 blocked") }
        }
    }

    func testSingleLetterTerminalColonIsBlocked() {
        if case .blocked = ImageReferenceParser.classify("a:") {} else {
            XCTFail("A terminal-colon destination must be blocked")
        }
    }

    func testHTTPTerminalColonIsBlocked() {
        if case .blocked = ImageReferenceParser.classify("http:") {} else {
            XCTFail("An incomplete HTTP destination must be blocked")
        }
    }

    func testTerminalColonClassificationCorpusIsBlocked() {
        for raw in [":", "x:", "https:", "file:", "mailto:", " http: "] {
            if case .blocked = ImageReferenceParser.classify(raw) {} else {
                XCTFail("\(raw) must be blocked")
            }
        }
    }

    // MARK: - Purlory 확장 {width align}

    func test확장옵션을분리하고적용한다() throws {
        let ref = try XCTUnwrap(parse("![표지](images/cover.png){width=50 align=left}"))
        XCTAssertEqual(ref.destinationRaw, "images/cover.png")
    }

    func test알수없는옵션이면확장으로보지않는다() {
        // `{...}` 내용이 확장 문법이 아니면 몸통에 포함돼 이미지가 아니게 된다 —
        // 옛 동작(정규식 불일치 → 일반 텍스트)과 같다.
        XCTAssertNil(parse("![a](images/x.png) 이것은 각주 {각주}"))
    }
}
