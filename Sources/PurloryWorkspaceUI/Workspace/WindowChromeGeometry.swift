import AppKit
import SwiftUI

/// One source of truth for content that shares the hidden macOS title-bar row.
///
/// The actual traffic-light geometry is measured from NSWindow standard buttons. Design
/// padding remains explicit, but no child view guesses a magic traffic-light width.
enum WindowChromeGeometry {
    static let navigatorBaseLeadingPadding: CGFloat = 18
    static let toolbarHorizontalPadding: CGFloat = 22
    static let trafficLightGap: CGFloat = 12

    static func leadingContentInset(trafficLightMaxX: CGFloat?) -> CGFloat {
        guard let trafficLightMaxX, trafficLightMaxX > 0 else {
            return navigatorBaseLeadingPadding
        }
        return max(
            navigatorBaseLeadingPadding,
            ceil(trafficLightMaxX + trafficLightGap))
    }
}

private struct PurloryWindowChromeLeadingInsetKey: EnvironmentKey {
    static let defaultValue = WindowChromeGeometry.navigatorBaseLeadingPadding
}

extension EnvironmentValues {
    var purloryWindowChromeLeadingInset: CGFloat {
        get { self[PurloryWindowChromeLeadingInsetKey.self] }
        set { self[PurloryWindowChromeLeadingInsetKey.self] = newValue }
    }
}

/// AppKit bridge that measures the real standard window buttons in the root workspace's
/// coordinate space. It is read-only and has no window-style side effects.
struct WindowChromeProbe: NSViewRepresentable {
    @Binding var trafficLightMaxX: CGFloat?

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = publish
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = publish
        nsView.scheduleMeasurement()
    }

    private func publish(_ value: CGFloat?) {
        guard value != trafficLightMaxX else { return }
        DispatchQueue.main.async {
            if trafficLightMaxX != value {
                trafficLightMaxX = value
            }
        }
    }

    final class ProbeView: NSView {
        var onChange: ((CGFloat?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            measure()
        }

        func scheduleMeasurement() {
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            guard let window else {
                onChange?(nil)
                return
            }
            let kinds: [NSWindow.ButtonType] = [
                .closeButton, .miniaturizeButton, .zoomButton,
            ]
            let maxX = kinds.compactMap { window.standardWindowButton($0) }
                .map { button -> CGFloat in
                    // Convert through window base coordinates because title-bar buttons
                    // are outside the normal content view hierarchy.
                    let windowRect = button.convert(button.bounds, to: nil)
                    return convert(windowRect, from: nil).maxX
                }
                .max()
            onChange?(maxX)
        }
    }
}
