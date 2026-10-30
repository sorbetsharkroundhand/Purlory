import AppKit
import SwiftUI

struct WorkspaceFrame<Content: View>: View {
    let theme: PurloryTheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(WorkspacePaperSurface(theme: theme))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("purlory.workspace.frame")
    }
}

/// The background is a sibling of the editor, so rounding never clips its transients.
struct WorkspacePaperSurface: NSViewRepresentable {
    let theme: PurloryTheme
    var identifier = "purlory.workspace.frame"
    var surface: NSColor? = nil
    var cornerRadius: CGFloat = PurloryRadius.lg
    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView(); view.wantsLayer = true
        view.setAccessibilityIdentifier(identifier)
        return view
    }
    func updateNSView(_ view: SurfaceView, context: Context) {
        view.layer?.backgroundColor = (surface ?? theme.editorSurface).cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = false
    }
    final class SurfaceView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WorkspaceWindowChrome: View {
    let projectTitle: String
    let theme: PurloryTheme
    var trailingInset: CGFloat = 16
    var onTitlePress: (() -> Void)? = nil
    var documentTitle: String? = nil
    var openCount: Int? = nil
    var glass = false
    @State private var trafficLightMaxX: CGFloat?

    var body: some View {
        WorkspaceProjectTitle(title: projectTitle, theme: theme, action: onTitlePress, documentTitle: documentTitle, openCount: openCount)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, WindowChromeGeometry.leadingContentInset(trafficLightMaxX: trafficLightMaxX))
            .padding(.trailing, trailingInset)
            .frame(height: WorkspaceLayoutPolicy.chromeHeight)
            .background { if !glass { WorkspaceChromeSurface(theme: theme).allowsHitTesting(false) } }
            .background(WorkspaceWindowDragRegion())
            .background(WindowChromeProbe(trafficLightMaxX: $trafficLightMaxX))
    }
}

private struct WorkspaceProjectTitle: NSViewRepresentable {
    let title: String
    let theme: PurloryTheme
    let action: (() -> Void)?
    var documentTitle: String?
    var openCount: Int?
    func makeNSView(context: Context) -> NSTextField {
        let field = TitleField(labelWithString: title)
        field.font = PurloryFonts.serif(11.5, weight: .medium)
        field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingMiddle
        field.setAccessibilityIdentifier("purlory.workspace.chrome.title")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = title; field.textColor = theme.ink2
        if let documentTitle {
            let value = NSMutableAttributedString(string: title, attributes: [.font: PurloryFonts.serif(11.5, weight: .medium), .foregroundColor: theme.ink2])
            value.append(NSAttributedString(string: "  /  ", attributes: [.font: PurloryFonts.ui(11.5), .foregroundColor: theme.workspaceMuted.withAlphaComponent(0.35)]))
            value.append(NSAttributedString(string: documentTitle, attributes: [.font: PurloryFonts.ui(11.5), .foregroundColor: theme.workspaceMuted]))
            if let openCount { value.append(NSAttributedString(string: "   \(openCount)개 열림", attributes: [.font: PurloryFonts.mono(10), .foregroundColor: theme.workspaceMuted])) }
            field.attributedStringValue = value
        }
        (field as? TitleField)?.onPress = action
        field.setAccessibilityRole(action == nil ? .staticText : .button)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 18)
    }
    final class TitleField: NSTextField {
        var onPress: (() -> Void)?
        private var press: NSEvent?
        private var dragged = false
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override func hitTest(_ point: NSPoint) -> NSView? { onPress == nil ? nil : super.hitTest(point) }
        override func accessibilityPerformPress() -> Bool { guard let onPress else { return false }; onPress(); return true }
        override func mouseDown(with event: NSEvent) { press = event; dragged = false }
        override func mouseDragged(with event: NSEvent) {
            guard let press, !dragged, hypot(event.locationInWindow.x - press.locationInWindow.x, event.locationInWindow.y - press.locationInWindow.y) > 3 else { return }
            dragged = true; window?.performDrag(with: press)
        }
        override func mouseUp(with event: NSEvent) { if !dragged { onPress?() }; press = nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

}

private struct WorkspaceWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        let view = DragView(); view.setAccessibilityIdentifier("purlory.workspace.chrome")
        return view
    }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// Native actions preserve pointer-click caret state and remain keyboard accessible.
struct WorkspaceActionButton: NSViewRepresentable {
    let identifier: String
    let label: String
    let symbol: String
    let theme: PurloryTheme
    var selected: Bool? = nil
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.invokeAction))
        button.isBordered = false; button.refusesFirstResponder = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = selected == true ? theme.blue : theme.ink2
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        if let selected {
            button.setButtonType(.toggle); button.state = selected ? .on : .off
            button.setAccessibilityValue(NSNumber(value: selected))
        }
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invokeAction() { action() }
    }
}

/// Production options can enable accommodations, never disable system choices.
struct WorkspaceAccessibilityOptions {
    #if DEBUG
    // Only debug fixtures can replace the host's preference for motion checks.
    var systemReduceMotionOverride: Bool? = nil
    #endif
    func resolvedReduceMotion(system: Bool) -> Bool {
        #if DEBUG
        if let systemReduceMotionOverride { return systemReduceMotionOverride || reduceMotion }
        #endif
        return system || reduceMotion
    }
    var reduceMotion = false
    var reduceTransparency = false
}
private struct WorkspaceAccessibilityOptionsKey: EnvironmentKey {
    static let defaultValue = WorkspaceAccessibilityOptions()
}
extension EnvironmentValues {
    var purloryWorkspaceAccessibilityOptions: WorkspaceAccessibilityOptions {
        get { self[WorkspaceAccessibilityOptionsKey.self] }
        set { self[WorkspaceAccessibilityOptionsKey.self] = newValue }
    }
}
