@testable import PurloryIntelligence
import XCTest
import UniformTypeIdentifiers

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 이미지 객체 copy/paste의 메타데이터 보존과 asset 수명 장부 (이슈 #17).
///
/// 계약: 복사는 Purlory 객체(JSON)·Markdown·파일 URL·비트맵을 함께 담고, 내부
/// 붙여넣기는 src를 새로 만들지 않고 alt/title/width/align까지 되살리며,
/// 편집마다 이름 있는 undo가 남고, 고아 asset은 유예 후 참조 기반으로만 정리된다.
final class ImageObjectPasteboardTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-obj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ]).write(to: root.appendingPathComponent("images").appendingPathComponent("a.png"))
        let isolatedRoot = root
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(isolatedRoot) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { PurloryImageStore.setDirectoryOverride(nil) }
        // window.close()는 정리 구간 세그폴트를 만든다 — 참조만 내려 ARC에 맡긴다.
        let windowsToClean = windows
        MainActor.assumeIsolated {
            // 다음 비동기 테스트의 이벤트 루프에 자동 undo 그룹 종료를 남기지 않는다.
            windowsToClean.forEach { $0.undoManager?.removeAllActions() }
        }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    /// ImageAtomTests와 같은 창 기반 조립.
    @MainActor
    private func makeEditor(text: String) -> BlockTextView {
        let storage = NSTextStorage()
        let layoutManager = PurloryLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: container)
        storage.delegate = view
        view.allowsUndo = true
        // 스마트 치환은 픽스처의 따옴표를 컬리 퀴트로 바꿔 파싱을 깬다 — 끄고 본다.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        windows.append(window)
        if !text.isEmpty {
            view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            while view.undoManager?.groupingLevel ?? 0 > 0 {
                view.undoManager?.endUndoGrouping()
            }
        }
        return view
    }

    @MainActor
    private func grouped(_ editor: BlockTextView, _ body: () -> Void) {
        editor.undoManager?.beginUndoGrouping()
        body()
        editor.undoManager?.endUndoGrouping()
    }

    // MARK: - 페이스트보드 왕복

    @MainActor
    func test복사는네가지표현을모두담는다() throws {
        let line = #"![주인공 초상](images/a.png "설명"){width=60 align=right}"#
        let editor = makeEditor(text: line)
        let loc = (line as NSString).range(of: "![").location

        XCTAssertTrue(editor.copyImageObject(atParagraph: loc))

        let pb = NSPasteboard.general
        let object = try XCTUnwrap(
            PurloryImageObject(data: try XCTUnwrap(pb.data(forType: .purloryImageObject))))
        XCTAssertEqual(object.src, "images/a.png")
        XCTAssertEqual(object.alt, "주인공 초상")
        XCTAssertEqual(object.title, "설명")
        XCTAssertEqual(object.width, 60)
        XCTAssertEqual(object.align, "right")
        // Markdown 소스 — 원문 공백이 정규화될 수 있으므로 파싱 등가로 비교한다.
        let markdownFlavor = try XCTUnwrap(pb.string(forType: .string))
        let reparsed = try XCTUnwrap(BlockTextView.imageAttrs(from: markdownFlavor))
        let original = try XCTUnwrap(BlockTextView.imageAttrs(from: line))
        XCTAssertEqual(reparsed.src, original.src)
        XCTAssertEqual(reparsed.alt, original.alt)
        XCTAssertEqual(reparsed.title, original.title)
        XCTAssertEqual(reparsed.width, original.width)
        XCTAssertEqual(reparsed.align, original.align)
        // 파일 URL
        let urls = try XCTUnwrap(pb.readObjects(
            forClasses: [NSURL.self], options: [:]) as? [URL])
        XCTAssertEqual(urls.first?.lastPathComponent, "a.png")
        // 호환 비트맵
        XCTAssertNotNil(NSImage(pasteboard: pb))
    }

    @MainActor
    func test내부붙여넣기는메타데이터와같은asset을살린다() throws {
        let line = #"![표지](images/a.png "첫 장면"){width=40 align=left}"#
        let editor = makeEditor(text: line)
        XCTAssertTrue(editor.copyImageObject(atParagraph: (line as NSString).range(of: "![").location))

        // 새 문단을 만들어 끝에 붙여넣는다.
        editor.setSelectedRange(
            NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("\n", replacementRange: editor.selectedRange())
        while editor.undoManager?.groupingLevel ?? 0 > 0 {
            editor.undoManager?.endUndoGrouping()
        }
        var pasteSucceeded = false
        grouped(editor) { pasteSucceeded = editor.insertImages(from: NSPasteboard.general) }
        XCTAssertTrue(pasteSucceeded)

        let pasted = try XCTUnwrap((editor.string as NSString).range(of: "![표지]").location)
        let ns = editor.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: pasted, length: 0))
        let probeText = ns.substring(with: para).trimmingCharacters(in: .whitespaces)
        let attrs = try XCTUnwrap(BlockTextView.imageAttrs(
            from: probeText.trimmingCharacters(in: .whitespacesAndNewlines)))
        // 새 UUID가 아니라 **같은 asset**, 모든 메타데이터 보존.
        XCTAssertEqual(attrs.src, "images/a.png")
        XCTAssertEqual(attrs.alt, "표지")
        XCTAssertEqual(attrs.title, "첫 장면")
        XCTAssertEqual(attrs.width, 40)
        XCTAssertEqual(attrs.align, "left")
    }

    // MARK: - 이름 있는 원자적 undo

    @MainActor
    func test정렬_크기_대체텍스트_삭제_이동의이력이름() throws {
        let line = "![사진](images/a.png)"
        let editor = makeEditor(text: line)
        let image = (line as NSString).paragraphRange(for: NSRange(location: 0, length: 0))

        grouped(editor) { editor.rewriteImage(image, setAlign: "left") }
        XCTAssertEqual(editor.undoManager?.undoActionName, "이미지 정렬")

        grouped(editor) { editor.rewriteImage(image, setWidth: 50) }
        XCTAssertEqual(editor.undoManager?.undoActionName, "이미지 크기 조절")

        grouped(editor) { editor.rewriteImage(image, setAlt: "새 alt") }
        XCTAssertEqual(editor.undoManager?.undoActionName, "대체 텍스트 편집")

        editor.selectedImageLocation = image.location
        grouped(editor) { editor.moveImageParagraph(image, offset: 1) }
        XCTAssertEqual(editor.undoManager?.undoActionName, "이미지 이동")

        grouped(editor) { editor.deleteImageParagraph(image) }
        XCTAssertEqual(editor.undoManager?.undoActionName, "이미지 삭제")
    }

    // MARK: - AssetJanitor (유예 + 참조 기반)

    @MainActor
    func test장부는유예중참조중후보를구분해청소한다() throws {
        let imagesDir = root.appendingPathComponent("images")
        // 유예 지난 고아 — 삭제 대상
        try Data([0x89]).write(to: imagesDir.appendingPathComponent("old-orphan.png"))
        // 유예 지난 참조 — 살아남음 (장부에서만 내려감)
        try Data([0x89]).write(to: imagesDir.appendingPathComponent("old-used.png"))
        // 유예 중 고아 — 살아남음 (redo 가능 기간)
        try Data([0x89]).write(to: imagesDir.appendingPathComponent("young-orphan.png"))

        let now = Date()
        let aged = now.addingTimeInterval(-(AssetJanitor.graceInterval + 120))
        AssetJanitor.record("images/old-orphan.png", at: aged)
        AssetJanitor.record("images/old-used.png", at: aged)
        AssetJanitor.record("images/young-orphan.png", at: now)  // 유예 중
        AssetJanitor.record("images/never-written.png", at: aged)

        let bodies = ["![사용 중](images/old-used.png)"]
        let removed = AssetJanitor.sweepAll(bodies: bodies, now: now)

        XCTAssertEqual(Set(removed), ["images/old-orphan.png", "images/never-written.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("old-orphan.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("old-used.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent("young-orphan.png").path))
    }

    @MainActor
    func test참조판정은모든지원문법을산다() throws {
        // #7 교훈 — title·꺾쇠·참조형을 못 읽어 지우던 사고를 파서 단일 진실로 막는다.
        let bodies = [
            #"![t](images/titled.png "제목")"#,
            "![]( <images/with space.png> )",
            "[r1]: images/refstyle.png",
            "```\n![펜스](images/fenced.png)\n```",  // 펜스 안은 참조 아님
        ]
        let referenced = AssetJanitor.collectReferenced(in: bodies)

        XCTAssertFalse(referenced.contains("images/fenced.png"))
        // sweepAll 간접 검증 — 펜스 것만 유예 없이 고아 판정되는지.
        try Data([0x89]).write(
            to: root.appendingPathComponent("images").appendingPathComponent("titled.png"))
        try Data([0x89]).write(
            to: root.appendingPathComponent("images").appendingPathComponent("with space.png"))
        try Data([0x89]).write(
            to: root.appendingPathComponent("images").appendingPathComponent("refstyle.png"))
        for path in ["images/titled.png", "images/with space.png", "images/refstyle.png"] {
            AssetJanitor.record(path)
        }
        let future = Date().addingTimeInterval(AssetJanitor.graceInterval + 60)
        let removed = AssetJanitor.sweepAll(bodies: bodies, now: future)

        XCTAssertFalse(removed.contains("images/titled.png"))
        XCTAssertFalse(removed.contains("images/with space.png"))
        XCTAssertFalse(removed.contains("images/refstyle.png"))
    }
}
