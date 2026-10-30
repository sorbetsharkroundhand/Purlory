@testable import PurloryIntelligence
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor final class WorkspacePaperGrainTests: XCTestCase {
    func testGrainCoversEveryQuadrantAtStandardAndRetinaScaleAfterResize() throws {
        let view = WorkspacePaperGrain.Grain(frame: .zero)
        for scale in [1, 2] {
            for size in [CGSize(width: 320, height: 240), CGSize(width: 800, height: 500), CGSize(width: 240, height: 180)] {
                view.setFrameSize(size)
                let context = try bitmap(size: size, scale: scale)
                draw(view, in: context, dirty: view.bounds)
                let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                var means: [Double] = []
                for row in 0..<2 {
                    for column in 0..<2 {
                        var alpha = 0, covered = 0, count = 0
                        var shades: Set<UInt8> = []
                        for y in (row * context.height / 2)..<((row + 1) * context.height / 2) {
                            for x in (column * context.width / 2)..<((column + 1) * context.width / 2) {
                                let index = y * context.bytesPerRow + x * 4
                                alpha += Int(bytes[index + 3]); count += 1
                                if bytes[index + 3] > 0 { covered += 1 }
                                shades.insert(bytes[index])
                            }
                        }
                        XCTAssertGreaterThan(Double(covered) / Double(count), 0.95, "No quadrant may lose its grain at scale \(scale)")
                        XCTAssertGreaterThan(shades.count, 2, "Grain must not decode as a flat rectangle")
                        means.append(Double(alpha) / Double(count))
                    }
                }
                XCTAssertLessThan(try XCTUnwrap(means.max()) - XCTUnwrap(means.min()), 1)
            }
        }
    }

    func testPartialRedrawDoesNotStackTintOrChangeTexturePhase() throws {
        let view = WorkspacePaperGrain.Grain(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let context = try bitmap(size: view.bounds.size, scale: 2)
        draw(view, in: context, dirty: view.bounds)
        let count = context.bytesPerRow * context.height
        let before = Data(bytes: try XCTUnwrap(context.data), count: count)
        for _ in 0..<3 { draw(view, in: context, dirty: CGRect(x: 35, y: 41, width: 170, height: 121)) }
        XCTAssertEqual(Data(bytes: try XCTUnwrap(context.data), count: count), before)
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
    }

    private func bitmap(size: CGSize, scale: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width) * scale,
            height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        return context
    }

    private func draw(_ view: WorkspacePaperGrain.Grain, in context: CGContext, dirty: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(dirty)
    }
}
