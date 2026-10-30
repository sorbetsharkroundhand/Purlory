@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import AppKit
import Combine
import UniformTypeIdentifiers
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ClipboardImagePasteTests: XCTestCase {
    func testStandardPasteIsEnabledForBitmapOnlyClipboard() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        let view = try await h.editor()
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        for (type, format) in bitmapFormats {
            let data = try bitmap(format)
            await withClipboard({ $0.setData(data, forType: type) }) {
                XCTAssertTrue(view.validateUserInterfaceItem(item), type.rawValue)
                view.isEditable = false
                XCTAssertFalse(view.validateUserInterfaceItem(item))
                XCTAssertFalse(view.readSelection(from: .general))
                view.isEditable = true
            }
        }
    }

    func testStandardBitmapPasteIsManagedAtCaretAndSurvivesUndoRedoAndReopen() async throws {
        for (type, format) in bitmapFormats {
            let bytes = try bitmap(format)
            try await assertManagedPaste { $0.setData(bytes, forType: type) }
        }
        let image = try XCTUnwrap(NSImage(data: bitmap(.png)))
        try await assertManagedPaste { $0.writeObjects([image]) }
    }

    func testStandardPastePreservesInternalImageMetadata() async throws {
        let object = PurloryImageObject(src: "images/original.png", alt: "Cover", title: "Chapter one",
                                    width: 60, align: "right")
        let payload = try XCTUnwrap(object.encoded()), bytes = try bitmap(.png)
        try await assertManagedPaste(object: object) { pb in
            pb.setData(payload, forType: .purloryImageObject)
            pb.setData(bytes, forType: .png)
            pb.setString(object.markdown, forType: .string)
        }
    }

    func testTextOnlyPasteKeepsNativeTextAndUndoBehavior() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("BeforeAfter")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let catalog = h.fixture.session.assetCatalog
        await withClipboard({ $0.setString("copied text", forType: .string) }) {
            view.paste(nil)
            drainEvent(manager)
            XCTAssertEqual(view.serialize(), "Beforecopied textAfter")
            XCTAssertEqual(h.fixture.session.assetCatalog, catalog)
            manager.undo()
            XCTAssertEqual(view.serialize(), "BeforeAfter")
        }
    }

    func testAdvertisedBitmapReadUsesManagedStorage() async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.setData(try bitmap(.png), forType: .png)
        let pasted = expectation(description: "Pasteboard read uses managed image insertion")
        let sub = h.fixture.session.activeProjectChanges.compactMap { $0?.documents.first?.body }
            .filter { $0.contains("![](") }.prefix(1).sink { _ in pasted.fulfill() }
        XCTAssertTrue(view.readSelection(from: pb))
        await fulfillment(of: [pasted], timeout: 3)
        drainEvent(manager)
        withExtendedLifetime(sub) {}
    }

    private func assertManagedPaste(object: PurloryImageObject? = nil,
                                    _ populate: (NSPasteboard) -> Void) async throws {
        let h = try await SourceNavigationHarness()
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("BeforeAfter")
        let view = try await h.editor(), manager = try XCTUnwrap(view.undoManager)
        manager.groupsByEvent = true
        view.setSelectedRange(NSRange(location: 6, length: 0))
        try await withClipboard(populate) {
            let pasted = expectation(description: "Standard Paste inserts a managed bitmap")
            let sub = h.fixture.session.activeProjectChanges
                .compactMap { $0?.documents.first?.body }
                .filter { $0.contains("](") }.prefix(1).sink { _ in pasted.fulfill() }
            view.paste(nil)
            await fulfillment(of: [pasted], timeout: 3)
            withExtendedLifetime(sub) {}
            drainEvent(manager)
            let body = view.serialize(), lines = body.components(separatedBy: "\n")
            guard lines.count == 3 else { return XCTFail("No image block inserted at the caret") }
            XCTAssertEqual(lines.first, "Before")
            XCTAssertEqual(lines.last, "After")
            let attrs = try XCTUnwrap(BlockTextView.imageAttrs(from: lines[1]))
            if let object {
                XCTAssertNotEqual(attrs.src, object.src)
                XCTAssertEqual(attrs.alt, object.alt)
                XCTAssertEqual(attrs.title, object.title)
                XCTAssertEqual(attrs.width, object.width)
                XCTAssertEqual(attrs.align, object.align)
            }
            guard case .managedRelative = ImageReferenceParser.classify(attrs.src) else {
                return XCTFail("Clipboard image escaped managed storage")
            }
            let bytes = try XCTUnwrap(h.fixture.session.assetCatalog?.data(for: attrs.src))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: bytes))
            XCTAssertEqual(rep.pixelsWide, 2)
            XCTAssertEqual(rep.pixelsHigh, 2)
            XCTAssertEqual(view.selectedRange().location, (view.string as NSString).range(of: "After").location)
            manager.undo()
            XCTAssertEqual(view.serialize(), "BeforeAfter")
            manager.redo()
            XCTAssertEqual(view.serialize(), body)
            try await h.fixture.session.flushForTermination()
            let reopened = ProjectSession(store: h.fixture.store, defaults: h.fixture.defaults)
            try await reopened.bootstrap()
            XCTAssertEqual(reopened.selectedDocument?.body, body)
            XCTAssertEqual(reopened.assetCatalog?.data(for: attrs.src), bytes)
        }
    }

    private var bitmapFormats: [(NSPasteboard.PasteboardType, NSBitmapImageRep.FileType)] {
        [(.png, .png), (.tiff, .tiff), (.init(UTType.jpeg.identifier), .jpeg)]
    }

    private func bitmap(_ format: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.bitmapData).initialize(repeating: 0xCC, count: rep.bytesPerRow * rep.pixelsHigh)
        return try XCTUnwrap(rep.representation(using: format, properties: [:]))
    }

    private func withClipboard(
        _ populate: (NSPasteboard) -> Void, body: () async throws -> Void
    ) async rethrows {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        populate(pb)
        let ownedChange = pb.changeCount
        defer {
            // Do not overwrite a new clipboard supplied by the user during the test.
            if pb.changeCount == ownedChange {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
        try await body()
    }

    private func drainEvent(_ manager: UndoManager) {
        let deadline = Date().addingTimeInterval(1)
        while manager.groupingLevel > 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        XCTAssertEqual(manager.groupingLevel, 0)
    }
}
