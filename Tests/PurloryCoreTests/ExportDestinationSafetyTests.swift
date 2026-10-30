@testable import PurloryIntelligence
@testable import PurloryStorage
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ExportDestinationSafetyTests: XCTestCase {
    func testFailedAtomicCommitPreservesPriorBytesAndSuccessfulCommitReplacesThem() throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("book.epub")
        let staged = root.appendingPathComponent("completed.epub")
        try Data([8, 7, 6]).write(to: destination)
        // A missing staging file produces a deterministic rename failure at the commit boundary.
        XCTAssertThrowsError(try ExportDestination.commit(stagedFile: staged, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([8, 7, 6]))
        try Data([1, 2, 3]).write(to: staged)
        try ExportDestination.commit(stagedFile: staged, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    // Catches manuscript writes, asset copies, or EPUB replacement following user symlinks.
    func testBothFormatsRejectSymlinkAncestorsLeavesAndDanglingLeaves() async throws {
        for epub in [false, true] {
            for kind in ["ancestor", "leaf", "dangling"] {
                let root = try temporaryProjectRoot().resolvingSymlinksInPath()
                defer { try? FileManager.default.removeItem(at: root) }
                let selected = root.appendingPathComponent("selected")
                let outside = root.appendingPathComponent("outside")
                try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let original = outside.appendingPathComponent("book")
                try Data([8, 7, 6]).write(to: original)
                let link = selected.appendingPathComponent("link")
                let target = kind == "ancestor" ? outside : (kind == "leaf" ? original : outside.appendingPathComponent("absent"))
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                let destination = kind == "ancestor" ? link.appendingPathComponent("book") : link
                let (document, catalog) = try await fixture(root)
                do {
                    if epub { try EpubExporter.export(document, assets: catalog, to: destination) }
                    else { try MarkdownExporter.export(document, assets: catalog, to: destination) }
                    XCTFail("Accepted \(kind) symlink for \(epub ? "EPUB" : "Markdown")")
                } catch ProjectStoreError.unsafePath {}
                XCTAssertEqual(try Data(contentsOf: original), Data([8, 7, 6]))
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["book"])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selected.path), ["link"])
            }
        }
    }

    func testBothFormatsAcceptNormalMacOSTemporaryDirectoryDestinations() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (document, catalog) = try await fixture(root)
        try MarkdownExporter.export(document, assets: catalog, to: root.appendingPathComponent("book.md"))
        try EpubExporter.export(document, assets: catalog, to: root.appendingPathComponent("book.epub"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("book.md"), encoding: .utf8), "![A](images/a.png)\n")
        XCTAssertEqual(try epubMember("OEBPS/images/a.png", in: root.appendingPathComponent("book.epub")), Data([1, 2, 3]))
    }

    func testEpubCancellationAfterArchiveBuildPreservesPriorExport() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (document, catalog) = try await fixture(root)
        let destination = root.appendingPathComponent("book.epub")
        try Data([8, 7, 6]).write(to: destination)
        do {
            try await EpubExporter.exportAsync(document, assets: catalog, to: destination, progress: { progress in
                if progress == 0.95 { withUnsafeCurrentTask { $0?.cancel() } }
            })
            XCTFail("Cancelled archive replaced the prior export")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: destination), Data([8, 7, 6]))
    }

    func testEpubRejectsDirectoryDestinationWithoutRemovingItsContents() async throws {
        let root = try temporaryProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (document, catalog) = try await fixture(root)
        let destination = root.appendingPathComponent("book.epub")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let prior = destination.appendingPathComponent("prior-export")
        try Data([8, 7, 6]).write(to: prior)
        do { try EpubExporter.export(document, assets: catalog, to: destination); XCTFail("Removed a directory destination") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: prior), Data([8, 7, 6]))
    }

    private func fixture(_ root: URL) async throws -> (WritingDocument, ProjectAssetCatalog) {
        let store = ProjectStore(root: root.appendingPathComponent("store"))
        let document = WritingDocument(id: WritingDocumentID(), title: "Book", body: "![A](images/a.png)\n", kind: .manuscript)
        let project = WritingProject(id: WritingProjectID(), title: "Project", mode: .general, documents: [document])
        try await store.save(project)
        try await store.addAsset(Data([1, 2, 3]), reference: "images/a.png", to: project.id)
        return (document, try await store.assetCatalog(id: project.id))
    }
}
