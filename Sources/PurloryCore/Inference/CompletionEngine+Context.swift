import Foundation

extension CompletionEngine {
    /// 구 API 호환(PurloryBench 단발 측정 등) — 조립기 없이 prefix만으로 생성.
    /// 앱 경로는 컨트롤러가 조립기를 거쳐 `complete(prompt:)`를 쓴다.
    public func complete(
        prefix: String,
        parameters: CompletionParameters,
        onLoadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Completion {
        try await complete(
            prompt: ContextAssembler.assemble(
                prefix: prefix, document: nil, style: parameters.promptStyle),
            parameters: parameters,
            onLoadProgress: onLoadProgress
        )
    }

    @_spi(Benchmark)
    public func completeForCancellationStress(
        prefix: String, parameters: CompletionParameters, stopAfterFirstChunk: Bool = false,
        onGenerationStarted: @escaping @Sendable () -> Void
    ) async throws -> Completion {
        try await completeForCancellationStress(
            prompt: ContextAssembler.assemble(prefix: prefix, document: nil, style: parameters.promptStyle),
            parameters: parameters, stopAfterFirstChunk: stopAfterFirstChunk,
            onGenerationStarted: onGenerationStarted)
    }
}
