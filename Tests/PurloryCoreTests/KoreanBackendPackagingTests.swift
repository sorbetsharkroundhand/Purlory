@testable import PurloryIntelligence
import Foundation
import XCTest
@testable import PurloryKoreanBackend

@MainActor
final class KoreanBackendPackagingTests: XCTestCase {
    func testOfflinePackagedResourceAndNativeResult() async throws {
        let worker = KoreanNativeWorker(resources: KoreanNativeWorker.bundledResourcesURL)
        let input = "🙂 한글을 쓴다."
        let analysis = try await worker.analyze(input)
        XCTAssertTrue(analysis.tokens.contains {
            $0.range == NSRange(location: 3, length: 2)
                && (input as NSString).substring(with: $0.range) == "한글"
        })
        for token in analysis.tokens {
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), input.utf16.count)
        }
        await worker.release()
    }

    func testMissingOrChangedResourceIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = KoreanNativeWorker(resources: root.appendingPathComponent("missing"))
        do { _ = try await absent.analyze("한글"); XCTFail("Missing resources were accepted") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .unavailable) }
        await absent.release()

        let copy = root.appendingPathComponent("Kiwi")
        try FileManager.default.copyItem(at: KoreanNativeWorker.bundledResourcesURL, to: copy)
        let model = copy.appendingPathComponent("models/cong/base/sj.morph")
        let file = try FileHandle(forUpdating: model)
        let originalByte = try XCTUnwrap(try file.read(upToCount: 1)?.first)
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data([originalByte ^ 0xff]))
        try file.close()
        let changed = KoreanNativeWorker(resources: copy)
        do { _ = try await changed.analyze("한글"); XCTFail("Changed resources were accepted") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .unavailable) }
        await changed.release()
    }

    func testInitializationIsLazyAndNativeInputIsBounded() async throws {
        let gate = KoreanFactoryGate(block: .none)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        XCTAssertEqual(gate.counts.opened, 0)
        let empty = try await worker.analyze("")
        XCTAssertTrue(empty.tokens.isEmpty)
        XCTAssertEqual(gate.counts.opened, 0, "Empty input must not initialize the native library")
        for input in [String(repeating: "가", count: 1025), "문장\0뒤"] {
            do { _ = try await worker.analyze(input); XCTFail("Invalid input was admitted") }
            catch { XCTAssertEqual(error as? KoreanNativeError, .invalidInput) }
        }
        XCTAssertEqual(gate.counts.opened, 0)
        await worker.release()
    }

    func testAlreadyCancelledTaskNeverInitializes() async throws {
        let gate = KoreanFactoryGate(block: .none)
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let task = Task { try await worker.analyze("문장") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task was accepted") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        await worker.release()
        XCTAssertEqual(gate.counts.opened, 0)
    }

    func testReleaseWaitsForAdmittedCall() async throws {
        let gate = KoreanFactoryGate(block: .analysis)
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let first = Task { try await worker.analyze("첫 문장") }
        await fulfillment(of: [gate.started], timeout: 3)
        let retirement = worker.beginRelease()
        do { _ = try await worker.analyze("대기 문장"); XCTFail("Release admitted another call") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        XCTAssertEqual(gate.counts.closed, 0)
        gate.allow.signal()
        do { _ = try await first.value; XCTFail("Retired result was returned") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        await retirement.value
        XCTAssertEqual(gate.counts.analyzed, 1)
        XCTAssertEqual(gate.counts.closed, 1)
        XCTAssertFalse(gate.counts.usedMainThread)
    }

    func testReleaseDuringInitializationNeverAnalyzes() async throws {
        let gate = KoreanFactoryGate(block: .initialization)
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let first = Task { try await worker.analyze("문장") }
        await fulfillment(of: [gate.started], timeout: 3)
        let retirement = worker.beginRelease()
        gate.allow.signal()
        do { _ = try await first.value; XCTFail("Retired initialization published") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        await retirement.value
        XCTAssertEqual(gate.counts.opened, 1)
        XCTAssertEqual(gate.counts.analyzed, 0)
        XCTAssertEqual(gate.counts.closed, 1)
        XCTAssertFalse(gate.counts.usedMainThread)
    }

    func testCancellationDuringResourceValidationNeverInitializesNativeLibrary() async throws {
        let gate = KoreanFactoryGate(block: .validation)
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let first = Task { try await worker.analyze("문장") }
        await fulfillment(of: [gate.started], timeout: 3)
        worker.cancelPending()
        gate.allow.signal()
        do { _ = try await first.value; XCTFail("Cancelled validation published") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        await worker.release()
        XCTAssertEqual(gate.counts.opened, 0)
        XCTAssertEqual(gate.counts.analyzed, 0)
    }

    func testCancelPendingRejectsQueuedAndLateResults() async throws {
        let gate = KoreanFactoryGate(block: .analysis)
        defer { gate.allow.signal() }
        let worker = KoreanNativeWorker(resources: URL(fileURLWithPath: "/unused"), factory: gate)
        let first = Task { try await worker.analyze("문장") }
        await fulfillment(of: [gate.started], timeout: 3)
        let queued = worker.enqueueAnalysis("대기 문장")
        worker.cancelPending()
        gate.allow.signal()
        do { _ = try await first.value; XCTFail("Cancelled native result was returned") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        do { _ = try await queued.value(); XCTFail("Queued native call was admitted") }
        catch { XCTAssertEqual(error as? KoreanNativeError, .cancelled) }
        await worker.release()
        XCTAssertEqual(gate.counts.analyzed, 1)
        XCTAssertEqual(gate.counts.closed, 1)
    }
}

private final class KoreanFactoryGate: KoreanNativeFactory, @unchecked Sendable {
    enum Block { case none, validation, initialization, analysis }
    struct Counts { var opened = 0; var analyzed = 0; var closed = 0; var usedMainThread = false }
    let started = XCTestExpectation(description: "Native boundary entered")
    let allow = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value = Counts()
    private let block: Block
    init(block: Block) { self.block = block }
    var counts: Counts { lock.withLock { value } }
    func open(resources: URL, admission: @Sendable () -> Bool) throws -> any KoreanNativeHandle {
        if block == .validation { started.fulfill(); allow.wait() }
        guard admission() else { throw KoreanNativeError.cancelled }
        lock.withLock { value.opened += 1; value.usedMainThread = value.usedMainThread || Thread.isMainThread }
        if block == .initialization { started.fulfill(); allow.wait() }
        return KoreanControlledHandle(gate: self)
    }
    func analyze(_ text: String) -> KoreanNativeAnalysis {
        let first = lock.withLock {
            value.analyzed += 1
            value.usedMainThread = value.usedMainThread || Thread.isMainThread
            return value.analyzed == 1
        }
        if block == .analysis && first { started.fulfill(); allow.wait() }
        return KoreanNativeAnalysis(tokens: [], sentences: [], candidates: [])
    }
    func close() { lock.withLock { value.closed += 1 } }
}

private final class KoreanControlledHandle: KoreanNativeHandle, @unchecked Sendable {
    let gate: KoreanFactoryGate
    init(gate: KoreanFactoryGate) { self.gate = gate }
    func analyze(_ text: String, admission: @Sendable () -> Bool) throws -> KoreanNativeAnalysis {
        guard admission() else { throw KoreanNativeError.cancelled }
        return gate.analyze(text)
    }
    func close() { gate.close() }
}
