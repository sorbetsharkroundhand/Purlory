@testable import PurloryStorage
import Foundation
import XCTest
@testable import PurloryCore

@MainActor
final class WorkspaceShellModeTests: XCTestCase {
    func testLivingMarginShowAndHideDoNotEmitEditorFocusRequests() {
        let editorRequests = ProjectEditorRequests()
        let initialFocusRequests = editorRequests.editorFocusRequest
        var section = SidebarSection.files.rawValue

        WorkspaceToolSelection.showLivingMargin(currentSection: &section)
        XCTAssertEqual(section, SidebarSection.margin.rawValue)
        WorkspaceToolSelection.hide(currentSection: &section)

        XCTAssertEqual(section, SidebarSection.files.rawValue)
        XCTAssertEqual(editorRequests.editorFocusRequest, initialFocusRequests)
    }

    func testLivingMarginEvidenceJumpUsesProjectDocumentIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-LivingMarginJump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "Purlory.LivingMarginJump.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults)
        let document = WritingDocument(
            id: WritingDocumentID(),
            title: "Chapter",
            body: "Before. The lantern was still lit. After.",
            kind: .manuscript)
        let project = WritingProject(
            id: WritingProjectID(), title: "Novel", mode: .fiction, documents: [document])
        try await session.saveAndActivate(project)
        let anchor = EvidenceAnchor(
            documentID: document.id,
            quote: "The lantern was still lit.")

        let jump = LivingMarginWorkspaceBridge.jump(to: anchor, in: session, sequence: 7)

        XCTAssertEqual(jump?.documentID, document.id)
        XCTAssertEqual(jump?.query, "The lantern was still lit.")
        XCTAssertEqual(jump?.sequence, 7)
        XCTAssertEqual(session.selectedDocumentID, document.id)
    }

    func testLivingMarginRejectsUnknownOrStaleEvidenceWithoutMovingEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-LivingMarginStale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "Purlory.LivingMarginStale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let session = ProjectSession(store: ProjectStore(root: root), defaults: defaults)
        let document = WritingDocument(
            id: WritingDocumentID(),
            title: "Chapter",
            body: "Current manuscript text.",
            kind: .manuscript)
        let project = WritingProject(
            id: WritingProjectID(), title: "Novel", mode: .fiction, documents: [document])
        try await session.saveAndActivate(project)
        let unknown = EvidenceAnchor(
            documentID: WritingDocumentID(),
            quote: "Current manuscript text.")
        let stale = EvidenceAnchor(
            documentID: document.id,
            quote: "A vanished lantern sentence.")

        XCTAssertNil(LivingMarginWorkspaceBridge.jump(to: unknown, in: session, sequence: 1))
        XCTAssertNil(LivingMarginWorkspaceBridge.jump(to: stale, in: session, sequence: 2))
        XCTAssertEqual(session.selectedDocumentID, document.id)
    }

    func testModeOptionsMatchTheActiveProjectType() {
        XCTAssertEqual(
            WorkspaceModePresentation.options(for: .fiction),
            [
                WorkspaceModeOption(mode: .write, label: "쓰기"),
                WorkspaceModeOption(mode: .map, label: "지도"),
            ])
        XCTAssertEqual(
            WorkspaceModePresentation.options(for: .general),
            [
                WorkspaceModeOption(mode: .write, label: "쓰기"),
                WorkspaceModeOption(mode: .outline, label: "개요"),
            ])
    }

    func testReleaseToolPresentationUsesPlainWriterFacingLabels() {
        XCTAssertEqual(
            WorkspaceToolPresentation.descriptor(for: SidebarSection.margin.rawValue),
            WorkspaceToolDescriptor(
                title: "리빙 마진",
                subtitle: "원고 옆에서 확인할 제안",
                systemImage: "sparkles"))
        XCTAssertEqual(
            WorkspaceToolPresentation.descriptor(for: SidebarSection.bible.rawValue).title,
            "인물과 작품 정보")
        XCTAssertEqual(
            WorkspaceToolPresentation.descriptor(for: SidebarSection.narrative.rawValue).title,
            "작가 수정과 기록")
        XCTAssertEqual(
            WorkspaceToolPresentation.descriptor(for: SidebarSection.context.rawValue).title,
            "제안에 쓰인 내용")
    }

    func testReleaseHidesStoredEmptyMarginButPreservesExistingDataTools() {
        for section in [SidebarSection.margin.rawValue, SidebarSection.files.rawValue, "unknown"] {
            XCTAssertFalse(WorkspaceToolPresentation.isVisible(section), section)
        }
        for section in [SidebarSection.bible, .narrative, .context] {
            XCTAssertTrue(WorkspaceToolPresentation.isVisible(section.rawValue), section.rawValue)
        }
    }

    func testModelChoicesUseWriterFacingSummaries() {
        XCTAssertEqual(ModelChip.userFacingSummary(for: .purlory), "검증 대기")
        XCTAssertEqual(ModelChip.userFacingSummary(for: .basil), "검증 대기")
        XCTAssertEqual(ModelChip.userFacingSummary(for: .qwenMoE), "검증 대기")
        XCTAssertEqual(ModelChip.displayName("custom/model"), "사용자 지정 모델")
    }

    func testModeSelectionUpdatesSessionAndRestoresEditorFocus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Purlory-WorkspaceMode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "Purlory.WorkspaceShellModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let projectStore = ProjectStore(root: root.appendingPathComponent("Projects"))
        let session = ProjectSession(store: projectStore, defaults: defaults)
        let project = WritingProject(
            id: WritingProjectID(),
            title: "Novel",
            mode: .fiction,
            documents: [
                WritingDocument(
                    id: WritingDocumentID(),
                    title: "Chapter 1",
                    body: "Draft",
                    kind: .manuscript)
            ])
        try await session.saveAndActivate(project)

        var focusRequests = 0

        WorkspaceModeSelection.select(.map, session: session) {
            focusRequests += 1
        }

        XCTAssertEqual(session.workspaceMode, .map)
        XCTAssertEqual(focusRequests, 1)
    }
}
