@testable import PurloryIntelligence
import AppKit
import SwiftUI
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 색상 팔레트 — 저장 왕복과 **대비 보장**.
///
/// 대비 테스트가 핵심이다: 팔레트는 사용자가 아무 색이나 고를 수 있고 기본
/// 팔레트조차 라이트는 전부 밝고 다크는 전부 어둡다. 액센트가 배경에 묻히면
/// 화면의 글자·아이콘이 사라지므로, 파생 규칙이 그걸 막는지 확인한다.
final class PaletteTests: XCTestCase {

    // MARK: - 기본 액센트 (팔레트를 켜지 않아도 적용되는 색)

    /// The approved dark accent remains unchanged on the default dark surface.
    func test_다크_기본_액센트는_지정색_그대로다() {
        XCTAssertEqual(PurloryTheme.dark.novel.hexValue, PurloryTheme.accentSeed)
    }

    /// 라이트 모드는 같은 색상(hue)에서 명도만 낮춘 값 — 흰 배경 대비 확보.
    func test_라이트_기본_액센트는_색상을_지키며_읽힌다() {
        let seed = NSColor(hex: PurloryTheme.accentSeed).usingColorSpace(.sRGB)!
        let accent = PurloryTheme.light.novel.usingColorSpace(.sRGB)!

        XCTAssertEqual(
            accent.hueComponent, seed.hueComponent, accuracy: 0.02,
            "라이트 액센트가 지정색의 색상을 잃었다")
        XCTAssertLessThan(
            accent.brightnessComponent, seed.brightnessComponent,
            "흰 배경 대비를 위해 어두워져야 한다")
        XCTAssertGreaterThanOrEqual(
            PurloryTheme.light.novel.contrastRatio(against: .white), 4.5,
            "라이트 기본 액센트가 흰 배경에서 안 읽힌다")
    }

    /// 원색 그대로 썼다면 읽히지 않았을 것 — 파생이 실제로 일을 하는지 확인.
    func test_지정색을_그대로_썼다면_라이트에서_안보였다() {
        let raw = NSColor(hex: PurloryTheme.accentSeed).contrastRatio(against: .white)
        XCTAssertLessThan(raw, 4.5, "The unadjusted dark accent must not be used as small text on paper")
    }

    // MARK: - 기본값

    func test_기본_팔레트는_지정된_다섯색이다() {
        XCTAssertEqual(
            PurloryPalette.lightDefault.hexes,
            [0xFFEC87, 0xE8E164, 0xE9FF7A, 0xB2EB7F, 0x9FFF92])
        XCTAssertEqual(
            PurloryPalette.darkDefault.hexes,
            [0x618C03, 0x4F7302, 0x465902, 0x252601, 0x402929])
    }

    /// 저장값이 짧거나 길어도 슬롯 수가 맞춰진다 — 구 버전·손상된 값 방어.
    func test_슬롯수가_어긋난_입력을_보정한다() {
        XCTAssertEqual(PurloryPalette(hexes: [0x111111]).hexes.count, PurloryPalette.slotCount)
        XCTAssertEqual(
            PurloryPalette(hexes: Array(repeating: 0x222222, count: 9)).hexes.count,
            PurloryPalette.slotCount)
    }

    // MARK: - hex 왕복

    func test_색_왕복() {
        for hex in [0xFFEC87, 0x618C03, 0x000000, 0xFFFFFF, 0x402929] {
            let color = NSColor(hex: UInt32(hex))
            XCTAssertEqual(color.hexValue, UInt32(hex), "0x\(String(hex, radix: 16)) 왕복 실패")
        }
    }

    // MARK: - 대비 보장 (이 기능의 핵심 계약)

