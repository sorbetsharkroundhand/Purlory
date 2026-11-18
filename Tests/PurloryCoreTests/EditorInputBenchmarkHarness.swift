import AppKit
import CoreGraphics
import XCTest
@testable import PurloryStorage
@testable import PurloryWorkspaceUI

/// TextKit 1 comparator. Overrides only observe; the native implementation owns each edit.
@MainActor
final class InputBenchmarkNativeTextView: NSTextView, @preconcurrency NSTextStorageDelegate {
    var recorder: EditorInputTraceRecorder?
    override func keyDown(with event: NSEvent) {
        let r = recorder, token = r?.beginOperation(kind: .keyDown, eventTimestamp: event.timestamp, composing: hasMarkedText())
        defer { if let token { r?.endOperation(token) } }
        super.keyDown(with: event)
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let r = recorder, token = r?.beginOperation(kind: .insertText, composing: hasMarkedText())
        defer { if let token { r?.endOperation(token) } }
        super.insertText(string, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let r = recorder, token = r?.beginOperation(kind: .setMarkedText, composing: hasMarkedText())
        defer { if let token { r?.endOperation(token) } }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() {
        let r = recorder, token = r?.beginOperation(kind: .unmarkText, composing: hasMarkedText())
        defer { if let token { r?.endOperation(token) } }
        super.unmarkText()
    }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        recorder?.storageProcessed(range: range, delta: delta, editedCharacters: mask.contains(.editedCharacters), composing: hasMarkedText())
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = recorder, token = r?.drawBegan(dirtyRect)
        defer { if let token { r?.drawEnded(token) } }
        super.draw(dirtyRect)
    }
}

/// A low-rate sentinel, not a frame counter. The lock bounds outstanding main-queue work to one.
final class InputBenchmarkProbe: @unchecked Sendable {
    struct Sample: Codable { let posted: Double; let executed: Double }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.purlory.input-benchmark.probe", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var pending = false
    private var values: [Sample] = []
    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.post() }
        timer.resume()
    }
    private func post() {
        lock.lock()
        guard !stopped, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        let posted = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [self] in
            let executed = ProcessInfo.processInfo.systemUptime
            lock.lock()
            values.append(Sample(posted: posted, executed: executed))
            pending = false
            lock.unlock()
        }
    }
    private func stopTimer() {
        queue.sync {
            lock.lock(); stopped = true; lock.unlock()
            timer?.cancel(); timer = nil
        }
    }
    private func drained() -> [Sample]? {
        lock.lock(); defer { lock.unlock() }
        return pending ? nil : values
    }
    @MainActor func stopAndDrain() async -> [Sample] {
        stopTimer()
        while true {
            if let values = drained() { return values }
            await Task.yield()
        }
    }
}

struct InputBenchmarkConfiguration: Codable {
    static let localDocumentEnvironmentKey = "PURLORY_INPUT_BENCHMARK_LOCAL_DOCUMENT"

