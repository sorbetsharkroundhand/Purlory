@_spi(Benchmark) @testable import PurloryInference
import XCTest

@testable import PurloryCore

/// 한국어 조사·어미 보조기 회귀 테스트 — 지식 블록을 자연 문장으로 펼 때
/// 받침 판정이 틀리면 프롬프트 전체의 어투가 무너진다("서연이" ↔ "서연가").
/// 유니코드 계산(PLAN §11)만으로 맞는 조사가 붙는지 고정한다.
final class KoreanProseTests: XCTestCase {

    func test받침_유무_판정() {
        // 받침 있음
        XCTAssertTrue(KoreanProse.hasFinalConsonant("서연"))   // ㄴ
        XCTAssertTrue(KoreanProse.hasFinalConsonant("강"))     // ㅇ
        XCTAssertTrue(KoreanProse.hasFinalConsonant("불안"))   // ㄴ
        XCTAssertTrue(KoreanProse.hasFinalConsonant("책"))     // ㄱ
        XCTAssertTrue(KoreanProse.hasFinalConsonant("기쁨"))   // ㅁ
        // 받침 없음
        XCTAssertFalse(KoreanProse.hasFinalConsonant("지우"))
        XCTAssertFalse(KoreanProse.hasFinalConsonant("나"))
    }

    func test조합형_음절_밖은_받침_없음() {
        // 라틴·숫자·문장부호는 받침 없음으로 처리 — 문서화된 상한 낮은 실패 방향.
        XCTAssertFalse(KoreanProse.hasFinalConsonant(""))
        XCTAssertFalse(KoreanProse.hasFinalConsonant("Zion"))
        XCTAssertFalse(KoreanProse.hasFinalConsonant("3"))
        XCTAssertFalse(KoreanProse.hasFinalConsonant("."))
    }

    func test조사_결합() {
        XCTAssertEqual(KoreanProse.topic("서연"), "서연은")
        XCTAssertEqual(KoreanProse.topic("지우"), "지우는")
        XCTAssertEqual(KoreanProse.subject("민준"), "민준이")
        XCTAssertEqual(KoreanProse.subject("수아"), "수아가")
        XCTAssertEqual(KoreanProse.object("책상"), "책상을")
        XCTAssertEqual(KoreanProse.object("바다"), "바다를")
        XCTAssertEqual(KoreanProse.copula("불안"), "불안이다")
        XCTAssertEqual(KoreanProse.copula("기쁨"), "기쁨이다")
    }

    func test종결부호_보장() {
        XCTAssertEqual(KoreanProse.terminated("문장이다."), "문장이다.")
        XCTAssertEqual(KoreanProse.terminated("외쳤다!"), "외쳤다!")
        XCTAssertEqual(KoreanProse.terminated("대답했다?"), "대답했다?")
        XCTAssertEqual(KoreanProse.terminated("말없이…"), "말없이…")
        XCTAssertEqual(KoreanProse.terminated("조용했다"), "조용했다.")
        XCTAssertEqual(KoreanProse.terminated("  공백 정리  "), "공백 정리.")
        XCTAssertEqual(KoreanProse.terminated(""), "")
        XCTAssertEqual(KoreanProse.terminated("   "), "")
    }
}
