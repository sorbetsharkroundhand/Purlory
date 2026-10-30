@testable import PurloryIntelligence
@testable import PurloryDocumentEngine
import AppKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

enum ComplexMathFixture {
    // Exact pasted source, including the line-end control spaces and repeated row breaks.
    static let pasted = #"""
    \begin{aligned}\
    \nabla \times \mathbf{B} - \frac{1}{c} \frac{\partial \mathbf{E}}{\partial t} &= \frac{4\pi}{c}\mathbf{J} \\\\\
    \mathbf{H} &= \begin{pmatrix} \
    \frac{\partial^2 f}{\partial x_1^2} & \frac{\partial^2 f}{\partial x_1 \partial x_2} & \cdots & \frac{\partial^2 f}{\partial x_1 \partial x_n} \\\\\
    \frac{\partial^2 f}{\partial x_2 \partial x_1} & \frac{\partial^2 f}{\partial x_2^2} & \cdots & \frac{\partial^2 f}{\partial x_2 \partial x_n} \\\\\
    \vdots & \vdots & \ddots & \vdots \\\\\
    \frac{\partial^2 f}{\partial x_n \partial x_1} & \frac{\partial^2 f}{\partial x_n \partial x_2} & \cdots & \frac{\partial^2 f}{\partial x_n^2}\
    \end{pmatrix}\
    \end{aligned}
    """#

    static let canonical = #"""
    \begin{aligned}
    \nabla \times \mathbf{B} - \frac{1}{c} \frac{\partial \mathbf{E}}{\partial t} &= \frac{4\pi}{c}\mathbf{J} \\
    \mathbf{H} &= \begin{pmatrix}
    \frac{\partial^2 f}{\partial x_1^2} & \frac{\partial^2 f}{\partial x_1 \partial x_2} & \cdots & \frac{\partial^2 f}{\partial x_1 \partial x_n} \\
    \frac{\partial^2 f}{\partial x_2 \partial x_1} & \frac{\partial^2 f}{\partial x_2^2} & \cdots & \frac{\partial^2 f}{\partial x_2 \partial x_n} \\
    \vdots & \vdots & \ddots & \vdots \\
    \frac{\partial^2 f}{\partial x_n \partial x_1} & \frac{\partial^2 f}{\partial x_n \partial x_2} & \cdots & \frac{\partial^2 f}{\partial x_n^2}
    \end{pmatrix}
    \end{aligned}
    """#
}

@MainActor final class ComplexMathRenderingTests: XCTestCase {
    func testEmptyMathDoesNotBecomeABlankImageWhenDisplayPaddingIsAdded() {
        for source in ["", "{}", " \n "] {
            XCTAssertNil(MathRenderer.image(latex: source, color: .black, fontSize: 18))
            XCTAssertNil(EpubExporter.mathPNG(source))
        }
    }

    func testEscapedPhysicalNewlinesBehaveAsControlSpacesWithoutConsumingRowBreaks() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for slashCount in 1...5 {
                let prefix = #"\begin{aligned}a &= b"# + String(repeating: "\\", count: slashCount)
                let suffix = slashCount > 1 ? #"c &= d\end{aligned}"# : #"c\end{aligned}"#
                let result = MathRenderer.render(latex: prefix + newline + suffix, color: .black, fontSize: 18)
                let explicitSpace = MathRenderer.render(
                    latex: prefix + (slashCount % 2 == 1 ? " " : "") + "\n" + suffix, color: .black, fontSize: 18)
                XCTAssertNil(result.error)
                XCTAssertEqual(try XCTUnwrap(result.image).size, try XCTUnwrap(explicitSpace.image).size)
            }
        }
        XCTAssertNotNil(MathRenderer.render(latex: "\\frac{1{\\\n", color: .black, fontSize: 18).error,
            "Line-ending adaptation must not hide malformed braces")
        XCTAssertNotNil(MathRenderer.render(latex: #"\unknowncommand"#, color: .black, fontSize: 18).error)
    }

    func testNestedAlignedMatrixRendersCanonicalAndPastedSources() throws {
        for (name, latex) in [("canonical", ComplexMathFixture.canonical), ("pasted", ComplexMathFixture.pasted)] {
            let result = MathRenderer.render(latex: latex, color: .black, fontSize: 20)
            XCTAssertNil(result.error, "\(name): \(result.error ?? "")")
            let image = try XCTUnwrap(result.image, name)
            XCTAssertGreaterThan(image.size.height, 100, "The four matrix rows must be visible")
            XCTAssertGreaterThan(image.size.width, 200)
            let raster = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            for x in 0..<raster.pixelsWide {
                XCTAssertEqual(raster.colorAt(x: x, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01,
                    "The top of a fraction must not touch the crop boundary")
                XCTAssertEqual(raster.colorAt(x: x, y: raster.pixelsHigh - 1)?.alphaComponent ?? 1, 0, accuracy: 0.01,
                    "The last matrix subscripts must not touch the crop boundary")
            }
            if let directory = ProcessInfo.processInfo.environment["PURLORY_MATH_CAPTURE_DIR"] {
                let plate = NSImage(size: image.size)
                plate.lockFocus()
                NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill()
                image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                plate.unlockFocus()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(plate.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory + "/math-\(name).png"))
            }
        }
    }
}
