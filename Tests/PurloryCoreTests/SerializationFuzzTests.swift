@testable import PurloryIntelligence
import AppKit
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 증분 직렬화 캐시의 핵심 불변조건을 무작위 편집으로 검증한다:
///
///     serialize(증분 상태) == serialize(전체 문서)
///
/// 캐시가 있는 에디터와 매번 캐시를 버리고 전체 재구축하는 기준 에디터를
/// **같은 편집 시퀀스**로 몰아, 매 편집 직후 직렬화가 일치하는지 본다.
/// 하나라도 어긋나면 원고 손상이므로, 시드를 로그에 남겨 재현 가능하게 한다.
final class SerializationFuzzTests: XCTestCase {

    private var windows: [NSWindow] = []
    override func tearDown() { windows.removeAll(); super.tearDown() }

    @MainActor
    private func makeEditor() -> BlockTextView {
        let storage = NSTextStorage()
        let lm = PurloryLayoutManager()
        storage.addLayoutManager(lm)
        let c = NSTextContainer(
            containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(c)
        let v = BlockTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: c)
        storage.delegate = v
        v.allowsUndo = true
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
        w.contentView?.addSubview(v)
        w.makeFirstResponder(v)
        windows.append(w)
        return v
    }

    /// 캐시가 없는 진실값 — 매번 새 에디터에 열어 직렬화한다(증분 상태가 절대
    /// 개입하지 않는 기준선).
    @MainActor
    private func groundTruth(_ text: String) -> String {
        let v = makeEditor()
        v.load(markdown: text)
        return v.serialize()
    }

    /// 무작위 편집을 한 번 가한다 — 타이핑·개행·삭제·붙여넣기·커서 이동을 섞는다.
    @MainActor
    private func randomEdit(_ v: BlockTextView, _ rng: inout SplitMix64) {
        let ns = v.string as NSString
        let len = ns.length
        let loc = len == 0 ? 0 : Int(rng.next() % UInt64(len + 1))
        switch rng.next() % 10 {
        case 0, 1, 2, 3:  // 한글 한 글자 타이핑(가장 흔한 경로)
            let syllables = Array("가나다라마바사아자차타파하글한")
            let ch = syllables[Int(rng.next() % UInt64(syllables.count))]
            v.setSelectedRange(NSRange(location: loc, length: 0))
            v.insertText(String(ch), replacementRange: NSRange(location: loc, length: 0))
        case 4:  // 영문/숫자 (선두 숫자·인라인 함정 포함)
            let s = ["A", "1", "33번지", "*강조*", "x"][Int(rng.next() % 5)]
            v.setSelectedRange(NSRange(location: loc, length: 0))
            v.insertText(s, replacementRange: NSRange(location: loc, length: 0))
        case 5:  // 개행(문단 분할)
            v.setSelectedRange(NSRange(location: loc, length: 0))
            v.insertText("\n", replacementRange: NSRange(location: loc, length: 0))
        case 6:  // 한 글자 삭제
            if loc < len {
                v.insertText("", replacementRange: NSRange(location: loc, length: 1))
            }
        case 7:  // 범위 삭제(문단 병합 가능)
            if loc < len {
                let dl = min(Int(rng.next() % 12) + 1, len - loc)
                v.insertText("", replacementRange: NSRange(location: loc, length: dl))
            }
        case 8:  // 대량 붙여넣기(여러 문단)
            v.setSelectedRange(NSRange(location: loc, length: 0))
            v.insertText(
                "붙여넣기 첫 줄.\n둘째 줄.\n셋째 줄.",
                replacementRange: NSRange(location: loc, length: 0))
        default:  // 커서만 이동(편집 없음)
            v.setSelectedRange(NSRange(location: loc, length: 0))
        }
    }

    /// 여러 시드로 긴 편집 시퀀스를 돌리며 매 스텝마다 불변조건을 확인한다.
    @MainActor
    func testFuzzIncrementalEqualsFull() {
        let seeds: [UInt64] = [1, 7, 42, 1337, 20260716, 99999]
        for seed in seeds {
            var rng = SplitMix64(seed: seed)
            let live = makeEditor()
            live.load(markdown: "# 시작\n첫 문단이다.\n\n둘째 문단이다.")

            for step in 0..<300 {
                randomEdit(live, &rng)
                let incremental = live.serialize()  // 캐시 경유
                let full = groundTruth(incremental)  // 캐시 없는 진실값
                XCTAssertEqual(
                    incremental, full,
                    "불변조건 위반 — seed=\(seed) step=\(step)\n증분:\n\(incremental)\n전체:\n\(full)")
                if incremental != full { return }  // 첫 실패에서 멈춰 로그를 짧게
            }
        }
    }

    /// IME 조합을 섞은 시퀀스 — 한글 입력의 실제 경로(markedText 반복 교체).
    @MainActor
    func testFuzzWithIMEComposition() {
        var rng = SplitMix64(seed: 2026)
        let live = makeEditor()
        live.load(markdown: "가나다")

        for step in 0..<120 {
            let ns = live.string as NSString
            let loc = ns.length == 0 ? 0 : Int(rng.next() % UInt64(ns.length + 1))
            live.setSelectedRange(NSRange(location: loc, length: 0))
            // "ㅎ" → "하" → "한" 조합 후 확정
            live.setMarkedText(
                "ㅎ", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: loc, length: 0))
            live.setMarkedText(
                "하", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: live.markedRange())
            live.setMarkedText(
                "한", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: live.markedRange())
            live.unmarkText()

            let incremental = live.serialize()
            let full = groundTruth(incremental)
            XCTAssertEqual(incremental, full, "IME 불변조건 위반 — step=\(step)")
            if incremental != full { return }
        }
    }

    /// Undo/Redo를 섞은 시퀀스 — undo 뒤 캐시가 화면과 어긋나지 않아야 한다.
    @MainActor
    func testFuzzWithUndoRedo() {
        var rng = SplitMix64(seed: 555)
        let live = makeEditor()
        live.load(markdown: "본문 시작이다.")

        for step in 0..<200 {
            if rng.next() % 3 == 0 {
                if rng.next() % 2 == 0 { live.undoManager?.undo() } else { live.undoManager?.redo() }
            } else {
                randomEdit(live, &rng)
            }
            let incremental = live.serialize()
            let full = groundTruth(incremental)
            XCTAssertEqual(incremental, full, "undo/redo 불변조건 위반 — step=\(step)")
            if incremental != full { return }
        }
    }
}

/// 재현 가능한 결정적 난수 — 시드로 실패를 그대로 되살린다.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
