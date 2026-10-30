@testable import PurloryIntelligence
import AppKit
import Combine
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class SourceSearchPanelTests: XCTestCase {
    func testNativePanelUsesAccessibleControlsAndCancelRestoresWritingWithoutMutation() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let view = try await h.editor(), before = h.fixture.session.activeProject
        view.setSelectedRange(NSRange(location: 3, length: 4))
        let selection = view.selectedRange(), focus = h.requests.editorFocusRequest
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests))
        defer { panel.close() }
        XCTAssertTrue(panel.searchField.delegate === panel)
        XCTAssertEqual(panel.searchField.accessibilityIdentifier(), "purlory.source-search.query")
        XCTAssertEqual(panel.scopePicker.numberOfItems, 3)
        XCTAssertEqual(panel.resultTable.accessibilityIdentifier(), "purlory.source-search.results")
        XCTAssertEqual(panel.searchField.maximumRecents, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(panel.window).frame.width, h.window.frame.width)
        XCTAssertTrue(panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        await h.layout()
        XCTAssertEqual(h.requests.editorFocusRequest, focus + 1)
        XCTAssertEqual(h.fixture.session.activeProject, before)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(h.window.firstResponder === view)
    }

    func testKeyboardSelectsOriginalResultAndReturnUsesNativeWritingPosition() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let view = try await h.editor(); view.setSelectedRange(NSRange(location: 0, length: 0))
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests))
        defer { panel.close() }
        let ready = expectation(description: "Original results")
        let sub = panel.model.$hits.filter { $0.count == 2 }.prefix(1).sink { _ in ready.fulfill() }
        panel.searchField.stringValue = "needle"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchField))
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(panel.resultTable.numberOfRows, 2)
        XCTAssertEqual(panel.resultTable.selectedRow, 0)
        XCTAssertTrue(panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(panel.resultTable.selectedRow, 1)
        XCTAssertTrue(panel.control(panel.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await h.layout()
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).range(of: "needle", options: .backwards).location)
        XCTAssertFalse(panel.window?.isVisible == true)
        XCTAssertTrue(h.requests.returnToWriting(in: h.fixture.session)); await h.layout()
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        withExtendedLifetime(sub) {}
    }

    func testCompositionKeepsNavigationKeysAndDocumentSwitchClosesPanel() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let panel = try XCTUnwrap(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests))
        defer { panel.close() }
        let composer = NSTextView(); composer.allowsUndo = false
        composer.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
                        #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(panel.control(panel.searchField, textView: composer, doCommandBy: command))
        }
        XCTAssertTrue(composer.hasMarkedText())
        XCTAssertFalse(panel.model.isInvalidated)
        _ = h.fixture.session.createDocument(title: "Other")
        await h.layout()
        XCTAssertTrue(panel.model.isInvalidated)
        XCTAssertFalse(panel.window?.isVisible == true)
        XCTAssertTrue(panel.model.hits.isEmpty)
    }

    func testMarkedManuscriptCannotBeInterruptedByOpeningSearch() async throws {
        let h = try await SourceNavigationHarness(short: true); defer { h.close() }
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.beginUndoGrouping()
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(SourceSearchPanel.present(session: h.fixture.session, requests: h.requests))
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText(); view.didChangeText(); manager.endUndoGrouping()
    }
}
