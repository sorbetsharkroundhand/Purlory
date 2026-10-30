@testable import PurloryIntelligence
import AppKit
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 증분 직렬화의 전후 지연 측정 (docs/editor-perf.md).
/// `swift test --filter SerializationPerfTests` — 수치를 로그로 출력한다.
final class SerializationPerfTests: XCTestCase {

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

    private func corpus(_ target: Int) -> String {
        let unit =
            "여름밤 내내 이웃집에서 음악이 흘러나왔다. 그의 푸른 정원에서는 남자와 여자가 "
            + "속삭임과 샴페인과 별들 사이를 나방처럼 왔다 갔다 했다. 오후 만조 때 나는 그의 "
            + "손님들이 뗏목 탑에서 다이빙을 하는 것을 보았다.\n\n"
        var s = ""
        while (s as NSString).length < target { s += unit }
        return String(s.prefix(target))
    }

    @MainActor
    func testKeystrokeSerializeLatency() {
        print("\n=== serialize() 키 입력 1회 지연 — 증분 캐시 (프레임 예산 16.7ms) ===")
        for target in [88_000, 300_000, 600_000] {
            let view = makeEditor()
            view.load(markdown: corpus(target))
            let mid = (view.string as NSString).length / 2
            view.setSelectedRange(NSRange(location: mid, length: 0))

            // 캐시 워밍업: 첫 serialize는 전체 재구축(기준선).
            let coldStart = DispatchTime.now().uptimeNanoseconds
            _ = view.serialize()
            let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000

            // 같은 문단에서 연속 타이핑 → 빠른 경로.
            var samples: [Double] = []
            for i in 0..<20 {
                let at = mid + i
                view.setSelectedRange(NSRange(location: at, length: 0))
                view.insertText("가", replacementRange: NSRange(location: at, length: 0))
                let t = DispatchTime.now().uptimeNanoseconds
                _ = view.serialize()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
            }
            samples.sort()
            let median = samples[samples.count / 2]
            let len = (view.string as NSString).length
            print(
                String(
                    format: "  %7d자: 첫 호출(전체) %6.2fms · 타이핑 중위 %6.3fms · 최대 %6.3fms",
                    len, cold, median, samples.last!))
        }
        print("")
    }
}
