import AppKit
import CryptoKit
import XCTest
@testable import PurloryWorkspaceUI

struct InputBenchmarkRun: Codable {
    struct DispatchSample: Codable {
        let sequence: Int
        let action: InputBenchmarkTrace.Action
        let requested: Double
        let started: Double
        let ended: Double
        var schedulingDelay: Double { max(0, started - requested) }
    }
    let scenarioID: String
    let runID: Int
    let burstID: Int
    let target: String
    let fixture: InputBenchmarkFixture.Metadata
    let position: String
    let activeParagraphUTF16Count: Int
    let initialRenderedUTF16Count: Int
    let traceKind: InputBenchmarkTrace
    let timing: String
    let elapsedIdleSeconds: Double
    let started: Double
    let ended: Double
    let settings: [String: String]
    let referenceSettings: [String: String]
    let settingsDifferences: [String]
    let scope: [String: String]
    let visibilityBefore: [String: Bool]
    let visibilityAfter: [String: Bool]
    let countersBefore: [String: Int]
    let countersAfter: [String: Int]
    let integrity: [String: String]
    let schedule: [DispatchSample]
    let probes: [InputBenchmarkProbe.Sample]
    let trace: EditorInputTrace?
    let metrics: InputBenchmarkMetrics?
    let dispatchDurationSeconds: InputBenchmarkDistribution?
    let syntheticSchedulingDelaySeconds: InputBenchmarkDistribution?
    let probeDelaySeconds: InputBenchmarkDistribution?
}

struct InputBenchmarkReport: Codable {
    let schemaVersion: Int
    let clock: String
    let timestampUnit: String
    let configuration: InputBenchmarkConfiguration
    let provenance: [String: String]
    let environment: [String: String]
    let limitations: [String]
    let runs: [InputBenchmarkRun]

    func write(to directory: URL) throws {
        let urls = ["report.json", "trace.csv", "schedule.csv", "probes.csv"].map { directory.appendingPathComponent($0) }
        guard urls.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else { throw InputBenchmarkError.existingReport }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(self)
        // Only schema enums, synthetic IDs and numbers are admitted to CSV fields.
        var trace = "schema_version,scenario_id,run_id,burst_id,target,sequence,kind,timestamp_seconds,id,operation_id,parent_id,revision,event_timestamp_seconds,event_timestamp_comparable,location,length,delta,edited_characters,main_thread,composing,rect_x,rect_y,rect_width,rect_height\n"
        var schedule = "schema_version,scenario_id,run_id,burst_id,target,sequence,action,requested_seconds,started_seconds,ended_seconds\n"
        var probes = "schema_version,scenario_id,run_id,burst_id,target,sequence,posted_seconds,executed_seconds\n"
        func cell<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? "" }
        for run in runs {
            let prefix = "\(schemaVersion),\(run.scenarioID),\(run.runID),\(run.burstID),\(run.target),"
            for row in run.trace?.samples ?? [] {
                trace += prefix + [String(row.sequence), row.kind, String(row.timestamp), String(row.id),
                    cell(row.operationID), cell(row.parentID), String(row.revision), cell(row.eventTimestamp), cell(row.eventTimestampComparable),
                    cell(row.location), cell(row.length), cell(row.delta), cell(row.editedCharacters),
                    String(row.mainThread), String(row.composing), cell(row.rect?[0]), cell(row.rect?[1]),
                    cell(row.rect?[2]), cell(row.rect?[3])].joined(separator: ",") + "\n"
            }
            for row in run.schedule {
                schedule += prefix + "\(row.sequence),\(row.action.rawValue),\(row.requested),\(row.started),\(row.ended)\n"
            }
            for (index, row) in run.probes.enumerated() {
                probes += prefix + "\(index),\(row.posted),\(row.executed)\n"
            }
        }
        for (url, data) in zip(urls, [json, Data(trace.utf8), Data(schedule.utf8), Data(probes.utf8)]) {
            try data.write(to: url, options: .withoutOverwriting)
        }
    }
}

