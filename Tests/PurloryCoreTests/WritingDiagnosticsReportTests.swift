@testable import PurloryIntelligence
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI
@testable import PurloryKoreanBackend

@MainActor
final class WritingDiagnosticsReportTests: XCTestCase {
    func testFrozenProjectionCachesEligibleTotalsAndOriginalMapping() throws {
        let index = WritingProjectionIndex()
        index.reset(source: "**한글** 😀")
        let frozen = index.freeze()
        XCTAssertEqual(frozen.eligibleProseLength, 5)
        XCTAssertEqual(frozen.sourceLength, 9)
        XCTAssertEqual(frozen.sourceRanges(forProse: .init(location: 0, length: 2)), [.init(location: 2, length: 2)])
        XCTAssertEqual(frozen.sourceText(in: .init(location: 2, length: 2)), "한글")
        XCTAssertTrue(index.apply(.init(oldSourceRange: .init(location: 0, length: 9), replacement: WritingProseProjection.blocks(source: "새 본문"))))
        XCTAssertEqual(index.eligibleProseLength, 4)
        XCTAssertEqual(frozen.eligibleProseLength, 5)
        XCTAssertEqual(frozen.sourceText(in: .init(location: 2, length: 2)), "한글")
    }

    func testReportProgressCancelAndLateLocalRace() async throws {
        let holder = WritingReportSnapshotHolder(WritingReportSnapshotHolder.snapshot(
            "# 합성 원고\n" + String(repeating: "그 사람은 걸었다. 그 사람은 웃었다. 그 사람은 떠났다.\n", count: 150)
            + "```\n코드는 검사하지 않는다.\n```\n![합성 그림](image.png)\n"))
        let runtime = WritingDiagnosticsRuntime(observeEnergy: false)
        runtime.configure(currentSnapshot: { holder.value })
        runtime.controller.noteSnapshot(holder.value)
        let localBefore = runtime.controller.state.findings.map(\.id)
        let report = runtime.controller.scanDocument(holder.value)
        var progress: [Int] = [], total: Int?, findings: [WritingDiagnosticsFinding] = [], finished: WritingDiagnosticsCoverage?
        for await event in report {
            XCTAssertEqual(event.runtime, holder.value.identity)
            switch event.kind {
            case .progress(let completed, let expected):
                progress.append(completed); total = expected
            case .findings(let values): findings += values
            case .finished(let coverage): finished = coverage
            case .cancelled: XCTFail("Report unexpectedly cancelled")
            case .failed(let reason): XCTFail("Report failed: \(reason)")
            }
        }
        XCTAssertFalse(progress.isEmpty); XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(progress.last, total)
        XCTAssertEqual(finished?.isComplete, true)
        XCTAssertEqual(finished?.assessed.reduce(0) { $0 + $1.length }, total)
        XCTAssertFalse(findings.isEmpty)
        XCTAssertEqual(Set(findings.map(\.id)).count, findings.count)
        XCTAssertEqual(runtime.controller.state.findings.map(\.id), localBefore, "A report cannot overwrite local state")
        for value in findings {
            let source = holder.value.body as NSString
            let range = NSRange(location: value.evidence.utf16Hint ?? -1, length: value.evidence.quote.utf16.count)
            XCTAssertEqual(Array(source.substring(with: range).utf16), Array(value.evidence.quote.utf16))
        }
        let cancel = runtime.controller.scanDocument(holder.value)
        var terminal = false
        for await event in cancel {
            if case .progress = event.kind { cancel.cancel() }
            if case .cancelled = event.kind { terminal = true }
        }
        XCTAssertTrue(terminal)
        await runtime.prepareForTermination()
    }

