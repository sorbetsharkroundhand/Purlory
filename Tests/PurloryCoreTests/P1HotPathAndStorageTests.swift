import AppKit
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryFoundation
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

final class P1HotPathAndStorageTests: XCTestCase {

    // MARK: - 1. DocumentSource zero-materialization equality & overflow safety

    func testDocumentSourceEqualityDoesNotMaterializeStrings() {
        let a = DocumentSource(chunks: ["안녕", "하세요\n", "긴 원고의 ", "두 번째 문단"])
        let b = DocumentSource(chunks: ["안녕하세요", "\n긴 원고의 두 번째 문단"])
        let c = DocumentSource(chunks: ["안녕하세요", "\n긴 원고의 두 번째 문장"])

        XCTAssertTrue(a == b)
        XCTAssertFalse(a == c)
        XCTAssertEqual(a.materializationCount, 0, "Equality must compare chunks without materializing lhs.string")
        XCTAssertEqual(b.materializationCount, 0, "Equality must compare chunks without materializing rhs.string")
        XCTAssertEqual(c.materializationCount, 0, "Inequality must compare chunks without materializing string")
    }

    func testDocumentSourceClampedSliceHandlesNSNotFoundAndOverflowRanges() {
        let source = DocumentSource(chunks: ["가나다", "😀라마"])
        XCTAssertEqual(source.clampedSlice(in: NSRange(location: NSNotFound, length: 5)), "")
        XCTAssertEqual(source.clampedSlice(in: NSRange(location: 0, length: Int.max)), "가나다😀라마")
        XCTAssertEqual(source.clampedSlice(in: NSRange(location: 4, length: Int.max)), "😀라마")
    }

    func testDocumentSourceCartesianTreeBuilderPreservesOrderAndOffsets() throws {
        let chunks = (0..<2_000).map { "문단 \($0)\n" }
        let source = DocumentSource(chunks: chunks)
        XCTAssertEqual(source.chunkCount, 2_000)
        XCTAssertEqual(source.newlineCount, 2_000)
        XCTAssertEqual(source.materializationCount, 0)
        let first = try source.substring(in: NSRange(location: 0, length: ("문단 0\n" as NSString).length))
        XCTAssertEqual(first, "문단 0\n")
        let lastChunk = "문단 1999\n"
        let lastLen = (lastChunk as NSString).length
        let last = try source.substring(in: NSRange(location: source.utf16Length - lastLen, length: lastLen))
        XCTAssertEqual(last, lastChunk)
    }

    // MARK: - 2. ProjectStore skips materializing unchanged documents on save

    func testProjectStoreSaveSkipsMaterializingUnchangedDocuments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P1-Save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(root: root)
        var docA = WritingDocument(id: WritingDocumentID(), title: "A", body: "", kind: .manuscript)
        docA.source = DocumentSource(chunks: ["초안 ", "A"])
        var docB = WritingDocument(id: WritingDocumentID(), title: "B", body: "", kind: .manuscript)
        docB.source = DocumentSource(chunks: ["변경 없는 ", "긴 원고 ", "본문입니다."])
        let project = WritingProject(id: WritingProjectID(), title: "Novel", mode: .fiction, documents: [docA, docB])

        try await store.save(project)

        // Rebuild docB with a fresh unmaterialized DocumentSource representing an unchanged multi-chunk document.
        let unmaterializedB = DocumentSource(chunks: ["변경 없는 ", "긴 원고 ", "본문입니다."])
        var updated = project
        updated.documents[0].source = DocumentSource(chunks: ["수정된 ", "A"])
        updated.documents[1].source = unmaterializedB

        try await store.save(updated)
        XCTAssertEqual(unmaterializedB.materializationCount, 0, "Saving an edited sibling must not materialize unchanged documents")
    }

    func testProjectStorePersistsCanonicallyEquivalentButByteDistinctUnicodeEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P1-UnicodeSave-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(root: root)
        let original = "\u{00C5}"
        let replacement = "\u{212B}"
        var project = WritingProject(
            id: WritingProjectID(),
            title: "Unicode Save Regression",
            mode: .general,
            documents: [
                WritingDocument(id: WritingDocumentID(), title: "Draft", body: original, kind: .manuscript)
            ]
        )
        try await store.save(project)

        project.documents[0].body = replacement
        try await store.save(project)

        let reopened = try await ProjectStore(root: root).load(id: project.id).documents[0].body
        XCTAssertTrue(
            reopened.utf16.elementsEqual(replacement.utf16),
            "Reopened manuscript must preserve exact edited UTF-16 scalar U+212B instead of stale U+00C5"
        )
        XCTAssertFalse(reopened.utf16.elementsEqual(original.utf16))
    }

    // MARK: - 3. ProjectStore.projectSummary reads manifest only (does not fail or hash unrelated blobs)

    func testProjectStoreSummaryReadsManifestWithoutLoadingDocumentBlobs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-P1-Summary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class CountingFileSystem: ProjectFileSystem, @unchecked Sendable {
            private let base = LocalProjectFileSystem()
            private let lock = NSLock()
            private var paths: [String] = []
            var readPaths: [String] { lock.withLock { paths } }

            func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
            func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
            func read(_ url: URL) throws -> Data {
                lock.withLock { paths.append(url.lastPathComponent) }
                return try base.read(url)
            }
            func writeAtomically(_ data: Data, to url: URL) throws { try base.writeAtomically(data, to: url) }
            func version(of url: URL) throws -> ProjectFileVersion? { try base.version(of: url) }
        }

        let seedStore = ProjectStore(root: root)
        let project = WritingProject(
            id: WritingProjectID(),
            title: "장편 초고",
            mode: .fiction,
            documents: [WritingDocument(id: WritingDocumentID(), title: "1장", body: "본문", kind: .manuscript)]
        )
        try await seedStore.save(project)

        let spyFS = CountingFileSystem()
        let readerStore = ProjectStore(root: root, fileSystem: spyFS)
        let summary = try await readerStore.projectSummary(id: project.id)
        XCTAssertEqual(summary.id, project.id)
        XCTAssertEqual(summary.title, "장편 초고")
        XCTAssertEqual(summary.mode, .fiction)
        XCTAssertEqual(spyFS.readPaths, ["project.json"], "projectSummary must only read project.json, never document blobs")
    }

    // MARK: - 4. Nested quote bar geometry stays left of paragraph text indent

    @MainActor
    func testNestedQuoteBarXStaysLeftOfParagraphHeadIndent() {
        let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        for indent in 0...6 {
            let attrs = editor.styleAttributes(for: .quote, checked: false, indent: indent)
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let textIndent = ps?.firstLineHeadIndent ?? 0
            let rightmostBarEnd = CGFloat(indent) * BlockTextView.quoteIndentStep + 3
            XCTAssertLessThan(
                rightmostBarEnd,
                textIndent,
                "Quote bar at nesting level \(indent) must not overlap quote text"
            )
        }
    }
}
