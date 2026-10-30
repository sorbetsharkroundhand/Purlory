import AppKit
import SwiftUI

/// 서식 툴바 액션 — `BlockTextView.perform(_:)`이 처리한다.
enum SelectionToolbarAction {
    /// 블록 전환 (같은 블록을 다시 누르면 본문으로 토글).
    case block(PurloryBlock)
    case toggleBold
    case toggleItalic
    case toggleStrikethrough
    case toggleHighlight
    case toggleCode
    case insertLink
    /// nil = 왼쪽(기본) / "center" / "right".
    case align(String?)
    /// 인라인 색 hex, nil = 기본 잉크색으로 복원.
    case color(String?)
    /// 글자 크기 pt (절대값) — 블록 기본 크기와 같으면 속성이 제거된다.
    case fontSize(Double)
    /// 선택 문단들의 줄 간격 pt (요구 4).
    case lineSpacing(Double)
}

/// 툴바 버튼 하이라이트용 — 선택 시작 위치의 현재 서식 상태.
struct SelectionStyleState: Equatable {
    var block: PurloryBlock = .p
    var bold = false
    var italic = false
    var strikethrough = false
    var highlight = false
    var code = false
    var align: String?
    var colorHex: String?
    /// 선택 시작 위치의 실제 글자 크기 pt (표시·± 스텝 기준).
    var fontSize: Double = 20
    /// 선택 시작 문단의 줄 간격 pt (표시·± 스텝 기준).
    var lineSpacing: Double = 7
}

/// 드래그 선택 위에 뜨는 플로팅 서식 툴바 (리퀴드 글래스 필 — 단축키 필과 동일 톤).
struct SelectionToolbarView: View {
    let theme: PurloryTheme
    let state: SelectionStyleState
    let onAction: (SelectionToolbarAction) -> Void
    var onPolish: (() -> Void)? = nil

    /// 인라인 색 프리셋 (시스템 팔레트 계열).
    /// ⚠️ Theme 토큰 규칙의 **문서화된 예외** (이슈 #56): 사용자가 본문에 칠하는
    /// 글자색 프리셋이라 UI 크롬 팔레트와 무관하다 — Theme 범위 밖이 정당하다.
    static let colorPresets = ["FF453A", "FF9F0A", "30D158", "0A84FF", "BF5AF2"]
    /// 글자 크기 허용 범위 (± 버튼·키보드 입력 공통 한계).
    static let minFontSize = 10.0
    static let maxFontSize = 64.0
    /// 줄 간격 허용 범위(pt).
    static let minLineSpacing = 0.0
    static let maxLineSpacing = 20.0

