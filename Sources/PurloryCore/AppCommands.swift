import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 메뉴 막대 명령 (에디터 v3 — 상용 v1.0).
///
/// 단일 `Window` 씬에서 ⌘N은 활성 프로젝트의 새 문서를 만든다. 서식·정렬·목록 명령은
/// 리스폰더 체인(NSApp.sendAction)으로 포커스된 `BlockTextView`에 도달한다 —
/// 단축키의 단일 소스라 에디터의 performKeyEquivalent과 이중 처리되지 않는다.
/// 에디터(BlockTextView 서브트리)에 포커스가 있는가 — 서식·찾기 명령의
/// 실행 가능 판정용 (이슈 #26). 사용처는 ContentView의 에디터 체인.
struct HasPurloryEditorKey: FocusedValueKey {
    typealias Value = Bool
}
extension FocusedValues {
    var hasPurloryEditor: Bool? {
        get { self[HasPurloryEditorKey.self] }
        set { self[HasPurloryEditorKey.self] = newValue }
    }
}

/// Testable command routing for mutations owned by the active project session.
@MainActor
public struct ProjectCommandActions {
    public let newDocument: (WritingDocument.Kind) -> Void
    public let renameDocument: (String) -> Void
    public let trashDocument: () -> Void
    public let restoreDocument: (WritingDocumentID) -> Void
    public let save: () async throws -> Void

    public init(session: ProjectSession) {
        newDocument = { kind in
            session.createDocument(kind: kind)
        }
        renameDocument = { title in
            session.renameSelectedDocument(to: title)
        }
        trashDocument = {
            session.trashSelectedDocument()
        }
        restoreDocument = { id in
            session.restoreDocument(id)
        }
        save = {
            try await session.saveNow()
        }
    }
}

public struct PurloryCommands: Commands {
    @ObservedObject private var session: ProjectSession
    private let startup: ProjectStartupCoordinator
    @ObservedObject private var editorRequests: ProjectEditorRequests
    private let projectStore: ProjectStore
    /// 에디터 포커스 여부 — 없으면 서식·찾기 명령을 비활성화해 "눌러도 무반응"을
    /// 없앤다 (이슈 #26).
    @FocusedValue(\.hasPurloryEditor) private var hasPurloryEditor
    @AppStorage("purlory.appearance") private var appearance = ""
    @AppStorage("purlory.sidebarVisible") private var sidebarVisible = true
    @AppStorage("purlory.chromeHidden") private var chromeHidden = false

    public init(
        session: ProjectSession,
        startup: ProjectStartupCoordinator,
        projectStore: ProjectStore,
        editorRequests: ProjectEditorRequests
    ) {
        self._session = ObservedObject(wrappedValue: session)
        self.startup = startup
        self.projectStore = projectStore
        self._editorRequests = ObservedObject(wrappedValue: editorRequests)
    }

