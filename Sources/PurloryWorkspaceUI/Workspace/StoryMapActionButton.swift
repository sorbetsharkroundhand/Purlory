import AppKit
import SwiftUI

/// Native source actions keep stable accessibility identity and route back through the editor owner.
struct StoryMapActionButton: NSViewRepresentable {
    let identifier: String
    let title: String
    let theme: PurloryTheme
    var detail: String? = nil
    var help: String = ""
    var label: String? = nil
    var marker: String = ""
    var current = false
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false; button.alignment = .left; button.wantsLayer = true
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let displayTitle = current ? "현재 · " + title : title
        let text = NSMutableAttributedString(string: marker + displayTitle, attributes: [
            .font: PurloryFonts.ui(12, weight: current ? .semibold : .regular), .foregroundColor: theme.ink, .paragraphStyle: paragraph])
        if !marker.isEmpty { text.addAttribute(.foregroundColor, value: theme.blue, range: NSRange(location: 0, length: marker.utf16.count)) }
        if let detail {
            let visible = detail.replacingOccurrences(of: "\n", with: " ")
            text.append(NSAttributedString(string: "\n" + visible, attributes: [.font: PurloryFonts.ui(10), .foregroundColor: theme.ink3, .paragraphStyle: paragraph]))
        }
        button.attributedTitle = text; button.toolTip = help
        button.layer?.cornerRadius = PurloryRadius.sm
        button.layer?.backgroundColor = current ? theme.activeBg.cgColor : NSColor.clear.cgColor
        button.setAccessibilityIdentifier(identifier); button.setAccessibilityLabel(label ?? title)
        button.setAccessibilityHelp(help); button.setAccessibilityValue(current ? "현재 장면" : "")
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
