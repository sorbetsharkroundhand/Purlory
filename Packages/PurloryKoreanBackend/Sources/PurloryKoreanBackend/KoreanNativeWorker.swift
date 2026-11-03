import Foundation

public final class KoreanNativeWorker: @unchecked Sendable {
    public static let maximumInputUTF16 = 1024
    public static var bundledResourcesURL: URL {
        if Bundle.main.bundleURL.pathExtension == "app",
           let url = Bundle.main.url(forResource: "Purlory_PurloryKoreanBackend", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("Kiwi")
        }
        return (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Kiwi")
    }
    private let ownership = NativeOwnership()
    private let executor = NativeSerialThread()
    private let context: NativeContext

    public convenience init(resources: URL) {
        self.init(resources: resources, factory: VerifiedKoreanFactory())
    }
    init(resources: URL, factory: any KoreanNativeFactory) {
        context = NativeContext(resources: resources, factory: factory)
    }
    deinit { _ = beginRelease() }

    public func analyze(_ text: String) async throws -> KoreanNativeAnalysis {
        let request = NativeAnalysisRequest()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { request.cancel(); throw KoreanNativeError.cancelled }
            return try await enqueueAnalysis(text, request: request).value()
        } onCancel: { request.cancel() }
    }

    func enqueueAnalysis(_ text: String, request: NativeAnalysisRequest = NativeAnalysisRequest()) -> NativeAnalysisRequest {
        guard text.utf16.count <= Self.maximumInputUTF16, !text.utf16.contains(0) else {
            request.completion.finish(.failure(.invalidInput))
            return request
        }
        if text.isEmpty {
            request.completion.finish(.success(KoreanNativeAnalysis(tokens: [], sentences: [], candidates: [])))
            return request
        }
        guard let generation = ownership.capture() else { request.cancel(); return request }
        let owner = ownership, context = context
        let valid: @Sendable () -> Bool = { owner.isCurrent(generation) && !request.isCancelled }
        executor.enqueue(.init(valid: valid, perform: {
            do {
                let opening = context.handle == nil
                if opening { context.handle = try context.factory.open(resources: context.resources, admission: valid) }
                guard valid() else {
                    if opening { context.close() }
                    request.cancel()
                    return
                }
                guard let handle = context.handle else { throw KoreanNativeError.unavailable }
                let analysis = try handle.analyze(text, admission: valid)
                guard valid() else { request.cancel(); return }
                request.completion.finish(.success(analysis))
            } catch {
                request.completion.finish(.failure(valid() ? (error as? KoreanNativeError ?? .unavailable) : .cancelled))
            }
        }, cancel: { request.cancel() }))
        return request
    }

    public func cancelPending() { ownership.invalidate() }

    func beginRelease() -> Task<Void, Never> {
        let (completion, started) = ownership.beginRetirement()
        if started {
            let context = context, owner = ownership
            executor.enqueue(.init(valid: { true }, perform: { context.close() }, cancel: {}, retired: {
                owner.endRetirement(completion)
                completion.finish(.success(()))
            }))
        }
        return Task { _ = try? await completion.value() }
    }

    public func release() async { await beginRelease().value }
}

private final class NativeOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var retirement: NativeCompletion<Void>?
    func capture() -> UInt64? { lock.withLock { retirement == nil ? generation : nil } }
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { retirement == nil && self.generation == generation }
    }
    func invalidate() { lock.withLock { generation &+= 1 } }
    func beginRetirement() -> (NativeCompletion<Void>, Bool) {
        lock.withLock {
            if let retirement { return (retirement, false) }
            generation &+= 1
            let next = NativeCompletion<Void>()
            retirement = next
            return (next, true)
        }
    }
    func endRetirement(_ completion: NativeCompletion<Void>) {
        lock.withLock { if retirement === completion { retirement = nil } }
    }
}

/// Only NativeSerialThread reads or mutates handle; the other fields are immutable.
private final class NativeContext: @unchecked Sendable {
    let resources: URL
    let factory: any KoreanNativeFactory
    var handle: (any KoreanNativeHandle)?
    init(resources: URL, factory: any KoreanNativeFactory) { self.resources = resources; self.factory = factory }
    func close() { handle?.close(); handle = nil }
}