    func testLongIntentionalOccurrenceUsesExactOwnedSourceAndBoundedEvidence() async throws {
        let body = String(repeating: "가", count: 9000) + "."
        let source = WritingReportSnapshotHolder.snapshot(body)
        var style = WritingStyleRecord()
        style.intentionalOccurrences = [try WritingStyleRepository.captureIntentional(ruleID: "ko.style.sentence-length", range: .init(location: 0, length: body.utf16.count), in: source)]
        let bytes = try JSONEncoder().encode(style)
        let original = ProjectDocumentSnapshot(identity: source.identity, title: source.title, body: body,
            kind: .manuscript, mode: .general, userData: [WritingStyleRepository.key: bytes])
        let holder = WritingReportSnapshotHolder(original), gate = WritingReportNativeGate(blockFirst: false)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let runtime = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        runtime.configure(currentSnapshot: { holder.value }); runtime.controller.noteSnapshot(holder.value)
        var findings: [WritingDiagnosticsFinding] = []
        for await event in runtime.controller.scanDocument(holder.value) {
            if case .findings(let values) = event.kind { findings += values }
        }
        XCTAssertFalse(findings.contains { $0.diagnostic.kind == .sentenceLength }, "The full owned intentional occurrence is suppressed even when its displayed evidence is bounded")
        holder.value = ProjectDocumentSnapshot(identity: .init(key: original.identity.key, generation: 2), title: original.title,
            body: String(repeating: "가", count: 9000) + "!", kind: .manuscript, mode: .general, userData: original.userData)
        runtime.controller.noteSnapshot(holder.value)
        findings.removeAll()
        for await event in runtime.controller.scanDocument(holder.value) {
            if case .findings(let values) = event.kind { findings += values }
        }
        let length = try XCTUnwrap(findings.first { $0.diagnostic.kind == .sentenceLength })
        XCTAssertEqual(length.sourceRanges.reduce(0) { $0 + $1.length }, 9001)
        XCTAssertLessThanOrEqual(length.evidence.quote.utf16.count, 2048)
        XCTAssertEqual(holder.value.userData[WritingStyleRepository.key], bytes)
        await runtime.prepareForTermination()
    }

    func testCancelledPreparationAndFragmentedCoverageStayBounded() async throws {
        let source = String(repeating: "가\n", count: 150_000)
        let admission = WritingProjectionAdmission(limit: 8)
        XCTAssertThrowsError(try WritingProjectionSnapshot.prepare(source: source, admission: { admission.allow() }))
        XCTAssertLessThan(admission.calls, 20, "Cancelled projection preparation stops visiting source")
        let formatted = String(repeating: "**가** ", count: 1000), prose = String(repeating: "가 ", count: 1000)
        let projection = try WritingProjectionSnapshot.prepare(source: formatted)
        let identity = WritingReportSnapshotHolder.snapshot(formatted).identity
        let mapper = WritingReportMapper(projection: projection, prose: prose, sourceRevision: "synthetic", profile: WritingStyleRecord(),
            identity: identity, profileRevision: 1, providerRevision: "probe", ruleRevision: 1, coverageBudgetBytes: 128)
        _ = try await mapper.consume(.init(diagnostics: [], assessedRange: .init(location: 0, length: prose.utf16.count), totalProseUTF16: prose.utf16.count, unsupportedRanges: []))
        let coverage = await mapper.finish()
        XCTAssertFalse(coverage.isComplete)
        XCTAssertLessThanOrEqual(coverage.assessed.count * 64, 128)
        XCTAssertLessThanOrEqual(coverage.dirty.count, 1, "Budget overflow cannot turn into an unbounded dirty-range array")
        XCTAssertFalse(coverage.dirty.isEmpty)
        let unsupportedMapper = WritingReportMapper(projection: projection, prose: prose, sourceRevision: "synthetic", profile: WritingStyleRecord(),
            identity: identity, profileRevision: 1, providerRevision: "probe", ruleRevision: 1, coverageBudgetBytes: 128)
        let unsupported = stride(from: 0, to: prose.utf16.count, by: 4).map { WritingDiagnosticRange(location: $0, length: 1) }
        _ = try await unsupportedMapper.consume(.init(diagnostics: [], assessedRange: .init(location: 0, length: prose.utf16.count),
            totalProseUTF16: prose.utf16.count, unsupportedRanges: unsupported))
        let incomplete = await unsupportedMapper.finish()
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertLessThanOrEqual(incomplete.unsupported.count, 1)
    }

