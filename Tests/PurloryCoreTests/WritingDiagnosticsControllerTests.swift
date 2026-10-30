@testable import PurloryIntelligence
import Foundation
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class WritingDiagnosticsControllerTests: XCTestCase {
    func test350msDebounceAndBoundedDirtyCoverage() async throws {
        for size in [100_000, 300_000] {
            let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
            let holder = SnapshotHolder(snapshot(text: String(repeating: "가", count: size)))
            let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
            bind(controller, holder.value)
            await clock.waitForSleep()
            await clock.advance(by: .milliseconds(349))
            let beforeDebounce = await provider.callCount
            XCTAssertEqual(beforeDebounce, 0)
            await clock.advance(by: .milliseconds(1))
            await provider.waitForCalls(1)
            await controller.waitForCurrentWork()
            XCTAssertTrue(controller.state.coverage.isComplete)
            let requests = await provider.requests
            XCTAssertTrue(requests.allSatisfy { $0.text.utf16.count <= 4096 })
            XCTAssertLessThanOrEqual(requests.count, 3, "Repeated unchanged windows are memoized")
            XCTAssertFalse(controller.state.findings.isEmpty)
            let resets = controller.projectionResetCount
            let before = holder.value, previousIDs = Set(controller.state.findings.filter { $0.sourceRanges[0].location > 4096 }.map(\.id))
            holder.value = snapshot(text: "나" + String(repeating: "가", count: size - 1), key: before.identity.key, generation: 2)
            controller.noteSnapshot(holder.value)
            controller.noteEditorCommit(.init(baseIdentity: before.identity, nativeRevision: 2,
                patch: .init(oldSourceRange: .init(location: 0, length: 2048), replacement: WritingProseProjection.blocks(source: "나" + String(repeating: "가", count: 2047))), markedRange: nil), snapshot: holder.value)
            XCTAssertEqual(controller.projectionResetCount, resets)
            XCTAssertLessThanOrEqual(controller.lastMutationSourceUTF16, 2048)
            XCTAssertLessThan(controller.lastMutationVisits, 150)
            XCTAssertTrue(previousIDs.isSubset(of: Set(controller.state.findings.map(\.id))))
            XCTAssertFalse(controller.state.findings.contains { $0.sourceRanges[0].location == 0 })
            await clock.waitForSleep(); await clock.advance(by: .milliseconds(350))
            await controller.waitForCurrentWork()
            XCTAssertTrue(controller.state.coverage.isComplete)
            controller.cancel()
        }
    }

    func testLateProviderAndLocalReportCannotPublishAcrossGenerations() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider(held: true)
        let a = snapshot(text: "old"), b = snapshot(text: "new")
        let holder = SnapshotHolder(a)
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, a); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await provider.waitForCalls(1)
        let old = controller.workTask
        holder.value = b; bind(controller, b)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await provider.waitForCalls(2)
        await provider.complete(1); await controller.waitForCurrentWork()
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime == b.identity })
        await provider.complete(0); await old?.value
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime == b.identity })
        holder.value = a; bind(controller, a)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await provider.waitForCalls(3)
        await provider.complete(2); await controller.waitForCurrentWork()
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime == a.identity })
        XCTAssertEqual(controller.state.findings.count, 1)
        controller.cancel()
    }

    func testProviderFailureIsNotClean() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider(fails: true)
        let holder = SnapshotHolder(snapshot(text: "실패한 구간"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350))
        await controller.waitForCurrentWork()
        XCTAssertEqual(controller.state.status, .unavailable)
        XCTAssertEqual(controller.state.availability, .unavailableProvider)
        XCTAssertTrue(controller.state.coverage.assessed.isEmpty)
        XCTAssertFalse(controller.state.coverage.isComplete)
        XCTAssertFalse(controller.state.coverage.dirty.isEmpty)
        XCTAssertTrue(controller.state.findings.isEmpty)
    }

    func testWindowMemoAndCacheEviction() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let holder = SnapshotHolder(snapshot(text: "동일한 문장"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let calls = await provider.callCount, old = holder.value
        holder.value = snapshot(text: old.body, key: old.identity.key, generation: 2, userData: ["unrelated": Data([1])])
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 1, patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: holder.value)
        await controller.waitForCurrentWork()
        let afterMetadata = await provider.callCount
        XCTAssertEqual(afterMetadata, calls)
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime == holder.value.identity })
        let metadata = holder.value
        holder.value = snapshot(text: metadata.body, key: metadata.identity.key, generation: 3)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: metadata.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: metadata.body.utf16.count), replacement: WritingProseProjection.blocks(source: metadata.body)), markedRange: nil), snapshot: holder.value)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let afterIdenticalWindow = await provider.callCount
        XCTAssertEqual(afterIdenticalWindow, calls)
        let cache = WritingDiagnosticsCache(budgetBytes: 4096)
        let first = WritingDiagnosticsCache.Key(digest: "a", languageTag: "ko", profileRevision: 1, providerRevision: "probe", ruleRevision: 1)
        let second = WritingDiagnosticsCache.Key(digest: "b", languageTag: "ko", profileRevision: 1, providerRevision: "probe", ruleRevision: 1)
        let text = String(repeating: "x", count: 1000)
        XCTAssertTrue(cache.insert([], text: text, for: first))
        XCTAssertTrue(cache.insert([], text: text, for: second))
        XCTAssertLessThanOrEqual(cache.costBytes, 4096)
        XCTAssertNil(cache.value(for: first, text: text))
        XCTAssertNotNil(cache.value(for: second, text: text))
        var changed = second; changed.ruleRevision = 2
        XCTAssertNil(cache.value(for: changed, text: text))
        controller.cancel()
    }

    func testCompositionForegroundEnergyAndPressurePreventAdmission() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let holder = SnapshotHolder(snapshot(text: "합성 입력"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        controller.setMarkedRange(.init(location: 0, length: 1)); controller.setForegroundBusy(true)
        controller.setEnergyPolicy(thermal: .serious, lowPower: true); controller.setMemoryPressure(.warning)
        bind(controller, holder.value)
        await clock.advance(by: .seconds(1))
        let blocked = await provider.callCount
        XCTAssertEqual(blocked, 0); XCTAssertEqual(controller.state.status, .paused)
        controller.setMarkedRange(nil); controller.setForegroundBusy(false)
        controller.setEnergyPolicy(thermal: .nominal, lowPower: false)
        await clock.advance(by: .seconds(1))
        let stillBlocked = await provider.callCount
        XCTAssertEqual(stillBlocked, 0)
        controller.setMemoryPressure(.normal)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let admitted = await provider.callCount
        XCTAssertEqual(admitted, 1); XCTAssertTrue(controller.state.coverage.isComplete)
        let before = holder.value
        holder.value = snapshot(text: "새 합성 입력", key: before.identity.key, generation: 2)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: before.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: before.body.utf16.count), replacement: WritingProseProjection.blocks(source: holder.value.body)), markedRange: nil), snapshot: holder.value)
        let pending = controller.workTask
        controller.setForegroundBusy(true); await pending?.value
        await clock.advance(by: .seconds(1))
        let whileTyping = await provider.callCount
        XCTAssertEqual(whileTyping, admitted)
        controller.setForegroundBusy(false)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        XCTAssertTrue(controller.state.coverage.isComplete)
        controller.setMemoryPressure(.critical)
        XCTAssertEqual(controller.cacheCostBytes, 0); XCTAssertTrue(controller.state.findings.isEmpty)
        XCTAssertEqual(holder.value.body, "새 합성 입력")
        controller.cancel()
    }

    func testResultBudgetIsPartialAndAllTextDeletionCanComplete() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let holder = SnapshotHolder(snapshot(text: "본문"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock,
            currentSnapshot: { holder.value }, findingBudgetBytes: 1)
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.state.status, .partial)
        XCTAssertFalse(controller.state.coverage.isComplete); XCTAssertTrue(controller.state.coverage.assessed.isEmpty)
        XCTAssertTrue(controller.state.findings.isEmpty)
        let old = holder.value
        holder.value = snapshot(text: "", key: old.identity.key, generation: 2)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: old.body.utf16.count), replacement: []), markedRange: nil), snapshot: holder.value)
        XCTAssertEqual(controller.state.status, .idle)
        XCTAssertTrue(controller.state.coverage.isComplete, "No eligible prose remains unassessed")
    }

    func testProfileRevisionsAndUnreadableOrUnsupportedSettingsCannotReuseCleanHealth() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let holder = SnapshotHolder(snapshot(text: "본문"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let old = holder.value, oldRevision = try XCTUnwrap(controller.state.findings.first?.stamp.profileRevision)
        let profile = WritingStyleRecord(profile: WritingStyleProfile(ignoredRuleIDs: ["synthetic"]))
        holder.value = snapshot(text: old.body, key: old.identity.key, generation: 2, userData: [WritingStyleRepository.key: try JSONEncoder().encode(profile)])
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 1, patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: holder.value)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let afterProfile = await provider.callCount
        XCTAssertEqual(afterProfile, 2); XCTAssertTrue(controller.state.findings.isEmpty); XCTAssertTrue(controller.state.coverage.isComplete)
        XCTAssertGreaterThan(oldRevision, 0)
        let prior = holder.value, bytes = Data("{invalid-profile".utf8)
        holder.value = snapshot(text: prior.body, key: prior.identity.key, generation: 3, userData: [WritingStyleRepository.key: bytes])
        controller.noteSnapshot(holder.value)
        XCTAssertEqual(controller.state.availability, .unavailableProfile)
        XCTAssertFalse(controller.state.coverage.isComplete); XCTAssertEqual(holder.value.userData[WritingStyleRepository.key], bytes)
        var unsupported = WritingStyleRecord(); unsupported.languageTag = "en"
        holder.value = snapshot(text: prior.body, key: prior.identity.key, generation: 4, userData: [WritingStyleRepository.key: try JSONEncoder().encode(unsupported)])
        controller.noteSnapshot(holder.value)
        XCTAssertEqual(controller.state.availability, .unsupportedLanguage)
        XCTAssertFalse(controller.state.coverage.isComplete)
        controller.cancel()
    }

    func testMappedEvidenceAndDuplicateOccurrenceIDsStayDistinct() async throws {
        let clock = ManualDiagnosticsClock()
        let provider = ControlledWritingProvider(makeDiagnostics: { request in
            let ns = request.text as NSString
            let first = ns.range(of: "가"), second = ns.range(of: "가", range: NSRange(location: first.upperBound, length: ns.length - first.upperBound))
            return [first, second].enumerated().map { index, range in
                .init(id: "duplicate-\(index)", ruleID: "synthetic", providerID: "probe", category: .style, kind: .repeatedWord,
                      severity: .suggestion, range: .init(range), relatedRanges: [.init(ns.range(of: "😀"))], message: "Synthetic duplicate", languageTag: "ko")
            }
        })
        let holder = SnapshotHolder(snapshot(text: "**가** 😀 가"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let values = controller.state.findings
        XCTAssertEqual(values.count, 2); XCTAssertEqual(Set(values.map(\.id)).count, 2)
        XCTAssertEqual(values.map(\.evidence.quote), ["가", "가"])
        XCTAssertEqual(values.map { $0.sourceRanges[0].location }, [2, 9])
        XCTAssertTrue(values.allSatisfy { $0.relatedSourceRanges == [[.init(location: 6, length: 2)]] })
        controller.cancel()
    }

    func testFailedReanalysisCannotKeepOldContextAssessed() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let holder = SnapshotHolder(snapshot(text: String(repeating: "가", count: 10_000)))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        XCTAssertTrue(controller.state.coverage.isComplete)
        await provider.setFailure(true)
        let old = holder.value
        holder.value = snapshot(text: "나" + String(repeating: "가", count: 9999), key: old.identity.key, generation: 2)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: 2048), replacement: WritingProseProjection.blocks(source: "나" + String(repeating: "가", count: 2047))), markedRange: nil), snapshot: holder.value)
        XCTAssertFalse(controller.state.coverage.assessed.contains { NSIntersectionRange($0.nsRange, NSRange(location: 0, length: 4096)).length > 0 }, "Changed context loses its previous assessment immediately")
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        XCTAssertFalse(controller.state.coverage.assessed.contains { NSIntersectionRange($0.nsRange, NSRange(location: 0, length: 4096)).length > 0 })
        XCTAssertFalse(controller.state.coverage.isComplete)
        controller.cancel()
    }

    func testUnchangedOccurrenceIDsAndAnchorsMoveThroughPrefixInsertion() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let holder = SnapshotHolder(snapshot(text: String(repeating: "가", count: 10_000)))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        let prior = controller.state.findings.filter { $0.sourceRanges[0].location > 4096 }, old = holder.value
        XCTAssertFalse(prior.isEmpty)
        holder.value = snapshot(text: "나" + old.body, key: old.identity.key, generation: 2)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: 2048), replacement: WritingProseProjection.blocks(source: "나" + String(repeating: "가", count: 2048))), markedRange: nil), snapshot: holder.value)
        for finding in prior {
            let shifted = try XCTUnwrap(controller.state.findings.first { $0.id == finding.id })
            XCTAssertEqual(shifted.sourceRanges[0].location, finding.sourceRanges[0].location + 1)
            XCTAssertEqual(shifted.evidence.utf16Hint, finding.evidence.utf16Hint.map { $0 + 1 })
            XCTAssertEqual(shifted.stamp.runtime, holder.value.identity)
            XCTAssertEqual(shifted.stamp.nativeRevision, 2)
        }
        controller.cancel()
    }

    func testInterruptedScanRetainsCompletedCoverageWithoutDirtyingItAgain() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider(held: true)
        let holder = SnapshotHolder(snapshot(text: String(repeating: "가", count: 4096) + String(repeating: "나", count: 4096)))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await provider.waitForCalls(1)
        let task = controller.workTask
        await provider.complete(0); await provider.waitForCalls(2)
        XCTAssertEqual(controller.state.coverage.assessed.first, .init(location: 0, length: 4096))
        XCTAssertTrue(controller.state.coverage.dirty.allSatisfy { $0.location >= 4096 }, "Completed windows stop being dirty before the next await")
        controller.setForegroundBusy(true)
        await provider.complete(1); await task?.value
        XCTAssertEqual(controller.state.coverage.assessed.first, .init(location: 0, length: 4096))
        XCTAssertTrue(controller.state.coverage.dirty.allSatisfy { $0.location >= 4096 })
        XCTAssertFalse(controller.state.coverage.isComplete)
        controller.cancel()
    }

    func testIntentionalSuppressionRequiresVerifiedLoadSourceRevision() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider()
        let source = snapshot(text: "본문")
        var record = WritingStyleRecord()
        record.intentionalOccurrences = [try WritingStyleRepository.captureIntentional(ruleID: "synthetic", range: .init(location: 0, length: 1), in: source)]
        let bytes = try JSONEncoder().encode(record)
        let holder = SnapshotHolder(snapshot(text: source.body, key: source.identity.key, generation: 2, userData: [WritingStyleRepository.key: bytes]))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        XCTAssertTrue(controller.state.findings.isEmpty); XCTAssertTrue(controller.state.coverage.isComplete)
        let old = holder.value
        holder.value = snapshot(text: "본안", key: old.identity.key, generation: 3, userData: old.userData)
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 2,
            patch: .init(oldSourceRange: .init(location: 0, length: old.body.utf16.count), replacement: WritingProseProjection.blocks(source: holder.value.body)), markedRange: nil), snapshot: holder.value)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.state.findings.count, 1, "An unverified new source revision cannot inherit occurrence suppression")
        XCTAssertEqual(holder.value.userData[WritingStyleRepository.key], bytes)
        controller.cancel()
    }

    func testLRUHitPromotesItsEntryBeforeEviction() {
        let cache = WritingDiagnosticsCache(budgetBytes: 7000), text = String(repeating: "x", count: 1000)
        let first = WritingDiagnosticsCache.Key(digest: "a", languageTag: "ko", profileRevision: 1, providerRevision: "probe", ruleRevision: 1)
        var second = first; second.digest = "b"
        var third = first; third.digest = "c"
        XCTAssertTrue(cache.insert([], text: text, for: first)); XCTAssertTrue(cache.insert([], text: text, for: second))
        XCTAssertNotNil(cache.value(for: first, text: text))
        XCTAssertTrue(cache.insert([], text: text, for: third))
        XCTAssertNil(cache.value(for: second, text: text)); XCTAssertNotNil(cache.value(for: first, text: text)); XCTAssertNotNil(cache.value(for: third, text: text))
        XCTAssertLessThanOrEqual(cache.costBytes, 7000)
        cache.clear(); XCTAssertEqual(cache.costBytes, 0); XCTAssertEqual(cache.count, 0)
    }

    func testHeldProviderCannotPublishAcrossMetadataOnlyGenerationChange() async throws {
        let clock = ManualDiagnosticsClock(), provider = ControlledWritingProvider(held: true)
        let holder = SnapshotHolder(snapshot(text: "본문"))
        let controller = WritingDiagnosticsController(engine: WritingDiagnosticsEngine(providers: [provider]), clock: clock, currentSnapshot: { holder.value })
        bind(controller, holder.value); await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await provider.waitForCalls(1)
        let task = controller.workTask, old = holder.value
        holder.value = snapshot(text: old.body, key: old.identity.key, generation: 2, userData: ["unrelated": Data([2])])
        controller.noteSnapshot(holder.value)
        controller.noteEditorCommit(.init(baseIdentity: old.identity, nativeRevision: 1,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: holder.value)
        await clock.waitForSleep(); await clock.advance(by: .milliseconds(350)); await provider.waitForCalls(2)
        await provider.complete(1); await controller.waitForCurrentWork()
        XCTAssertEqual(controller.state.findings.count, 1)
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime == holder.value.identity && $0.stamp.nativeRevision == 1 })
        await provider.complete(0); await task?.value
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime == holder.value.identity })
        let current = holder.value
        holder.value = snapshot(text: "새 본문", key: current.identity.key, generation: 3, userData: current.userData)
        controller.noteSnapshot(holder.value)
        await clock.advance(by: .seconds(1))
        let count = await provider.callCount
        XCTAssertEqual(count, 2, "A source snapshot without a proved native commit cannot start analysis")
        XCTAssertFalse(controller.state.coverage.isComplete)
        XCTAssertTrue(controller.state.findings.allSatisfy { $0.stamp.runtime != holder.value.identity })
        controller.cancel()
    }

    private func snapshot(text: String, key: ProjectDocumentKey? = nil, generation: UInt64 = 1, userData: [String: Data] = [:]) -> ProjectDocumentSnapshot {
        .init(identity: .init(key: key ?? .init(projectID: WritingProjectID(), documentID: WritingDocumentID()), generation: generation), title: "Synthetic diagnostics", body: text, kind: .manuscript, mode: .general, userData: userData)
    }
    private func bind(_ controller: WritingDiagnosticsController, _ snapshot: ProjectDocumentSnapshot) {
        controller.noteSnapshot(snapshot)
        controller.noteEditorCommit(.init(baseIdentity: snapshot.identity, nativeRevision: 1,
            patch: .init(oldSourceRange: .init(location: 0, length: 0), replacement: []), markedRange: nil), snapshot: snapshot)
    }
    private final class SnapshotHolder { var value: ProjectDocumentSnapshot; init(_ value: ProjectDocumentSnapshot) { self.value = value } }
}

