@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import CryptoKit
import Darwin
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// Synthetic AppKit measurements; native event-to-idle/IME and actual paint are owner checks.
@MainActor
final class LongDocumentRenderMeasurementTests: XCTestCase {
    func test300kCharactersAnd100MediaKeepOrdinaryRenderWorkBounded() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.body.count, 300_000)
        XCTAssertEqual(fixture.assets.count, 50)
        XCTAssertEqual(Set(fixture.assets.values.map(digest)).count, 50)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let storage = NSTextStorage(), manager = NSLayoutManager()
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        let view = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 4_000), textContainer: container)
        view.textStorage?.delegate = view
        view.projectAssetCatalog = ProjectAssetCatalog(projectID: WritingProjectID(), verifiedAssets: fixture.assets)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        scroll.documentView = view
        let loadMs = elapsed { view.load(markdown: fixture.body) }
        XCTAssertEqual(view.mathRenders.count, 50)
        XCTAssertEqual(view.imageRenders.count, 50)
        XCTAssertTrue(view.imageRenders.allSatisfy { $0.failure == nil })
        let paragraphCount = try XCTUnwrap(view.mediaParagraphIndex).paragraphCount
        let buildCount = view.mediaIndexBuildCount
        let firstVisibleMs = elapsed {
            manager.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: 600, height: manager.usedRect(for: container).height + 100))
            scroll.layoutSubtreeIfNeeded()
            view.refreshVisibleBlocks()
        }
        _ = view.serialize() // Warm the existing incremental serialization cache.
        let caret = (view.string as NSString).range(of: "한글").location
        view.setSelectedRange(NSRange(location: caret, length: 0))
        var typing: [Double] = [], scrolling: [Double] = [], full: [Double] = []
        var typingParagraphs: [Int] = [], scrollParagraphs: [Int] = []
        for _ in 0..<40 {
            typing.append(elapsed {
                view.insertText("글", replacementRange: view.selectedRange())
                _ = view.serialize()
                manager.ensureLayout(forBoundingRect: scroll.contentView.bounds, in: container)
            })
            typingParagraphs.append(view.lastMediaRenderParagraphCount)
            XCTAssertLessThan(view.lastMediaRenderParagraphCount, paragraphCount / 10)
            XCTAssertEqual(view.mediaIndexBuildCount, buildCount)
        }
        for index in 0..<40 {
            scrolling.append(elapsed {
                let y = max(0, view.frame.height - 600) * CGFloat(index) / 39
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.refreshVisibleBlocks()
            })
            scrollParagraphs.append(view.lastMediaRenderParagraphCount)
            XCTAssertLessThan(view.lastMediaRenderParagraphCount, paragraphCount / 10)
        }
        for _ in 0..<10 { full.append(elapsed { view.refreshRenderedBlocks(forceRender: true) }) }
        XCTAssertEqual(view.lastMediaRenderParagraphCount, paragraphCount)
        let report = Report(fixtureVersion: 1, bodySHA256: digest(Data(fixture.body.utf8)),
            assetSHA256: fixture.assets.mapValues(digest), characters: fixture.body.count,
            sourceUTF16: (fixture.body as NSString).length, paragraphs: paragraphCount,
            imageCount: 50, mathCount: 50, imagePixels: [2048, 1024],
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            loadMs: loadMs, firstVisibleRenderReadinessMs: firstVisibleMs,
            typingMs: typing, scrollMs: scrolling, fullRenderMs: full,
            typingP95Ms: p95(typing), scrollP95Ms: p95(scrolling), fullRenderP95Ms: p95(full),
            typingParagraphs: typingParagraphs, scrollParagraphs: scrollParagraphs,
            processLifetimePeakPhysicalBytes: processPeak())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let path = ProcessInfo.processInfo.environment["PURLORY_RENDER_REPORT_PATH"] {
            try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
        print("Synthetic render: typing p95 \(report.typingP95Ms)ms, scroll p95 \(report.scrollP95Ms)ms, full p95 \(report.fullRenderP95Ms)ms")
    }

    private func makeFixture() throws -> (body: String, assets: [String: Data]) {
        var body = "", assets: [String: Data] = [:]
        let prose = String(String(repeating: "한글🙂 이야기가 이어지는 합성 원고입니다. ", count: 5).prefix(97)) + "\n"
        for index in 0..<100 {
            body += String(repeating: prose, count: 30)
            if index % 2 == 0 {
                let reference = "images/fixture-\(index).png"
                assets[reference] = try autoreleasepool {
                    let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048,
                        pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    NSGraphicsContext.current = context
                    NSColor(deviceRed: 0.2 + CGFloat(index) / 150, green: 0.4, blue: 0.7, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 2048, height: 1024).fill()
                    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                }
                body += "![fixture \(index)](\(reference))\n"
            } else { body += "$$x_\(index)^2 + \\frac{1}{\(index + 1)}$$\n" }
        }
        precondition(body.count < 300_000)
        body += String(repeating: "가", count: 300_000 - body.count)
        return (body, assets)
    }

    private func elapsed(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    // Match the editor's existing noteKeystroke percentile convention.
    private func p95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    // Same process-lifetime physical-footprint definition as #179/PurloryBench.
    private func processPeak() -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_lifetime_max_phys_footprint : nil
    }
    private struct Report: Encodable {
        let fixtureVersion: Int
        let bodySHA256: String
        let assetSHA256: [String: String]
        let characters: Int, sourceUTF16: Int, paragraphs: Int, imageCount: Int, mathCount: Int
        let imagePixels: [Int]
        let os: String
        let physicalMemoryBytes: UInt64
        let loadMs: Double, firstVisibleRenderReadinessMs: Double
        let typingMs: [Double], scrollMs: [Double], fullRenderMs: [Double]
        let typingP95Ms: Double, scrollP95Ms: Double, fullRenderP95Ms: Double
        let typingParagraphs: [Int], scrollParagraphs: [Int]
        let processLifetimePeakPhysicalBytes: UInt64?
    }
}
