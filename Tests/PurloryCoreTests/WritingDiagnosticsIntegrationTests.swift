@testable import PurloryIntelligence
@testable import PurloryStorage
import AppKit
import SwiftUI
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI
@testable import PurloryKoreanBackend

@MainActor
final class WritingDiagnosticsIntegrationTests: XCTestCase {
    func testMarginEvidenceSelectsSecondFormattedDuplicateAndCapturesExactReturn() async throws {
        try await withDiagnosticsFixture(body: "🙂 한 `됬다`. **됬다**.") { fixture in
            fixture.edit(" 끝", range: .init(location: fixture.editor.string.utf16.count, length: 0))
            try await fixture.settle()
            let findings = fixture.runtime.controller.state.findings.filter { $0.diagnostic.kind == .spelling }
                .sorted { ($0.evidence.utf16Hint ?? 0) < ($1.evidence.utf16Hint ?? 0) }
            let finding = try XCTUnwrap(findings.last)
            let body = try XCTUnwrap(fixture.session.selectedDocument?.body)
            XCTAssertEqual(finding.evidence.utf16Hint, (body as NSString).range(of: "됬다", options: .backwards).location,
                "The earlier inline-code duplicate intentionally has no correctness finding")
            let insight = try XCTUnwrap(fixture.margin.visibleInsights(for: .general).first { $0.id == "writing-quality:" + finding.id })
            let requests = ProjectEditorRequests()
            requests.nativeEditor = fixture.editor; requests.nativeEditorKey = fixture.session.runtimeIdentity?.key
            fixture.editor.setSelectedRange(NSRange(location: 3, length: 1))
            let selection = fixture.editor.selectedRange(), original = fixture.editor.serialize()
            let undo = fixture.editor.undoManager
            XCTAssertTrue(fixture.runtime.navigateMarginEvidence(insightID: insight.id, evidence: finding.evidence, requests: requests))
            XCTAssertEqual(fixture.editor.selectedRange(), (fixture.editor.string as NSString).range(of: "됬다", options: .backwards))
            let point = try XCTUnwrap(requests.sourceReturnPoint)
            XCTAssertEqual(point.selection, selection)
            XCTAssertTrue(fixture.editor.applySourceNavigation(.returnTo(point)))
            XCTAssertEqual(fixture.editor.selectedRange(), selection)
            XCTAssertTrue(fixture.editor.serialize().utf16.elementsEqual(original.utf16))
            XCTAssertTrue(fixture.editor.undoManager === undo); XCTAssertTrue(undo?.canUndo == true)
            fixture.window.testUndo.undo()
            XCTAssertFalse(fixture.session.selectedDocument?.body.hasSuffix(" 끝") == true)
        }
    }

