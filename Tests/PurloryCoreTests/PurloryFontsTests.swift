@testable import PurloryDocumentEngine
import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import PurloryCore

@MainActor
final class PurloryFontsTests: XCTestCase {
    func testUIFontUsesBundledPretendardRatherThanAnInstalledCopy() throws {
        for size: CGFloat in [11, 13, 20] {
            let font = PurloryFonts.ui(size)
            XCTAssertEqual(font.familyName, "Pretendard Variable")
            XCTAssertEqual(font.pointSize, size)
            let url = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
            XCTAssertTrue(url.path.contains("Purlory_PurloryDocumentEngine.bundle/"), url.path)
            XCTAssertEqual(url.lastPathComponent, "PretendardVariable.ttf")
        }
    }

    func testUIFontCoversAllModernHangulWithoutFallback() {
        let font = PurloryFonts.ui(13)
        let characters = Array(UInt16(0xAC00)...UInt16(0xD7A3))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        XCTAssertFalse(glyphs.contains(0))
    }

    func testUIFontResolvesRealVariableWeights() throws {
        for (weight, expected): (NSFont.Weight, Double) in [(.regular, 400), (.medium, 500), (.semibold, 600), (.bold, 700)] {
            let font = PurloryFonts.ui(13, weight: weight)
            let variation = try XCTUnwrap(CTFontCopyVariation(font) as? [NSNumber: NSNumber])
            let axes = try XCTUnwrap(CTFontCopyVariationAxes(font) as? [[CFString: Any]])
            let axis = try XCTUnwrap(axes.first {
                ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value == 0x77676874
            })
            let defaultValue = try XCTUnwrap(axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)
            // Core Text omits a variation when it equals the font's axis default.
            XCTAssertEqual((variation[NSNumber(value: 0x77676874)] ?? defaultValue).doubleValue,
                           expected, accuracy: 0.01)
        }
    }

    func testBodyFontUsesBundledNotoRatherThanAnInstalledCopy() throws {
        for size: CGFloat in [14, 18, 28] {
            let font = PurloryFonts.serif(size)
            XCTAssertEqual(font.familyName, "Noto Serif KR")
            XCTAssertEqual(font.pointSize, size)
            let url = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
            XCTAssertTrue(url.path.contains("Purlory_PurloryDocumentEngine.bundle/"), url.path)
            XCTAssertEqual(url.lastPathComponent, "NotoSerifKR[wght].ttf")
        }
    }

    func testBodyFontCoversAllModernHangulWithoutFallback() {
        let font = PurloryFonts.serif(18)
        let characters = Array(UInt16(0xAC00)...UInt16(0xD7A3))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        XCTAssertFalse(glyphs.contains(0))
    }

    func testBodyFontResolvesRealVariableWeights() throws {
        for (weight, expected): (NSFont.Weight, Double) in [(.regular, 400), (.medium, 500), (.bold, 700)] {
            let font = PurloryFonts.serif(18, weight: weight)
            let variation = try XCTUnwrap(CTFontCopyVariation(font) as? [NSNumber: NSNumber])
            XCTAssertEqual(try XCTUnwrap(variation[NSNumber(value: 0x77676874)]).doubleValue,
                           expected, accuracy: 0.01)
        }
    }

    func testPackagedBodyFontResolvesInsideAppResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let resources = app.appendingPathComponent("Contents/Resources/Purlory_PurloryDocumentEngine.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "invalid.purlory.font-fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let font = resources.appendingPathComponent("NotoSerifKR[wght].ttf")
        try Data("synthetic font resource".utf8).write(to: font)
        let uiFont = resources.appendingPathComponent("PretendardVariable.ttf")
        try Data("synthetic UI font resource".utf8).write(to: uiFont)
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(PurloryFonts.bodyFontURL(in: bundle), font)
        try FileManager.default.removeItem(at: font)
        XCTAssertNil(PurloryFonts.bodyFontURL(in: bundle), "An app must not read a developer checkout")
        XCTAssertEqual(PurloryFonts.uiFontURL(in: bundle), uiFont)
        try FileManager.default.removeItem(at: uiFont)
        XCTAssertNil(PurloryFonts.uiFontURL(in: bundle), "An app must not read a developer checkout")
    }

    func testInlineBoldUsesRealWeightAndPreservesMarkdown() throws {
        let storage = NSTextStorage()
        let manager = PurloryLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: 900))
        manager.addTextContainer(container)
        let editor = BlockTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900), textContainer: container)
        storage.delegate = editor
        for markdown in ["일반 **굵은 글씨**", "## **굵은 제목**"] {
            editor.load(markdown: markdown)
            let range = (editor.string as NSString).range(of: "굵은")
            let font = try XCTUnwrap(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            let variation = try XCTUnwrap(CTFontCopyVariation(font) as? [NSNumber: NSNumber])
            XCTAssertEqual(variation[NSNumber(value: 0x77676874)]?.doubleValue, 700)
            XCTAssertEqual(editor.serialize(), markdown)
        }
    }

#if compiler(>=6.2)
    func testSwiftUIUIFontUsesAuditedCopyDespiteAnotherRegisteredVersion() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("Public SwiftUI font resolution requires macOS 26")
        }
        let original = try XCTUnwrap(CTFontCopyAttribute(PurloryFonts.ui(13), kCTFontURLAttribute) as? URL)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        try FileManager.default.copyItem(at: original, to: copy)
        defer {
            CTFontManagerUnregisterFontsForURL(copy as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: copy)
        }
        CTFontManagerRegisterFontsForURL(copy as CFURL, .process, nil)
        let resolved = PurloryFonts.uiFont(13, .semibold).resolve(in: EnvironmentValues().fontResolutionContext)
        XCTAssertEqual(CTFontCopyAttribute(resolved.ctFont, kCTFontURLAttribute) as? URL, original)
        let variation = try XCTUnwrap(CTFontCopyVariation(resolved.ctFont) as? [NSNumber: NSNumber])
        XCTAssertEqual(variation[NSNumber(value: 0x77676874)]?.doubleValue, 600)
    }

    func testSwiftUISerifUsesAuditedCopyDespiteAnotherRegisteredVersion() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("Public SwiftUI font resolution requires macOS 26")
        }
        let original = try XCTUnwrap(PurloryFonts.bodyFontURL(in: .main))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        try FileManager.default.copyItem(at: original, to: copy)
        defer {
            CTFontManagerUnregisterFontsForURL(copy as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: copy)
        }
        CTFontManagerRegisterFontsForURL(copy as CFURL, .process, nil)
        let resolved = PurloryFonts.serifUI(20, .semibold).resolve(in: EnvironmentValues().fontResolutionContext)
        XCTAssertEqual(CTFontCopyAttribute(resolved.ctFont, kCTFontURLAttribute) as? URL, original)
        let variation = try XCTUnwrap(CTFontCopyVariation(resolved.ctFont) as? [NSNumber: NSNumber])
        XCTAssertEqual(variation[NSNumber(value: 0x77676874)]?.doubleValue, 600)
    }
#endif
}
