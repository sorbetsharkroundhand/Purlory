import Foundation

enum ToolDockPosition: String, CaseIterable, Codable, Sendable {
    case automatic
    case left
    case right
    case bottom
    case floating

    var label: String {
        switch self {
        case .automatic: "자동"
        case .left: "왼쪽"
        case .right: "오른쪽"
        case .bottom: "아래"
        case .floating: "플로팅"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "rectangle.3.group"
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .floating: "macwindow.on.rectangle"
        }
    }
}

enum WorkspaceToolbarDensity: Equatable {
    case standard
    case compact
}

/// Projects stored or dragged width with resistance below the minimum, then
/// bounds it to the available allocation without changing the preference.
struct WorkspaceLayoutState {
    static let navigatorMinWidth: CGFloat = 200
    static let navigatorMaxWidth: CGFloat = 360
    static let editorMinWidth: CGFloat = 560
    static let navigatorCollapseThreshold: CGFloat = 150
    static let navigatorCollapseReleaseThreshold: CGFloat = 176

    var navigatorWidth: Double = 250

    func navigatorWidth(in availableWidth: CGFloat) -> CGFloat {
        let projected = Self.projectedNavigatorWidth(CGFloat(navigatorWidth))
        return min(
            projected,
            min(
                Self.navigatorMaxWidth,
                max(Self.navigatorMinWidth, availableWidth - Self.editorMinWidth)))
    }

    static func projectedNavigatorWidth(_ width: CGFloat) -> CGFloat {
        let preferred = width.isFinite ? width : 250
        let projected: CGFloat
        if preferred >= 0, preferred < Self.navigatorMinWidth {
            let overshoot = Self.navigatorMinWidth - preferred
            let dimension = Self.navigatorMinWidth
            let resistance: CGFloat = 0.55
            let resistedOvershoot =
                overshoot * dimension * resistance
                / (dimension + resistance * overshoot)
            projected = Self.navigatorMinWidth - resistedOvershoot
        } else {
            projected = max(preferred, Self.navigatorMinWidth)
        }
        return projected
    }

    /// Hysteresis for drag-to-collapse: arm only after a deliberate pull well past the
    /// minimum width, then require a larger reverse movement before disarming.
    static func navigatorCollapseArmed(
        projectedWidth: CGFloat,
        wasArmed: Bool
    ) -> Bool {
        if wasArmed {
            return projectedWidth < navigatorCollapseReleaseThreshold
        }
        return projectedWidth <= navigatorCollapseThreshold
    }

    static let toolWidth: CGFloat = 340
    static let bottomToolMaxHeight: CGFloat = 320
    static let floatingToolMaxHeight: CGFloat = 520

    static func toolbarDensity(forEditorWidth width: CGFloat) -> WorkspaceToolbarDensity {
        width < 840 ? .compact : .standard
    }

    /// Resolve the visible placement without mutating the persisted preference.
    /// Explicit side docks fall back to bottom when the editor's minimum width would
    /// be violated; widening the window automatically restores the saved side choice.
    static func effectiveToolDock(
        preferred: ToolDockPosition,
        availableWidth: CGFloat,
        navigatorVisible: Bool,
        navigatorWidth: CGFloat
    ) -> ToolDockPosition {
        let usedByNavigator = navigatorVisible ? navigatorWidth : 0
        let sideFits =
            availableWidth - usedByNavigator - toolWidth
                - WorkspaceLayoutPolicy.toolSeparatorWidth >= editorMinWidth

        switch preferred {
        case .automatic:
            return sideFits ? .right : .bottom
        case .left, .right:
            return sideFits ? preferred : .bottom
        case .bottom, .floating:
            return preferred
        }
    }
}

enum WorkspaceNavigatorPlacement: Equatable {
    case hidden, inline, overlay
}

struct WorkspaceResolvedLayout {
    let navigatorPlacement: WorkspaceNavigatorPlacement
    let navigatorWidth: CGFloat
    let navigatorMaximumWidth: CGFloat
    let navigatorReservation: CGFloat
    let toolDock: ToolDockPosition
    let manuscriptWidth: CGFloat
}

/// Resolves complete frame allocations without writing preferences or domain state.
enum WorkspaceLayoutPolicy {
    static let outerInset: CGFloat = 8
    static let surfaceGap: CGFloat = 8
    static let railWidth: CGFloat = 44
    static let chromeHeight: CGFloat = 36
    static let overlayThreshold: CGFloat = 1024
    static let toolSeparatorWidth: CGFloat = surfaceGap

    static func resolve(availableWidth: CGFloat, presentation: WorkspacePresentationState,
                        railWidth: CGFloat = railWidth,
                        projectedNavigatorWidth: CGFloat? = nil) -> WorkspaceResolvedLayout {
        let viewport = availableWidth.isFinite ? max(0, availableWidth) : 0
        let rail = railWidth.isFinite ? max(0, railWidth) : 0
        let base = max(0, viewport - 2 * outerInset - (rail > 0 ? rail + surfaceGap : 0))
        let canInline = viewport >= overlayThreshold
            && base >= WorkspaceLayoutState.editorMinWidth + surfaceGap + WorkspaceLayoutState.navigatorMinWidth
        let placement: WorkspaceNavigatorPlacement = !presentation.navigatorVisible
            ? .hidden : (canInline ? .inline : .overlay)
        let maximum = min(WorkspaceLayoutState.navigatorMaxWidth, max(0,
            placement == .inline ? base - surfaceGap - WorkspaceLayoutState.editorMinWidth : base))
        let savedWidth = presentation.navigatorWidth.isFinite
            ? max(WorkspaceLayoutState.navigatorMinWidth, CGFloat(presentation.navigatorWidth)) : 250
        let width = min(maximum, WorkspaceLayoutState.projectedNavigatorWidth(
            projectedNavigatorWidth ?? savedWidth))
        let reservation = placement == .inline ? width + surfaceGap : 0
        let writingWidth = max(0, base - reservation)
        let hasTool = presentation.contextVisible
        let dock = hasTool ? WorkspaceLayoutState.effectiveToolDock(preferred: presentation.toolDock,
            availableWidth: writingWidth, navigatorVisible: false, navigatorWidth: 0)
            : (presentation.toolDock == .automatic ? .right : presentation.toolDock)
        let sideWidth = hasTool && (dock == .left || dock == .right)
            ? WorkspaceLayoutState.toolWidth + toolSeparatorWidth : 0
        return WorkspaceResolvedLayout(navigatorPlacement: placement, navigatorWidth: width,
            navigatorMaximumWidth: maximum, navigatorReservation: reservation,
            toolDock: dock, manuscriptWidth: max(0, writingWidth - sideWidth))
    }
}
