import SwiftUI
import AppKit
import PurloryCore

/// Local writing runtime with one shared inference engine and model-free editing.
@main
struct PurloryApp: App {
    private let preparedPreferences: Void = PurloryPreferences.prepareStandard()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Completion, background preparation and pressure release own this same engine.
    static let sharedEngine = CompletionEngine()
    // Swift 6.1 crashes when lowering these defaults inside StateObject's autoclosure.
    @StateObject private var completion = CompletionController(
        settings: .shared, engine: PurloryApp.sharedEngine, metricsStorageLocation: .standard)
    @StateObject private var livingMargin = LivingMarginModel()
    @StateObject private var writingDiagnostics = WritingDiagnosticsRuntime()
    private static let projectStore = ProjectStore(root: PurloryStorageLocation.standard.projectsDirectory)
    private static let knowledgeSidecars = KnowledgeSidecarRepository(
        projectStore: PurloryApp.projectStore)
    @StateObject private var indexer = BackgroundIndexer(
        engine: PurloryApp.sharedEngine,
        sidecarPersistence: PurloryApp.knowledgeSidecars)
    @StateObject private var projectSession: ProjectSession
    private var startup: ProjectStartupCoordinator {
        ProjectStartupCoordinator(session: projectSession, store: Self.projectStore)
    }
    @StateObject private var editorRequests = ProjectEditorRequests()

    init() {
        let session = ProjectSession(store: Self.projectStore, prepareProject: { project, store in
            try await ProjectWriterDataMigration.prepare(project, store: store)
        })
        _projectSession = StateObject(wrappedValue: session)
    }

    var body: some Scene {
        Window("Purlory", id: "main") {
            ContentView(
                projectSession: projectSession,
                startup: startup,
                editorRequests: editorRequests,
                completion: completion,
                indexer: indexer,
                livingMargin: livingMargin,
                firstRunFlow: FirstRunFlow(
                    session: projectSession,
                    store: PurloryApp.projectStore,
                    editorRequests: editorRequests), writingDiagnostics: writingDiagnostics)
                .onAppear {
                    appDelegate.configure(session: projectSession,
                        completion: completion, indexer: indexer, writingDiagnostics: writingDiagnostics)
                }
        }
        // 에디터 v3 — 타이틀 바를 숨기고 사이드바가 창 상단까지 차오르게 한다.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            PurloryCommands(
                session: projectSession,
                startup: startup,
                projectStore: PurloryApp.projectStore,
                editorRequests: editorRequests)
        }

        // ⌘, — 자동완성 설정 (M4): 모델 · 프롬프트 방식 · 디바운스 · 토큰.
        // 컨트롤러를 함께 넘겨 설정 창의 스위치·모델 변경도 의유 API로 무효화를
        // 발화하게 한다 (이슈 #11).
        Settings {
            SettingsView(settings: completion.settings, completion: completion,
                projectSession: projectSession, writingDiagnostics: writingDiagnostics)
        }
    }
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var projectSession: ProjectSession?
    private var termination: ProjectTerminationCoordinator?
    private var memoryPressure: MemoryPressureRuntime?
    private var backgroundFlush: Task<Void, Never>?

    func configure(session: ProjectSession,
                   completion: CompletionController, indexer: BackgroundIndexer,
                   writingDiagnostics: WritingDiagnosticsRuntime? = nil) {
        guard termination == nil else { return }
        projectSession = session
        memoryPressure = MemoryPressureRuntime(completion: completion, indexer: indexer,
            engine: PurloryApp.sharedEngine, writingDiagnostics: writingDiagnostics)
        termination = ProjectTerminationCoordinator(
            session: session,
            persistPositions: { WritingPositionStore.shared.persistNow() },
            shutdown: { [weak self] in
                self?.memoryPressure?.stop()
                writingDiagnostics?.stop()
                completion.shutdown(); indexer.shutdown()
            },
            drain: { [weak self] in
                await self?.memoryPressure?.drain()
                await writingDiagnostics?.prepareForTermination()
                // Yield the main actor until every engine operation has released its resources.
                while PurloryApp.sharedEngine.pendingOperationCount > 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Explicit archive smoke only; no model selection, download or AI authorization.
        if ProcessInfo.processInfo.environment["PURLORY_VERIFY_MLX_RESOURCES"] == "1" {
            let root = PurloryStorageLocation.standard.rootDirectory
            Task.detached(priority: .utility) {
                let result: String
                do {
                    let library = try MLXRuntimeResources.initialize()
                    result = "PASS\n\(library.path)\nMLX GPU result: 42\n"
                } catch { result = "FAIL\n\(error.localizedDescription)\n" }
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try Data(result.utf8).write(to: root.appendingPathComponent("mlx-runtime-verification.txt"), options: .atomic)
                } catch { NSLog("MLX archive diagnostic could not save its result: %@", error.localizedDescription) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the suction animation's temporary panel must not quit the app
        // while its document window lives inside the floating pouch.
        !WorkspacePouchLifetime.hasCollapsedWorkspace
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock reopening uses the retained workspace and its original editor.
        !WorkspacePouchLifetime.restoreCollapsedWorkspaces()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let termination else { return .terminateNow }
        return termination.requestTermination { [weak self] success in
            sender.reply(toApplicationShouldTerminate: success)
            if !success, let message = self?.projectSession?.lastErrorMessage {
                let alert = NSAlert()
                alert.messageText = "저장하지 못해 종료를 취소했습니다"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard backgroundFlush == nil, let projectSession, projectSession.phase == .ready, !projectSession.isTransitioning else { return }
        backgroundFlush = Task { @MainActor [weak self, weak projectSession] in
            defer { self?.backgroundFlush = nil }
            try? await projectSession?.saveNow()
        }
    }
}
