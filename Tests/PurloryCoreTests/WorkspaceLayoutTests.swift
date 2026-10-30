@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class WorkspaceLayoutTests: XCTestCase {
    func testExplicitMarginUsesExistingDockAndKeepsStoredEmptyChoiceQuiet() {
        for (navigator, boundary) in [(true, CGFloat(1234)), (false, CGFloat(976))] {
            let closed = WorkspacePresentationState(navigatorVisible: navigator, navigatorWidth: 250,
                rawToolSection: "margin", rawToolDock: "right", chromeHidden: false)
            var opened = closed; opened.marginVisible = true
            XCTAssertFalse(closed.contextVisible); XCTAssertTrue(opened.contextVisible)
            XCTAssertEqual(opened.rawToolSection, closed.rawToolSection)
            XCTAssertEqual(opened.rawToolDock, closed.rawToolDock)
            let narrow = WorkspaceLayoutPolicy.resolve(availableWidth: boundary - 1, presentation: opened)
            let wide = WorkspaceLayoutPolicy.resolve(availableWidth: boundary, presentation: opened)
            XCTAssertEqual(narrow.toolDock, .bottom)
            XCTAssertEqual(wide.toolDock, .right); XCTAssertEqual(wide.manuscriptWidth, 560)
            XCTAssertEqual(WorkspaceLayoutPolicy.resolve(availableWidth: boundary, presentation: closed).manuscriptWidth, 908)
        }
    }

    func testOutlineReservesExistingDockWithoutOverwritingStoredTool() {
        for section in ["files", "bible", "margin", "unknown"] {
            for (visible, boundary) in [(true, CGFloat(1234)), (false, CGFloat(976))] {
                let state = WorkspacePresentationState(navigatorVisible: visible, navigatorWidth: 250,
                    rawToolSection: section, rawToolDock: "right", chromeHidden: false, outlineVisible: true)
                XCTAssertTrue(state.contextVisible)
                XCTAssertEqual(state.rawToolSection, section)
                let narrow = WorkspaceLayoutPolicy.resolve(availableWidth: boundary - 1, presentation: state)
                let wide = WorkspaceLayoutPolicy.resolve(availableWidth: boundary, presentation: state)
                XCTAssertEqual(narrow.toolDock, .bottom)
                XCTAssertEqual(wide.toolDock, .right); XCTAssertEqual(wide.manuscriptWidth, 560)
            }
        }
    }

    func testSideFitIncludesRenderedDivider() {
        for dock in [ToolDockPosition.automatic, .left, .right] {
            for (visible, boundary) in [(true, CGFloat(1158)), (false, CGFloat(908))] {
                XCTAssertEqual(WorkspaceLayoutState.effectiveToolDock(preferred: dock,
                    availableWidth: boundary - 1, navigatorVisible: visible, navigatorWidth: 250), .bottom)
                XCTAssertEqual(WorkspaceLayoutState.effectiveToolDock(preferred: dock,
                    availableWidth: boundary, navigatorVisible: visible, navigatorWidth: 250),
                    dock == .automatic ? .right : dock)
            }
        }
    }

    func testFramedNavigatorWidthMatrix() {
        let cases: [(CGFloat, WorkspaceNavigatorPlacement, CGFloat, CGFloat)] = [
            (860, .overlay, 0, 792), (1023, .overlay, 0, 955),
            (1024, .inline, 258, 698), (1180, .inline, 258, 854), (1440, .inline, 258, 1114),
        ]
        for (width, placement, reservation, manuscript) in cases {
            let layout = WorkspaceLayoutPolicy.resolve(availableWidth: width, presentation: presentation())
            XCTAssertEqual(layout.navigatorPlacement, placement)
            XCTAssertEqual(layout.navigatorWidth, 250)
            XCTAssertEqual(layout.navigatorReservation, reservation)
            XCTAssertEqual(layout.manuscriptWidth, manuscript)
        }
    }

    func testFramedSideFitUsesAllAllocatedGeometry() {
        for dock in [ToolDockPosition.automatic, .left, .right] {
            for (visible, boundary) in [(true, CGFloat(1234)), (false, CGFloat(976))] {
                let state = presentation(visible: visible, section: "bible", dock: dock.rawValue)
                let narrow = WorkspaceLayoutPolicy.resolve(availableWidth: boundary - 1, presentation: state)
                let wide = WorkspaceLayoutPolicy.resolve(availableWidth: boundary, presentation: state)
                XCTAssertEqual(narrow.toolDock, .bottom)
                XCTAssertEqual(wide.toolDock, dock == .automatic ? .right : dock)
                XCTAssertEqual(wide.manuscriptWidth, 560)
                XCTAssertEqual(state.rawToolDock, dock.rawValue)
            }
            // Below the overlay threshold, showing the navigator does not reserve width.
            let state = presentation(section: "bible", dock: dock.rawValue)
            XCTAssertEqual(WorkspaceLayoutPolicy.resolve(availableWidth: 975, presentation: state).toolDock, .bottom)
            let fit = WorkspaceLayoutPolicy.resolve(availableWidth: 976, presentation: state)
            XCTAssertEqual(fit.navigatorPlacement, .overlay)
            XCTAssertEqual(fit.toolDock, dock == .automatic ? .right : dock)
            XCTAssertEqual(fit.manuscriptWidth, 560)
        }
        for dock in [ToolDockPosition.bottom, .floating] {
            let state = presentation(section: "bible", dock: dock.rawValue)
            for width: CGFloat in [860, 1440] {
                XCTAssertEqual(WorkspaceLayoutPolicy.resolve(availableWidth: width, presentation: state).toolDock, dock)
            }
        }
        for section in ["files", "unknown", "margin"] {
            let layout = WorkspaceLayoutPolicy.resolve(availableWidth: 1440,
                presentation: presentation(section: section, dock: "left"))
            XCTAssertEqual(layout.manuscriptWidth, 1114)
        }
    }

    func testProjectionKeepsResistanceAndSafeWidths() {
        for (saved, expected) in [(-10.0, CGFloat(200)), (0, 200), (175, 200),
                                  (.infinity, 250), (.nan, 250), (999, 360)] {
            let state = presentation(width: saved)
            let layout = WorkspaceLayoutPolicy.resolve(availableWidth: 1180, presentation: state)
            XCTAssertEqual(layout.navigatorWidth, expected)
            if saved.isNaN { XCTAssertTrue(state.navigatorWidth.isNaN) }
            else { XCTAssertEqual(state.navigatorWidth, saved) }
        }
        for drag: CGFloat in [175, 150] {
            let layout = WorkspaceLayoutPolicy.resolve(availableWidth: 1180,
                presentation: presentation(), projectedNavigatorWidth: drag)
            XCTAssertGreaterThan(layout.navigatorWidth, drag)
            XCTAssertLessThan(layout.navigatorWidth, 200)
        }
        for viewport: CGFloat in [0, -10, .infinity, .nan] {
            let layout = WorkspaceLayoutPolicy.resolve(availableWidth: viewport,
                presentation: presentation(width: .nan, section: "bible"))
            for value in [layout.navigatorWidth, layout.navigatorMaximumWidth,
                          layout.navigatorReservation, layout.manuscriptWidth] {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
            }
        }
        let constrained = WorkspaceLayoutPolicy.resolve(availableWidth: 1024,
            presentation: presentation(width: 999))
        XCTAssertGreaterThanOrEqual(constrained.manuscriptWidth, 560)
        XCTAssertEqual(WorkspaceLayoutPolicy.resolve(availableWidth: 860,
            presentation: presentation(), railWidth: 0).manuscriptWidth, 844)
    }

    private func presentation(visible: Bool = true, width: Double = 250,
                              section: String = "files", dock: String = "automatic") -> WorkspacePresentationState {
        WorkspacePresentationState(navigatorVisible: visible, navigatorWidth: width,
            rawToolSection: section, rawToolDock: dock, chromeHidden: false)
    }

    func testToolbarDensityKeepsPrimaryControlsReadableAtNarrowEditorWidths() {
        XCTAssertEqual(WorkspaceLayoutState.toolbarDensity(forEditorWidth: 560), .compact)
        XCTAssertEqual(WorkspaceLayoutState.toolbarDensity(forEditorWidth: 760), .compact)
        XCTAssertEqual(WorkspaceLayoutState.toolbarDensity(forEditorWidth: 840), .standard)
        XCTAssertEqual(WorkspaceLayoutState.toolbarDensity(forEditorWidth: 980), .standard)
    }

    func testNavigatorWidthLeavesRoomForEditorAndSurvivesCollapse() {
        let layout = WorkspaceLayoutState(navigatorWidth: 340)
        XCTAssertEqual(layout.navigatorWidth(in: 860), 300)
        XCTAssertEqual(layout.navigatorWidth(in: 1180), 340)
        XCTAssertEqual(WorkspaceLayoutState(navigatorWidth: -10).navigatorWidth(in: 1180), 200)
        XCTAssertEqual(WorkspaceLayoutState(navigatorWidth: .infinity).navigatorWidth(in: 1180), 250)
    }

    func testNavigatorCollapseUsesHysteresis() {
        XCTAssertFalse(
            WorkspaceLayoutState.navigatorCollapseArmed(
                projectedWidth: 170, wasArmed: false))
        XCTAssertTrue(
            WorkspaceLayoutState.navigatorCollapseArmed(
                projectedWidth: 150, wasArmed: false))

        // Once armed, a small reverse movement does not flicker the state off.
        XCTAssertTrue(
            WorkspaceLayoutState.navigatorCollapseArmed(
                projectedWidth: 170, wasArmed: true))
        XCTAssertFalse(
            WorkspaceLayoutState.navigatorCollapseArmed(
                projectedWidth: 176, wasArmed: true))
    }

    func testNavigatorWidthRubberBandsBelowMinimumDuringCollapseDrag() {
        let atMinimum = WorkspaceLayoutState(navigatorWidth: 200)
            .navigatorWidth(in: 1180)
        let midway = WorkspaceLayoutState(navigatorWidth: 175)
            .navigatorWidth(in: 1180)
        let atThreshold = WorkspaceLayoutState(navigatorWidth: 150)
            .navigatorWidth(in: 1180)
        let beyondThreshold = WorkspaceLayoutState(navigatorWidth: 100)
            .navigatorWidth(in: 1180)

        XCTAssertLessThan(midway, atMinimum)
        XCTAssertGreaterThan(midway, 175)
        XCTAssertLessThan(atThreshold, midway)
        XCTAssertGreaterThan(atThreshold, 150)
        XCTAssertLessThan(beyondThreshold, atThreshold)
        XCTAssertGreaterThan(beyondThreshold, 100)
    }

    func testToolDockAutomaticAndSideFallbackPreservePreferenceSemantics() {
        let navWidth: CGFloat = 250

        XCTAssertEqual(
            WorkspaceLayoutState.effectiveToolDock(
                preferred: .automatic,
                availableWidth: 1180,
                navigatorVisible: true,
                navigatorWidth: navWidth),
            .right)

        XCTAssertEqual(
            WorkspaceLayoutState.effectiveToolDock(
                preferred: .automatic,
                availableWidth: 900,
                navigatorVisible: true,
                navigatorWidth: navWidth),
            .bottom)

        // A narrow-window fallback is computed only; the caller's persisted .left
        // preference is not mutated and will become effective again when width returns.
        XCTAssertEqual(
            WorkspaceLayoutState.effectiveToolDock(
                preferred: .left,
                availableWidth: 900,
                navigatorVisible: true,
                navigatorWidth: navWidth),
            .bottom)
        XCTAssertEqual(
            WorkspaceLayoutState.effectiveToolDock(
                preferred: .left,
                availableWidth: 1200,
                navigatorVisible: true,
                navigatorWidth: navWidth),
            .left)

        XCTAssertEqual(
            WorkspaceLayoutState.effectiveToolDock(
                preferred: .floating,
                availableWidth: 860,
                navigatorVisible: true,
                navigatorWidth: navWidth),
            .floating)
    }

    func testEditorialSurfaceIsOpaqueInBothAppearancesAndCustomPalettes() {
        for theme in [PurloryTheme.light, .dark, PurloryTheme.light.tinted(with: .lightDefault, dark: false),
                      PurloryTheme.dark.tinted(with: .darkDefault, dark: true)] {
            XCTAssertEqual(theme.editorSurface.alphaComponent, 1)
            XCTAssertGreaterThan(theme.activeLine.alphaComponent, 0)
        }
    }
}