@MainActor
extension EditorInputBenchmarkTests {
    func testRecordBaseline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["PURLORY_INPUT_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Opt-in experiment: use scripts/benchmark-editor-input.sh with a new output directory")
        }
        guard let isolatedHome = environment["CFFIXED_USER_HOME"], !isolatedHome.isEmpty,
              isolatedHome != FileManager.default.homeDirectoryForCurrentUser.path || environment["PURLORY_INPUT_BENCHMARK_ISOLATED"] == "1"
        else { throw InputBenchmarkError.missingIsolation }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.json").path) else { throw InputBenchmarkError.existingReport }
        let configuration = try InputBenchmarkConfiguration(environment: environment)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        var runs: [InputBenchmarkRun] = []
        for size in configuration.sizes {
            for shape in configuration.shapes {
                for format in configuration.formats {
                    let fixture = InputBenchmarkFixture(size: size, shape: shape, format: format)
                    for position in configuration.positions {
                        for trace in configuration.traces {
                            for timing in configuration.timings {
                                for repetition in 0..<configuration.repetitions {
                                    // Alternate order by repetition; retain order in the output for paired analysis.
                                    for target in repetition.isMultiple(of: 2) ? ["native", "workspace"] : ["workspace", "native"] {
                                        runs.append(try await recordRun(fixture: fixture, position: position, trace: trace,
                                            timing: timing, target: target, repetition: repetition, configuration: configuration))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        var provenance: [String: String] = [:]
        if let data = try? Data(contentsOf: directory.appendingPathComponent("provenance.json")) {
            provenance = try JSONDecoder().decode([String: String].self, from: data)
        }
        let binary = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        provenance["observedExecutableSHA256"] = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
        if let expected = provenance["executableSHA256"], expected != provenance["observedExecutableSHA256"] {
            throw InputBenchmarkError.integrity("executable changed after recorded build")
        }
        let screen = NSScreen.main
        var runtime: [String: String] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory),
            "processorCount": String(ProcessInfo.processInfo.processorCount),
            "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "thermalState": String(ProcessInfo.processInfo.thermalState.rawValue),
            "backingScale": screen.map { String(describing: $0.backingScaleFactor) } ?? "unknown",
            "inputSource": "unknown", "inputDelivery": "synthetic-text-input-client-calls", "gpu": "unknown",
            "maximumFramesPerSecond": screen.map { String($0.maximumFramesPerSecond) } ?? "unknown",
            "configuredRefreshHz": "unknown", "physicalPresentation": "unmeasured", "realKoreanIME": "unmeasured"]
        if let display = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            runtime["displayID"] = display.stringValue
            if let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(display.uint32Value)), mode.refreshRate > 0 {
                runtime["configuredRefreshHz"] = String(mode.refreshRate)
            }
        }
        let report = InputBenchmarkReport(schemaVersion: 1, clock: "ProcessInfo.systemUptime", timestampUnit: "seconds",
            configuration: configuration, provenance: provenance, environment: runtime, limitations: [
                "Synthetic calls have no native event ID or OS event-queue delay; schedule delay belongs to the harness.",
                "A completed draw observes the revision captured at draw start, not a specific glyph or physical presentation.",
                "Revisions can share one draw; unmatched revisions and dropped samples cannot be counted as zero latency.",
                "The low-rate main-queue sentinel is neither frame measurement nor a physical freeze detector.",
                "Visibility flags cannot prove that the target pixels were unobscured or presented.",
                "Synthetic marked text does not validate the macOS Korean input method.",
                "Native comparator uses the workspace rendered attributed content; source Markdown sizes differ from rendered sizes.",
                "Paste is a separately labeled direct synthetic insertion; clipboard services are not exercised.",
                "No-model workspace is not the all-features production app; background job start/cancel attribution is not captured.",
                "Save/reopen and undo/redo are checked outside timing; EPUB/media/math export is not measured by this experiment."
            ], runs: runs)
        try report.write(to: directory)
    }

    // Freezing settings during host construction misses caret-dependent Markdown font runs.
    func testMarkdownRunsExportPreparedPositionSettings() async throws {
        let fixture = InputBenchmarkFixture(size: 1000, shape: .short, format: .markdown)
        var expectedFonts: [String: String] = [:]
        do {
            let reference = try await InputBenchmarkHost.makeWorkspace(fixture: fixture)
            defer { reference.close() }
            for position in ["start", "middle", "end"] {
                let view = reference.view
                let initial = view.string
                let length = (initial as NSString).length
                let location = position == "start" ? 0 : position == "middle" ? length / 2 : length
                view.setSelectedRange(NSRange(location: location, length: 0))
                reference.window.makeKeyAndOrderFront(nil)
                reference.window.makeFirstResponder(view)
                let undo = try XCTUnwrap(view.undoManager)
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                view.insertText("w", replacementRange: view.selectedRange())
                view.deleteBackward(nil)
                undo.endUndoGrouping()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(view.string, initial)
                expectedFonts[position] = try XCTUnwrap(view.typingAttributes[.font] as? NSFont).fontName
                undo.removeAllActions()
            }
            try await reference.workspace?.fixture.session.flush()
        }
        XCTAssertNotEqual(expectedFonts["start"], expectedFonts["end"], "The fixture must exercise distinct inline font runs")
        let configuration = try InputBenchmarkConfiguration(environment: ["PURLORY_INPUT_BENCHMARK_INSTRUMENTATION": "off"])
        for position in ["start", "middle", "end"] {
            for target in ["native", "workspace"] {
                let run = try await recordRun(fixture: fixture, position: position, trace: .latin,
                    timing: "immediate", target: target, repetition: 0, configuration: configuration)
                XCTAssertEqual(run.settings["font"], expectedFonts[position], "\(target) \(position) actual")
                XCTAssertEqual(run.referenceSettings["font"], expectedFonts[position], "\(target) \(position) reference")
                XCTAssertFalse(run.settingsDifferences.contains("font"), "\(target) \(position) matched font")
            }
        }
    }

    func testNativeComparatorMatchesWorkspaceNonContiguousLayout() async throws {
        let fixture = InputBenchmarkFixture(size: 1000, shape: .short, format: .plain)
        let workspace = try await InputBenchmarkHost.makeWorkspace(fixture: fixture)
        defer { workspace.close() }
        let native = InputBenchmarkHost.makeNative(matching: workspace.view)
        defer { native.close() }

        let workspaceLayout = try XCTUnwrap(workspace.view.layoutManager)
        let nativeLayout = try XCTUnwrap(native.view.layoutManager)
        XCTAssertEqual(nativeLayout.allowsNonContiguousLayout, workspaceLayout.allowsNonContiguousLayout)
        XCTAssertEqual(native.effectiveSettings["allowsNonContiguousLayout"], String(workspaceLayout.allowsNonContiguousLayout))
        XCTAssertEqual(workspace.effectiveSettings["allowsNonContiguousLayout"], String(workspaceLayout.allowsNonContiguousLayout))
        try await workspace.workspace?.fixture.session.flush()
    }

    private func prepare(_ host: InputBenchmarkHost, initial: String, location: Int,
                         timing: String) async throws -> (undo: UndoManager, idleDuration: Double) {
        let view = host.view
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        host.window.makeKeyAndOrderFront(nil)
        host.window.makeFirstResponder(view)
        host.window.displayIfNeeded() // Setup only. Never used in a measured burst.
        let undo = try XCTUnwrap(view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText("w", replacementRange: view.selectedRange())
        view.deleteBackward(nil)
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(100))
        guard view.string == initial else { throw InputBenchmarkError.integrity("warmup final text") }
        view.breakUndoCoalescing()
        undo.removeAllActions()
        let idleStart = ProcessInfo.processInfo.systemUptime
        if timing == "idle" { try await Task.sleep(for: .seconds(5)) }
        let idleDuration = ProcessInfo.processInfo.systemUptime - idleStart
        return (undo, idleDuration)
    }

    private func nativeComparator(fixture: InputBenchmarkFixture, position: String,
                                  timing: String) async throws -> (host: InputBenchmarkHost, referenceSettings: [String: String]) {
        let reference = try await InputBenchmarkHost.makeWorkspace(fixture: fixture)
        defer { reference.close() }
        let initial = reference.view.string
        let location = caretLocation(position, length: (initial as NSString).length)
        _ = try await prepare(reference, initial: initial, location: location, timing: timing)
        let settings = reference.effectiveSettings
        let native = InputBenchmarkHost.makeNative(matching: reference.view)
        do {
            try await reference.workspace?.fixture.session.flush()
            return (native, settings)
        } catch {
            native.close()
            throw error
        }
    }

    private func caretLocation(_ position: String, length: Int) -> Int {
        switch position {
        case "start": 0
        case "middle": length / 2
        default: length
        }
    }

    private func recordRun(fixture: InputBenchmarkFixture, position: String, trace: InputBenchmarkTrace,
                           timing: String, target: String, repetition: Int,
                           configuration: InputBenchmarkConfiguration) async throws -> InputBenchmarkRun {
        let host: InputBenchmarkHost
        let workspaceReference: [String: String]?
        if target == "native" {
            (host, workspaceReference) = try await nativeComparator(fixture: fixture, position: position, timing: timing)
        } else {
            host = try await InputBenchmarkHost.makeWorkspace(fixture: fixture)
            workspaceReference = nil
        }
        defer { host.close() }
        let view = host.view
        let initial = view.string
        let sourceBefore = (view as? BlockTextView)?.serialize()
        let length = (initial as NSString).length
        let location = caretLocation(position, length: length)
        let paragraph = (initial as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let (undo, idleDuration) = try await prepare(host, initial: initial, location: location, timing: timing)
        let expected = trace.expectedText(initial, location: location)
        let before = host.counters
        let visibilityBefore = host.visibility
        let settings = host.effectiveSettings
        let referenceSettings = workspaceReference ?? settings
        let recorder = configuration.instrumentation ? EditorInputTraceRecorder(signposts: configuration.signposts) : nil
        host.attach(recorder)
        let probe = InputBenchmarkProbe()
        var schedule: [InputBenchmarkRun.DispatchSample] = []
        undo.beginUndoGrouping()
        let started = ProcessInfo.processInfo.systemUptime
        for (sequence, action) in trace.actions.enumerated() {
            let requested = started + Double(sequence) * configuration.cadenceSeconds
            let delay = requested - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            let actual = ProcessInfo.processInfo.systemUptime
            // Input overrides cover insert/marked calls. These outer tokens identify other
            // synthetic operations and preserve nested insertText attribution.
            let kind: EditorInputTraceRecorder.OperationKind?
            switch action {
            case .newline: kind = .newline
            case .deleteBackward: kind = .deleteBackward
            case .left, .right: kind = .cursor
            case .replace: kind = .selectionReplacement
            case .paste: kind = .paste
            default: kind = nil
            }
            let token = kind.flatMap { recorder?.beginOperation(kind: $0, composing: view.hasMarkedText()) }
            InputBenchmarkTrace.perform(action, in: view)
            if let token { recorder?.endOperation(token) }
            schedule.append(.init(sequence: sequence, action: action, requested: requested,
                                  started: actual, ended: ProcessInfo.processInfo.systemUptime))
        }
        let ended = ProcessInfo.processInfo.systemUptime
        undo.endUndoGrouping()
        // Let the ordinary run loop observe draws, without forcing layout or display.
        try await Task.sleep(for: .milliseconds(250))
        let probes = await probe.stopAndDrain()
        let captured = recorder?.finish()
        host.attach(nil)
        let after = host.counters
        let visibilityAfter = host.visibility
        guard view.string == expected, !view.hasMarkedText() else { throw InputBenchmarkError.integrity("measured final text/composition") }
        let sourceAfter = (view as? BlockTextView)?.serialize()
        view.breakUndoCoalescing()
        guard undo.canUndo else { throw InputBenchmarkError.integrity("missing undo") }
        undo.undo()
        guard view.string == initial, (view as? BlockTextView)?.serialize() == sourceBefore else { throw InputBenchmarkError.integrity("undo") }
        guard undo.canRedo else { throw InputBenchmarkError.integrity("missing redo") }
        undo.redo()
        guard view.string == expected, (view as? BlockTextView)?.serialize() == sourceAfter else { throw InputBenchmarkError.integrity("redo") }
        if let workspace = host.workspace {
            let session = workspace.fixture.session
            guard session.selectedDocument?.source.string == sourceAfter else { throw InputBenchmarkError.integrity("binding") }
            try await session.flush()
            let project = try await workspace.fixture.store.load(id: workspace.fixture.project.id)
            guard project.documents.first(where: { $0.id == session.selectedDocumentID })?.source.string == sourceAfter
            else { throw InputBenchmarkError.integrity("workspace flush/reopen") }
        } else {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("input-benchmark-\(UUID()).txt")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(view.string.utf8).write(to: url, options: .withoutOverwriting)
            guard try String(contentsOf: url, encoding: .utf8) == expected else { throw InputBenchmarkError.integrity("native scratch reopen") }
        }
        let scenario = "\(fixture.metadata.utf16Count)-\(fixture.metadata.shape.rawValue)-\(fixture.metadata.format.rawValue)-\(position)-\(trace.rawValue)-\(timing)"
        return InputBenchmarkRun(scenarioID: scenario, runID: repetition, burstID: 0, target: target,
            fixture: fixture.metadata, position: position, activeParagraphUTF16Count: paragraph.length,
            initialRenderedUTF16Count: length, traceKind: trace, timing: timing, elapsedIdleSeconds: idleDuration,
            started: started, ended: ended, settings: settings, referenceSettings: referenceSettings,
            settingsDifferences: settings.keys.filter { settings[$0] != referenceSettings[$0] }.sorted(),
            scope: target == "workspace" ? ["host": "FramedWorkspaceHarness-ContentView", "writingMode": "general",
                "completion": "disabled-no-model", "diagnostics": "nil", "indexer": "instantiated-no-model",
                "outline": "workspace-default", "positionStore": "enabled", "autosaveDelayMilliseconds": "800",
                "livingMargin": "default-no-model", "chrome": "workspace-default", "instrumentation": String(configuration.instrumentation)]
                : ["host": "native-TextKit1-NSScrollView", "workspaceOwners": "none", "instrumentation": String(configuration.instrumentation)],
            visibilityBefore: visibilityBefore, visibilityAfter: visibilityAfter, countersBefore: before, countersAfter: after,
            integrity: ["finalText": "passed", "compositionEnded": "passed", "undo": "passed", "redo": "passed",
                        "saveReopen": target == "workspace" ? "projectSession-flush-projectStore-reload-passed" : "utf8-scratch-file-passed"],
            schedule: schedule, probes: probes, trace: captured, metrics: captured.map(InputBenchmarkMetrics.init),
            dispatchDurationSeconds: InputBenchmarkDistribution(schedule.map { $0.ended - $0.started }),
            syntheticSchedulingDelaySeconds: InputBenchmarkDistribution(schedule.map(\.schedulingDelay)),
            probeDelaySeconds: InputBenchmarkDistribution(probes.map { $0.executed - $0.posted }))
    }
}
