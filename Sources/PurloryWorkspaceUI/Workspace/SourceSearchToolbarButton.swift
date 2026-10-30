import AppKit
import SwiftUI

/// A native search action does not move the manuscript caret before capturing it.
struct SourceSearchToolbarButton: NSViewRepresentable {
    @ObservedObject var session: ProjectSession
    let requests: ProjectEditorRequests
    let compact: Bool
    var theme: PurloryTheme? = nil

    func makeCoordinator() -> Coordinator { Coordinator(session: session, requests: requests) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.openSearch))
        button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "원문 검색")
        button.isBordered = false
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "원문 검색"
        button.setAccessibilityIdentifier("purlory.source-search.show")
        button.setAccessibilityLabel("원문 검색")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.session = session; context.coordinator.requests = requests
        button.title = compact ? "" : "원문 검색"
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.isEnabled = session.isEditorEditable
        button.contentTintColor = theme?.ink2 ?? .secondaryLabelColor
    }

    @MainActor final class Coordinator: NSObject {
        var session: ProjectSession
        var requests: ProjectEditorRequests
        init(session: ProjectSession, requests: ProjectEditorRequests) {
            self.session = session; self.requests = requests
        }
        @objc func openSearch() {
            if let spatial = requests.spatialWorkspace { spatial.openSearch() }
            else { SourceSearchPanel.present(session: session, requests: requests) }
        }
    }
}
