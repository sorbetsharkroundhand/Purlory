@testable import PurloryIntelligence
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testInitialPaneLetsWritersEditAuthorWithoutChangingSavedPreferences() async throws {
        let h = SettingsPresentationHarness(); defer { h.close() }
        await h.layout()
        let author = try XCTUnwrap(h.field(value: "Saved pen name"),
            "Shared writing and export settings must be reachable in the initial pane")
        XCTAssertEqual(author.stringValue, "Saved pen name")
        XCTAssertTrue(h.window.makeFirstResponder(author))
        let editor = try XCTUnwrap(author.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Updated pen name", replacementRange: editor.selectedRange())
        h.window.makeFirstResponder(nil)
        await h.layout()
        XCTAssertEqual(h.settings.authorName, "Updated pen name")
        XCTAssertEqual(h.defaults.string(forKey: "purlory.authorName"), "Updated pen name")
        XCTAssertEqual(h.settings.editorFontSize, 25)
        XCTAssertEqual(h.settings.lineSpacing, 7)
        XCTAssertEqual(h.settings.novelContextCharacters, 4_800)
        XCTAssertEqual(h.defaults.string(forKey: "purlory.appearance"), "dark")
        XCTAssertFalse(h.settings.autocompleteEnabled)
    }

    func testAdvancedContextEditSurvivesPaneSwitches() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Grouped native tab navigation requires macOS 15")
        }
        let h = SettingsPresentationHarness(navigableTabs: true); defer { h.close() }
        await h.layout()
        let tabs = try XCTUnwrap(h.tabs())
        let modelID = h.settings.modelID
        let advanced = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "고급" })
        tabs.selectTabViewItem(advanced)
        await h.layout()
        let context = try XCTUnwrap(h.elements().first { $0.accessibilityRole() == .incrementor })
        _ = context.accessibilityPerformIncrement()
        await h.layout()
        XCTAssertEqual(h.settings.novelContextCharacters, 5_200)
        XCTAssertEqual(h.defaults.integer(forKey: "completion.novelContextCharacters"), 5_200)

        for label in ["모양", "자동완성", "사용 방법", "글쓰기", "고급"] {
            tabs.selectTabViewItem(try XCTUnwrap(tabs.tabViewItems.first { $0.label == label }))
            await h.layout()
            XCTAssertEqual(h.settings.novelContextCharacters, 5_200)
            XCTAssertEqual(h.settings.authorName, "Saved pen name")
            XCTAssertEqual(h.settings.editorFontSize, 25)
            XCTAssertEqual(h.settings.lineSpacing, 7)
            XCTAssertEqual(h.defaults.string(forKey: "purlory.appearance"), "dark")
            XCTAssertFalse(h.settings.autocompleteEnabled)
            XCTAssertEqual(h.settings.modelID, modelID)
            if label == "글쓰기" {
                XCTAssertNotNil(h.field(value: "Saved pen name"))
            }
        }
    }
}

/// A native Settings fixture with a synthetic defaults suite; never launches Purlory.
@MainActor
private final class SettingsPresentationHarness {
    let suite = "purlory-settings-presentation-" + UUID().uuidString
    let defaults: UserDefaults
    let settings: CompletionSettings
    let window: NSWindow
    let host: NSView

    init(navigableTabs: Bool = false) {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("Saved pen name", forKey: "purlory.authorName")
        defaults.set(25.0, forKey: "editor.fontSize")
        defaults.set(7.0, forKey: "editor.lineSpacing")
        defaults.set(4_800, forKey: "completion.novelContextCharacters")
        defaults.set("dark", forKey: "purlory.appearance")
        settings = CompletionSettings(defaults: defaults)
        settings.setCompletionEnabled(false)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic Settings"
        let content = SettingsView(settings: settings).defaultAppStorage(defaults)
        let root: AnyView
        if #available(macOS 15.0, *), navigableTabs {
            // A grouped bar exposes native tabs outside a SwiftUI Settings scene.
            // The production scene keeps its automatic style.
            root = AnyView(content.tabViewStyle(.grouped))
        } else {
            root = AnyView(content)
        }
        let controller = NSHostingController(rootView: root)
        host = controller.view
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
    }

    func layout() async {
        for _ in 0..<25 { host.layoutSubtreeIfNeeded(); await Task.yield() }
    }

    func field(value: String) -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let field = view as? NSTextField, field.isEditable, field.stringValue == value {
                return field
            }
            return view.subviews.compactMap(find).first
        }
        return find(host)
    }

    func tabs() -> NSTabView? {
        func find(_ view: NSView) -> NSTabView? {
            (view as? NSTabView) ?? view.subviews.compactMap(find).first
        }
        return find(host)
    }

    func close() {
        window.contentViewController = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }

    func elements() -> [any NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: AnyObject) -> [any NSAccessibilityProtocol] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result: [any NSAccessibilityProtocol] = []
            if let element = object as? any NSAccessibilityProtocol {
                result.append(element)
                result += (element.accessibilityChildren() ?? []).flatMap { walk($0 as AnyObject) }
            }
            if let view = object as? NSView {
                result += view.subviews.flatMap { walk($0) }
            }
            return result
        }
        return walk(window) + walk(host)
    }
}