actor ManualDiagnosticsClock: WritingDiagnosticsClock {
    private var now: Duration = .zero
    private var sleepers: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var sleepSerial = 0, observedSleep = 0
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (now + duration, continuation)
                sleepSerial += 1
                let current = observers; observers.removeAll(); current.forEach { $0.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    func waitForSleep() async {
        if sleepers.isEmpty || sleepSerial == observedSleep { await withCheckedContinuation { observers.append($0) } }
        observedSleep = sleepSerial
    }
    func advance(by duration: Duration) {
        now += duration
        let ready = sleepers.filter { $0.value.0 <= now }
        for (id, value) in ready { sleepers.removeValue(forKey: id); value.1.resume() }
    }
}

private actor ControlledWritingProvider: WritingDiagnosticsProvider {
    nonisolated let id = "probe"
    let held: Bool; var fails: Bool
    let makeDiagnostics: (@Sendable (WritingDiagnosticsRequest) -> [WritingDiagnostic])?
    var requests: [WritingDiagnosticsRequest] = []
    var callCount: Int { requests.count }
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    init(held: Bool = false, fails: Bool = false, makeDiagnostics: (@Sendable (WritingDiagnosticsRequest) -> [WritingDiagnostic])? = nil) {
        self.held = held; self.fails = fails; self.makeDiagnostics = makeDiagnostics
    }
    func analyze(_ request: WritingDiagnosticsRequest) async throws -> [WritingDiagnostic] {
        let index = requests.count; requests.append(request)
        if held { await withCheckedContinuation { pending[index] = $0; notify() } } else { notify() }
        if fails { throw SyntheticFailure() }
        if let makeDiagnostics { return makeDiagnostics(request) }
        return [.init(id: "probe", ruleID: "synthetic", providerID: id, category: .style, kind: .repeatedWord, severity: .suggestion,
                      range: .init(location: 0, length: 1), message: "Synthetic finding", languageTag: "ko")]
    }
    func setFailure(_ value: Bool) { fails = value }
    func complete(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func waitForCalls(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    private func notify() {
        let ready = observers.filter { requests.count >= $0.0 }
        observers.removeAll { requests.count >= $0.0 }; ready.forEach { $0.1.resume() }
    }
    private struct SyntheticFailure: Error { }
}
