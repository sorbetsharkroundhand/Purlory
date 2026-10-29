import Foundation

/// 자동완성 프롬프트 방식 (PLAN §9-4 — M2 실험으로 확정).
public enum PromptStyle: String, CaseIterable, Codable, Sendable {
    /// 커서 앞 텍스트를 챗 템플릿 없이 그대로 이어쓴다.
    /// 어절 중간에서도 자연스럽게 이어지므로 자동완성 기본값.
    case continuation
    /// instruct 모델 + 간결 시스템 프롬프트("이어질 내용을 짧게 이어써").
    case instruct

    public var label: String {
        switch self {
        case .continuation: "이어쓰기 (continuation)"
        case .instruct: "지시형 (instruct)"
        }
    }
}

/// Whether the writer has explicitly chosen to allow local completion work.
public enum CompletionAuthorization: String, Codable, Sendable {
    case unconfigured
    case disabled
    case enabled
}

/// 모델 프리셋 (PLAN §3).
public enum ModelPresets {
    // Owner-selected writing candidates; availability still follows the memory policy.
    public static let qwen3_5_9B = "mlx-community/Qwen3.5-9B-4bit"
    public static let ministral3_14B = "mlx-community/Ministral-3-14B-Instruct-2512-4bit"
    public static let gemma4_26B_A4B = "mlx-community/gemma-4-26b-a4b-it-4bit"
    /// **Purlory** — Ternary-Bonsai-27B (Qwen3.5-27B dense, 2비트 삼진 ~1.71bpw), ~8.5GB.
    /// 27B **밀집** 모델이라 토큰마다 전 가중치를 읽는다 — 파일은 셋 중 가장 작지만
    /// 토큰당 대역폭은 MoE(활성 ~3B)보다 크다. 즉 "작다 = 빠르다"가 성립하지 않는
    /// 체급이다 (지연은 PurloryBench로 재기 전까지 표기하지 않는다, CLAUDE.md §2-7).
    /// 저장소 config는 VLM(`Qwen3_5ForConditionalGeneration` + vision_config)이지만
    /// `model_type: "qwen3_5"`가 mlx-swift-lm LLMModelFactory에 등록되어 있고,
    /// `Qwen35Model`이 `textConfig`만 취해 언어 모델로 로드한다 (비전 타워는 미사용).
    /// ⚠️ 한국어 지원이 모델 카드에 명시되지 않았고 1.71bpw는 공격적 양자화다 —
    /// 한국어 장편 품질은 **실사용·벤치로 판정 대기** (PLAN §16 열린 질문).
    public static let ternaryBonsai27B = "prism-ml/Ternary-Bonsai-27B-mlx-2bit"
    /// **Basil** — MoE(총 30B, 활성 ~3B: 라우팅 전문가 64개 중 4개 + 공유 1개), ~16.9GB.
    /// 활성 파라미터가 3B대라 디코딩은 3B 밀집 모델급이면서 30B의 이해를 쓴다.
    /// `glm4_moe_lite` 아키텍처는 mlx-swift-lm 3.31.3 LLMModelFactory에 등록되어 있다.
    public static let glm4_7_flash = "mlx-community/GLM-4.7-Flash-4bit"
    /// **Qwen3.6-35B-A3B** — MoE(활성 ~3B), 약 20GB. 저장소 id는 Mac 첫 다운로드 때
    /// 검증되며, 없거나 무거우면 Settings(⌘,)·PurloryBench `--model`로 대안 교체.
    public static let qwen3_6_35B_A3B = "mlx-community/Qwen3.6-35B-A3B-4bit"

    // MARK: 대안 (피커 미노출 — Settings 직접 입력·벤치 `--model` 전용)

    /// mlx-swift-lm LLMRegistry에 수록된 검증된 MoE 대안 (활성 ~3B, ~17GB).
    public static let qwen3_30B_A3B = "mlx-community/Qwen3-30B-A3B-4bit"
    /// 경량 대안 (~4.7GB, 2026-08-25 벤치 통과로 슬롯 교체 — 이슈 #63).
    /// A.X-4.0-Light(SKT, Apache-2.0) 한국어 특화 · 순수 어텐션(qwen2)이라
    /// §12 KV 재사용이 온전히 작동(웜 460/461 tok, 웜 TTFC 0.03s). 같은 fixture에서
    /// 이전 경량 후보 Qwen2.5-3B보다 어절 적중률 17% vs 8%.
    public static let ax4Light = "meetLog/A.X-4.0-Light-mlx-4bit"
    /// 가벼운 대안 (~1.9GB).
    public static let qwen2_5_3B = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    /// 가장 가벼운 대안 (~1GB).
    public static let qwen2_5_1_5B = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"

    public static let all: [String] = [
        qwen3_5_9B, ministral3_14B, gemma4_26B_A4B,
        ternaryBonsai27B, glm4_7_flash, qwen3_6_35B_A3B,
        qwen3_30B_A3B, ax4Light, qwen2_5_3B, qwen2_5_1_5B,
    ]
}

