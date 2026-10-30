import AppKit
import Foundation
import UniformTypeIdentifiers

/// Purlory 이미지 객체 페이스트보드 타입 (이슈 #17) — 비트맵만 담던 클립보드에
/// 메타데이터 전체를 얹는다. 내부 붙여넣기는 이 표현을 최우선으로 읽어
/// src·alt·title·width·align을 그대로 되살린다.
public extension UTType {
    /// exportedAs — 앱 내부·같은 서명 앱 사이에서 동적으로 유효하다.
    static let purloryImageObject = UTType(exportedAs: "app.purlory.image-object")
}

public extension NSPasteboard.PasteboardType {
    static let purloryImageObject = NSPasteboard.PasteboardType(
        UTType.purloryImageObject.identifier)
}

/// 페이스트보드에 실리는 이미지 객체 표현. 문서 소스(`ImageAttrs`)와 1:1이라
/// 역직렬화만으로 마크다운을 무손실 재합성할 수 있다 (#14 escape 규칙 승계).
public struct PurloryImageObject: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Purlory 폴더 기준 상대경로 또는 외부 절대경로 — **재사용**한다.
    /// 같은 기기·같은 Purlory 폴더라면 asset 복사가 아니라 참조 공유가 정답이다.
    public var src: String
    public var alt: String
    public var title: String?
    public var width: Int
    public var align: String

    public init(
        version: Int = PurloryImageObject.currentVersion,
        src: String, alt: String = "", title: String? = nil,
        width: Int = 100, align: String = "center"
    ) {
        self.version = version
        self.src = src
        self.alt = alt
        self.title = title
        self.width = width
        self.align = align
    }

    public init?(data: Data) {
        guard let object = try? JSONDecoder().decode(PurloryImageObject.self, from: data),
            object.version == PurloryImageObject.currentVersion
        else { return nil }
        self = object
    }

    /// Editor 레이어의 파싱 결과(ImageAttrs, internal)에서 만든다.
    init(attrs: ImageAttrs) {
        self.init(
            src: attrs.src, alt: attrs.alt, title: attrs.title,
            width: attrs.width, align: attrs.align)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// 원문 구문으로 되돌린다 — ImageAttrs 합성 경로(#14)의 이스케이프 규칙을 쓴다.
    public var markdown: String {
        var attrs = ImageAttrs(src: src)
        attrs.alt = alt
        attrs.title = title
        attrs.width = width
        attrs.align = align
        return attrs.markdown
    }
}
