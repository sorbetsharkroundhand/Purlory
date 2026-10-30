import AppKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

/// 이미지 소스 한 줄(`![](src){width=NN align=X}`)에서 파싱한 표시 속성.
/// 마크다운 왕복은 소스 문자열 그대로라 별도 저장 없이 `markdown`으로 되돌린다.
struct ImageAttrs: Equatable {
    var src: String
    /// 컬럼 폭 대비 표시 너비(%). 기본 100(=폭에 맞춤).
    var width: Int = 100
    /// 가로 정렬 — "left" / "center"(기본) / "right".
    var align: String = "center"
    /// 원문 alt·title — 속성 재작성 시 손실 없이 되돌리려고 보관 (이슈 #12).
    var alt: String = ""
    var title: String?
    /// `{…}` 앞부분(이미지 구문) 원문 — 있으면 markdown 재합성 대신 스플라이스.
    var optionsPrefix: String?
    /// 인식 못 한 확장 속성 토큰 원문(`custom=x` 등, 원래 순서 유지) —
    /// 정렬·리사이즈를 해도 사라지지 않게 (이슈 #14).
    var extraOptions: [String] = []

    /// 소스 마크다운으로 직렬화. optionsPrefix가 있으면 원문 구문을 그대로 쓰고
    /// `{…}`만 다시 붙인다 — alt·title·destination 표기가 절대 변하지 않는다.
    /// 없으면(새 조립) 구성요소를 CommonMark 규칙으로 **이스케이프해** 합성한다 —
    /// 기본값이면 접미를 생략한다.
    var markdown: String {
        var opts: [String] = []
        if width != 100 { opts.append("width=\(width)") }
        if align != "center" { opts.append("align=\(align)") }
        opts.append(contentsOf: extraOptions)
        let suffix = opts.isEmpty ? "" : "{\(opts.joined(separator: " "))}"
        if let prefix = optionsPrefix {
            return suffix.isEmpty ? prefix : "\(prefix) \(suffix)"
        }
        let titlePart = title.map { " \"" + Self.escapeTitle($0) + "\"" } ?? ""
        // title은 닫는 괄호 **안**이다 — 밖에 두면 파서가 이미지로 인정하지 않는다.
        return "![\(Self.escapeAlt(alt))](\(Self.serializeDestination(src))\(titlePart))\(suffix)"
    }

    // MARK: 신규 합성용 이스케이프 (#14) — 파서의 unescape와 짝을 이룬다.

    /// alt 텍스트 — 이미지 구문을 닫는 `]`와 백슬래시만 막으면 충분하다
    /// (파서 scanAlt가 중첩 괄호 카운트·escape만 존중).
    static func escapeAlt(_ text: String) -> String {
        escapeCharacters(text, in: "\\[]")
    }

    /// title — 여는 따옴표 종류에 따라 닫힘이 갈리므로 세 따옴표를 모두 막는다.
    static func escapeTitle(_ text: String) -> String {
        escapeCharacters(text, in: "\\\"'()")
    }

    /// destination — 공백·괄호가 있으면 angle destination(`<…>`)으로 감싸고,
    /// 내부의 `<` `>`는 이스케이프한다. 일반 destination은 공백에서 끊긴다.
    static func serializeDestination(_ path: String) -> String {
        guard path.contains(where: { " \t()".contains($0) }) else { return path }
        return "<\(escapeCharacters(path, in: "\\<>"))>"
    }

    private static func escapeCharacters(_ text: String, in set: String) -> String {
        var out = ""
        for c in text {
            if set.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

/// 렌더 모드 이미지 문단 하나 — 레이아웃 매니저 드로잉이 읽는 값 스냅샷.
struct ImageRender {
    let range: NSRange
    let image: NSImage
    /// 실제 그려질 크기(폭 % 반영 후).
    let size: NSSize
    let align: String
    /// 객체 선택 상태 — true면 선택 테두리를 그린다.
    let selected: Bool
    /// 로드 실패 플레이스홀더일 때의 원인 — nil이면 정상 렌더 (이슈 #15).
    let failure: ImageLoadFailure?

    init(
        range: NSRange, image: NSImage, size: NSSize, align: String,
        selected: Bool, failure: ImageLoadFailure? = nil
    ) {
        self.range = range
        self.image = image
        self.size = size
        self.align = align
        self.selected = selected
        self.failure = failure
    }
}
