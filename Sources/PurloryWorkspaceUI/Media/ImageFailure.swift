import AppKit

/// 이미지 로드 실패의 원인 — 플레이스홀더가 원인별로 다르게 안내한다 (이슈 #15).
public enum ImageLoadFailure: Equatable {
    /// 파일이 없다 — 참조는 남아 있고 asset만 사라졌다.
    case missing
    /// 파일은 있지만 이미지로 해석되지 않는다 (손상·빈 파일).
    case corrupt
    /// 확장자가 지원 목록 밖이다.
    case unsupported
}

/// 로드 실패 판정과 플레이스홀더 렌더 (이슈 #15).
///
/// 과거엔 로드 실패 줄이 조용히 소스 텍스트로 빠졌고, EPUB은 그런 이미지를
/// 생략했다 — 콘텐츠가 경고 없이 사라졌다. 이제 실패를 **분류해 표면화**한다:
/// 에디터는 원인·alt·경로를 적은 플레이스홀더를 렌더하고, export는 누락을
/// 미리 검증해 명시적 계속을 요구한다.
@MainActor
public enum ImageFailure {

    /// 소스가 로컬 이미지인데 못 읽는 이유. 정상이면 nil.
    /// 원격·차단 소스는 애초에 로드 대상이 아니므로 nil (#12 정책).
    public static func classify(_ src: String) -> ImageLoadFailure? {
        switch ImageReferenceParser.classify(src) {
        case .managedRelative, .externalFile:
            break
        case .remote, .blocked:
            return nil
        }
        let ext = (src as NSString).pathExtension.lowercased()
        if !ext.isEmpty, !PurloryImageStore.imageExtensions.contains(ext) {
            return .unsupported
        }
        guard let url = PurloryImageStore.url(for: src),
            FileManager.default.fileExists(atPath: url.path)
        else { return .missing }
        // NSImage는 손상 데이터에서도 nil 또는 크기 0 이미지를 돌려준다.
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            return .corrupt
        }
        return nil
    }

    /// 실패 플레이스홀더 이미지 — 원인·alt·경로를 적어 렌더 파이프라인이
    /// 정상 이미지처럼 그릴 수 있게 한다 (소스 노출 금지 불변식 유지).
    public static func placeholder(
        reason: ImageLoadFailure, alt: String, path: String, theme: PurloryTheme
    ) -> NSImage {
        let width: CGFloat = 340
        let height: CGFloat = 120
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let box = NSRect(x: 1, y: 1, width: width - 2, height: height - 2)
        let rounded = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        theme.codeBg.setFill()
        rounded.fill()
        // 점선 테두리 — "비어 있는 자리"임을 정상 이미지와 구분.
        let dashed: [CGFloat] = [4, 4]
        theme.sepStrong.setStroke()
        rounded.setLineDash(dashed, count: 2, phase: 0)
        rounded.lineWidth = 1.5
        rounded.stroke()

        let label: String
        switch reason {
        case .missing: label = "이미지 파일을 찾을 수 없어요"
        case .corrupt: label = "이미지 파일이 손상됐어요"
        case .unsupported: label = "지원하지 않는 형식이에요"
        }
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(
            string: "⚠︎  \(label)",
            attributes: [
                .font: PurloryFonts.ui(12, weight: .semibold),
                .foregroundColor: theme.ink,
            ]))
        let detail = [alt.isEmpty ? nil : "대체 텍스트: \(alt)" as String?, path]
            .compactMap { $0 }
            .joined(separator: "\n")
        head.append(NSAttributedString(string: "\n\(detail)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.ink2,
        ]))
        // 세로 중앙 정렬로 그린다.
        let bounds = head.boundingRect(
            with: NSSize(width: width - 32, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        head.draw(
            with: NSRect(
                x: 16, y: (height - bounds.height) / 2,
                width: width - 32, height: bounds.height),
            options: [.usesLineFragmentOrigin])
        return image
    }
}
