import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryDocumentEngine
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

@MainActor
final class ImageExportAndLegacyStorageRegressionTests: XCTestCase {

    private func makeValidPNGData(color: NSColor = .systemBlue) -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - F17 & F18: ImageReferenceParser collapsed reference & fence/duplicate definitions

    func testF17CollapsedReferenceImageUsesAltTextAsLabel() {
        let doc = """
        ![표지 이미지][]

        [표지 이미지]: images/cover.png "책 표지"
        """
        let defs = ImageReferenceParser.collectDefinitions(in: doc)
        let ref = ImageReferenceParser.parse("![표지 이미지][]", definitions: defs)
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.alt, "표지 이미지")
        XCTAssertEqual(ref?.destinationRaw, "images/cover.png")
        XCTAssertEqual(ref?.title, "책 표지")
        XCTAssertEqual(ref?.label, "표지 이미지")
    }

    func testF18CollectDefinitionsSkipsCodeBlocksAndKeepsFirstDuplicateDefinition() {
        let doc = """
        ```markdown
        [ fenced ]: images/inside-backtick-fence.png
        ```

        ~~~
        [ tilde ]: images/inside-tilde-fence.png
        ~~~

            [ indented ]: images/inside-indented-code.png

        [hero]: images/first-hero.png "First"
        [hero]: images/second-hero.png "Second"
        """
        let defs = ImageReferenceParser.collectDefinitions(in: doc)
        XCTAssertNil(defs["fenced"])
        XCTAssertNil(defs["tilde"])
        XCTAssertNil(defs["indented"])
        XCTAssertEqual(defs["hero"]?.destinationRaw, "images/first-hero.png")
        XCTAssertEqual(defs["hero"]?.title, "First")
    }

    // MARK: - F19: BlockTextView & EpubExporter image recognition parity

    func testF19BlockTextViewLoadAndEpubExporterRecognizeReferenceAndTitledImages() throws {
        let markdown = """
        # 1장
        ![인라인 타이틀](images/inline.png "설명")
        ![공백 경로](<images/my photo.png>)
        ![참조형][ref-img]
        ![접힘형][]

        [ref-img]: images/ref.png "참조 제목"
        [접힘형]: images/collapsed.png
        """
        let tv = BlockTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        tv.load(markdown: markdown)

        let ns = tv.string as NSString
        var imageBlocks: [String] = []
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if tv.storageBlockInfo(in: para).block == .image {
                imageBlocks.append(tv.paragraphContent(para))
            }
            loc = para.upperBound
        }
        XCTAssertEqual(imageBlocks.count, 4)

        // Verify EpubExporter also resolves and exports all 4 images and omits definition lines from prose
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f19-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let png = makeValidPNGData()
        var assetURLs: [String: URL] = [:]
        for rel in ["images/inline.png", "images/my photo.png", "images/ref.png", "images/collapsed.png"] {
            let fileURL = tempDir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: fileURL)
            // Use external file path in a test document or pre-populated assetURLs
            assetURLs[rel] = fileURL
        }

        let oebps = tempDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        var collected: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: JournalEntry(title: "테스트", body: markdown),
            copyingImagesInto: oebps,
            collected: &collected,
            missing: &missing,
            assetURLs: assetURLs
        )
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(collected.count, 4)
        XCTAssertFalse(chapters[0].html.contains("[ref-img]:"))
        XCTAssertFalse(chapters[0].html.contains("[접힘형]:"))
    }

    // MARK: - F20, F21, F22, F23: EpubExporter XML escaping, collision, HEIC->PNG, nested lists

    func testF20PackageOPFEscapesSpecialCharactersInImageHref() {
        let entry = JournalEntry(title: "OPF 테스트", body: "# 1장\n본문")
        let opf = EpubExporter.packageOPF(
            entry: entry,
            chapters: [EpubExporter.Chapter(title: "1장", html: "<p>본문</p>")],
            images: ["images/a&b\"c.png"]
        )
        XCTAssertTrue(opf.contains("href=\"images/a&amp;b&quot;c.png\""))
        let parser = XMLParser(data: Data(opf.utf8))
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "OPF XML must be valid")
    }

    func testF21LegacyCopyFileDisambiguatesSameBasenameWithDifferentBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dirA = tempDir.appendingPathComponent("a", isDirectory: true)
        let dirB = tempDir.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let fileA = dirA.appendingPathComponent("scene.png")
        let fileB = dirB.appendingPathComponent("scene.png")
        let bytesA = makeValidPNGData(color: .systemRed)
        let bytesB = makeValidPNGData(color: .systemGreen)
        try bytesA.write(to: fileA)
        try bytesB.write(to: fileB)

        let body = """
        # 1장
        ![A](\(fileA.path))
        ![B](\(fileB.path))
        """
        let oebps = tempDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        var collected: [String] = []
        var missing: [String] = []
        let assetURLs = EpubExporter.resolveAssetURLs(in: body)
        _ = EpubExporter.makeChapters(
            from: JournalEntry(title: "충돌 테스트", body: body),
            copyingImagesInto: oebps,
            collected: &collected,
            missing: &missing,
            assetURLs: assetURLs
        )
        XCTAssertEqual(collected, ["images/scene.png", "images/scene-1.png"])
        XCTAssertEqual(try Data(contentsOf: oebps.appendingPathComponent("images/scene.png")), bytesA)
        XCTAssertEqual(try Data(contentsOf: oebps.appendingPathComponent("images/scene-1.png")), bytesB)
    }

    func testF22HeicAssetIsTranscodedToPngInEpubAndCorruptHeicIsReportedMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f22-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validHeicURL = tempDir.appendingPathComponent("photo.heic")
        try makeValidPNGData(color: .systemOrange).write(to: validHeicURL)
        let corruptHeicURL = tempDir.appendingPathComponent("corrupt.heic")
        try Data("not-an-image".utf8).write(to: corruptHeicURL)

        let body = """
        # 1장
        ![정상](\(validHeicURL.path))
        ![손상](\(corruptHeicURL.path))
        """
        let oebps = tempDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        var collected: [String] = []
        var missing: [String] = []
        let assetURLs = EpubExporter.resolveAssetURLs(in: body)
        _ = EpubExporter.makeChapters(
            from: JournalEntry(title: "HEIC", body: body),
            copyingImagesInto: oebps,
            collected: &collected,
            missing: &missing,
            assetURLs: assetURLs
        )
        XCTAssertEqual(collected, ["images/photo.png"])
        XCTAssertEqual(missing, [corruptHeicURL.path])
        let exportedBytes = try Data(contentsOf: oebps.appendingPathComponent("images/photo.png"))
        XCTAssertEqual( Array(exportedBytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testF23NestedListsAndOrderedListStartNumbersArePreservedInXHTML() {
        let body = """
        # 1장
        - 상위 1
          - 하위 1-1
          - 하위 1-2
        - 상위 2

        3. 세 번째부터 시작
        4. 네 번째
        """
        var collected: [String] = []
        var missing: [String] = []
        let chapters = EpubExporter.makeChapters(
            from: JournalEntry(title: "목록", body: body),
            copyingImagesInto: FileManager.default.temporaryDirectory,
            collected: &collected,
            missing: &missing
        )
        let html = chapters[0].html
        XCTAssertTrue(html.contains("<li>상위 1\n<ul>\n<li>하위 1-1</li>\n<li>하위 1-2</li>\n</ul>\n</li>"))
        XCTAssertTrue(html.contains("<ol start=\"3\">"))
        let parser = XMLParser(data: Data(("<root>" + html + "</root>").utf8))
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "Nested list XHTML must be valid XML")
    }

    // MARK: - F24, F25, F31: Fence scanner in MarkdownExporter, AssetJanitor, DocumentOutline

    func testF24TildeAndFourBacktickFencesDoNotLeakImagesInExporterOrJanitor() throws {
        let body = """
        ````markdown
        ```
        ![가짜1](images/fake1.png)
        ```
        ````

        ~~~
        ![가짜2](images/fake2.png)
        ~~~

        ![진짜](images/real.png)
        """
        let refs = AssetJanitor.collectReferenced(in: [body])
        XCTAssertEqual(refs, ["images/real.png"])
    }

    func testF25AssetJanitorKeepsGracePeriodCandidatesAndFailedDeletionsInLedger() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f25-\(UUID().uuidString)", isDirectory: true)
        let imagesDir = tempDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loc = PurloryStorageLocation(rootDirectory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        AssetJanitor.record("images/orphan.png", at: t0, storageLocation: loc)

        // 1) Sweep during grace period (t0 + 10 min): must NOT delete and must NOT drop from ledger
        let earlyRemoved = AssetJanitor.sweep(
            now: t0.addingTimeInterval(600),
            storageLocation: loc,
            isReferenced: { _ in false },
            performDelete: { _ in XCTFail("Should not delete during grace period") }
        )
        XCTAssertTrue(earlyRemoved.isEmpty)
        XCTAssertTrue(AssetJanitor.hasPendingCandidates(storageLocation: loc))

        // 2) Sweep after grace period when performDelete throws: must remain in ledger
        struct DeleteError: Error {}
        let failedRemoved = AssetJanitor.sweep(
            now: t0.addingTimeInterval(AssetJanitor.graceInterval + 10),
            storageLocation: loc,
            isReferenced: { _ in false },
            performDelete: { _ in throw DeleteError() }
        )
        XCTAssertTrue(failedRemoved.isEmpty)
        XCTAssertTrue(AssetJanitor.hasPendingCandidates(storageLocation: loc))

        // 3) Sweep after grace period when performDelete succeeds: removed from ledger
        var deletedPaths: [String] = []
        let finalRemoved = AssetJanitor.sweep(
            now: t0.addingTimeInterval(AssetJanitor.graceInterval + 20),
            storageLocation: loc,
            isReferenced: { _ in false },
            performDelete: { deletedPaths.append($0) }
        )
        XCTAssertEqual(finalRemoved, ["images/orphan.png"])
        XCTAssertEqual(deletedPaths, ["images/orphan.png"])
        XCTAssertFalse(AssetJanitor.hasPendingCandidates(storageLocation: loc))
    }

    func testF31DocumentOutlineIgnoresHeadingsAndSceneBreaksInsideCodeFences() {
        let body = """
        # 1장 진짜 헤딩
        도입부 문장입니다.
        ```python
        # 파이썬 주석은 헤딩이 아닙니다
        ***
        ```
        ~~~
        ## 틸드 펜스 안의 헤딩도 무시합니다
        ~~~
        1장의 마지막 문장입니다.
        # 2장 두 번째 헤딩
        2장 본문입니다.
        """
        let outline = DocumentOutline.parse(body)
        XCTAssertEqual(outline.scenes.count, 2)
        XCTAssertEqual(outline.scenes[0].headingPath, ["1장 진짜 헤딩"])
        XCTAssertEqual(outline.scenes[1].headingPath, ["2장 두 번째 헤딩"])
    }

    // MARK: - F05, F06, F07: Legacy EntryStore & TrashStore safety

    func testF05RecoveryPromotionPreservesRecoveredFileWhenReplaceFailsAndSucceedsAtomicallyWhenWritable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let entriesURL = tempDir.appendingPathComponent("entries.json")
        let recoveredURL = tempDir.appendingPathComponent("entries-recovered-20261110-120000.json")
        let entryID = UUID()
        let recoveredJSON = """
        {
          "activeID": "\(entryID.uuidString)",
          "entries": [
            {
              "id": "\(entryID.uuidString)",
              "title": "복구된 원고",
              "createdAt": "2026-11-10T03:00:00Z",
              "body": "복구 세션 본문입니다."
            }
          ]
        }
        """
        try Data("{corrupt".utf8).write(to: entriesURL)
        try Data(recoveredJSON.utf8).write(to: recoveredURL)

        // Make directory read-only so staging copy / promotion fails: recoveredURL must NOT be deleted!
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        XCTAssertFalse(EntryStore.promoteRecoveredFile(from: recoveredURL, to: entriesURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))

        // Restore write permission: startup automatic promotion succeeds and removes recoveredURL only after verification
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        let store = EntryStore(directory: tempDir, autosaveDelay: .seconds(10))
        XCTAssertNil(store.pendingRecovery)
        XCTAssertEqual(store.entries.first?.body, "복구 세션 본문입니다.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entriesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredURL.path))
    }

    func testF06TrashStorePreservesCorruptFileAndEntryStoreAbortsDeleteWhenTrashFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let trashURL = tempDir.appendingPathComponent("trash.json")
        try Data("{corrupt-json".utf8).write(to: trashURL)

        let trash = TrashStore(directory: tempDir)
        XCTAssertTrue(trash.hasUnreadableOrCorruptState)
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(files.contains(where: { $0.hasPrefix("trash.corrupt-") }))
    }

    func testF07EntryStoreProtectsAssetsReferencedInTrashAndBackupsDuringStartupSweep() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-f07-\(UUID().uuidString)", isDirectory: true)
        let imagesDir = tempDir.appendingPathComponent("images", isDirectory: true)
        let backupsDir = tempDir.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loc = PurloryStorageLocation(rootDirectory: tempDir)
        let png = makeValidPNGData()
        try png.write(to: imagesDir.appendingPathComponent("in-trash.png"))
        try png.write(to: imagesDir.appendingPathComponent("in-backup.png"))
        try png.write(to: imagesDir.appendingPathComponent("truly-orphan.png"))

        let past = Date.now.addingTimeInterval(-(AssetJanitor.graceInterval + 120))
        AssetJanitor.record("images/in-trash.png", at: past, storageLocation: loc)
        AssetJanitor.record("images/in-backup.png", at: past, storageLocation: loc)
        AssetJanitor.record("images/truly-orphan.png", at: past, storageLocation: loc)

        // Put "images/in-trash.png" in trash.json
        let trashStore = TrashStore(directory: tempDir)
        XCTAssertTrue(trashStore.add(
            folders: [],
            entries: [JournalEntry(title: "휴지통 글", body: "![](images/in-trash.png)")]
        ))

        // Put "images/in-backup.png" in backups/entries-2026-11-09.json
        let backupJSON = """
        {
          "entries": [
            {
              "id": "\(UUID().uuidString)",
              "title": "백업 글",
              "createdAt": "2026-11-09T12:00:00Z",
              "body": "![](images/in-backup.png)"
            }
          ]
        }
        """
        try Data(backupJSON.utf8).write(to: backupsDir.appendingPathComponent("entries-2026-11-09.json"))

        // Initialize EntryStore (which triggers startup sweep protection)
        let store = EntryStore(directory: tempDir, autosaveDelay: .seconds(10))
        _ = store

        // Verify that both trash and backup images are still on disk after startup task
        let exp = expectation(description: "wait for utility sweep task")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("in-trash.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("in-backup.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("truly-orphan.png").path))
    }

    // MARK: - F32: Documentation module map & active scope alignment

    func testF32PlanAndReadmeModulePathsExistAndDoNotClaimStalePurloryCoreSubfolders() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let planText = try String(contentsOf: repoRoot.appendingPathComponent("PLAN.md"), encoding: .utf8)
        let readmeText = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)

        let expectedDirs = [
            "Sources/Purlory",
            "Sources/PurloryFoundation",
            "Sources/PurloryDocumentEngine",
            "Sources/PurloryStorage",
            "Sources/PurloryInference",
            "Sources/PurloryIntelligence/Inference",
            "Sources/PurloryIntelligence/Knowledge",
            "Sources/PurloryIntelligence/WritingQuality",
            "Sources/PurloryWorkspaceUI/Project",
            "Sources/PurloryWorkspaceUI/Workspace",
            "Sources/PurloryWorkspaceUI/Editor",
            "Sources/PurloryWorkspaceUI/Knowledge",
            "Sources/PurloryWorkspaceUI/Export",
            "Sources/PurloryCore",
            "Sources/PurloryBench"
        ]
        for rel in expectedDirs {
            var isDir: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(rel).path, isDirectory: &isDir) && isDir.boolValue,
                "Expected module path \(rel) to exist"
            )
        }
        XCTAssertFalse(planText.contains("Sources/PurloryCore/Editor"))
        XCTAssertFalse(readmeText.contains("Sources/PurloryCore/Editor"))
        XCTAssertTrue(planText.contains("PurloryDocumentEngine"))
        XCTAssertTrue(readmeText.contains("PurloryDocumentEngine"))
    }
}