    let fixtureOrigin: InputBenchmarkFixture.Origin
    let sizes: [Int]
    let shapes: [InputBenchmarkFixture.Shape]
    let formats: [InputBenchmarkFixture.Format]
    let positions: [String]
    let traces: [InputBenchmarkTrace]
    let timings: [String]
    let repetitions: Int
    let cadenceSeconds: Double
    let instrumentation: Bool
    let signposts: Bool
    let smokeSubset: Bool
    init(environment e: [String: String]) throws {
        func list<T>(_ key: String, _ fallback: String, parse: (String) -> T?) throws -> [T] {
            let parts = (e["PURLORY_INPUT_BENCHMARK_" + key] ?? fallback).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let values = parts.compactMap(parse)
            guard !values.isEmpty, values.count == parts.count, Set(parts).count == parts.count
            else { throw InputBenchmarkError.invalidConfiguration(key) }
            return values
        }
        if let path = e[Self.localDocumentEnvironmentKey] {
            guard !path.isEmpty, ["SIZES", "SHAPES", "FORMATS"].allSatisfy({ e["PURLORY_INPUT_BENCHMARK_" + $0] == nil })
            else { throw InputBenchmarkError.invalidConfiguration("local document excludes synthetic size, shape, and format filters") }
            fixtureOrigin = .localDocument
            sizes = []
            shapes = []
            formats = []
        } else {
            fixtureOrigin = .generated
            sizes = try list("SIZES", "1000,10000,100000,230544,500000,1000000") {
                guard let value = Int($0), [1000,10000,100000,230544,500000,1000000].contains(value) else { return nil }; return value
            }
            shapes = try list("SHAPES", "short,long", parse: InputBenchmarkFixture.Shape.init(rawValue:))
            formats = try list("FORMATS", "plain,markdown", parse: InputBenchmarkFixture.Format.init(rawValue:))
        }
        let supportedPositions = ["start", "middle", "end", "moving"]
        positions = try list("POSITIONS", supportedPositions.joined(separator: ",")) { supportedPositions.contains($0) ? $0 : nil }
        traces = try list("TRACES", "latin,hangul,editing,paste", parse: InputBenchmarkTrace.init(rawValue:))
        timings = try list("TIMINGS", "immediate,idle") { ["immediate","idle"].contains($0) ? $0 : nil }
        guard let repetitions = Int(e["PURLORY_INPUT_BENCHMARK_REPETITIONS"] ?? "5"), (1...100).contains(repetitions),
              let cadence = Double(e["PURLORY_INPUT_BENCHMARK_CADENCE_MS"] ?? "30"), cadence.isFinite, (1...1000).contains(cadence),
              let instrumentation = ["on": true, "off": false][e["PURLORY_INPUT_BENCHMARK_INSTRUMENTATION"] ?? "on"],
              let signposts = ["on": true, "off": false][e["PURLORY_INPUT_BENCHMARK_SIGNPOSTS"] ?? "off"]
        else { throw InputBenchmarkError.invalidConfiguration("repetitions/cadence/instrumentation/signposts") }
        self.repetitions = repetitions; cadenceSeconds = cadence / 1000
        self.instrumentation = instrumentation; self.signposts = signposts
        smokeSubset = e["PURLORY_INPUT_BENCHMARK_QUICK"] == "1"
    }
}

enum InputBenchmarkError: Error { case invalidConfiguration(String), integrity(String), existingReport, missingIsolation }

@MainActor
struct InputBenchmarkHost {
    let view: NSTextView
    let window: NSWindow
    let workspace: FramedWorkspaceHarness?

    static func makeWorkspace(fixture: InputBenchmarkFixture) async throws -> Self {
        let workspace = try await FramedWorkspaceHarness(autosaveDelay: .milliseconds(800))
        do {
            workspace.fixture.session.updateSelectedDocumentBody(fixture.text)
            let editor = try await workspace.editor()
            if fixture.metadata.origin == .localDocument {
                guard workspace.fixture.session.selectedDocument?.source.string.utf8.elementsEqual(fixture.text.utf8) == true
                else { throw InputBenchmarkError.integrity("initial local source binding") }
            }
            return Self(view: editor, window: workspace.window, workspace: workspace)
        } catch {
            workspace.close()
            throw error
        }
    }

