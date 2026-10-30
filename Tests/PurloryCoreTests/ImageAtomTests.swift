@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 이미지 블록의 원자 캐럿·키보드·VoiceOver 모델 (이슈 #16).
///
/// 계약: 렌더된 이미지는 원자다 — 화살표 한 번에 앞/뒤로 건너뛰고, VoiceOver는
/// 소스 대신 alt·너비·정렬을 듣고, ⌘←/⌘→·±·⌥↑↓·Backspace로 정렬·크기·이동·
/// 삭제가 undo 가능하게 이뤄진다.
final class ImageAtomTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-atom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        // 1×1 PNG — 실제 렌더 가능한 최소 바이트.
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
        // window.close()는 XCTest 정리 구간에서 autorelease 불균형 세그폴트를
        // 만든다 — SerializationTests와 같이 참조만 내려 ARC에 맡긴다.
        let windowsToClean = windows
        MainActor.assumeIsolated {
            // 다음 비동기 테스트의 이벤트 루프에 자동 undo 그룹 종료를 남기지 않는다.
            windowsToClean.forEach { $0.undoManager?.removeAllActions() }
        }
        windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    /// SerializationTests와 같은 조립 — 창을 넣어야 undoManager가 생긴다.
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
        print(" 뷰 생성")
        storage.delegate = view
        print(" 델리게이트")
        view.allowsUndo = true
        // 창에 넣어야 undoManager가 생긴다 (앱과 같은 조건).
        print(" undo")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        print(" 창")
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(view)
        print(" 추가")
        window.makeFirstResponder(view)
        print(" 응답자")
        windows.append(window)
        if !text.isEmpty {
            view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }
        print(" 삽입 후 [\(view.string)]")
        return view
    }

    /// 본문: "앞문단\n![사진](images/a.png){width=60}\n뒷문단"
    /// 이미지 문단은 {4, 30} — 경계는 4(앞)와 34(뒤).
    @MainActor
    private func fixture() -> (text: String, image: NSRange) {
        let text = "앞문단\n![사진](images/a.png){width=60}\n뒷문단"
        let ns = text as NSString
        let image = ns.paragraphRange(for: NSRange(location: 8, length: 0))
        return (text, image)
    }

    // MARK: - 원자 캐럿

    @MainActor
    func test내부제안은들어온방향반대경계로튕겨나간다() throws {
        let (text, image) = fixture()
        let ns = text as NSString

        // 위쪽에서 들어온 제안 — 이미지 앞 경계로 스냅.
        XCTAssertEqual(
            BlockTextView.atomicCaretRange(
                3, result: NSRange(location: 8, length: 0), in: ns,
                isImage: { $0 == image }),
            NSRange(location: image.location, length: 0))
        // 아래쪽에서 들어온 제안 — 이미지 뒤 경계로 스냅.
        XCTAssertEqual(
            BlockTextView.atomicCaretRange(
                36, result: NSRange(location: 20, length: 0), in: ns,
                isImage: { $0 == image }),
            NSRange(location: image.upperBound, length: 0))
    }

    @MainActor
    func test경계와범위선택은그대로둔다() throws {
        let (text, image) = fixture()
        let ns = text as NSString
        let boundary = NSRange(location: image.location, length: 0)
        XCTAssertEqual(
            BlockTextView.atomicCaretRange(
                4, result: boundary, in: ns, isImage: { $0 == image }),
            boundary, "이미지 앞 자리는 유효하다")
        let selection = NSRange(location: image.location + 2, length: 3)
        XCTAssertEqual(
            BlockTextView.atomicCaretRange(
                0, result: selection, in: ns, isImage: { $0 == image }),
            selection, "범위 선택(Shift 확장)은 원자화하지 않는다")
    }

    @MainActor
    func testselectionRange우회가실제로원자화한다() throws {
        let (text, image) = fixture()
        let editor = makeEditor(text: text)
        // 렌더 파이프라인을 거치지 않고 블록 표식만 심는다 — 원자화 판정은
        // purloryBlock 속성 하나로 이뤄진다.
        editor.textStorage?.addAttribute(
            .purloryBlock, value: PurloryBlock.image.rawValue, range: image)
        // 이미지 소스 한가운데를 제안 — 경계로 튕겨야 한다.
        let snapped = editor.selectionRange(
            forProposedRange: NSRange(location: image.location + 5, length: 0),
            granularity: .selectByCharacter)
        XCTAssertTrue(
            snapped.location <= image.location || snapped.location >= image.upperBound,
            "캐럿이 이미지 내부에 남았다: \(snapped)")
        // 일반 문단은 그대로다.
        XCTAssertEqual(
            editor.selectionRange(
                forProposedRange: NSRange(location: 1, length: 0),
                granularity: .selectByCharacter),
            NSRange(location: 1, length: 0))
    }

    // MARK: - VoiceOver 읽기

    @MainActor
    func test읽기문장은alt와너비정렬을담는다() {
        var attrs = ImageAttrs(src: "images/a.png", alt: "주인공 초상")
        attrs.width = 60
        attrs.align = "left"
        XCTAssertEqual(
            BlockTextView.spokenDescription(attrs: attrs, failure: nil),
            "이미지, 주인공 초상, 너비 60%, 왼쪽 정렬")
        // alt가 비면 파일명으로 대체하고, 실패 원인을 앞세운다.
        XCTAssertEqual(
            BlockTextView.spokenDescription(attrs: ImageAttrs(src: "images/gone.png"), failure: .missing),
            "이미지, 표시 불가, gone.png, 너비 100%, 가운데 정렬")
    }

    @MainActor
    func test접근성읽기는이미지소스를문장으로바꾼다() throws {
        let (text, image) = fixture()
        let editor = makeEditor(text: text)
        editor.textStorage?.addAttribute(
            .purloryBlock, value: PurloryBlock.image.rawValue, range: image)
        let full = editor.accessibilityString(for: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertFalse(full.contains("!["), "마크다운 구문이 그대로 읽혔다: \(full)")
        XCTAssertTrue(full.contains("사진"), full)
        XCTAssertTrue(full.contains("앞문단"), full)
        XCTAssertTrue(full.contains("뒷문단"), full)
    }

    // MARK: - 키 매핑

    @MainActor
    func test객체모드키매핑() {
        let left = "\u{F702}", right = "\u{F703}", up = "\u{F700}", down = "\u{F704}"
        XCTAssertEqual(BlockTextView.objectKeyAction(left, command: false, option: false), .exitBefore)
        XCTAssertEqual(BlockTextView.objectKeyAction(right, command: false, option: false), .exitAfter)
        XCTAssertEqual(BlockTextView.objectKeyAction(left, command: true, option: false), .align("left"))
        XCTAssertEqual(BlockTextView.objectKeyAction(up, command: true, option: false), .align("center"))
        XCTAssertEqual(BlockTextView.objectKeyAction(right, command: true, option: false), .align("right"))
        XCTAssertEqual(BlockTextView.objectKeyAction("+", command: false, option: false), .adjustWidth(10))
        XCTAssertEqual(BlockTextView.objectKeyAction("-", command: false, option: false), .adjustWidth(-10))
        XCTAssertEqual(BlockTextView.objectKeyAction(up, command: false, option: true), .move(-1))
        XCTAssertEqual(BlockTextView.objectKeyAction(down, command: false, option: true), .move(1))
        XCTAssertEqual(BlockTextView.objectKeyAction("\r", command: false, option: false), .revealToolbar)
        XCTAssertNil(BlockTextView.objectKeyAction("a", command: false, option: false))
    }

    // MARK: - 키보드 이동·undo

    @MainActor
    func test문단이동은내용을보존하고undo로되돌린다() throws {
        let (text, image) = fixture()
        let editor = makeEditor(text: text)
        editor.selectedImageLocation = image.location
        let um = editor.undoManager
        // insertText가 열어 둔 이벤트 그룹을 닫는다 — 안 닫으면 undo()가 중첩
        // 그룹 전체를 되돌려 빈 문서가 된다.
        while um?.groupingLevel ?? 0 > 0 { um?.endUndoGrouping() }

        // 헤드리스에선 이벤트 주기가 그룹을 열어주지 않으므로 이동 단위로
        // 명시적으로 묶는다 — 앱에서는 NSTextView가 이 역할을 한다.
        um?.beginUndoGrouping()
        editor.moveImageParagraph(image, offset: -1)
        um?.endUndoGrouping()

        XCTAssertEqual(editor.string, "![사진](images/a.png){width=60}\n앞문단\n뒷문단")
        // 이동도 undo 한 번으로 되돌아간다.
        um?.undo()
        XCTAssertEqual(editor.string, text, "이동이 undo에 등록되지 않았다")

        // 아래로 이동 — 끝 문단과 맞바꾼다.
        um?.beginUndoGrouping()
        editor.moveImageParagraph(image, offset: 1)
        um?.endUndoGrouping()
        XCTAssertEqual(editor.string, "앞문단\n뒷문단\n![사진](images/a.png){width=60}")
    }

    @MainActor
    func test경계에서이동은무시된다() throws {
        // 이미지가 첫 문단인 픽스처 — 위로 이동은 무시돼야 한다.
        let text = "![사진](images/a.png){width=60}\n뒷문단"
        let editor = makeEditor(text: text)
        let image = (text as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        editor.moveImageParagraph(image, offset: -1)
        XCTAssertEqual(editor.string, text)
    }
}
