import AppKit
import CoreText
import SwiftUI

public enum PurloryFonts {
    // Core Text descriptors are immutable; this wrapper only shares the cached descriptor.
    private struct BundledFont: @unchecked Sendable {
        let descriptor: CTFontDescriptor
    }

    package static func bodyFontURL(in mainBundle: Bundle) -> URL? {
        fontURL("NotoSerifKR[wght]", in: mainBundle)
    }

    package static func uiFontURL(in mainBundle: Bundle) -> URL? {
        fontURL("PretendardVariable", in: mainBundle)
    }

    private static func fontURL(_ name: String, in mainBundle: Bundle) -> URL? {
        // CLI SwiftPM accessors look beside the executable, while a macOS app
        // stores package bundles inside Contents/Resources. Do not fall back to
        // the accessor's absolute developer build path in a packaged app.
        let resources: Bundle
        if mainBundle.bundleURL.pathExtension == "app" {
            guard let url = mainBundle.url(forResource: "Purlory_PurloryDocumentEngine", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else { return nil }
            resources = bundle
        } else {
            resources = .module
        }
        guard let url = resources.url(forResource: name, withExtension: "ttf"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    // Resolve once, before selecting the family. No font file reads occur during typing.
    // Process registration leaves the user's system fonts untouched. The file descriptor
    // also makes AppKit use our audited copy when another Noto version is installed.
    private static let bundledBodyFont = bundledFont(at: bodyFontURL(in: .main))
    private static let bundledUIFont = bundledFont(at: uiFontURL(in: .main))
    private static let bundledMonoFont = bundledFont(at: fontURL("JetBrainsMono[wght]", in: .main))

    private static func bundledFont(at url: URL?) -> BundledFont? {
        guard let url,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return BundledFont(descriptor: descriptor)
    }

    /// Keep Korean coverage if a damaged developer bundle cannot load its font.
    package static let serifFamily: String? = bundledBodyFont.flatMap {
        CTFontDescriptorCopyAttribute($0.descriptor, kCTFontFamilyNameAttribute) as? String
    } ?? [
        "Nanum Myeongjo", "AppleMyungjo",
    ].first { NSFontManager.shared.availableFontFamilies.contains($0) }

    /// Prefer the audited UI font; retain Korean coverage for damaged developer bundles.
    package static let uiFamily: String? = bundledUIFont.flatMap {
        CTFontDescriptorCopyAttribute($0.descriptor, kCTFontFamilyNameAttribute) as? String
    } ?? "Apple SD Gothic Neo"

    /// 본문 세리프 (AppKit).
    public static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let base = bundledBodyFont {
            let value: CGFloat = switch weight {
            case .ultraLight, .thin: 200
            case .light: 300
            case .regular: 400
            case .medium: 500
            case .semibold: 600
            case .bold: 700
            case .heavy: 800
            case .black: 900
            default: 400
            }
            let descriptor = CTFontDescriptorCreateCopyWithVariation(
                base.descriptor, NSNumber(value: 0x77676874), value)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        if let family = serifFamily,
            let font = NSFontManager.shared.font(
                withFamily: family, traits: [], weight: Self.fontManagerWeight(weight),
                size: size)
        {
            return font
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// UI sans serif from the audited bundled descriptor (AppKit).
    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let base = bundledUIFont {
            let value: CGFloat = switch weight {
            case .ultraLight: 100
            case .thin: 200
            case .light: 300
            case .regular: 400
            case .medium: 500
            case .semibold: 600
            case .bold: 700
            case .heavy: 800
            case .black: 900
            default: 400
            }
            let descriptor = CTFontDescriptorCreateCopyWithVariation(
                base.descriptor, NSNumber(value: 0x77676874), value)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        if let family = uiFamily,
            let font = NSFontManager.shared.font(
                withFamily: family, traits: [], weight: Self.fontManagerWeight(weight),
                size: size)
        {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Descriptor-backed SwiftUI font. Use `purlorySerifFont` on views for relative scaling.
    public static func serifUI(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(serif(size, weight: appKitWeight(weight)))
    }

    private static func appKitWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    /// Descriptor-backed SwiftUI font. Use `purloryUIFont` on views for relative scaling.
    public static func uiFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(ui(size, weight: appKitWeight(weight)))
    }

    /// 모노 (상태·칩·kbd) — Dynamic Type 연동 (#31).
    public static func monoUI(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(mono(size, weight: appKitWeight(weight)))
    }

    public static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let base = bundledMonoFont else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let value: CGFloat = weight == .bold ? 700 : (weight == .semibold ? 600 : (weight == .medium ? 500 : 400))
        let descriptor = CTFontDescriptorCreateCopyWithVariation(base.descriptor, NSNumber(value: 0x77676874), value)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    /// pt → 가장 가까운 SwiftUI 텍스트 스타일 — relativeTo의 기준 (#31).
    package nonisolated static func nearestTextStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<10.5: .caption2
        case ..<12.5: .caption
        case ..<14: .footnote
        case ..<16: .subheadline
        case ..<19: .body
        case ..<21: .title3
        case ..<23: .title2
        default: .title
        }
    }

    /// NSFontManager 가중치(0-15)로 변환.
    private static func fontManagerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight: 1
        case .thin: 2
        case .light: 3
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 10
        case .black: 11
        default: 5
        }
    }
}

