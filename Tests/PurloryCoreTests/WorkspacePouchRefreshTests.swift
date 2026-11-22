import AppKit
import Combine
import QuartzCore
import SwiftUI
import XCTest
@testable import PurloryWorkspaceUI

@MainActor final class WorkspacePouchRefreshTests: XCTestCase {
    func testReattachingToTheSameWindowDoesNotBuildAnUnopenedMenu() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pouch = WorkspacePouchController(model: SpatialWorkspaceController(defaults: defaults), defaults: defaults)
        defer { pouch.detach(); window.close() }
        pouch.attach(to: window)
        var queries = 0
        var selected = false
        pouch.extraActions = [WorkspacePouchAction(id: "extra", label: "Extra", symbol: "plus",
            selected: { queries += 1; return selected }, perform: {})]
        pouch.attach(to: window)
        pouch.syncAttachment()
        XCTAssertEqual(queries, 0, "A repeated attachment should leave an unopened contextual menu alone")

        selected = true
        let item = try XCTUnwrap(pouch.moreMenu().items.first)
        XCTAssertEqual(item.state, .on)
        XCTAssertEqual(queries, 1)
    }

    func testEquivalentIndexActionsReusePresentationAndInvokeTheLatestClosure() throws {
        let view = WorkspacePouchIndexView(frame: NSRect(x: 0, y: 0, width: 84, height: 400))
        var performed: [Int] = []
        var enabled = true
        var selected = false
        func action(_ version: Int) -> WorkspacePouchAction {
            WorkspacePouchAction(id: "action", label: "Action", symbol: "plus",
                selected: { selected }, enabled: { enabled }, perform: { performed.append(version) })
        }
        view.configure(theme: .light, actions: [action(1)])
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let button = try XCTUnwrap(scroll.documentView?.subviews.compactMap { $0 as? NSButton }.first)
        view.layoutSubtreeIfNeeded()
        view.needsLayout = false
        view.configure(theme: .light, actions: [action(2)])
        XCTAssertFalse(view.needsLayout, "Replacing only a closure must not schedule native layout")
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
        XCTAssertEqual(performed, [2])

        selected = true
        enabled = false
        view.configure(theme: .light, actions: [action(3)])
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.accessibilityValue() as? NSNumber, NSNumber(value: true))
    }

    func testUnchangedIndexGeometryKeepsTheInstalledShape() throws {
        let view = WorkspacePouchIndexView(frame: NSRect(x: 0, y: 0, width: 84, height: 400))
        let geometry = WorkspacePouchIndexGeometry(window: NSRect(x: 25, y: 20, width: 800, height: 600),
            screen: NSRect(x: 0, y: 0, width: 1600, height: 1000), progress: 1, hover: 0)
        view.update(geometry: geometry, progress: 1, expanded: true)
        let silhouette = try XCTUnwrap(view.layer?.mask as? CAShapeLayer)
        let installed = try XCTUnwrap(silhouette.path)
        view.update(geometry: geometry, progress: 1, expanded: true)
        XCTAssertTrue(silhouette.path === installed, "Repeated geometry must not reconstruct the rail silhouette")
    }

    func testDocumentOutlineControllerSuppressesDuplicateUnchangedPublications() async throws {
        let controller = DocumentOutlineController(observeEnergy: false, sleep: {
            try await Task.sleep(for: .seconds(10))
        })
        defer { controller.stop() }

        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let snapshot1 = ProjectDocumentSnapshot(
            identity: .init(key: key, generation: 1),
            title: "Draft",
            body: "# One\nFirst",
            kind: .manuscript,
            mode: .general
        )
        let snapshot2 = ProjectDocumentSnapshot(
            identity: .init(key: key, generation: 2),
            title: "Draft",
            body: "# One\nFirst more",
            kind: .manuscript,
            mode: .general
        )

        var publicationCount = 0
        let cancellable = controller.objectWillChange.sink { _ in
            publicationCount += 1
        }
        defer { cancellable.cancel() }

        controller.update(snapshot1)
        XCTAssertEqual(controller.status, .checking)
        XCTAssertNil(controller.prepared)
        XCTAssertEqual(publicationCount, 1, "Initial transition to .checking should publish once")

        publicationCount = 0
        controller.update(snapshot2)
        XCTAssertEqual(controller.status, .checking)
        XCTAssertNil(controller.prepared)
        XCTAssertEqual(publicationCount, 0, "Repeated updates while already .checking with nil prepared/currentHeadingID must not republish")
    }

    func testDocumentOutlineHolderDoesNotForwardControllerPublicationsAndInitializesLazily() async throws {
        var createdControllers: [DocumentOutlineController] = []
        defer { createdControllers.forEach { $0.stop() } }

        func makeIsolatedController() -> DocumentOutlineController {
            let controller = DocumentOutlineController(observeEnergy: false, sleep: {
                try await Task.sleep(for: .seconds(10))
            })
            createdControllers.append(controller)
            return controller
        }

        let holder = DocumentOutlineHolder(controller: makeIsolatedController())
        func observeObjectWillChange<Object: ObservableObject>(
            _ object: Object,
            onChange: @escaping () -> Void
        ) -> AnyCancellable {
            object.objectWillChange.sink { _ in onChange() }
        }

        var holderPublications = 0
        let holderCancellable = observeObjectWillChange(holder) {
            holderPublications += 1
        }
        defer { holderCancellable.cancel() }

        var controllerPublications = 0
        let controllerCancellable = holder.controller.objectWillChange.sink { _ in
            controllerPublications += 1
        }
        defer { controllerCancellable.cancel() }

        let key = ProjectDocumentKey(projectID: WritingProjectID(), documentID: WritingDocumentID())
        let snapshot1 = ProjectDocumentSnapshot(
            identity: .init(key: key, generation: 1),
            title: "Draft",
            body: "# One\nFirst",
            kind: .manuscript,
            mode: .general
        )
        holder.controller.update(snapshot1)
        XCTAssertEqual(holder.controller.status, .checking)
        XCTAssertEqual(controllerPublications, 1)
        XCTAssertEqual(holderPublications, 0, "DocumentOutlineHolder must not forward controller objectWillChange publications")

        let driver = OutlineProbeDriver()
        var makeControllerCount = 0
        var observedRevisions: [Int] = []
        var observedControllerIDs: [ObjectIdentifier] = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OutlineHolderParentProbe(
            driver: driver,
            makeController: {
                makeControllerCount += 1
                return makeIsolatedController()
            },
            onEvaluate: { revision, controller in
                observedRevisions.append(revision)
                observedControllerIDs.append(ObjectIdentifier(controller))
            }
        ))
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        XCTAssertEqual(makeControllerCount, 1)
        XCTAssertEqual(observedRevisions.last, 0)

        driver.revision = 1
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        driver.revision = 2
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); await Task.yield() }

        XCTAssertEqual(makeControllerCount, 1, "StateObject holder must lazily create DocumentOutlineController only once across parent re-evaluations")
        XCTAssertTrue(observedRevisions.contains(1))
        XCTAssertEqual(observedRevisions.last, 2)
        let firstID = try XCTUnwrap(observedControllerIDs.first)
        XCTAssertTrue(observedControllerIDs.allSatisfy { $0 == firstID }, "Controller instance must stay alive across parent re-evaluations")
    }

    func testCollapsedPouchToolsDefersRootViewUpdatesUntilExpanded() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = WorkspacePouchView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let placement = try XCTUnwrap(WorkspacePouchPlacement(
            anchor: CGRect(x: 740, y: 20, width: 28, height: 28),
            visible: CGRect(x: 0, y: 0, width: 800, height: 600),
            toolHeight: 240
        ))
        view.placement = placement
        view.frame = placement.frame
        view.configure(orb: false, horizontal: false, actions: [], theme: .light, attached: true)
        window.contentView = view
        defer { window.contentView = nil; window.close() }

        var appliedVersions: [Int] = []
        view.setTools(AnyView(ToolsVersionProbe(version: 1) { appliedVersions.append($0) }))
        view.setTools(AnyView(ToolsVersionProbe(version: 2) { appliedVersions.append($0) }))
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); await Task.yield() }

        XCTAssertFalse(view.hasMountedToolsHost, "Collapsed pouch must defer mounting toolsHost until expanded")
        XCTAssertEqual(view.toolsHostUpdateCount, 0, "Collapsed pouch must not mount or update toolsHost")
        XCTAssertTrue(appliedVersions.isEmpty)

        view.toolsExpanded = true
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); await Task.yield() }

        XCTAssertTrue(view.hasMountedToolsHost)
        XCTAssertEqual(view.toolsHostUpdateCount, 1)
        XCTAssertFalse(appliedVersions.contains(1), "Stale pending tools must be coalesced before mounting")
        XCTAssertEqual(appliedVersions.last, 2, "Expanding must immediately apply the latest pending tools")

        view.toolsExpanded = false
        view.setTools(AnyView(ToolsVersionProbe(version: 3) { appliedVersions.append($0) }))
        view.setTools(AnyView(ToolsVersionProbe(version: 4) { appliedVersions.append($0) }))
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); await Task.yield() }

        XCTAssertEqual(view.toolsHostUpdateCount, 1, "Updating tools while re-collapsed must defer rootView assignment")
        XCTAssertFalse(appliedVersions.contains(3))
        XCTAssertFalse(appliedVersions.contains(4))

        view.toolsExpanded = true
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); await Task.yield() }

        XCTAssertEqual(view.toolsHostUpdateCount, 2)
        XCTAssertFalse(appliedVersions.contains(3))
        XCTAssertEqual(appliedVersions.last, 4, "Re-expanding must immediately apply the latest deferred tools")
    }

    func testConsecutiveTypingCommitsDoNotRefreshPouchOrRelayoutCanvas() async throws {
        let h = try await FramedWorkspaceHarness(mode: .general)
        defer { h.close() }
        h.fixture.session.updateSelectedDocumentBody("# Heading\nStart ")
        h.window.makeKeyAndOrderFront(nil)
        let editor = try await h.editor()
        h.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        await h.layout()

        let pouch = try XCTUnwrap(h.requests.pouch)
        let canvas = try XCTUnwrap(h.requests.spatialWorkspace?.canvas)
        pouch.syncAttachment()
        await h.layout()

        let initialRefreshCount = pouch.refreshCount
        let initialLayoutTilesCount = canvas.layoutTilesCount

        for character in ["a", "b", "c", "d", "e"] {
            h.window.testUndo.beginUndoGrouping()
            editor.insertText(character, replacementRange: editor.selectedRange())
            h.window.testUndo.endUndoGrouping()
            await h.layout()
        }
        XCTAssertEqual(pouch.refreshCount, initialRefreshCount, "Consecutive typing commits before outline settles must not refresh pouch")
        XCTAssertEqual(canvas.layoutTilesCount, initialLayoutTilesCount, "Consecutive typing commits before outline settles must not relayout canvas")

        try await Task.sleep(for: .milliseconds(450))
        await h.layout()
        XCTAssertEqual(pouch.refreshCount, initialRefreshCount, "Outline preparation completion must not refresh pouch")
        XCTAssertEqual(canvas.layoutTilesCount, initialLayoutTilesCount, "Outline preparation completion must not relayout canvas")

        for character in ["f", "g", "h", "i", "j"] {
            h.window.testUndo.beginUndoGrouping()
            editor.insertText(character, replacementRange: editor.selectedRange())
            h.window.testUndo.endUndoGrouping()
            await h.layout()
        }
        XCTAssertEqual(pouch.refreshCount, initialRefreshCount, "Consecutive typing commits after outline preparation must not refresh pouch")
        XCTAssertEqual(canvas.layoutTilesCount, initialLayoutTilesCount, "Consecutive typing commits after outline preparation must not relayout canvas")

        XCTAssertEqual(editor.string, "Heading\nStart abcdefghij")
        XCTAssertEqual(h.fixture.session.selectedDocument?.body, "# Heading\nStart abcdefghij")
    }

    func testIndexPanelStaysTopAlignedWhenParentExceedsScreenVisibleTop() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let visible = screen.visibleFrame
        let parent = FramedWorkspaceWindow(
            contentRect: NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 860, height: visible.height + 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        let index = WorkspacePouchIndexController(parent: parent)
        defer { index.detach(); parent.close() }

        let requested = NSRect(x: parent.frame.maxX - 18, y: visible.maxY + 10, width: 38, height: 94)
        XCTAssertGreaterThan(requested.maxY, visible.maxY)
        let constrained = index.panel.constrainFrameRect(requested, to: screen)
        XCTAssertEqual(constrained, requested, "IndexPanel must preserve top alignment even when parent exceeds visibleFrame.maxY")
    }
}