    func testMarginRelatedEvidenceUsesItsOwnMappedOccurrence() async throws {
        try await withDiagnosticsFixture(body: "그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다. 됬다.") { fixture in
            try await fixture.settle()
            let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first { !$0.relatedEvidence.isEmpty })
            let evidence = try XCTUnwrap(finding.relatedEvidence.last)
            let requests = ProjectEditorRequests()
            requests.nativeEditor = fixture.editor; requests.nativeEditorKey = fixture.session.runtimeIdentity?.key
            XCTAssertTrue(fixture.runtime.navigateMarginEvidence(insightID: "writing-quality:" + finding.id,
                evidence: evidence, requests: requests))
            let expected = NSRange(location: try XCTUnwrap(evidence.utf16Hint), length: evidence.quote.utf16.count)
            XCTAssertEqual(fixture.editor.selectedRange(), expected)
        }
    }

    func testMarginNavigationRefusesAlteredDismissedStaleAndWrongNativeOwners() async throws {
        try await withDiagnosticsFixture { fixture in
            try await fixture.settle()
            let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first { $0.diagnostic.kind == .spelling })
            let id = "writing-quality:" + finding.id, requests = ProjectEditorRequests()
            requests.nativeEditor = fixture.editor; requests.nativeEditorKey = fixture.session.runtimeIdentity?.key
            let selection = fixture.editor.selectedRange()
            var altered = finding.evidence
            altered.quote = altered.quote.decomposedStringWithCanonicalMapping
            XCTAssertEqual(altered.quote, finding.evidence.quote)
            XCTAssertFalse(altered.quote.utf16.elementsEqual(finding.evidence.quote.utf16))
            XCTAssertFalse(fixture.runtime.navigateMarginEvidence(insightID: id, evidence: altered, requests: requests))
            altered = finding.evidence; altered.utf16Hint = Int.max
            XCTAssertFalse(fixture.runtime.navigateMarginEvidence(insightID: id, evidence: altered, requests: requests))
            fixture.margin.dismiss(id)
            XCTAssertFalse(fixture.runtime.navigateMarginEvidence(insightID: id, evidence: finding.evidence, requests: requests))
            fixture.margin.restoreDismissed()
            XCTAssertTrue(fixture.runtime.navigateMarginEvidence(insightID: id, evidence: finding.evidence, requests: requests))
            fixture.editor.setSelectedRange(selection)
            fixture.replaceFromSession("Changed " + (fixture.session.selectedDocument?.body ?? ""))
            let afterEdit = fixture.editor.selectedRange()
            XCTAssertFalse(fixture.runtime.navigateMarginEvidence(insightID: id, evidence: finding.evidence, requests: requests))
            let key = try XCTUnwrap(fixture.session.runtimeIdentity?.key)
            fixture.loadUnownedNativeSource(fixture.session.selectedDocument?.body ?? "",
                documentKey: .init(projectID: WritingProjectID(), documentID: key.documentID))
            XCTAssertFalse(fixture.runtime.navigateMarginEvidence(insightID: id, evidence: finding.evidence, requests: requests))
            XCTAssertEqual(fixture.editor.selectedRange(), afterEdit)
        }
    }

    func testMarginNavigationRefusesCompositionWithoutCommittingIt() async throws {
        try await withDiagnosticsFixture { fixture in
            try await fixture.settle()
            let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first { $0.diagnostic.kind == .spelling })
            let requests = ProjectEditorRequests()
            requests.nativeEditor = fixture.editor; requests.nativeEditorKey = fixture.session.runtimeIdentity?.key
            fixture.window.testUndo.beginUndoGrouping()
            fixture.editor.setMarkedText("한", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 0, length: 0))
            let selection = fixture.editor.selectedRange(), source = fixture.session.selectedDocument?.body
            XCTAssertFalse(fixture.runtime.navigateMarginEvidence(insightID: "writing-quality:" + finding.id,
                evidence: finding.evidence, requests: requests))
            XCTAssertTrue(fixture.editor.hasMarkedText()); XCTAssertEqual(fixture.editor.selectedRange(), selection)
            XCTAssertTrue(fixture.session.selectedDocument?.body.utf16.elementsEqual((source ?? "").utf16) == true)
            fixture.window.testUndo.endUndoGrouping()
        }
    }

    func testPreparedMarginOpenDoesNotAnalyzeOrMoveFocus() async throws {
        let gate = WritingReportNativeGate(blockFirst: false)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        try await withDiagnosticsFixture(worker: worker) { fixture in
            let responder = fixture.window.firstResponder
            let before = gate.counts.analyzed
            _ = LivingMarginView(model: fixture.margin, mode: .general, theme: .dark, onJumpToEvidence: { _, _ in }).body
            _ = WritingDiagnosticsSettingsView(session: fixture.session, runtime: fixture.runtime).body
            XCTAssertEqual(gate.counts.analyzed, before)
            XCTAssertEqual(before, 0, "Opening prepared surfaces does not admit native analysis")
            XCTAssertTrue(fixture.window.firstResponder === responder)
            try await fixture.settle()
            XCTAssertTrue(fixture.window.firstResponder === responder, "Automatic publication never moves focus")
        }
    }

    func testModelFreeFictionAndGeneralEndToEnd() async throws {
        for mode in [WritingMode.fiction, .general] {
            try await withDiagnosticsFixture(mode: mode) { fixture in
                fixture.edit(" 끝", range: .init(location: fixture.editor.string.utf16.count, length: 0))
                let original = try XCTUnwrap(fixture.session.selectedDocument?.body)
                try await fixture.settle()
                let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first { $0.diagnostic.kind == .spelling })
                let insight = try XCTUnwrap(fixture.margin.visibleInsights(for: mode).first { $0.evidence.contains(finding.evidence) })
                let action = try XCTUnwrap(insight.actions.first { $0.title.contains("됐다") })
                XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
                XCTAssertEqual(try fixture.runtime.performMarginAction(insightID: insight.id, action: action), .applied)
                let expected = original.replacingOccurrences(of: "됬다", with: "됐다")
                XCTAssertEqual(fixture.session.selectedDocument?.body, expected)
                XCTAssertEqual(fixture.editor.serialize(), expected)
                fixture.window.testUndo.undo()
                XCTAssertEqual(fixture.session.selectedDocument?.body, original)
                try await fixture.settle()
                try await fixture.session.flush()
                let reopened = ProjectSession(store: fixture.store, defaults: fixture.defaults)
                try await reopened.bootstrap()
                XCTAssertEqual(reopened.selectedDocument?.body, original)
                XCTAssertTrue(fixture.session.isEditorEditable)
            }
        }
    }

    func testDismissIntentionalDisableAndLearnAreDistinct() async throws {
        let original = "그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다. 됬다."
        for operation in ["dismiss", "intentional", "disable", "learn"] {
            try await withDiagnosticsFixture(body: original) { fixture in
                try await fixture.settle()
                let values = fixture.runtime.controller.state.findings
                let selected: WritingDiagnosticsFinding?
                if operation == "intentional" {
                    selected = values.first { $0.diagnostic.category == .style && $0.diagnostic.severity != .info }
                } else { selected = values.first { $0.diagnostic.kind == .spelling } }
                let finding = try XCTUnwrap(selected)
                let insight = try XCTUnwrap(fixture.margin.visibleInsights(for: .general).first { $0.evidence.contains(finding.evidence) })
                if operation == "dismiss" {
                    fixture.margin.dismiss(insight.id)
                    XCTAssertNil(fixture.session.activeProject?.userData[WritingStyleRepository.key])
                    XCTAssertFalse(fixture.margin.visibleInsights(for: .general).contains { $0.id == insight.id })
                } else {
                    let selectedAction: MarginAction?
                    switch operation {
                    case "intentional": selectedAction = insight.actions.first { $0.kind == .markIntentional }
                    case "disable": selectedAction = insight.actions.first { $0.title == "이 검사 끄기" }
                    default: selectedAction = insight.actions.first { $0.title.contains("기억하기") }
                    }
                    let action = try XCTUnwrap(selectedAction)
                    _ = try fixture.runtime.performMarginAction(insightID: insight.id, action: action)
                    try await fixture.settle()
                    guard case .ready(let record) = WritingStyleRepository.read(try XCTUnwrap(fixture.session.selectedDocumentSnapshot)) else {
                        return XCTFail("Writer decisions remain readable")
                    }
                    XCTAssertEqual(record.intentionalOccurrences.count, operation == "intentional" ? 1 : 0)
                    XCTAssertEqual(record.profile.ignoredRuleIDs.contains(finding.diagnostic.ruleID), operation == "disable")
                    XCTAssertEqual(record.isLearned("됬다"), operation == "learn")
                    XCTAssertFalse(record.isLearned("됬다는"), "Learning one word never becomes a prefix allow-list")
                    XCTAssertFalse(fixture.runtime.controller.state.findings.contains { $0.diagnostic.ruleID == finding.diagnostic.ruleID && $0.evidence == finding.evidence })
                    XCTAssertThrowsError(try fixture.runtime.performMarginAction(insightID: insight.id, action: action), "A previous action stamp cannot mutate current choices")
                }
                XCTAssertEqual(fixture.session.selectedDocument?.body, original)
                try await fixture.session.flush()
                let bytes = fixture.session.activeProject?.userData[WritingStyleRepository.key]
                let reopened = ProjectSession(store: fixture.store, defaults: fixture.defaults)
                try await reopened.bootstrap()
                XCTAssertEqual(reopened.activeProject?.userData[WritingStyleRepository.key], bytes)
                XCTAssertEqual(reopened.selectedDocument?.body, original)
            }
        }
    }

    func testIntentionalAfterEditUsesExplicitOwnedRevisionWithoutReloading() async throws {
        let source = "그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다."
        try await withDiagnosticsFixture(body: source) { fixture in
            fixture.edit(" 더", range: .init(location: fixture.editor.string.utf16.count, length: 0))
            let original = fixture.session.selectedDocument?.body
            try await fixture.settle()
            let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first {
                $0.diagnostic.category == .style && $0.diagnostic.severity != .info
            })
            let insight = try XCTUnwrap(fixture.margin.visibleInsights(for: .general).first { $0.evidence.contains(finding.evidence) })
            let action = try XCTUnwrap(insight.actions.first { $0.kind == .markIntentional })
            let resets = fixture.runtime.controller.projectionResetCount
            try fixture.runtime.performMarginAction(insightID: insight.id, action: action)
            try await fixture.settle()
            XCTAssertFalse(fixture.runtime.controller.state.findings.contains {
                $0.diagnostic.ruleID == finding.diagnostic.ruleID && $0.evidence == finding.evidence
            }, "Explicitly captured current source proof suppresses this occurrence after typing")
            XCTAssertEqual(fixture.runtime.controller.projectionResetCount, resets)
            XCTAssertEqual(fixture.session.selectedDocument?.body, original)
        }
    }

    func testLateBindingReconnectAndTransitionReplayOnlyVerifiedAuthority() async throws {
        let gate = WritingReportNativeGate(blockFirst: false)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        try await withDiagnosticsFixture(worker: worker, bindAfterLoad: true) { fixture in
            try await fixture.settle()
            let calls = gate.counts.analyzed
            fixture.runtime.connect(session: fixture.session, editorBridge: fixture.bridge, livingMargin: fixture.margin)
            fixture.bridge.connect(fixture.editor, currentSnapshot: { fixture.session.selectedDocumentSnapshot })
            await fixture.runtime.waitForPresentation()
            XCTAssertNil(fixture.runtime.controller.workTask, "Same-editor reconnect never restarts a completed scan")
            XCTAssertEqual(gate.counts.analyzed, calls)
            fixture.runtime.prepareForProjectTransition()
            fixture.runtime.connect(session: fixture.session, editorBridge: fixture.bridge, livingMargin: fixture.margin)
            try await fixture.settle()
            XCTAssertGreaterThan(gate.counts.analyzed, calls, "A retained verified editor can restore authority after a transition")
        }
    }

    func testUnownedNativeLoadCannotPublishOrEnableCurrentActions() async throws {
        try await withDiagnosticsFixture { fixture in
            try await fixture.settle()
            let original = try XCTUnwrap(fixture.session.selectedDocument?.body)
            let before = try XCTUnwrap(fixture.runtime.controller.state.findings.first { $0.diagnostic.kind == .spelling })
            fixture.loadUnownedNativeSource("🙂 됬다. 다른 문서에서 늦게 도착한 원고")
            await fixture.runtime.waitForPresentation()
            let identity = try XCTUnwrap(fixture.session.runtimeIdentity)
            XCTAssertFalse(fixture.runtime.controller.isNativeBound(to: identity, revision: fixture.editor.writingNativeRevision))
            XCTAssertNil(fixture.runtime.controller.currentFinding(id: before.id))
            XCTAssertTrue(fixture.margin.visibleInsights(for: .general).isEmpty)
            XCTAssertEqual(fixture.session.selectedDocument?.body, original)
            fixture.edit("!", range: .init(location: fixture.editor.string.utf16.count, length: 0), acceptingBinding: false)
            await fixture.runtime.waitForPresentation()
            XCTAssertFalse(fixture.runtime.controller.isNativeBound(to: identity, revision: fixture.editor.writingNativeRevision),
                "An ignored stale native binding cannot restore diagnostic authority")
            fixture.loadUnownedNativeSource(original)
            await fixture.runtime.waitForPresentation()
            XCTAssertTrue(fixture.runtime.controller.isNativeBound(to: identity, revision: fixture.editor.writingNativeRevision))
            XCTAssertNotNil(fixture.runtime.controller.currentFinding(id: before.id))
            XCTAssertEqual(fixture.session.selectedDocument?.body, original)
        }
    }

    func testIdenticalSourceFromAnotherNativeDocumentCannotAcquireAuthority() async throws {
        try await withDiagnosticsFixture { fixture in
            try await fixture.settle()
            let original = try XCTUnwrap(fixture.session.selectedDocument?.body)
            let identity = try XCTUnwrap(fixture.session.runtimeIdentity)
            let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first { $0.diagnostic.kind == .spelling })
            let other = ProjectDocumentKey(projectID: identity.key.projectID, documentID: WritingDocumentID())
            fixture.loadUnownedNativeSource(original, documentKey: other)
            await fixture.runtime.waitForPresentation()
            XCTAssertFalse(fixture.runtime.controller.isNativeBound(to: identity, revision: fixture.editor.writingNativeRevision))
            XCTAssertNil(fixture.runtime.controller.currentFinding(id: finding.id))
            XCTAssertTrue(fixture.margin.visibleInsights(for: .general).isEmpty)
            fixture.edit("!", range: .init(location: fixture.editor.string.utf16.count, length: 0), acceptingBinding: false)
            await fixture.runtime.waitForPresentation()
            XCTAssertFalse(fixture.runtime.controller.isNativeBound(to: identity, revision: fixture.editor.writingNativeRevision))
            XCTAssertEqual(fixture.session.selectedDocument?.body, original)
            fixture.loadUnownedNativeSource(original, documentKey: identity.key)
            await fixture.runtime.waitForPresentation()
            XCTAssertTrue(fixture.runtime.controller.isNativeBound(to: identity, revision: fixture.editor.writingNativeRevision))
            XCTAssertNotNil(fixture.runtime.controller.currentFinding(id: finding.id))
        }
    }

    func testSameEditorExternalLoadUsesNewSourceIndexAndCurrentFinding() async throws {
        try await withDiagnosticsFixture { fixture in
            try await fixture.settle()
            let newSource = "# 새 제목\n🙂 됬다.\n원문을 확인한다."
            fixture.replaceFromSession(newSource)
            try await fixture.settle()
            let finding = try XCTUnwrap(fixture.runtime.controller.state.findings.first { $0.diagnostic.kind == .spelling })
            XCTAssertEqual(finding.stamp.runtime, fixture.session.runtimeIdentity)
            XCTAssertEqual(finding.evidence.utf16Hint, (newSource as NSString).range(of: "됬다").location)
            XCTAssertEqual(fixture.editor.serialize(), newSource)
            XCTAssertEqual(fixture.session.selectedDocument?.body, newSource)
        }
    }

    func testUnavailableProfileAndBackendRemainWritable() async throws {
        for corrupt in [false, true] {
            let bytes = corrupt ? Data(#"{"version":42,"profile":{}}"#.utf8) : nil
            let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/missing-synthetic-korean-resources"))
            try await withDiagnosticsFixture(profileData: bytes, worker: worker) { fixture in
                if !corrupt { try await fixture.settle() }
                XCTAssertEqual(fixture.runtime.controller.state.availability, corrupt ? .unavailableProfile : .unavailableResource)
                fixture.edit(" 계속", range: .init(location: fixture.editor.string.utf16.count, length: 0))
                if !corrupt { try await fixture.settle() }
                XCTAssertTrue(fixture.session.isEditorEditable)
                let project = try XCTUnwrap(fixture.session.activeProject)
                XCTAssertFalse(ProjectSearch.results(query: "계속", in: project).isEmpty)
                let destination = fixture.root.appendingPathComponent("synthetic.epub")
                try await EpubExporter.exportAsync(try XCTUnwrap(fixture.session.selectedDocument),
                    assets: try XCTUnwrap(fixture.session.assetCatalog), to: destination)
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
                if corrupt {
                    XCTAssertThrowsError(try WritingStyleRepository.update(WritingStyleRecord(), in: fixture.session,
                        identity: XCTUnwrap(fixture.session.runtimeIdentity)))
                }
                try await fixture.session.flush()
                let reopened = ProjectSession(store: fixture.store, defaults: fixture.defaults)
                try await reopened.bootstrap()
                XCTAssertEqual(reopened.activeProject?.userData[WritingStyleRepository.key], bytes)
                XCTAssertEqual(reopened.selectedDocument?.body, fixture.session.selectedDocument?.body)
            }
        }
    }

    private func withDiagnosticsFixture(mode: WritingMode = .general, body: String = "🙂 됬다.\n**합성 원고**\n앞 $x$ 뒤",
                                        profileData: Data? = nil, worker: KoreanNativeWorker? = nil, bindAfterLoad: Bool = false,
                                        run: @MainActor (DiagnosticsIntegrationFixture) async throws -> Void) async throws {
        let fixture = try await DiagnosticsIntegrationFixture(mode: mode, body: body, profileData: profileData, worker: worker, bindAfterLoad: bindAfterLoad)
        do { try await run(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }
}

@MainActor
private final class DiagnosticsIntegrationFixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "purlory.writing-integration.\(UUID())"
    let store: ProjectStore
    let session: ProjectSession
    let clock = ManualDiagnosticsClock()
    let runtime: WritingDiagnosticsRuntime
    let bridge = ProjectEditorBridge()
    let margin = LivingMarginModel()
    let window = LegacyUndoWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    let editor: BlockTextView
    private var coordinator: PurloryBlockEditor.Coordinator!
    private var acceptsBinding = true

    init(mode: WritingMode, body: String, profileData: Data?, worker: KoreanNativeWorker?, bindAfterLoad: Bool) async throws {
        root = try temporaryProjectRoot(); defaults = UserDefaults(suiteName: suite)!
        store = ProjectStore(root: root)
        session = ProjectSession(store: store, defaults: defaults, autosaveDelay: .seconds(3600))
        var project = projectFixture(); project.mode = mode; project.documents[0].body = body
        if let profileData { project.userData[WritingStyleRepository.key] = profileData }
        try await session.saveAndActivate(project)
        runtime = WritingDiagnosticsRuntime(worker: worker ?? KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL),
            observeEnergy: false, clock: clock)
        let storage = NSTextStorage(), layout = PurloryLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .init(width: 650, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        editor = BlockTextView(frame: .init(x: 0, y: 0, width: 650, height: 450), textContainer: container)
        storage.delegate = editor; editor.allowsUndo = true
        window.isReleasedWhenClosed = false; window.testUndo.groupsByEvent = false; window.contentView = editor
        let binding = Binding<String>(get: { [unowned self] in session.selectedDocument?.body ?? "" }, set: { [unowned self] in if acceptsBinding { session.updateSelectedDocumentBody($0) } })
        let key = try XCTUnwrap(session.runtimeIdentity?.key)
        coordinator = PurloryBlockEditor(text: binding, documentIdentity: .project(key)).makeCoordinator()
        editor.delegate = coordinator
        session.documentDidChange = { [weak bridge] in bridge?.noteSnapshot($0) }
        if !bindAfterLoad { runtime.connect(session: session, editorBridge: bridge, livingMargin: margin) }
        bridge.connect(editor, currentSnapshot: { [weak session] in session?.selectedDocumentSnapshot })
        window.testUndo.beginUndoGrouping()
        editor.load(markdown: body)
        coordinator.lastSyncedText = body; coordinator.loadedDocumentIdentity = .project(key); coordinator.attach(to: editor)
        window.testUndo.endUndoGrouping(); window.testUndo.removeAllActions(); window.makeFirstResponder(editor)
        if bindAfterLoad { runtime.connect(session: session, editorBridge: bridge, livingMargin: margin) }
    }
    func replaceFromSession(_ body: String) {
        session.updateSelectedDocumentBody(body)
        coordinator.isDocumentTransitioning = true
        editor.load(markdown: body); coordinator.lastSyncedText = body
        coordinator.isDocumentTransitioning = false
    }
    func settle() async throws {
        _ = try XCTUnwrap(runtime.controller.workTask, "Verified initial/post-binding authority must schedule work")
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350))
        await runtime.controller.waitForCurrentWork(); await runtime.waitForPresentation()
    }
    func edit(_ value: String, range: NSRange, acceptingBinding: Bool = true) {
        acceptsBinding = acceptingBinding
        window.testUndo.beginUndoGrouping(); editor.insertText(value, replacementRange: range); window.testUndo.endUndoGrouping()
        acceptsBinding = true
    }
    func loadUnownedNativeSource(_ body: String, documentKey: ProjectDocumentKey? = nil) {
        if let documentKey {
            let binding = Binding<String>(get: { [unowned self] in session.selectedDocument?.body ?? "" },
                set: { [unowned self] in if acceptsBinding { session.updateSelectedDocumentBody($0) } })
            coordinator.parent = PurloryBlockEditor(text: binding, documentIdentity: .project(documentKey))
            coordinator.loadedDocumentIdentity = .project(documentKey)
            coordinator.attach(to: editor)
        }
        coordinator.isDocumentTransitioning = true
        editor.load(markdown: body); coordinator.lastSyncedText = body
        coordinator.isDocumentTransitioning = false
    }
    func close() async {
        await runtime.prepareForTermination(); bridge.disconnect(editor)
        session.documentDidChange = nil
        try? await session.flush()
        while window.testUndo.groupingLevel > 0 { window.testUndo.endUndoGrouping() }
        window.testUndo.removeAllActions(); window.testUndo.disableUndoRegistration(); window.contentView = nil; window.close()
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
    }
}
