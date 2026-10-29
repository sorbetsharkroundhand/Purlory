import Foundation

/// 긴 문단을 문장 경계에서 나누는 **결정적** 로직 (docs/editor-paragraph-split.md).
///
/// TextKit은 문단을 레이아웃 최소 단위로 쓰므로 키 입력 비용이 커서가 든 문단
/// 크기에 비례한다(editor-perf.md). 17k자 단일 문단(개츠비)이 랙의 근본 원인 —
/// 문단을 정상 크기로 나누는 것이 유일한 해소다.
///
/// 이 타입은 **원문을 수정하는 유일한 경로**라 UI·storage와 격리해 순수하게
/// 둔다(테스트 가능). 실제 storage 편집·undo·확인 UX는 `BlockTextView`가 맡는다.
///
/// 지식 파이프라인의 씬 분할(docs/m6-scene-split.md)과 **문장 경계 검출을
/// 공유**하되, 그쪽은 파생 지식(보이지 않음·내용 정의 경계)이고 이쪽은 원문
/// (보임·단순 누적)이라 목적이 다르다.
public enum ParagraphSplitter {

    /// 이 크기(UTF-16)를 넘는 문단만 나누기 대상 — IME 3자모가 프레임 예산 절반을
    /// 넘기 시작하는 지점(측정: editor-perf.md). 5000자(쾌적)는 굳이 안 나눈다.
    public static let trigger = 6000
    /// 조각을 이 크기로 누적해 문장 경계에서 끊는다 (2500자 ≈ 키당 0.7ms).
    public static let target = 2500
    /// 마지막 조각이 이보다 작으면 앞 조각에 합친다 — 토막 문단 방지.
    public static let minTail = 800

    /// 한국어 문장 경계: 종결부호 + 닫는 따옴표(선택) + 공백. 종결어미가 있어
    /// 이 규칙으로 충분하다 — 형태소 분석 불요(PLAN §16-7과 같은 논지).
    package static let sentenceBoundary = try! NSRegularExpression(
        pattern: #"[.!?…]["'”’」』]?\s+"#)

    /// 문단 평문이 `trigger`를 넘으면, `"\n\n"`을 넣을 UTF-16 오프셋 목록을
    /// 돌려준다(문단 시작 기준, 오름차순). 넣을 곳이 없으면 `[]`(안 나눔).
    ///
    /// 오프셋은 문장 경계 **직후**(공백을 포함한 뒤)라, 그 자리에 개행만 끼우면
    /// 문장 사이 공백은 앞 조각에 남아 **글자가 하나도 바뀌지 않는다**. 병적으로
    /// 긴 한 문장(경계 없음)은 자르지 않는다 — 문장 중간 절단 금지.
    public static func breakOffsetsUTF16(in text: String) -> [Int] {
        let ns = text as NSString
        guard ns.length > trigger else { return [] }

        var boundaries: [Int] = []
        sentenceBoundary.enumerateMatches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            if let match { boundaries.append(match.range.location + match.range.length) }
        }

        // 직전 나눔 이후 누적이 target 이상이면 이 경계에서 끊는다(단순 누적).
        var breaks: [Int] = []
        var lastBreak = 0
        for boundary in boundaries where boundary - lastBreak >= target {
            breaks.append(boundary)
            lastBreak = boundary
        }
        // 마지막 조각(끝까지)이 minTail보다 작으면 마지막 나눔을 취소해 앞에 합친다.
        if let last = breaks.last, ns.length - last < minTail {
            breaks.removeLast()
        }
        return breaks
    }

    /// 문단 평문 → 조각 배열. 테스트·미리보기용(에디터는 오프셋으로 직접 편집한다).
    /// 조각을 `"\n\n"`으로 이어 붙이면 원문에 개행만 더한 결과가 된다.
    public static func chunks(_ text: String) -> [String] {
        let offsets = breakOffsetsUTF16(in: text)
        guard !offsets.isEmpty else { return [text] }
        let ns = text as NSString
        var result: [String] = []
        var start = 0
        for offset in offsets {
            result.append(ns.substring(with: NSRange(location: start, length: offset - start)))
            start = offset
        }
        result.append(ns.substring(from: start))
        return result
    }
}