    var body: some View {
        // Keep the same direct formatting controls in every editor. Workspace
        // assistance adds an action without replacing size or color with a menu.
        HStack(spacing: 2) {
            textButton("B", weight: .bold, active: state.bold, help: "굵게 (⌘B / **텍스트**)") {
                onAction(.toggleBold)
            }
            textButton("I", italic: true, active: state.italic, help: "기울임 (⌘I / *텍스트*)") {
                onAction(.toggleItalic)
            }
            iconButton(
                "strikethrough",
                active: state.strikethrough, help: "취소선 (⇧⌘X / ~~텍스트~~)",
                id: "purlory.selection.strikethrough"
            ) { onAction(.toggleStrikethrough) }
            iconButton(
                "highlighter",
                active: state.highlight, help: "형광펜 (⇧⌘H / ==텍스트==)",
                id: "purlory.selection.highlight"
            ) { onAction(.toggleHighlight) }
            iconButton(
                "chevron.left.forwardslash.chevron.right",
                active: state.code, help: "인라인 코드 (⌘⇧C / `텍스트`)"
            ) { onAction(.toggleCode) }
            iconButton(
                "link",
                active: false, help: "링크 삽입 (⌘L / [텍스트](주소))",
                id: "purlory.selection.link"
            ) { onAction(.insertLink) }
            divider
            iconButton("minus", active: false, help: "글자 작게", id: "purlory.selection.font-size.smaller") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onAction(.fontSize(max(Self.minFontSize, state.fontSize - 2)))
            }
            .disabled(state.fontSize <= Self.minFontSize)
            NumberField(
                theme: theme, value: state.fontSize,
                range: Self.minFontSize...Self.maxFontSize,
                help: "글자 크기 (클릭 후 숫자 입력 · Enter)",
                id: "purlory.selection.font-size.value"
            ) { onAction(.fontSize($0)) }
            iconButton("plus", active: false, help: "글자 크게", id: "purlory.selection.font-size.larger") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onAction(.fontSize(min(Self.maxFontSize, state.fontSize + 2)))
            }
            .disabled(state.fontSize >= Self.maxFontSize)
            divider
            colorDot(nil)
            ForEach(Self.colorPresets, id: \.self) { hex in
                colorDot(hex)
            }
            if let onPolish {
                divider
                iconButton("text.quote", active: state.block == .quote, help: "인용", id: "purlory.selection.quote") {
                    onAction(.block(state.block == .quote ? .p : .quote))
                }
                iconButton("wand.and.stars", active: false, help: "선택한 문장 다듬기", tint: theme.novelC, id: "purlory.selection.polish", action: onPolish)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.pillC)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        )
        .fixedSize()
    }

    // MARK: 구성 요소

    private var divider: some View {
        theme.sepStrongC.frame(width: 1, height: 14).padding(.horizontal, 2)
    }

    private func textButton(
        _ label: String, weight: Font.Weight = .semibold, italic: Bool = false,
        active: Bool, help: String, id: String = "", action: @escaping () -> Void
    ) -> some View {
        ToolbarButton(theme: theme, active: active, help: help, id: id, action: action) {
            Text(label)
                .font(PurloryFonts.serifUI(11, weight))
                .italic(italic)
        }
    }

    private func iconButton(
        _ systemName: String, active: Bool, help: String, tint: Color? = nil, id: String = "", action: @escaping () -> Void
    ) -> some View {
        ToolbarButton(theme: theme, active: active, help: help, id: id, tint: tint, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private func colorDot(_ hex: String?) -> some View {
        let active = state.colorHex?.uppercased() == hex
        let name: String = switch hex {
        case "FF453A": "빨강"
        case "FF9F0A": "주황"
        case "30D158": "초록"
        case "0A84FF": "파랑"
        case "BF5AF2": "보라"
        default: "기본색"
        }
        let fill: Color =
            hex.flatMap { NSColor(inlineHex: $0).map(Color.init(nsColor:)) } ?? theme.inkC
        return ToolbarButton(
            theme: theme, active: active,
            help: name, id: "purlory.selection.color.\(hex ?? "default")",
            value: active ? "선택됨" : "", action: { onAction(.color(hex)) }
        ) {
            Circle()
                .fill(fill)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(theme.sepStrongC))
                .padding(3)
                .overlay(Circle().strokeBorder(active ? theme.ink2C : .clear, lineWidth: 1))
        }
    }
}

/// 숫자 입력 필드 (글자 크기·줄 간격 공용) — 표시값을 직접 타이핑해 바꾼다.
/// Enter나 포커스 이탈 때 수정된 경우에만 커밋하고, ± 버튼으로 바뀐 값(`value`)은 즉시 반영한다.
private struct NumberField: View {
    let theme: PurloryTheme
    /// 현재 값 — 외부(± 버튼)에서 바뀌면 표시를 갱신한다.
    let value: Double
    let range: ClosedRange<Double>
    let help: String
    var id: String = "purlory.selection.font-size.value"
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(PurloryFonts.monoUI(11, .semibold))
            .foregroundStyle(theme.inkC)
            .frame(width: 40)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, now in
                if !now, text != display(value) {
                    commit()
                }
            }
            // 외부 값 변화(± 버튼)는 즉시 표시에 동기화한다.
            .onChange(of: value) { _, newValue in
                text = display(newValue)
            }
            .onAppear { text = display(value) }
            .help(help)
            .accessibilityLabel("글자 크기")
            .accessibilityIdentifier(id)
            .background(WorkspaceAccessibilityProbe(identifier: id, label: "글자 크기", value: text.isEmpty ? display(value) : text, role: .textField))
    }

    private func display(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// 입력값을 숫자로 파싱해 허용 범위로 자른 뒤 커밋한다. 빈 값·오입력은 되돌린다.
    private func commit() {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else {
            text = display(value)
            return
        }
        let clamped = min(range.upperBound, max(range.lowerBound, parsed))
        text = display(clamped)
        onCommit(clamped)
    }
}

/// 툴바 공용 버튼 — hover/활성 배경.
private struct ToolbarButton<Label: View>: View {
    let theme: PurloryTheme
    let active: Bool
    let help: String
    var id: String = ""
    var value: String = ""
    var width: CGFloat = 24
    var tint: Color?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? theme.blueC : (tint ?? theme.inkC))
                .frame(width: width, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? theme.activeBgC : (hovered ? theme.hoverC : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
        .accessibilityValue(value)
        .background(WorkspaceAccessibilityProbe(identifier: id, label: help, value: value))
    }
}

final class WorkspaceSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
