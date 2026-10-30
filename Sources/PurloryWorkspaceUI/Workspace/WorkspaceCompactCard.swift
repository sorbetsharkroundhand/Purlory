import AppKit
import SwiftUI

struct WorkspaceCompactCard<Content: View>: View {
    @ObservedObject var model: SpatialWorkspaceController
    let id: String
    let title: String
    let detail: String
    let term: String
    let theme: PurloryTheme
    var initial: String? = nil
    var role: String? = nil
    var order: String? = nil
    var serif = false
    var sourceDocumentID: WritingDocumentID? = nil
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    private var expanded: Bool { model.expandedItem == id }
    private var matches: Bool {
        !term.isEmpty && model.activeParagraph.contains(term)
            && (sourceDocumentID == nil || sourceDocumentID == model.activeDocumentID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceCardHeader(id: id, title: title, initial: initial, role: role, order: order,
                serif: serif, expanded: expanded, theme: theme) { model.expandedItem = expanded ? nil : id }
                .frame(height: 16)
            if expanded {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.top, 16).purloryUIFont(11).foregroundStyle(theme.ink2C)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .background(matches ? theme.activeBgC : (hovered ? theme.hoverC : theme.chipC), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .onHover { hovered = $0 }
            .animation(WorkspaceHTMLStyle.animation(0.24), value: hovered)
    }
}


private struct WorkspaceCardHeader: NSViewRepresentable {
    let id: String
    let title: String
    let initial: String?
    let role: String?
    let order: String?
    let serif: Bool
    let expanded: Bool
    let theme: PurloryTheme
    let action: () -> Void
    func makeNSView(context: Context) -> HeaderButton { HeaderButton() }
    func updateNSView(_ button: HeaderButton, context: Context) {
        button.cardTitle = title; button.initial = initial; button.role = role; button.order = order
        button.serif = serif; button.expanded = expanded; button.theme = theme; button.invoke = action
        button.setAccessibilityIdentifier("purlory.card.\(id)"); button.setAccessibilityLabel(title)
        button.setAccessibilityValue(expanded ? "펼쳐짐" : "접힘")
        button.needsDisplay = true
    }
    final class HeaderButton: NSButton {
        var cardTitle = "", initial: String?, role: String?, order: String?
        var serif = false, expanded = false
        var theme = PurloryTheme.light
        var invoke: (() -> Void)?
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); isBordered = false; title = ""; target = self; action = #selector(activate)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { nil }
        @objc private func activate() { invoke?() }
        override func draw(_ dirtyRect: NSRect) {
            var x: CGFloat = 0
            func text(_ string: String, font: NSFont, color: NSColor, rect: CGRect) {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (string as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            }
            if let initial {
                theme.novelBg.setFill(); NSBezierPath(ovalIn: .init(x: 0, y: 0, width: 16, height: 16)).fill()
                let font = PurloryFonts.serif(10, weight: .bold)
                let width = (initial as NSString).size(withAttributes: [.font: font]).width
                text(initial, font: font, color: theme.novel, rect: .init(x: (16 - width) / 2, y: 0, width: 16, height: 16)); x = 24
            }
            if let order {
                let font = PurloryFonts.mono(10, weight: .semibold)
                let width = (order as NSString).size(withAttributes: [.font: font]).width
                text(order, font: font, color: theme.novel, rect: .init(x: 0, y: 1, width: width, height: 16)); x = width + 8
            }
            var right = bounds.width
            if let role, !role.isEmpty {
                let font = PurloryFonts.ui(10), width = min(bounds.width * 0.45, (role as NSString).size(withAttributes: [.font: PurloryFonts.ui(10)]).width)
                text(role, font: font, color: theme.workspaceMuted, rect: .init(x: right - width, y: 2, width: width, height: 14)); right -= width + 8
            } else if role == nil {
                let image = WorkspaceIcons.image(expanded ? "chevron.up" : "chevron.down", size: 12)
                image?.draw(in: .init(x: right - 12, y: 2, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 0.55, respectFlipped: true, hints: nil)
                right -= 20
            }
            text(cardTitle, font: serif || initial != nil ? PurloryFonts.serif(11.5, weight: initial == nil ? .medium : .semibold) : PurloryFonts.ui(11.5, weight: .medium),
                 color: theme.ink, rect: .init(x: x, y: 0, width: max(0, right - x), height: 18))
        }
    }
}