private struct ToolsVersionProbe: NSViewRepresentable {
    let version: Int
    let onApply: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        onApply(version)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onApply(version)
    }
}

@MainActor
private final class OutlineProbeDriver: ObservableObject {
    @Published var revision = 0
}

@MainActor
private struct OutlineHolderParentProbe: View {
    @ObservedObject var driver: OutlineProbeDriver
    let makeController: () -> DocumentOutlineController
    let onEvaluate: (Int, DocumentOutlineController) -> Void

    var body: some View {
        OutlineHolderChildProbe(
            revision: driver.revision,
            makeHolder: { DocumentOutlineHolder(controller: makeController()) },
            onEvaluate: onEvaluate
        )
    }
}

@MainActor
private struct OutlineHolderChildProbe: View {
    @StateObject private var holder: DocumentOutlineHolder
    let revision: Int
    let onEvaluate: (Int, DocumentOutlineController) -> Void

    init(
        revision: Int,
        makeHolder: @escaping () -> DocumentOutlineHolder,
        onEvaluate: @escaping (Int, DocumentOutlineController) -> Void
    ) {
        self.revision = revision
        self._holder = StateObject(wrappedValue: makeHolder())
        self.onEvaluate = onEvaluate
    }

    var body: some View {
        onEvaluate(revision, holder.controller)
        return Text("\(revision)")
            .frame(width: 40, height: 20)
    }
}