/// Release choices come from approved policy data; historical names identify saved selections.
public struct ModelChoice: Identifiable, Sendable {
    /// Hugging Face 저장소 id — `CompletionSettings.modelID`와 일치.
    public let id: String
    public let name: String
    public let sizeLabel: String
    public let detail: String
    /// 드롭다운 우측의 대략적 지연 표기 (디자인 v3).
    public let latencyLabel: String

    public static let purlory = ModelChoice(id: ModelPresets.ternaryBonsai27B, name: "Purlory", sizeLabel: "", detail: "검증 대기", latencyLabel: "")
    public static let basil = ModelChoice(id: ModelPresets.glm4_7_flash, name: "Basil", sizeLabel: "", detail: "검증 대기", latencyLabel: "")
    public static let qwenMoE = ModelChoice(id: ModelPresets.qwen3_6_35B_A3B, name: "Qwen3.6-35B-A3B", sizeLabel: "", detail: "검증 대기", latencyLabel: "")
    public static let all = available(using: .current)
    public static func available(using policy: ModelMemoryPolicy) -> [ModelChoice] {
        policy.availableEntries.map {
            .init(id: $0.id, name: $0.name, sizeLabel: "", detail: "이 Mac에서 사용 가능", latencyLabel: "")
        }
    }
    public static func matching(_ modelID: String) -> ModelChoice? {
        (all + [purlory, basil, qwenMoE]).first { $0.id == modelID }
    }
}

/// Immutable inference settings. New selections use the approved hardware policy default.
public struct CompletionParameters: Sendable, Equatable {
    public var modelID: String
    public var promptStyle: PromptStyle
    public var ghostContextMode: GhostContextMode
    /// 생성 토큰 상한 — 단어/구 단위 제안 + 저지연 (PLAN §10, ~8–16).
    public var maxTokens: Int
    /// 낮을수록 결정적 — 자동완성은 일관성이 중요.
    public var temperature: Double
    /// 누적 확률 컷 — 하드코딩(0.9)에서 승격, PurloryBench로 튜닝 (PLAN §10).
    public var topP: Double
    /// 프리필 토큰 안전 예산 — 문자 창이 넘칠 때만 프롬프트 앞을 잘라낸다
    /// (PLAN §11). UI 미노출, 벤치에서 오버라이드.
    public var maxPromptTokens: Int
    /// 이어쓰기 프리필 KV 재사용 (PLAN §12) — 문제 시 끌 수 있는 킬 스위치.
    public var kvCacheEnabled: Bool
    /// 대화 모드의 정지 사다리 확장 (PLAN §10) — 문장 경계 대신 발화 끝(닫는
    /// 따옴표)에서 멈춘다. 설정이 아니라 **요청별 런타임 값** — 컨트롤러가
    /// 커서의 따옴표 상태로 매 요청 결정한다 (UserDefaults 저장 안 함).
    public var stopAtUtteranceEnd: Bool

    public init(
        modelID: String = ModelMemoryPolicy.current.defaultModelID ?? "",
        promptStyle: PromptStyle = .continuation,
        maxTokens: Int = 12,
        temperature: Double = 0.3,
        topP: Double = 0.9,
        maxPromptTokens: Int = 3_072,
        kvCacheEnabled: Bool = true,
        stopAtUtteranceEnd: Bool = false,
        ghostContextMode: GhostContextMode = .current
    ) {
        self.modelID = modelID
        self.promptStyle = promptStyle
        self.ghostContextMode = ghostContextMode
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.maxPromptTokens = maxPromptTokens
        self.kvCacheEnabled = kvCacheEnabled
        self.stopAtUtteranceEnd = stopAtUtteranceEnd
    }
}

/// 자동완성 동작 설정 (M3 배선 · M4 Settings UI).
///
/// 모델 ID 수동 입력의 커밋 경계 검증 (이슈 #25 / #65 H2).
/// TextField는 초안만 편집하고, 이 검증을 통과한 값만 changeModel로 간다 —
/// 불완전한 ID가 네트워크 작업(취소·다운로드·preload)을 시작하지 않게.
public enum ModelIDCommit {

    public enum ValidationError: Swift.Error, Equatable, CustomStringConvertible {
        case empty
        case malformed(String)

        public var message: String {
            switch self {
            case .empty:
                return "모델 ID를 입력해 주세요."
            case .malformed(let raw):
                return "'\(raw)'은(는) Hugging Face 형식이 아니에요 — namespace/model"
            }
        }

        public var description: String { message }
    }

    /// 공백 제거 후 namespace/model 형식을 검증해 정제된 ID를 돌려준다.
    public static func validate(_ raw: String) -> Result<String, ValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if trimmed.contains(where: { $0 == " " || $0 == "\t" }) {
            return .failure(.malformed(trimmed))
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
            !parts[0].isEmpty, !parts[1].isEmpty
        else { return .failure(.malformed(trimmed)) }
        return .success(trimmed)
    }
}

