@_spi(Benchmark) @testable import PurloryInference
import Combine
import XCTest
@testable import PurloryCore

@MainActor
final class ContinuityJudgeControllerTests: XCTestCase {
    private func candidate(_ session: ProjectSession) throws -> ContinuityCandidate {
        let actor = CharacterCard(name: "민준"), document = try XCTUnwrap(session.selectedDocumentSnapshot)
        let scope = StoryMemoryScope.project(projectID: document.identity.key.projectID, documentID: document.identity.key.documentID)
        let time = StoryInterval.point(.init(timelineID: UUID(), tick: 1))
        let quotes = ["민준은 서울에 있었다.", "민준은 부산에 있었다."]
        let facts = quotes.enumerated().map { index, quote in
            let start = (document.body as NSString).range(of: quote).location
            return StoryFact(derivedID: "location-\(index)", scope: scope,
                content: .characterState(.init(characterID: actor.id, field: .location, value: index == 0 ? "서울" : "부산")),
                evidence: .init(documentID: scope.documentID, quote: quote, utf16Hint: start),
                discourseRange: start..<(start + quote.utf16.count), storyInterval: time, confidence: 0.9, origin: .deterministic(ruleID: "fixture"))
        }
        let snapshot = StoryKnowledgeSnapshot(scope: scope, source: document.body, facts: facts, entities: .init(characters: [actor]))
        return try XCTUnwrap(ContinuityCandidate.prepare(snapshot: snapshot, before: document.body.utf16.count).first)
    }
    private func fixture() async throws -> LegacyBoundaryFixture {
        let f = try await LegacyBoundaryFixture(mode: .fiction)
        f.session.updateSelectedDocumentBody("민준은 서울에 있었다.\n민준은 부산에 있었다.\n")
        return f
    }
    private func response(_ packet: JudgeEvidencePacket, verdict: String = "conflict", confidence: Double = 0.9) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["packet": packet.id.uuidString, "verdict": verdict, "confidence": confidence,
            "explanation": "원문을 함께 확인해 보세요.", "citations": [1, 2]]), as: UTF8.self)
    }

    func testExplicitRequestPublishesOnlyCompleteGroundedConflictWithoutWriterMutation() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let before = f.session.activeProject
        var calls = 0
        let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true) { packet in
            calls += 1; let raw = try self.response(packet)
            return AskAnswerGeneration { emit in try emit(String(raw.prefix(37))); try emit(String(raw.dropFirst(37))) }
        }
        defer { model.dismiss() }
        XCTAssertEqual(calls, 0)
        let done = expectation(description: "Complete cited proposal")
        let sub = model.$status.filter { $0 == .needsReview }.prefix(1).sink { _ in done.fulfill() }
        model.judge(candidate: try candidate(f.session))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 1); XCTAssertTrue(try XCTUnwrap(model.decision).visibleConflict)
        XCTAssertEqual(model.decision?.evidence.count, 2); XCTAssertEqual(f.session.activeProject, before)
        withExtendedLifetime(sub) {}
    }

    func testQuietVerdictsLowConfidenceAndMalformedTrailingDataNeverPublishConflict() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        for output in ["noConflict", "intentionalPossible", "insufficientEvidence", "low", "malformed", "overflow"] {
            let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true) { packet in
                var raw = try self.response(packet, verdict: output == "low" ? "conflict" : (["malformed", "overflow"].contains(output) ? "conflict" : output), confidence: output == "low" ? 0.79 : 0.9)
                if output == "malformed" { raw += "trailing" }
                if output == "overflow" { raw = String(repeating: "x", count: 4097) }
                let value = raw
                return AskAnswerGeneration { emit in try emit(value) }
            }
            let finished = expectation(description: "Quiet terminal \(output)")
            let sub = model.$status.filter { $0 == .quiet || $0 == .failed }.prefix(1).sink { _ in finished.fulfill() }
            model.judge(candidate: try candidate(f.session))
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertNil(model.decision, output)
            model.dismiss(); withExtendedLifetime(sub) {}
        }
    }

    func testNewRequestWaitsForActualOldProducerDrainAndGetsFreshNonce() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let started = expectation(description: "First producer"), cancelled = expectation(description: "First producer cancelled")
        let pause = AskTestPause(started, cancelled: cancelled)
        var packets: [UUID] = []
        let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true) { packet in
            packets.append(packet.id)
            if packets.count == 1 { return AskAnswerGeneration { emit in await pause.run(emit: emit) } }
            let raw = try self.response(packet)
            return AskAnswerGeneration { emit in try emit(raw) }
        }
        defer { model.dismiss() }
        let candidate = try candidate(f.session)
        model.judge(candidate: candidate); await fulfillment(of: [started], timeout: 2)
        model.judge(candidate: candidate); await fulfillment(of: [cancelled], timeout: 2)
        await Task.yield(); XCTAssertEqual(packets.count, 1, "The old producer still owns its actual operation")
        let done = expectation(description: "New request after drain")
        let sub = model.$status.filter { $0 == .needsReview }.prefix(1).sink { _ in done.fulfill() }
        await pause.release(); await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(packets.count, 2); XCTAssertNotEqual(packets.first, packets.last)
        withExtendedLifetime(sub) {}
    }

    func testExplicitCancelThenRetryStillWaitsForRetiredProducerDrain() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let started = expectation(description: "Old request entered"), cancelled = expectation(description: "Old request cancelled")
        let premature = expectation(description: "Retry cannot bypass a cancelled producer"); premature.isInverted = true
        let pause = AskTestPause(started, cancelled: cancelled)
        var calls = 0, released = false
        let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true) { packet in
            calls += 1
            if calls == 1 { return AskAnswerGeneration { emit in await pause.run(emit: emit) } }
            if !released { premature.fulfill() }
            let raw = try self.response(packet); return AskAnswerGeneration { emit in try emit(raw) }
        }
        defer { model.dismiss() }
        let value = try candidate(f.session)
        let done = expectation(description: "Explicit retry can finish after drain")
        let sub = model.$status.filter { $0 == .needsReview }.prefix(1).sink { _ in done.fulfill() }
        model.judge(candidate: value); await fulfillment(of: [started], timeout: 2)
        model.cancel(); model.judge(candidate: value)
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [premature], timeout: 0.05)
        released = true; await pause.release()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 2)
        withExtendedLifetime(sub) {}
    }

    func testBodyAndABAChangesRetireNoncooperativePreparationBeforeAnyGeneration() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let first = try XCTUnwrap(f.session.selectedDocumentID), second = try XCTUnwrap(f.session.createDocument(title: "Other"))
        f.session.selectDocument(first)
        let started = expectation(description: "Packet preparation suspended"), pause = AskTestPause(started)
        var calls = 0
        let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true, build: { candidate, document in
            let packet = try JudgeEvidencePacket.prepare(candidate: candidate, document: document)
            await pause.run(emit: { _ in }); return packet
        }) { _ in calls += 1; return AskAnswerGeneration { _ in } }
        defer { model.dismiss() }
        model.judge(candidate: try candidate(f.session)); await fulfillment(of: [started], timeout: 2)
        f.session.selectDocument(second); f.session.selectDocument(first)
        XCTAssertEqual(model.status, .invalidated); XCTAssertNil(model.decision); XCTAssertNil(model.packet)
        await pause.release(); await Task.yield(); XCTAssertEqual(calls, 0)
    }

    func testAvailabilityPolicyAndForegroundDoNotStartOrAutomaticallyResumeJudging() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        var calls = 0
        let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: false) { _ in calls += 1; return AskAnswerGeneration { _ in } }
        defer { model.dismiss() }
        let candidate = try candidate(f.session)
        model.judge(candidate: candidate); XCTAssertEqual(model.status, .unavailable)
        model.setModelAvailable(true); model.setForegroundBusy(true); XCTAssertFalse(model.canJudge)
        model.judge(candidate: candidate); XCTAssertEqual(model.status, .paused)
        model.setForegroundBusy(false); model.setPolicyPaused(true)
        model.judge(candidate: candidate); XCTAssertEqual(model.status, .paused)
        model.setPolicyPaused(false); await Task.yield(); XCTAssertEqual(calls, 0)
    }

    func testActiveForegroundPolicyAndModelRetirementCancelWithoutAutomaticResume() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        for gate in 0..<3 {
            let started = expectation(description: "Active gate request \(gate)"), cancelled = expectation(description: "Active gate cancellation \(gate)")
            let pause = AskTestPause(started, cancelled: cancelled)
            var calls = 0
            let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true) { _ in
                calls += 1; return AskAnswerGeneration { emit in await pause.run(emit: emit) }
            }
            model.judge(candidate: try candidate(f.session)); await fulfillment(of: [started], timeout: 2)
            if gate == 0 { model.setForegroundBusy(true) }
            else if gate == 1 { model.setPolicyPaused(true) }
            else { model.setModelAvailable(false) }
            await fulfillment(of: [cancelled], timeout: 2)
            XCTAssertNil(model.decision); XCTAssertNil(model.packet)
            XCTAssertEqual(model.status, gate == 2 ? .unavailable : .paused)
            model.setForegroundBusy(false); model.setPolicyPaused(false); model.setModelAvailable(true)
            await pause.release(); await Task.yield(); XCTAssertEqual(calls, 1)
            model.dismiss()
        }
    }

    func testActualMasterPublisherRetiresAnAdmittedOwnerWithoutInference() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let settings = CompletionSettings(); settings.autocompleteEnabled = true
        let completion = CompletionController(settings: settings)
        var calls = 0
        let support = ContinuityJudgeSupport(available: true) { _ in calls += 1; return AskAnswerGeneration { _ in } }
        support.observe(completion)
        let model = support.makeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity))
        defer { model.dismiss(); support.shutdown(); completion.shutdown() }
        // Seed only this synthetic owner admission; no real model state is changed.
        model.setModelAvailable(true); model.setPolicyPaused(false); model.setForegroundBusy(false)
        XCTAssertTrue(model.canJudge)
        settings.autocompleteEnabled = false
        XCTAssertFalse(model.canJudge); XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(calls, 0)
    }

    func testActualRuntimeSupportStartsUnavailableAndNeverLoadsOnCreationOrToolAttachment() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let lifetime = ModelLifetimeCoordinator(), settings = CompletionSettings()
        let completion = CompletionController(settings: settings, engine: CompletionEngine(memoryPolicy: .current, modelLifetime: lifetime))
        let support = completion.makeContinuityJudgeSupport()
        XCTAssertFalse(support.available)
        let requests = ProjectEditorRequests(); requests.judgeSupport = support
        let model = support.makeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity))
        defer { model.dismiss(); completion.shutdown() }
        model.judge(candidate: try candidate(f.session))
        XCTAssertEqual(model.status, .unavailable); XCTAssertEqual(lifetime.snapshotCount(), 0)
        XCTAssertFalse(completion.isManagingModel)
    }

    func testSupportShutdownCancelsActiveOwnersWithoutAutomaticRestart() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let started = expectation(description: "Owned producer"), cancelled = expectation(description: "Owner shutdown cancellation")
        let pause = AskTestPause(started, cancelled: cancelled)
        let support = ContinuityJudgeSupport(available: true) { _ in AskAnswerGeneration { emit in await pause.run(emit: emit) } }
        let model = support.makeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity))
        model.judge(candidate: try candidate(f.session)); await fulfillment(of: [started], timeout: 2)
        support.shutdown(); await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(model.status, .invalidated); XCTAssertNil(model.packet); XCTAssertNil(model.decision)
        await pause.release(); await Task.yield(); XCTAssertEqual(model.status, .invalidated)
    }

    func testRetirementClearsDecisionBeforeInvalidatedStatusPublishes() async throws {
        let f = try await fixture(); defer { f.cleanUp() }
        let model = ContinuityJudgeController(session: f.session, origin: try XCTUnwrap(f.session.runtimeIdentity), modelAvailable: true) { packet in
            let raw = try self.response(packet); return AskAnswerGeneration { emit in try emit(raw) }
        }
        defer { model.dismiss() }
        let done = expectation(description: "Decision ready")
        let first = model.$status.filter { $0 == .needsReview }.prefix(1).sink { _ in done.fulfill() }
        model.judge(candidate: try candidate(f.session)); await fulfillment(of: [done], timeout: 2)
        let retired = expectation(description: "No old action during synchronous status observation")
        let second = model.$status.filter { $0 == .invalidated }.prefix(1).sink { _ in
            XCTAssertNil(model.decision); XCTAssertNil(model.packet); retired.fulfill()
        }
        f.session.updateSelectedDocumentBody("Changed original")
        await fulfillment(of: [retired], timeout: 2)
        withExtendedLifetime((first, second)) {}
    }
}

final class ContinuityJudgeBackendTests: XCTestCase {
    func testSupplementalReadyAdmissionRefusesAnActiveOperationWithoutLoadingOrSwitching() async throws {
        let lifetime = ModelLifetimeCoordinator()
        _ = try await lifetime.acquire(modelID: "ready", reservingOperation: false)
        await lifetime.finishSwitch(to: "ready", succeeded: true, reservingOperation: false)
        let first = await lifetime.reserveReadyOperation(modelID: "ready"); XCTAssertTrue(first)
        let overlapping = await lifetime.reserveReadyOperation(modelID: "ready"); XCTAssertFalse(overlapping)
        if overlapping { await lifetime.releaseOperation() }
        await lifetime.releaseOperation()
        _ = try await lifetime.acquire(modelID: "ready", reservingOperation: true)
        let duringRegular = await lifetime.reserveReadyOperation(modelID: "ready"); XCTAssertFalse(duringRegular)
        if duringRegular { await lifetime.releaseOperation() }
        await lifetime.releaseOperation()
        XCTAssertEqual(lifetime.snapshotCount(), 0)
    }
}
