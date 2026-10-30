import SwiftUI

struct WorkspaceSpatialChrome: View {
    @Bindable var session: ProjectSession
    @Bindable var model: SpatialWorkspaceController
    let theme: PurloryTheme
    var body: some View {
        WorkspaceWindowChrome(projectTitle: session.projectPresentation?.title ?? "프로젝트", theme: theme,
            trailingInset: 60, documentTitle: session.selectedDocument?.title,
            openCount: model.layout.openDocuments.count, glass: true)
            .contextMenu {
                if let mode = session.projectPresentation?.mode {
                    ForEach(WorkspaceModePresentation.options(for: mode)) { option in
                        Button(option.label) { session.selectWorkspaceMode(option.mode) }
                    }
                }
            }
            .overlay(alignment: .trailing) {
                WorkspacePouchTrigger(model: model, theme: theme).frame(width: 28, height: 28).padding(.trailing, 14)
            }
            .opacity(model.whisperTyping ? 0 : 1).allowsHitTesting(!model.whisperTyping)
            .animation(WorkspaceHTMLStyle.animation(0.12), value: model.whisperTyping)
    }
}