    func testLateReportCannotReplaceNewProjectLocalFindings() async throws {
        let gate = WritingReportNativeGate(blockFirst: true), clock = ManualDiagnosticsClock()
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let runtime = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false, clock: clock)
        let holder = WritingReportSnapshotHolder(WritingReportSnapshotHolder.snapshot(String(repeating: "합성 문장. ", count: 1000)))
        runtime.configure(currentSnapshot: { holder.value }); runtime.controller.noteSnapshot(holder.value)
        let report = runtime.controller.scanDocument(holder.value)
        let consumer = Task { var events: [WritingDiagnosticsReportEvent] = []; for await event in report { events.append(event) }; return events }
        await fulfillment(of: [gate.started], timeout: 3)
        holder.value = WritingReportSnapshotHolder.snapshot(String(repeating: "나", count: 200))
        runtime.controller.noteSnapshot(holder.value)
        runtime.controller.noteEditorCommit(.init(baseIdentity: holder.value.identity, nativeRevision: 1,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: holder.value)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350))
        let current = runtime.controller.workTask
        gate.allow.signal(); await current?.value; await report.waitForCompletion()
        let events = await consumer.value
        XCTAssertTrue(events.contains { if case .cancelled = $0.kind { return true }; return false })
        XCTAssertFalse(events.contains { if case .findings = $0.kind { return true }; return false })
        XCTAssertEqual(runtime.controller.state.findings.count, 1)
        XCTAssertTrue(runtime.controller.state.findings.allSatisfy { $0.stamp.runtime == holder.value.identity })
        await runtime.prepareForTermination()
    }

    func testFindingBudgetIncludesFragmentedPrimaryAndRelatedSourceRanges() async throws {
        let source = String(repeating: "**가** ", count: 1000), prose = String(repeating: "가 ", count: 1000)
        let projection = try WritingProjectionSnapshot.prepare(source: source)
        let identity = WritingReportSnapshotHolder.snapshot(source).identity
        let mapper = WritingReportMapper(projection: projection, prose: prose, sourceRevision: "synthetic", profile: WritingStyleRecord(),
            identity: identity, profileRevision: 1, providerRevision: "probe", ruleRevision: 1, findingBudgetBytes: 4096)
        let diagnostic = WritingDiagnostic(id: "synthetic", ruleID: "fixture", providerID: "probe", category: .style, kind: .sentenceLength,
            severity: .suggestion, range: .init(location: 0, length: prose.utf16.count), relatedRanges: [.init(location: 0, length: prose.utf16.count)],
            message: "Synthetic mapped-range budget fixture", languageTag: "ko")
        let update = try await mapper.consume(.init(diagnostics: [diagnostic], assessedRange: .init(location: 0, length: prose.utf16.count),
            totalProseUTF16: prose.utf16.count, unsupportedRanges: []))
        XCTAssertTrue(update.findings.isEmpty, "Mapped source arrays are part of the packet budget")
        let coverage = await mapper.finish()
        XCTAssertFalse(coverage.isComplete)
    }

    func testSlowConsumerAndConsumerTerminationStopFurtherAdmission() async throws {
        let gate = WritingReportNativeGate(blockFirst: true)
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let runtime = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        let holder = WritingReportSnapshotHolder(WritingReportSnapshotHolder.snapshot(String(repeating: "합성 문장을 쓴다. ", count: 1000)))
        runtime.configure(currentSnapshot: { holder.value }); runtime.controller.noteSnapshot(holder.value)
        let report = runtime.controller.scanDocument(holder.value)
        var iterator: WritingDiagnosticsReport.AsyncIterator? = report.makeAsyncIterator()
        _ = await iterator?.next()
        await fulfillment(of: [gate.started], timeout: 3)
        gate.allow.signal()
        await report.waitForBufferedEvent()
        let queued = await report.bufferedEventCount
        XCTAssertLessThanOrEqual(queued, 1)
        let admitted = gate.counts.analyzed
        iterator = nil
        await report.waitForCompletion()
        XCTAssertEqual(gate.counts.analyzed, admitted, "No next native slice/window after a slow consumer disappears")
        XCTAssertEqual(runtime.controller.state.findings.count, 0)
        await runtime.prepareForTermination()
        XCTAssertEqual(gate.counts.closed, 1)
    }

    func testForegroundThermalAndLowPowerStopAdmission() async throws {
        let gate = WritingReportNativeGate(blockFirst: false)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let runtime = WritingDiagnosticsRuntime(worker: worker, observeEnergy: false)
        let holder = WritingReportSnapshotHolder(WritingReportSnapshotHolder.snapshot("합성 문장"))
        runtime.configure(currentSnapshot: { holder.value }); runtime.controller.noteSnapshot(holder.value)
        runtime.setForegroundBusy(true)
        for await event in runtime.controller.scanDocument(holder.value) {
            if case .failed(let reason) = event.kind { XCTAssertEqual(reason, .pausedPolicy) }
        }
        XCTAssertEqual(gate.counts.analyzed, 0)
        runtime.setForegroundBusy(false); runtime.setEnergyPolicy(thermal: .serious, lowPower: false)
        for await _ in runtime.controller.scanDocument(holder.value) { }
        XCTAssertEqual(gate.counts.analyzed, 0)
        runtime.setEnergyPolicy(thermal: .nominal, lowPower: true)
        for await _ in runtime.controller.scanDocument(holder.value) { }
        XCTAssertEqual(gate.counts.analyzed, 0)
        runtime.setEnergyPolicy(thermal: .nominal, lowPower: false)
        let report = runtime.controller.scanDocument(holder.value)
        var iterator = report.makeAsyncIterator()
        _ = await iterator.next()
        runtime.setForegroundBusy(true)
        await report.waitForCompletion()
        let before = gate.counts.analyzed
        for await _ in report { }
        XCTAssertEqual(gate.counts.analyzed, before)
        await runtime.prepareForTermination()
    }
}

