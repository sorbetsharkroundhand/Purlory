@testable import PurloryIntelligence
import XCTest

@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// 의미 텍스트 토큰의 WCAG 대비 검증 (이슈 #29 / #65 Phase 5).
///
/// 계약:
/// - ink·ink2·ink3는 **의미 정보용** — 실제 합성 배경 위에서 4.5:1 이상.
/// - ghost·sep 등은 장식 전용 — 대비 하한을 적용하지 않는 대신 의미 텍스트에
///   쓰지 않는다는 것이 토큰 계약(Theme.swift 주석).
@MainActor
final class ContrastTests: XCTestCase {

    /// sRGB 상대 휘도 (WCAG 정의).
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private let lightSurface: UInt32 = 0xFFFFFF
    /// 다크 유리 합성 배경 근사 — glassWin(rgb 20,20,22 α.55)이 창 어두운 바탕에
    /// 얹힌 결과. 실제 시각 확인 없이도 수치 회귀를 잡는 그물 역할이 목적이다.
    private let darkSurface: UInt32 = 0x1B1B1E

    func test라이트테마_의미텍스트는45대1이상이다() {
        assertMeaningfulTextContrast(.light)
    }

    func test다크테마_의미텍스트는45대1이상이다() {
        assertMeaningfulTextContrast(.dark)
    }

    private func assertMeaningfulTextContrast(_ theme: PurloryTheme) {
        for surface in [theme.editorSurface, theme.cardSurface, theme.workspaceSurface] {
            for (name, color) in [("ink", theme.ink), ("ink2", theme.ink2), ("ink3", theme.ink3)] {
                XCTAssertGreaterThanOrEqual(ratio(color.hexValue, surface.hexValue), 4.5, name)
            }
        }
    }

    func test위험상태색은비텍스트최소31을넘는다() {
        // danger·warning은 상태 점·아이콘(비텍스트) 3:1 기준 적용 (#29).
        XCTAssertGreaterThanOrEqual(ratio(0xD93025, lightSurface), 3.0)
        XCTAssertGreaterThanOrEqual(ratio(0xFF453A, darkSurface), 3.0)
        XCTAssertGreaterThanOrEqual(ratio(0xC77800, lightSurface), 3.0)
        XCTAssertGreaterThanOrEqual(ratio(0xFF9F0A, darkSurface), 3.0)
    }
}
