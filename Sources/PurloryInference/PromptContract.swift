import Foundation

/// 토큰 카운터 스냅샷 (#43, PLAN §11 "예산은 토큰 기준") — 엔진 액터가 로드된
/// 모델의 토크나이저로 만들어 넘기는 값 객체. 원시 토크나이저 타입은 actor 경계를
/// 넘지 않고, 카운트 클로저만 Sendable 값으로 통과한다 (메타 이슈 #65 Phase 4).
/// encode는 어휘 사전에 대한 읽기 전용 변환이라 로드 이후 불변 — 동시 호출 안전을
/// 전제로 한다 (swift-transformers PreTrainedTokenizer의 불변 어휘 구조).
public struct TokenCounter: @unchecked Sendable {
    private let impl: @Sendable (String) -> Int
    private let promptCost: (@Sendable (AssembledPrompt) -> Int)?

    public init(_ impl: @escaping @Sendable (String) -> Int,
                promptCost: (@Sendable (AssembledPrompt) -> Int)? = nil) {
        self.impl = impl
        self.promptCost = promptCost
    }

    /// 문자열의 모델 토큰 수.
    public func count(_ text: String) -> Int {
        impl(text)
    }
    public func count(_ prompt: AssembledPrompt) -> Int {
        if let promptCost { return promptCost(prompt) }
        switch prompt {
        case .continuation(let text): return impl(text)
        case .instruct(let system, let user): return impl(system) + impl(user)
        }
    }
}

/// 엔진에 넘기는 조립 완료 프롬프트 (PLAN §10) — 엔진은 조립에 관여하지 않는다.
public enum AssembledPrompt: Sendable, Equatable {
    /// 챗 템플릿 없이 그대로 이어쓸 텍스트 — KV 프리필 재사용 대상 (PLAN §12).
    case continuation(String)
    /// instruct 챗 — 시스템 + 사용자 메시지.
    case instruct(system: String, user: String)
}
