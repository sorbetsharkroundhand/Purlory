@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class ImagePathSafetyTests: XCTestCase {
    private var fixtureRoot: URL!
    private var purloryRoot: URL!
    private var exportRoot: URL!
    private var external: URL!
    private let bytes = Data("outside-image-must-not-leak".utf8)

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-image-safety-\(UUID().uuidString)", isDirectory: true)
        purloryRoot = fixtureRoot.appendingPathComponent("purlory", isDirectory: true)
        exportRoot = fixtureRoot.appendingPathComponent("export", isDirectory: true)
        external = fixtureRoot.appendingPathComponent("secret.png")
        try FileManager.default.createDirectory(
            at: purloryRoot.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try bytes.write(to: external)
        let root = purloryRoot
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(root) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(nil) }
        try FileManager.default.removeItem(at: fixtureRoot)
    }

    func testUnsafeRelativePathsAreBlocked() {
        for path in [
            "../../x.png", "images/../../x.png", "../secret.png", "images/../../secret.png",
            "", ".", "..", "images/./x.png", "images//x.png", "images/",
            "images\\x.png", "images/\0x.png", "file:../../secret.png",
        ] {
            if case .blocked = ImageReferenceParser.classify(path) {} else {
                XCTFail("Unsafe reference was classified as a local image: \(path)")
            }
        }
    }

    @MainActor
    func testResolversRejectUnsafePathsEvenWithoutParser() {
        for path in ["../secret.png", "images/../../secret.png", "images/./x.png",
                     "images//x.png", "images\\x.png", "images/\0x.png"] {
            XCTAssertNil(PurloryImageStore.url(for: path), path)
            XCTAssertNil(PurloryImageStore.resolveURL(for: path), path)
        }
    }

    @MainActor
    func testValidManagedAndExplicitExternalReferencesRemainUsable() {
        XCTAssertEqual(
            PurloryImageStore.url(for: "images/nested/photo.png"),
            purloryRoot.appendingPathComponent("images/nested/photo.png"))
        for reference in [external.path, external.absoluteString] {
            XCTAssertEqual(PurloryImageStore.url(for: reference), external)
            XCTAssertEqual(PurloryImageStore.resolveURL(for: reference), external)
        }
        let homeImage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("purlory-safety-fixture.png")
        // Resolve only: never read or write anything in the user's home directory.
        XCTAssertEqual(PurloryImageStore.url(for: "~/purlory-safety-fixture.png"), homeImage)
        XCTAssertEqual(PurloryImageStore.resolveURL(for: "~/purlory-safety-fixture.png"), homeImage)
    }

    @MainActor
    func testManagedFileAndDirectorySymlinksAreRejected() throws {
        try FileManager.default.createSymbolicLink(
            at: purloryRoot.appendingPathComponent("images/link.png"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(
            at: purloryRoot.appendingPathComponent("linked"), withDestinationURL: fixtureRoot)
        XCTAssertNil(PurloryImageStore.url(for: "images/link.png"))
        XCTAssertNil(PurloryImageStore.url(for: "linked/secret.png"))
        XCTAssertNil(PurloryImageStore.image(for: "images/link.png"))
        XCTAssertNil(PurloryImageStore.displayImage(for: "images/link.png", maxPixelWidth: 100))
    }

    @MainActor
    func testSymlinkedManagedRootIsRejected() throws {
        let rootLink = fixtureRoot.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: purloryRoot)
        PurloryImageStore.setDirectoryOverride(rootLink)
        XCTAssertNil(PurloryImageStore.url(for: "images/photo.png"))
    }

    @MainActor
    func testSavingDoesNotWriteThroughSymlinkedImageDirectory() throws {
        let images = purloryRoot.appendingPathComponent("images")
        try FileManager.default.removeItem(at: images)
        try FileManager.default.createSymbolicLink(at: images, withDestinationURL: fixtureRoot)
        XCTAssertNil(PurloryImageStore.save(bytes, ext: "png"))
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }

    @MainActor
    func testJanitorCannotDeleteExternalFilesFromUnsafeLedgerPaths() throws {
        let ledger = AssetJanitor.Ledger(candidates: [
            "images/../../secret.png": .distantPast,
            external.path: .distantPast,
        ])
        let ledgerURL = try XCTUnwrap(AssetJanitor.ledgerURL())
        try JSONEncoder().encode(ledger).write(to: ledgerURL)
        AssetJanitor.sweepAll(bodies: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    @MainActor
    func testMarkdownDoesNotCopyTraversalFromInlineOrReferenceImages() throws {
        let body = """
            ![inline](../secret.png)
            ![nested](images/../../secret.png)
            ![reference][secret]
            [secret]: ../secret.png
            """
        let destination = exportRoot.appendingPathComponent("book.md")
        let report = try MarkdownExporter.export(
            JournalEntry(title: "Safety", body: body), to: destination)
        XCTAssertEqual(report.copiedAssets, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: exportRoot.appendingPathComponent("images").path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), body)
    }

    @MainActor
    func testMarkdownDoesNotCopyManagedSymlink() throws {
        try FileManager.default.createSymbolicLink(
            at: purloryRoot.appendingPathComponent("images/link.png"), withDestinationURL: external)
        let report = try MarkdownExporter.export(
            JournalEntry(title: "Safety", body: "![link](images/link.png)"),
            to: exportRoot.appendingPathComponent("book.md"))
        XCTAssertEqual(report.copiedAssets, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: exportRoot.appendingPathComponent("images/link.png").path))
    }

    @MainActor
    func testManagedDirectoryCannotSmuggleNestedSymlinksIntoExports() throws {
        let directory = purloryRoot.appendingPathComponent("images/folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("secret.png"), withDestinationURL: external)
        let entry = JournalEntry(title: "Safety", body: "![folder](images/folder)")
        let report = try MarkdownExporter.export(
            entry, to: exportRoot.appendingPathComponent("book.md"))
        XCTAssertEqual(report.copiedAssets, 0)
        XCTAssertTrue(EpubExporter.resolveAssetURLs(in: entry.body).isEmpty)
        let destination = exportRoot.appendingPathComponent("book.epub")
        try EpubExporter.export(entry, to: destination)
        XCTAssertFalse(try archiveEntries(destination).contains("OEBPS/images/"))
    }

    @MainActor
    func testEPUBDoesNotResolveOrPackageTraversalAndSymlinks() throws {
        try FileManager.default.createSymbolicLink(
            at: purloryRoot.appendingPathComponent("images/link.png"), withDestinationURL: external)
        let entry = JournalEntry(title: "Safety", body: """
            ![inline](../secret.png)
            ![nested](images/../../secret.png)
            ![link](images/link.png)
            """)
        XCTAssertTrue(EpubExporter.resolveAssetURLs(in: entry.body).isEmpty)
        let destination = exportRoot.appendingPathComponent("book.epub")
        try EpubExporter.export(entry, to: destination)
        let contents = try archiveEntries(destination)
        XCTAssertFalse(contents.contains("OEBPS/images/"), contents)
    }

    @MainActor
    func testEPUBRechecksManagedPathBeforeBackgroundCopy() throws {
        let safeImage = purloryRoot.appendingPathComponent("images/secret.png")
        try Data("safe-image".utf8).write(to: safeImage)
        let entry = JournalEntry(title: "Safety", body: "![image](images/secret.png)")
        let assetURLs = EpubExporter.resolveAssetURLs(in: entry.body)
        XCTAssertEqual(assetURLs.count, 1)
        try FileManager.default.removeItem(at: safeImage.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
            at: safeImage.deletingLastPathComponent(), withDestinationURL: fixtureRoot)
        var collected: [String] = []
        var missing: [String] = []
        _ = EpubExporter.makeChapters(
            from: entry, copyingImagesInto: exportRoot, collected: &collected,
            missing: &missing, assetURLs: assetURLs)
        XCTAssertTrue(collected.isEmpty)
        XCTAssertEqual(missing, ["images/secret.png"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: exportRoot.appendingPathComponent("images/secret.png").path))
    }

    @MainActor
    func testExportsStillCopyManagedAndExplicitExternalImages() throws {
        let managed = purloryRoot.appendingPathComponent("images/managed.png")
        try Data("managed-image".utf8).write(to: managed)
        let entry = JournalEntry(title: "Safety", body: """
            ![managed](images/managed.png)
            ![external](\(external.path))
            """)
        let report = try MarkdownExporter.export(
            entry, to: exportRoot.appendingPathComponent("book.md"))
        XCTAssertEqual(report.copiedAssets, 2)
        XCTAssertEqual(try Data(contentsOf: exportRoot.appendingPathComponent("images/secret.png")), bytes)
        let destination = exportRoot.appendingPathComponent("book.epub")
        try EpubExporter.export(entry, to: destination)
        let contents = try archiveEntries(destination)
        XCTAssertTrue(contents.contains("OEBPS/images/managed.png"), contents)
        XCTAssertTrue(contents.contains("OEBPS/images/secret.png"), contents)
    }

    private func archiveEntries(_ url: URL) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-Z1", url.path]
        let output = Pipe()
        task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
