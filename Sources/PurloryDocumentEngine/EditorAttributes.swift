import Foundation

package enum PurloryBlock: String {
    case p, h1, h2, h3, h4, h5, h6, quote, bullet, number, todo, code, math, divider, image
}

package extension NSAttributedString.Key {
    /// 문단의 블록 타입 (PurloryBlock rawValue).
    static let purloryBlock = NSAttributedString.Key("purlory.block")
    /// todo 체크 여부 (Bool).
    static let purloryChecked = NSAttributedString.Key("purlory.checked")
    /// number 블록의 마커 문자열 ("1." 등).
    static let purloryMarker = NSAttributedString.Key("purlory.marker")
    /// 목록·인용 들여쓰기 단계 (Int, 0...6).
    static let purloryIndent = NSAttributedString.Key("purlory.indent")
    /// 코드 블록 펜스 언어 태그 (String, 예: "swift").
    static let purloryCodeLang = NSAttributedString.Key("purlory.codeLang")
    /// 다중 행 display 수식 그룹에서의 구분자 역할 — "open"/"mid"/"close" (이슈 #20).
    /// serialize는 이 값으로 `$$`를 어디에 되돌릴지 정한다. 없으면 단독 완결 수식.
    static let purloryMathDelim = NSAttributedString.Key("purlory.mathDelim")
    /// 인라인 수식 원자 문자(attachment) 표시 (Bool) — 직렬화·접근성 판별용.
    static let purloryMath = NSAttributedString.Key("purlory.math")
}

package extension NSAttributedString.Key {
    static let purloryBold = NSAttributedString.Key("purlory.bold")
    static let purloryItalic = NSAttributedString.Key("purlory.italic")
    static let purloryCode = NSAttributedString.Key("purlory.code")
    static let purloryStrikethrough = NSAttributedString.Key("purlory.strikethrough")
    static let purloryHighlight = NSAttributedString.Key("purlory.highlight")
    /// 글자색 hex ("FF453A") — 저장은 `<font color="#…">` 태그.
    static let purloryColor = NSAttributedString.Key("purlory.color")
    /// 글자 크기 pt (Double) — 저장은 `<font size="…">` 태그. 블록 기본 크기와
    /// 같으면 속성을 두지 않는다 (서식 툴바 크기 조절).
    static let purloryFontSize = NSAttributedString.Key("purlory.fontSize")
    /// 문단 정렬 "center"/"right" — 저장은 `<p align="…">` 래퍼 (.p 문단만 직렬화).
    static let purloryAlign = NSAttributedString.Key("purlory.align")
    /// 문단별 줄 간격 pt (Double) — 선택 줄에 한해 조절 (요구 4). 표시 전용이라
    /// 마크다운으로는 저장되지 않고, 재로드 시 전역 설정값으로 돌아간다.
    static let purloryLineSpacing = NSAttributedString.Key("purlory.lineSpacing")
}
