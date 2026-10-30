import SwiftUI

/// Read-only live preview beside the source within its math block.
struct MathPreviewView: View {
    let theme: PurloryTheme
    /// 렌더 성공 결과 — nil이면 message를 보여준다.
    let image: NSImage?
    /// 빈 수식 힌트·파싱 오류 안내 (image가 nil일 때).
    let message: String?
    /// 오류(파싱 실패)인지 — 힌트보다 또렷한 잉크로 구분한다.
    let isError: Bool
    let maxWidth: CGFloat

    var body: some View {
        Group {
            if let image {
                let scale = min(1, min(520, maxWidth - 28) / max(image.size.width, 1))
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: image.size.width * scale,
                        height: image.size.height * scale)
            } else if let message {
                Text(message)
                    .purloryUIFont(11.5)
                    .foregroundStyle(isError ? theme.ink2C : theme.ink3C)
                    .lineLimit(1)
                    .frame(maxWidth: maxWidth - 28)
                    .help(message)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.pillC)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.pillBorderC)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}