@MainActor
final class WritingReportSnapshotHolder {
    var value: ProjectDocumentSnapshot
    init(_ value: ProjectDocumentSnapshot) { self.value = value }
    static func snapshot(_ body: String, key: ProjectDocumentKey? = nil, generation: UInt64 = 1) -> ProjectDocumentSnapshot {
        .init(identity: .init(key: key ?? .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: generation),
              title: "Synthetic report", body: body, kind: .manuscript, mode: .general)
    }
}

final class WritingReportNativeGate: KoreanNativeFactory, @unchecked Sendable {
    struct Counts { var opened = 0; var analyzed = 0; var closed = 0; var usedMainThread = false }
    let started = XCTestExpectation(description: "Native report call entered")
    let allow = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value = Counts()
    private let blockFirst: Bool
    init(blockFirst: Bool) { self.blockFirst = blockFirst }
    var counts: Counts { lock.withLock { value } }
    func open(resources: URL, admission: @Sendable () -> Bool) throws -> any KoreanNativeHandle {
        guard admission() else { throw KoreanNativeError.cancelled }
        lock.withLock { value.opened += 1 }
        return WritingReportNativeHandle(gate: self)
    }
    func analyze(_ text: String) -> KoreanNativeAnalysis {
        let first = lock.withLock { value.analyzed += 1; value.usedMainThread = value.usedMainThread || Thread.isMainThread; return value.analyzed == 1 }
        if first && blockFirst { started.fulfill(); allow.wait() }
        return .init(tokens: [], sentences: [], candidates: [])
    }
    func close() { lock.withLock { value.closed += 1 } }
}
private final class WritingReportNativeHandle: KoreanNativeHandle {
    let gate: WritingReportNativeGate
    init(gate: WritingReportNativeGate) { self.gate = gate }
    func analyze(_ text: String, admission: @Sendable () -> Bool) throws -> KoreanNativeAnalysis {
        guard admission() else { throw KoreanNativeError.cancelled }; return gate.analyze(text)
    }
    func close() { gate.close() }
}

private final class WritingProjectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }
    var calls: Int { lock.withLock { count } }
    func allow() -> Bool { lock.withLock { count += 1; return count <= limit } }
}
