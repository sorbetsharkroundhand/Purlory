import AppKit

/// 인라인 수식(`$…$`)의 storage 표현 — LaTeX 소스를 품은 NSTextAttachment (이슈 #20).
///
/// 본문 흐름 안에서 한 글자(U+FFFC)로 존재해 커서·선택·undo가 기본 동작을 따르고,
/// 직렬화 때 `$latex$`으로 되돌아간다 — 원문이 유일한 진실이라는 헌법 유지.
/// 렌더 이미지는 `MathRenderer.image(labelMode: .text)`로 다시 만든다.
final class MathAtomAttachment: NSTextAttachment {

    /// 구분자를 벗긴 LaTeX 소스 — 저장·재렌더의 단일 출처.
    let latex: String

    init(latex: String) {
        self.latex = latex
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // 왕복은 마크다운 문자열이 담당 — attachment는 코딩되지 않는다.
        return nil
    }

    /// VoiceOver 라벨은 storage의 .accessibilityLabel 속성으로 부여된다
    /// (convertInlineMath) — attachment 자체엔 AX 노출 면이 없다 (이슈 #22).

    /// 폰트 크기·테마 잉크색으로 렌더해 attachment를 준비한다 (text 모드 —
    /// 인라인은 display와 달리 위첨자·분수를 줄 안에 맞춰 그린다).
    /// 렌더 캐시가 메인 격리라 같은 격리를 따른다.
    @MainActor
    func render(fontSize: CGFloat, color: NSColor) {
        guard let image = MathRenderer.image(
            latex: latex, color: color, fontSize: fontSize, labelMode: .text)
        else { return }
        self.image = image
        let font = PurloryFonts.serif(fontSize)
        // 줄이 무한히 늘어나지 않게 상한 — 분수·행렬은 display 블록 쪽이 답이다.
        let maxHeight = (font.ascender - font.descender) * 2.6
        let scale = min(1, maxHeight / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        // x-height 중심에 세로 정렬 — 위아래 여백이 대칭이어야 본문과 어울린다.
        bounds = CGRect(
            x: 0, y: (font.capHeight - size.height) / 2,
            width: size.width, height: size.height)
    }
}
