@testable import PurloryIntelligence
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class ReleaseAccentContrastTests: XCTestCase {
    func testWritingAndFictionCommandAccentsShareOneReadableFamily() {
        XCTAssertEqual(PurloryTheme.light.blue.hexValue, 0x0F6E63)
        XCTAssertEqual(PurloryTheme.dark.blue.hexValue, 0x4CC9BD)
        for scheme in [ColorScheme.light, .dark] {
            let theme = PurloryTheme.of(scheme)
            XCTAssertEqual(theme.blue, theme.novel,
                "Writing and Fiction chrome must not use competing accent families")
            XCTAssertGreaterThanOrEqual(contrast(theme.blue, theme.editorSurface), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(theme.blue.accessibleForeground(), theme.blue), 4.5)
        }
    }

    func testCustomPaletteControlsBothCommandAccents() {
        let palette = PurloryPalette(hexes: [0xFFFFFF, 0xEEEEEE, 0xCCCCCC, 0xBB3366, 0xFFDDCC])
        for scheme in [ColorScheme.light, .dark] {
            let theme = PurloryTheme.of(scheme, palette: palette)
            XCTAssertEqual(theme.blue, theme.novel)
            XCTAssertEqual(theme.blue.usingColorSpace(.sRGB)?.hueComponent ?? -1, 0.9375, accuracy: 0.01)
        }
    }

    func testRenderedGhostHasReadableContrastInLightAndDark() throws {
        for theme in [PurloryTheme.light, .dark] {
            try assertRenderedGhostContrast(theme)
        }
    }

    func testRenderedGhostRemainsReadableWithCustomSurfaces() throws {
        let palettes = [
            PurloryPalette.lightDefault, .darkDefault,
            PurloryPalette(hexes: Array(repeating: 0xFFFFFF, count: 5)),
            PurloryPalette(hexes: Array(repeating: 0x000000, count: 5)),
            PurloryPalette(hexes: [0x777777, 0xEEEEEE, 0xCCCCCC, 0xBB3366, 0xFFDDCC]),
            PurloryPalette(hexes: [0x777777, 0xEEEEEE, 0xCCCCCC, 0x777777, 0x000000]),
            PurloryPalette(hexes: [0x757575, 0xEEEEEE, 0xCCCCCC, 0x757575, 0xFFFFFF]),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for palette in palettes {
                try assertRenderedGhostContrast(PurloryTheme.of(scheme, palette: palette))
            }
        }
    }

    func testWrappedGhostRemainsReadableOutsideTheCaretHighlight() throws {
        var themes = [PurloryTheme.light, .dark]
        for scheme in [ColorScheme.light, .dark] {
            for gray: UInt32 in [0x757575, 0x777777] {
                themes.append(PurloryTheme.of(scheme, palette: PurloryPalette(
                    hexes: [gray, gray, gray, gray, 0xFFFFFF])))
            }
        }
        for theme in themes {
            try assertRenderedGhostContrast(theme, width: 140)
        }
    }

    func testCheckedTodoMarkIsReadableOnBothReleaseAccents() throws {
        for theme in [PurloryTheme.light, .dark] {
            let storage = NSTextStorage()
            let layout = PurloryLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: 300, height: 120))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120),
                textContainer: container)
            storage.delegate = editor
            editor.palette = theme
            editor.backgroundColor = theme.editorSurface
            editor.drawsBackground = true
            editor.load(markdown: "- [x] 원고")
            let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            defer { window.contentView = nil; window.close() }
            window.makeFirstResponder(nil)
            editor.refreshActiveLineHighlight()
            let bitmap = try snapshot(editor)
            let scale = CGFloat(bitmap.pixelsWide) / editor.bounds.width
            let accent = theme.blue.usingColorSpace(.sRGB)!
            var fillPoints: [(Int, Int)] = []
            // Locate the actual filled control in the list gutter, independently
            // of the renderer's private checkbox geometry.
            for x in 0..<Int(30 * scale) {
                for y in 0..<Int(70 * scale) {
                    let pixel = try pixelColor(bitmap, x: x, y: y)
                    let delta = abs(pixel.redComponent - accent.redComponent)
                        + abs(pixel.greenComponent - accent.greenComponent)
                        + abs(pixel.blueComponent - accent.blueComponent)
                    if delta < 0.025 { fillPoints.append((x, y)) }
                }
            }
            XCTAssertGreaterThan(fillPoints.count, 40, "The checked todo fill must actually render")
            let inset = Int(4 * scale)
            let minX = try XCTUnwrap(fillPoints.map(\.0).min()) + inset
            let maxX = try XCTUnwrap(fillPoints.map(\.0).max()) - inset
            let minY = try XCTUnwrap(fillPoints.map(\.1).min()) + inset
            let maxY = try XCTUnwrap(fillPoints.map(\.1).max()) - inset
            XCTAssertLessThan(minX, maxX)
            XCTAssertLessThan(minY, maxY)
            guard minX < maxX, minY < maxY else { continue }
            var strongestMark: CGFloat = 1
            for x in minX...maxX {
                for y in minY...maxY {
                    strongestMark = max(strongestMark, contrast(try pixelColor(bitmap, x: x, y: y), accent))
                }
            }
            XCTAssertGreaterThanOrEqual(strongestMark, 3,
                "The completion mark must be distinguishable inside the accent fill")
            XCTAssertEqual(editor.serialize(), "- [x] 원고")
        }
    }

    private func assertRenderedGhostContrast(_ theme: PurloryTheme, width: CGFloat = 600,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: width, height: 220))
        editor.palette = theme
        editor.backgroundColor = theme.editorSurface
        editor.drawsBackground = true
        editor.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        editor.load(markdown: "원고")
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.refreshActiveLineHighlight()
        let caret = editor.convert(window.convertFromScreen(editor.firstRect(
            forCharacterRange: NSRange(location: 2, length: 0), actualRange: nil)), from: nil)
        XCTAssertGreaterThan(caret.height, 0, file: file, line: line)
        let before = try snapshot(editor)
        // The full-block glyph provides opaque interior pixels independent of
        // thin serif stroke smoothing; the Hangul still exercises real text drawing.
        editor.ghostText = "한글 제안 █"
        let after = try snapshot(editor)
        let scale = CGFloat(before.pixelsWide) / editor.bounds.width
        let startX = Int((caret.maxX + 3) * scale)
        var strongestContrast: CGFloat = 1
        var changedPixels = 0
        var strongestColors = ""
        for x in startX..<min(before.pixelsWide, startX + Int(150 * scale)) {
            for y in 0..<before.pixelsHigh {
                let bg = try pixelColor(before, x: x, y: y)
                let fg = try pixelColor(after, x: x, y: y)
                let delta = abs(bg.redComponent - fg.redComponent)
                    + abs(bg.greenComponent - fg.greenComponent) + abs(bg.blueComponent - fg.blueComponent)
                if delta > 0.04 {
                    changedPixels += 1
                    let ratio = contrast(fg, bg)
                    if ratio > strongestContrast {
                        strongestContrast = ratio
                        strongestColors = "foreground=\(String(fg.hexValue, radix: 16)), background=\(String(bg.hexValue, radix: 16))"
                    }
                }
            }
        }
        XCTAssertGreaterThan(changedPixels, 30, "The real Ghost renderer must paint the suggestion",
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(strongestContrast, 4.5,
            "Ghost text must be readable: \(strongestColors), surface=\(String(theme.editorSurface.hexValue, radix: 16)), suggestion=\(String(theme.ghostSuggestion.hexValue, radix: 16))",
            file: file, line: line)
        XCTAssertEqual(editor.serialize(), "원고", file: file, line: line)
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func pixelColor(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        // colorAt labels raw components as calibrated RGB even for a Display P3
        // bitmap. Honor the bitmap profile before converting to WCAG's sRGB.
        let color = NSColor(colorSpace: bitmap.colorSpace,
            components: [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent],
            count: 4)
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ c: CGFloat) -> CGFloat {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