    /// 라이트 기본 팔레트는 다섯 색이 전부 밝다 — 그대로 쓰면 글자가 안 보인다.
    /// 파생된 액센트는 흰 배경에서 읽혀야 한다.
    func test_라이트_액센트는_흰배경에서_읽힌다() {
        let theme = PurloryTheme.of(.light, palette: .lightDefault)
        let ratio = theme.novel.contrastRatio(against: .white)
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "라이트 액센트 대비 \(String(format: "%.2f", ratio)) — 흰 배경에서 안 읽힌다")
    }

    /// 다크 기본 팔레트는 전부 어둡다 — 액센트는 밝혀져야 한다.
    func test_다크_액센트는_어두운배경에서_읽힌다() {
        let theme = PurloryTheme.of(.dark, palette: .darkDefault)
        let ratio = theme.novel.contrastRatio(against: NSColor(hex: 0x141416))
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "다크 액센트 대비 \(String(format: "%.2f", ratio)) — 어두운 배경에서 안 읽힌다")
    }

    /// 극단적인 사용자 선택(순백/순흑만 고름)에서도 액센트가 배경에 묻히지 않는다.
    func test_극단적인_사용자_팔레트에서도_액센트가_살아남는다() {
        let allWhite = PurloryPalette(hexes: Array(repeating: 0xFFFFFF, count: 5))
        let lightRatio = PurloryTheme.of(.light, palette: allWhite)
            .novel.contrastRatio(against: .white)
        XCTAssertGreaterThanOrEqual(lightRatio, 4.5, "전부 흰색을 골라도 액센트는 읽혀야 한다")

        let allBlack = PurloryPalette(hexes: Array(repeating: 0x000000, count: 5))
        let darkRatio = PurloryTheme.of(.dark, palette: allBlack)
            .novel.contrastRatio(against: NSColor(hex: 0x141416))
        XCTAssertGreaterThanOrEqual(darkRatio, 4.5, "전부 검정을 골라도 액센트는 읽혀야 한다")
    }

    /// 액센트는 팔레트의 **색상(hue)을 물려받는다** — 명도만 옮긴다.
    /// 이게 깨지면 "팔레트를 바꿨는데 액센트 색감이 그대로"가 된다.
    func test_액센트는_팔레트의_색상을_물려받는다() {
        // 뚜렷한 색상 셋 — 빨강·초록·파랑.
        for hex: UInt32 in [0xFF0000, 0x00FF00, 0x0000FF] {
            let palette = PurloryPalette(hexes: Array(repeating: hex, count: 5))
            let accent = PurloryTheme.of(.light, palette: palette).novel
            let source = NSColor(hex: hex).usingColorSpace(.sRGB)!
            let derived = accent.usingColorSpace(.sRGB)!
            XCTAssertEqual(
                derived.hueComponent, source.hueComponent, accuracy: 0.02,
                "0x\(String(hex, radix: 16))의 색상이 파생 과정에서 바뀌었다")
        }
    }

    // MARK: - 옵트인 (기본은 꺼짐)

    /// 팔레트를 켜지 않으면 표면색이 기본 테마 그대로여야 한다 —
    /// 켜지 않은 사용자의 화면이 바뀌면 안 된다.
    @MainActor
    func test_팔레트가_꺼져_있으면_기본_테마다() {
        let settings = PaletteSettings.shared
        let wasEnabled = settings.enabled
        defer { settings.enabled = wasEnabled }

        settings.enabled = false
        for scheme in [ColorScheme.light, .dark] {
            let theme = settings.theme(for: scheme)
            let base = PurloryTheme.of(scheme)
            XCTAssertEqual(theme.glassWin, base.glassWin)
            XCTAssertEqual(theme.toolbar, base.toolbar)
            XCTAssertEqual(theme.sidebarTint, base.sidebarTint)
            XCTAssertEqual(theme.novel, base.novel)
        }

        // 켜면 표면이 팔레트로 바뀐다.
        settings.enabled = true
        XCTAssertNotEqual(
            settings.theme(for: .light).glassWin, PurloryTheme.light.glassWin,
            "켰는데도 표면색이 그대로다")
    }

    // MARK: - 글자색 불변 (팔레트는 배경·표면에만)

    /// 팔레트를 아무리 바꿔도 본문 글자색은 그대로다 — 가독성을 팔레트에
    /// 맡기지 않는다는 것이 이 기능의 설계 전제다.
    func test_팔레트가_본문_글자색을_바꾸지_않는다() {
        let base = PurloryTheme.light
        for palette in [PurloryPalette.lightDefault,
                        PurloryPalette(hexes: Array(repeating: 0x123456, count: 5))]
        {
            let tinted = PurloryTheme.of(.light, palette: palette)
            XCTAssertEqual(tinted.ink, base.ink)
            XCTAssertEqual(tinted.ink2, base.ink2)
            XCTAssertEqual(tinted.ink3, base.ink3)
            XCTAssertEqual(tinted.ghost, base.ghost)
        }
    }
}
