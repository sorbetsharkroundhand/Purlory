import SwiftUI

struct WorkspaceRail: View {
    @Binding var navigatorVisible: Bool
    @Binding var section: String
    @ObservedObject var session: ProjectSession
    let requests: ProjectEditorRequests
    let theme: PurloryTheme
    let openSettings: () -> Void
    var onShowLivingMargin: (() -> Void)? = nil
    var marginSelected = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.purloryWorkspaceAccessibilityOptions) private var accessibilityOptions

    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(theme.workspaceMutedC.opacity(0.35))
                .frame(width: 14, height: 3)
                .padding(.vertical, 5)
                .accessibilityHidden(true)
            WorkspaceActionButton(identifier: "purlory.workspace.navigator-toggle",
                label: navigatorVisible ? "파일 목록 숨기기" : "파일 목록 보이기",
                symbol: "folder", theme: theme, selected: navigatorVisible) {
                    withAnimation(accessibilityOptions.resolvedReduceMotion(system: systemReduceMotion) ? nil : WorkspaceMotion.navigator) {
                        navigatorVisible.toggle()
                    }
                    if !navigatorVisible { requests.focusEditor() }
                }
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: PurloryRadius.sm)
                    .fill(navigatorVisible ? theme.activeBgC : .clear))
            toolButton(.bible, identifier: "purlory.workspace.characters", label: "인물·작품 정보", symbol: "person.2")
            toolButton(.narrative, identifier: "purlory.workspace.narrative", label: "서사 기록", symbol: "point.topleft.down.curvedto.point.bottomright.up")
            if let onShowLivingMargin {
                WorkspaceActionButton(identifier: "purlory.workspace.margin", label: "문장 제안",
                    symbol: "sparkles", theme: theme, selected: marginSelected,
                    action: onShowLivingMargin)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: PurloryRadius.sm)
                        .fill(marginSelected ? theme.activeBgC : .clear))
            }
            WriterCompatibilityMenu(section: $section, theme: theme).frame(width: 32, height: 32)
            theme.sepStrongC.frame(width: 18, height: 1).padding(.vertical, 5)
                .accessibilityHidden(true)
            SourceSearchToolbarButton(session: session, requests: requests, compact: true, theme: theme)
                .frame(width: 32, height: 32)
            WorkspaceActionButton(identifier: "purlory.workspace.settings", label: "설정",
                symbol: "gearshape", theme: theme, action: openSettings).frame(width: 32, height: 32)
        }
        .padding(6)
        .background(WorkspacePaperSurface(theme: theme, identifier: "purlory.workspace.rail",
            surface: theme.pill.withAlphaComponent(1)))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purlory.workspace.rail")
        .accessibilityLabel("작업 공간 내비게이션")
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func toolButton(_ tool: SidebarSection, identifier: String, label: String, symbol: String) -> some View {
        let selected = section == tool.rawValue && session.workspaceMode == .write
        return WorkspaceActionButton(identifier: identifier, label: label,
            symbol: symbol, theme: theme, selected: selected) {
                section = selected ? SidebarSection.files.rawValue : tool.rawValue
                session.selectWorkspaceMode(.write)
                requests.focusEditor()
            }
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: PurloryRadius.sm)
                .fill(selected ? theme.activeBgC : .clear))
    }
}