    static func makeNative(matching editor: NSTextView) -> Self {
        let storage = NSTextStorage(attributedString: editor.textStorage!)
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = editor.layoutManager!.allowsNonContiguousLayout
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: editor.textContainer!.containerSize)
        container.widthTracksTextView = editor.textContainer!.widthTracksTextView
        container.lineFragmentPadding = editor.textContainer!.lineFragmentPadding
        manager.addTextContainer(container)
        let view = InputBenchmarkNativeTextView(frame: editor.frame, textContainer: container)
        storage.delegate = view
        view.isRichText = editor.isRichText
        view.allowsUndo = true
        view.isVerticallyResizable = editor.isVerticallyResizable
        view.isHorizontallyResizable = editor.isHorizontallyResizable
        view.autoresizingMask = editor.autoresizingMask
        view.minSize = editor.minSize; view.maxSize = editor.maxSize
        view.textContainerInset = editor.textContainerInset
        view.typingAttributes = editor.typingAttributes
        view.defaultParagraphStyle = editor.defaultParagraphStyle
        view.isAutomaticQuoteSubstitutionEnabled = editor.isAutomaticQuoteSubstitutionEnabled
        view.isAutomaticDashSubstitutionEnabled = editor.isAutomaticDashSubstitutionEnabled
        view.isAutomaticTextReplacementEnabled = editor.isAutomaticTextReplacementEnabled
        view.isAutomaticSpellingCorrectionEnabled = editor.isAutomaticSpellingCorrectionEnabled
        view.isContinuousSpellCheckingEnabled = editor.isContinuousSpellCheckingEnabled
        view.isGrammarCheckingEnabled = editor.isGrammarCheckingEnabled
        view.smartInsertDeleteEnabled = editor.smartInsertDeleteEnabled
        let viewport = editor.enclosingScrollView!.contentSize
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = view
        let window = FramedWorkspaceWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testUndo.groupsByEvent = false
        window.contentView = scroll
        window.layoutIfNeeded()
        return Self(view: view, window: window, workspace: nil)
    }

    var effectiveSettings: [String: String] {
        let font = (view.typingAttributes[.font] as? NSFont) ?? view.font
        let style = (view.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? view.defaultParagraphStyle
        let layoutManager = view.layoutManager!
        return [
            "font": font?.fontName ?? "unknown", "fontSize": String(describing: font?.pointSize ?? 0),
            "containerWidth": String(describing: view.textContainer?.containerSize.width ?? 0),
            "viewportWidth": String(describing: view.enclosingScrollView?.contentSize.width ?? 0),
            "viewportHeight": String(describing: view.enclosingScrollView?.contentSize.height ?? 0),
            "insetWidth": String(describing: view.textContainerInset.width), "insetHeight": String(describing: view.textContainerInset.height),
            "lineFragmentPadding": String(describing: view.textContainer?.lineFragmentPadding ?? 0),
            "lineSpacing": String(describing: style?.lineSpacing ?? 0),
            "paragraphSpacing": String(describing: style?.paragraphSpacing ?? 0),
            "lineHeightMultiple": String(describing: style?.lineHeightMultiple ?? 0),
            "quoteSubstitution": String(view.isAutomaticQuoteSubstitutionEnabled),
            "dashSubstitution": String(view.isAutomaticDashSubstitutionEnabled),
            "textReplacement": String(view.isAutomaticTextReplacementEnabled),
            "spellingCorrection": String(view.isAutomaticSpellingCorrectionEnabled),
            "spellChecking": String(view.isContinuousSpellCheckingEnabled), "grammarChecking": String(view.isGrammarCheckingEnabled),
            "smartInsertDelete": String(view.smartInsertDeleteEnabled), "richText": String(view.isRichText),
            "allowsNonContiguousLayout": String(layoutManager.allowsNonContiguousLayout),
            "layoutManager": String(describing: type(of: layoutManager))]
    }
    func attach(_ recorder: EditorInputTraceRecorder?) {
        (view as? BlockTextView)?.inputTraceRecorder = recorder
        (view as? InputBenchmarkNativeTextView)?.recorder = recorder
    }
    func close() {
        attach(nil)
        if let workspace { workspace.close() }
        else { window.undoManager?.removeAllActions(); window.contentView = nil; window.close() }
    }
    var counters: [String: Int] {
        guard let view = view as? BlockTextView else { return [:] }
        return ["serialCacheRebuild": view.serialCacheRebuildCount, "serializationInvocation": view.serializationInvocationCount,
                "mediaIndexBuild": view.mediaIndexBuildCount, "projectionReset": view.writingProjectionResetCount]
    }
    var visibility: [String: Bool] {
        ["windowVisible": window.isVisible, "windowKey": window.isKeyWindow,
         "occlusionVisible": window.occlusionState.contains(.visible), "firstResponder": window.firstResponder === view,
         "nonemptyVisibleRect": !view.visibleRect.isEmpty]
    }
}
