import SwiftUI

/// hover 시 라운드 배경이 깔리는 아이콘 버튼의 **단일 구현** (이슈 #61 PR3).
///
/// 사이드바 헤더·행 버튼·삭제 ✕·모델 칩 스텝 버튼이 각자 같은 그림을 그리고
/// 있었다 — 크기·코너·색 토큰만 다른 네 벌의 복제. 이 구조체 하나로 모으고,
/// 기존 타입(HeaderIconButton·RowIconButton·DeleteButton·StepIconButton)은
/// 호출부 무변경을 위해 이것을 감싼 얇은 래퍼로 남는다.
/// 접근성(help→label 승격, #55/#59)도 여기서 한 번에 적용된다.
struct HoverIconButton<Label: View>: View {
    let theme: PurloryTheme
    let help: String
    /// hover 배경·전경 강조 색 — 삭제 버튼의 위험색 변형을 지원 (#56 토큰).
    var tint: Color?
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(hovered ? (tint ?? theme.inkC) : theme.ink3C)
                .frame(width: contentWidth, height: contentHeight)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(hovered ? (tint.map { $0.opacity(0.14) } ?? theme.hoverC) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