    public var body: some Commands {
        // 파일 ▸ 프로젝트 문서와 verified project creation/import flows.
        CommandGroup(replacing: .newItem) {
            Button("새 문서") {
                ProjectCommandActions(session: session).newDocument(.manuscript)
                editorRequests.focusEditor()
            }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!hasWorkspace || session.isTransitioning)

            Divider()

            Button("새 Fiction 프로젝트…") { presentNewProject(mode: .fiction) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session.isTransitioning || session.phase == .loading)
            Button("새 General 프로젝트…") { presentNewProject(mode: .general) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(session.isTransitioning || session.phase == .loading)
            Button("프로젝트 가져오기…") { presentFolderImport() }
                .disabled(session.isTransitioning || session.phase == .loading)
            Button("이전 저장본에서 복구…") {
                Task {
                    if await ProjectRecoveryPanel.present(session: session) { editorRequests.focusEditor() }
                }
            }
            .disabled(session.isTransitioning || session.phase == .loading
                || (session.phase != .ready && session.phase != .failed))
            Divider()
            Button("이전 라이브러리를 프로젝트로 열기") {
                Task {
                    do { try await startup.openLegacyLibrary(); editorRequests.focusEditor() }
                    catch { presentError(title: "이전 원고를 열지 못했습니다", error: error) }
                }
            }
            .disabled(session.isTransitioning || session.phase == .loading)
            Button("이전 원고 파일 선택…") { presentFolderImport(legacyArchive: true) }
                .disabled(session.isTransitioning || session.phase == .loading)
        }

        CommandGroup(replacing: .saveItem) {
            Button("저장") {
                Task { try? await ProjectCommandActions(session: session).save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasWorkspace || session.isTransitioning)
        }

        // 파일 저장 영역 옆에 이름 바꾸기 · 내보내기 · 인쇄.
        CommandGroup(after: .saveItem) {
            Button("문서 이름 바꾸기") {
                sidebarVisible = true
                editorRequests.beginRename()
            }
            .disabled(!hasWorkspace || session.isTransitioning)

            Button("문서를 휴지통으로 이동", role: .destructive) {
                ProjectCommandActions(session: session).trashDocument()
                editorRequests.focusEditor()
            }
            .disabled(!hasWorkspace || session.isTransitioning)

            Divider()

            Button("Markdown으로 내보내기…") { presentProjectExport(epub: false) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!canExport || session.isTransitioning)
            Button("EPUB으로 내보내기…") { presentProjectExport(epub: true) }
                .disabled(!canExport || session.isTransitioning)
            Button("인쇄…") { printActiveManuscript() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasWorkspace)
        }

        // 서식 ▸ 텍스트 스타일 · 블록 · 정렬 · 이미지.
        // 편집 대상 명령이므로 에디터 포커스가 없으면 메뉴째 비활성 (이슈 #26).
        CommandMenu("서식") {
            Group {
            Button("굵게") { send(#selector(BlockTextView.purloryFormatBold(_:))) }
                .keyboardShortcut("b", modifiers: .command)
            Button("기울임") { send(#selector(BlockTextView.purloryFormatItalic(_:))) }
                .keyboardShortcut("i", modifiers: .command)
            Button("취소선") { send(#selector(BlockTextView.purloryFormatStrikethrough(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("형광펜 하이라이트") { send(#selector(BlockTextView.purloryFormatHighlight(_:))) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("인라인 코드") { send(#selector(BlockTextView.purloryFormatCode(_:))) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("링크 삽입") { send(#selector(BlockTextView.purloryFormatLink(_:))) }
                .keyboardShortcut("l", modifiers: .command)

            Divider()

            Button("본문") { send(#selector(BlockTextView.purloryBodyText(_:))) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("제목 1") { send(#selector(BlockTextView.purloryHeading1(_:))) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("제목 2") { send(#selector(BlockTextView.purloryHeading2(_:))) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("제목 3") { send(#selector(BlockTextView.purloryHeading3(_:))) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("제목 4") { send(#selector(BlockTextView.purloryHeading4(_:))) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Button("제목 5") { send(#selector(BlockTextView.purloryHeading5(_:))) }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Button("제목 6") { send(#selector(BlockTextView.purloryHeading6(_:))) }
                .keyboardShortcut("6", modifiers: [.command, .option])

            Divider()

            Button("글머리 목록") { send(#selector(BlockTextView.purloryBulletList(_:))) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("번호 목록") { send(#selector(BlockTextView.purloryNumberedList(_:))) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("인용") { send(#selector(BlockTextView.purloryQuoteBlock(_:))) }
            Button("코드 블록") { send(#selector(BlockTextView.purloryCodeBlock(_:))) }

            Divider()

            Button("문단 위로 이동") { send(#selector(BlockTextView.purloryMoveParagraphUp(_:))) }
                .keyboardShortcut(.upArrow, modifiers: [.option])
            Button("문단 아래로 이동") { send(#selector(BlockTextView.purloryMoveParagraphDown(_:))) }
                .keyboardShortcut(.downArrow, modifiers: [.option])

            Divider()

            Button("왼쪽 정렬") { send(#selector(BlockTextView.purloryAlignLeft(_:))) }
            Button("가운데 정렬") { send(#selector(BlockTextView.purloryAlignCenter(_:))) }
            Button("오른쪽 정렬") { send(#selector(BlockTextView.purloryAlignRight(_:))) }

            Divider()

            Button("이미지 삽입…") { send(#selector(BlockTextView.insertImageFromMenu(_:))) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("원본 마크다운 소스 보기 전환") { send(#selector(BlockTextView.purloryToggleSourceMode(_:))) }
                .keyboardShortcut("/", modifiers: .command)
            }
            .disabled(hasPurloryEditor != true)
        }

        // 보기 ▸ 검색 · 사이드바 · 외형.
        CommandMenu("보기") {
            Button("검색 객체 열기") { editorRequests.spatialWorkspace?.openSearch() }
                .disabled(!session.isEditorEditable || session.isTransitioning || session.phase == .loading)
            Button("빠른 명령 팔레트…") {
                _ = WorkspaceQuickCommandPanel.present(
                    session: session,
                    requests: editorRequests,
                    theme: effectiveDark ? .dark : .light,
                    toggleTheme: { appearance = effectiveDark ? "light" : "dark" }
                )
            }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!session.isEditorEditable || session.isTransitioning || session.phase == .loading)
            Button("원문 확인·질문…") { SourceSearchPanel.present(session: session, requests: editorRequests) }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!session.isEditorEditable || session.isTransitioning || session.phase == .loading)
            Button("이전 집필 위치로 돌아가기") { editorRequests.returnToWriting(in: session) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!session.isEditorEditable
                    || editorRequests.sourceReturnPoint?.key.projectID != session.activeProject?.id)
            Divider()
            // 문서 내 검색 — 에디터의 performKeyEquivalent(⌘F)가 우선 처리하고,
            // 한글 IME 등으로 뷰에 닿지 못한 경우 이 메뉴가 안전망이 된다.
            Group {
                Button("문서에서 찾기") {
                    if let spatial = editorRequests.spatialWorkspace { spatial.openSearch(scope: .document) }
                    else { send(#selector(BlockTextView.purloryFindInDocument(_:))) }
                }
                    .keyboardShortcut("f", modifiers: .command)
                Button("다음 찾기") {
                    if let advance = editorRequests.spatialWorkspace?.advanceSearch { advance(1) }
                    else { send(#selector(BlockTextView.purloryFindNext(_:))) }
                }
                    .keyboardShortcut("g", modifiers: .command)
                Button("이전 찾기") {
                    if let advance = editorRequests.spatialWorkspace?.advanceSearch { advance(-1) }
                    else { send(#selector(BlockTextView.purloryFindPrevious(_:))) }
                }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(hasPurloryEditor != true)

            Button("프로젝트 검색") {
                sidebarVisible = true
                editorRequests.spatialWorkspace?.openSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button(sidebarVisible ? "파일 목록 숨기기" : "파일 목록 보이기") {
                sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button(chromeHidden ? "집중 모드 끄기" : "집중 모드") {
                chromeHidden.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("글자 크게") { CompletionSettings.shared.editorFontSize += 1 }
                .keyboardShortcut("+", modifiers: .command)
            Button("글자 작게") { CompletionSettings.shared.editorFontSize -= 1 }
                .keyboardShortcut("-", modifiers: .command)
            Button("기본 글자 크기") {
                CompletionSettings.shared.editorFontSize = CompletionSettings.defaultFontSize
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button(effectiveDark ? "라이트 모드" : "다크 모드") {
                appearance = effectiveDark ? "light" : "dark"
            }
            Button("시스템 외형 따르기") { appearance = "" }
        }
    }

    private func send(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// 편집 대상 명령 공통 — 에디터 포커스가 없으면 비활성(무반응 제거, 이슈 #26).
    @ViewBuilder
    private func editCommand<Content: View>(_ title: String, shortcut: KeyEquivalent? = nil,
        modifiers: EventModifiers = [.command], _ action: @escaping () -> Void,
        @ViewBuilder content: () -> Content) -> some View {
        Button(title, action: action)
            .modifier(OptionalShortcut(shortcut: shortcut, modifiers: modifiers))
            .disabled(hasPurloryEditor != true)
        content()
    }

    struct OptionalShortcut: ViewModifier {
        let shortcut: KeyEquivalent?
        let modifiers: EventModifiers
        func body(content: Content) -> some View {
            if let shortcut {
                content.keyboardShortcut(shortcut, modifiers: modifiers)
            } else {
                content
            }
        }
    }

    private func presentNewProject(mode: WritingMode) {
        let alert = NSAlert()
        alert.messageText = mode == .fiction ? "새 Fiction 프로젝트" : "새 General 프로젝트"
        alert.informativeText = "프로젝트 이름을 입력하세요."
        alert.addButton(withTitle: "만들기")
        alert.addButton(withTitle: "취소")
        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        titleField.placeholderString = "프로젝트 이름"
        alert.accessoryView = titleField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            do {
                try await ProjectCreationCoordinator(session: session)
                    .createProject(title: titleField.stringValue, mode: mode)
                editorRequests.focusEditor()
            } catch {
                presentError(title: "프로젝트를 만들지 못했습니다", error: error)
            }
        }
    }

    private func presentFolderImport(legacyArchive: Bool = false) {
        guard let selection = legacyArchive ? ProjectImportPanel.selectLegacyArchive() : ProjectImportPanel.select() else { return }
        Task { @MainActor in
            do {
                try await ImportProjectCoordinator(store: projectStore, session: session)
                    .importFolder(from: selection.directory, legacyMode: selection.legacyMode, legacyFileName: selection.legacyFileName)
                editorRequests.focusEditor()
            } catch {
                presentError(title: "가져오지 못했습니다", error: error)
            }
        }
    }

    private func presentProjectExport(epub: Bool) {
        guard let document = session.selectedDocument, let assets = session.assetCatalog,
            assets.projectID == session.activeProject?.id else { return }
        let panel = NSSavePanel()
        let ext = epub ? "epub" : "md"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        let title = document.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = (title.isEmpty ? "Untitled" : title) + "." + ext
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let author = CompletionSettings.shared.authorName
        Task {
            do {
                if epub {
                    try await EpubExporter.exportAsync(document, assets: assets, to: destination, author: author)
                } else {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try MarkdownExporter.export(document, assets: assets, to: destination)
                    }.value
                    if !report.missingSources.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "일부 이미지 없이 내보냈습니다"
                        alert.informativeText = report.missingSources.joined(separator: "\n")
                        alert.runModal()
                    }
                }
            } catch is CancellationError {} catch {
                presentError(title: "내보내지 못했습니다", error: error)
            }
        }
    }

    private func printActiveManuscript() {
        guard let body = session.selectedDocument?.body else { return }
        let page = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 792))
        page.textStorage?.setAttributedString(NSAttributedString(
            string: body.isEmpty ? "(빈 원고)" : body,
            attributes: [
                .font: PurloryFonts.serif(12),
                .foregroundColor: NSColor.black,
                .paragraphStyle: {
                    let ps = NSMutableParagraphStyle()
                    ps.lineSpacing = 6
                    return ps
                }(),
            ]))
        page.printView(nil)
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private var hasWorkspace: Bool {
        session.selectedDocument != nil
    }

    private var canExport: Bool {
        session.selectedDocument != nil && session.assetCatalog != nil
    }

    /// 현재 유효 외형이 다크인가 — 명시값이 있으면 그대로, "시스템 따름"이면 실제
    /// 시스템 외형으로 판단한다.
    private var effectiveDark: Bool {
        switch appearance {
        case "dark": return true
        case "light": return false
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}
