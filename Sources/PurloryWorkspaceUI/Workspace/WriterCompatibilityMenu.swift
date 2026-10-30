import AppKit
import SwiftUI

/// Search cannot replace stored author decisions. Keep their existing routes secondary.
struct WriterCompatibilityMenu: NSViewRepresentable {
    @Binding var section: String
    var theme: PurloryTheme? = nil

    func makeCoordinator() -> Coordinator { Coordinator(section: $section) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false; button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.refusesFirstResponder = true
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityIdentifier("purlory.writer-tools.compatibility")
        button.setAccessibilityLabel("저장된 설정과 기록")
        button.toolTip = "저장된 인물·작품 정보, 작가 수정과 기록, 제안 참조"
        let menu = NSMenu(); menu.autoenablesItems = false
        let label = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "저장된 설정과 기록")
        menu.addItem(label)
        for target in [SidebarSection.bible, .narrative, .context] {
            let item = NSMenuItem(title: WorkspaceToolPresentation.descriptor(for: target.rawValue).title,
                action: #selector(Coordinator.selectSection(_:)), keyEquivalent: "")
            item.target = context.coordinator; item.representedObject = target.rawValue
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.section = $section
        button.contentTintColor = theme?.ink2 ?? .secondaryLabelColor
    }

    @MainActor final class Coordinator: NSObject {
        var section: Binding<String>
        init(section: Binding<String>) { self.section = section }
        @objc func selectSection(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String,
                WorkspaceToolPresentation.isVisible(raw) else { return }
            section.wrappedValue = raw
        }
    }
}
