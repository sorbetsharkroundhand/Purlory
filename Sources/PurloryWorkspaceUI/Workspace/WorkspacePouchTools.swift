import AppKit
import SwiftUI

enum WorkspacePouchSection: String, CaseIterable {
    case overview, format, ai, view, object
    // Retained as command destinations; these are no longer visual tabs.
    func title(for tile: WorkspaceTileID?) -> String {
        switch self {
        case .overview: return "Purlory"
        case .format: return "서식"
        case .ai: return "AI"
        case .view: return "환경"
        case .object:
            switch tile {
            case .characters: return "인물·작품"
            case .narrative: return "서사"
            case .margin: return "마진 노트"
            case .navigator: return "문서"
            case .search: return "검색"
            case .context: return "AI 문맥"
            case .map: return "지도"
            case .outline: return "개요"
            default: return "원고"
            }
        }
    }
}

/// A fixed writer's toolbox. Detailed model and author tools open separately.
struct WorkspacePouchTools: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var model: SpatialWorkspaceController
    @ObservedObject var completion: CompletionController
    @ObservedObject var settings: CompletionSettings
    let theme: PurloryTheme
    let openCoauthor: () -> Void
    let openSettings: () -> Void
    @AppStorage("purlory.appearance") private var appearance = ""
    @Environment(\.colorScheme) private var colorScheme
    @State private var markedText = false

    private var editor: BlockTextView? {
        guard let id = session.selectedDocumentID, let project = session.activeProject else { return nil }
        return requests.editor(for: .init(projectID: project.id, documentID: id))
    }
    private var canGenerate: Bool {
        session.isEditorEditable && editor != nil && !markedText && completion.engineState == .ready
            && settings.authorization == .enabled && settings.autocompleteEnabled && !completion.isMemoryPressurePaused
    }
    private var generationStatus: String {
        if markedText { return "한글 입력을 마치면 실행할 수 있습니다" }
        if settings.authorization != .enabled { return "설정에서 로컬 AI를 켜 주세요" }
        if !settings.autocompleteEnabled { return "자동완성을 켜 주세요" }
        if completion.isMemoryPressurePaused { return "메모리가 확보되면 다시 사용할 수 있습니다" }
        switch completion.engineState {
        case .ready: return "커서 앞의 원고를 바탕으로 이어쓰기"
        case .loading: return "로컬 모델을 불러오는 중입니다"
        case .downloading: return "로컬 모델을 받는 중입니다"
        case .failed: return "모델 상태를 확인해 주세요"
        case .idle: return "로컬 모델을 선택해 주세요"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                panelButton(.navigator, "문서 목록", "folder")
                panelButton(.characters, "인물·작품", "person.2")
                panelButton(.narrative, "서사 흐름", "arrow.triangle.branch")
                panelButton(.search, "원문 검색", "magnifyingglass")
            }
            divider
            VStack(spacing: 8) {
                themeRow
                HStack(spacing: 6) {
                    focusButton("문단 집중", "viewfinder", value: $model.focusDimming, id: "purlory.workspace.pouch.focus")
                    focusButton("타자기 스크롤", "text.line.first.and.arrowtriangle.forward", value: $model.typewriter, id: "purlory.workspace.pouch.typewriter")
                }
                stepper("글자 크기", value: $settings.editorFontSize,
                    range: CompletionSettings.minFontSize...CompletionSettings.maxFontSize, id: "font-size")
                stepper("줄 간격", value: $settings.lineSpacing, range: 0...20, id: "line-spacing")
            }
            divider
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("자동완성", isOn: Binding(get: { settings.autocompleteEnabled },
                        set: { completion.setAutocompleteEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.mini).tint(theme.novelC)
                        .disabled(completion.isManagingModel).fixedSize()
                        .accessibilityIdentifier("purlory.workspace.pouch.autocomplete")
                        .background(WorkspaceAccessibilityProbe(identifier: "purlory.workspace.pouch.autocomplete", label: "자동완성", value: settings.autocompleteEnabled ? "켜짐" : "꺼짐", role: .checkBox))
                    Spacer(minLength: 0)
                    ModelChip(completion: completion, settings: settings, theme: theme)
                        .frame(maxWidth: 150).accessibilityIdentifier("purlory.workspace.pouch.model")
                        .background(WorkspaceAccessibilityProbe(identifier: "purlory.workspace.pouch.model", label: "모델 선택"))
                }
                HStack(spacing: 6) {
                    actionButton("이어쓰기", "sparkles") {
                        guard let editor, !editor.hasMarkedText(), editor.window?.makeFirstResponder(editor) == true else { return }
                        requests.pouch?.dismissTools()
                        (editor.delegate as? PurloryBlockEditor.Coordinator)?.requestExplicitCompletion(editor)
                    }.disabled(!canGenerate).help(generationStatus)
                    actionButton("공동 집필", "square.and.pencil", action: openCoauthor)
                        .disabled(editor == nil || markedText || !session.isEditorEditable)
                        .accessibilityIdentifier("purlory.workspace.pouch.coauthor")
                        .background(WorkspaceAccessibilityProbe(identifier: "purlory.workspace.pouch.coauthor", label: "공동 집필"))
                }
            }
            divider
            HStack(spacing: 4) {
                Button { model.openAll() } label: {
                    Label("나란히 펼치기", systemImage: "rectangle.split.3x1").purloryUIFont(10.5)
                        .frame(height: 28)
                }.help("모든 원고 나란히 펼치기").accessibilityIdentifier("purlory.workspace.pouch.open-all")
                    .background(WorkspaceAccessibilityProbe(identifier: "purlory.workspace.pouch.open-all", label: "모든 원고 나란히 펼치기"))
                Spacer(minLength: 4)
                footerButton("전체 설정 · ⌘,", "gearshape", action: openSettings)
                footerButton("창을 미니 오브로 접기", "arrow.down.right.and.arrow.up.left") { requests.pouch?.collapse() }
                    .accessibilityIdentifier("purlory.workspace.pouch.collapse")
                    .background(WorkspaceAccessibilityProbe(identifier: "purlory.workspace.pouch.collapse", label: "창을 미니 오브로 접기"))
            }.buttonStyle(PouchRowButtonStyle())
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
        .fixedSize(horizontal: false, vertical: true)
        .purloryUIFont(11.5).foregroundStyle(theme.inkC).tint(theme.novelC)
        .preferredColorScheme(theme.editorSurface.relativeLuminance < 0.5 ? .dark : .light)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PouchContentHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PouchContentHeightKey.self) { model.setPouchContentHeight($0, for: model.selectedTile) }
        .onAppear { markedText = editor?.hasMarkedText() == true }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { _ in
            markedText = editor?.hasMarkedText() == true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in
            markedText = editor?.hasMarkedText() == true
        }
        .accessibilityIdentifier("purlory.workspace.pouch.tools")
    }
    private var divider: some View { theme.sepC.frame(height: 1) }
    private func panelButton(_ tile: WorkspaceTileID, _ title: String, _ symbol: String) -> some View {
        let active = model.layout.contains(tile)
        return Button {
            if tile == .search, !active { model.openSearch() }
            else { model.toggle(tile) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular))
                Text(title).purloryUIFont(10).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(height: 56)
                .foregroundStyle(active ? theme.novelC : theme.ink2C)
                .background(active ? theme.activeBgC : theme.hoverC, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(PouchRowButtonStyle()).help(title)
            .accessibilityIdentifier("purlory.workspace.pouch.panel.\(tile.id)")
            .accessibilityLabel(title).accessibilityValue(active ? "열림" : "닫힘")
    }
    private var themeRow: some View {
        HStack(spacing: 4) {
            themeOption("라이트", "sun.max", mode: "light", id: "purlory.workspace.pouch.appearance.light")
            themeOption("다크", "moon", mode: "dark", id: "purlory.workspace.pouch.appearance.dark")
            themeOption("시스템", "circle.lefthalf.filled", mode: "", id: "purlory.workspace.pouch.appearance.system")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purlory.workspace.pouch.appearance")
        .accessibilityLabel("화면 테마")
        .background(WorkspaceAccessibilityProbe(identifier: "purlory.workspace.pouch.appearance", label: "화면 테마", value: appearance.isEmpty ? "system" : appearance, role: .group))
    }
    private func themeOption(_ title: String, _ symbol: String, mode: String, id: String) -> some View {
        let active = appearance == mode
        return Button { appearance = mode } label: {
            Label(title, systemImage: symbol).purloryUIFont(10.5, .medium)
                .frame(maxWidth: .infinity).frame(height: 30)
                .foregroundStyle(active ? theme.novelC : theme.ink2C)
                .background(active ? theme.activeBgC : theme.hoverC, in: Capsule())
        }.buttonStyle(PouchRowButtonStyle())
            .accessibilityIdentifier(id)
            .accessibilityLabel(title)
            .accessibilityValue(active ? "선택됨" : "")
            .background(WorkspaceAccessibilityProbe(identifier: id, label: title, value: active ? "선택됨" : ""))
    }
    private func focusButton(_ title: String, _ symbol: String, value: Binding<Bool>, id: String) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Label(title, systemImage: symbol).purloryUIFont(10.5, .medium)
                .frame(maxWidth: .infinity).frame(height: 32)
                .foregroundStyle(value.wrappedValue ? theme.novelC : theme.ink2C)
                .background(value.wrappedValue ? theme.activeBgC : theme.hoverC, in: Capsule())
        }.buttonStyle(PouchRowButtonStyle()).accessibilityIdentifier(id)
            .accessibilityValue(value.wrappedValue ? "켜짐" : "꺼짐")
            .background(WorkspaceAccessibilityProbe(identifier: id, label: title, value: value.wrappedValue ? "켜짐" : "꺼짐"))
    }
    private func stepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        let fullID = "purlory.workspace.pouch.\(id)"
        return HStack(spacing: 8) {
            Text(title).foregroundStyle(theme.ink2C)
            Spacer(minLength: 4)
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 0.5) } label: {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }.disabled(value.wrappedValue <= range.lowerBound).accessibilityLabel(title + " 줄이기")
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                .font(PurloryFonts.monoUI(11)).frame(width: 54)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 0.5) } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }.disabled(value.wrappedValue >= range.upperBound).accessibilityLabel(title + " 늘리기")
        }.buttonStyle(PouchRowButtonStyle()).accessibilityIdentifier(fullID)
            .background(WorkspaceAccessibilityProbe(identifier: fullID, label: title, role: .group))
    }
    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).purloryUIFont(11, .medium)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(theme.hoverC, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(PouchRowButtonStyle())
    }
    private func footerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28) }
            .help(title).accessibilityLabel(title)
    }
}

private struct PouchContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PouchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1).contentShape(Rectangle())
    }
}
