import Foundation
import SwiftUI

/// 값은 `UserDefaults`에 보존된다. UI(SettingsView)는 이 객체에 바인딩하고,
/// 추론 쪽에는 `parameters` 스냅샷만 넘긴다.
@MainActor
public final class CompletionSettings: ObservableObject {    /// 입력이 멈춘 뒤 제안을 트리거하기까지 대기(ms) — PLAN §5 "수백 ms".
    public static let defaultDebounceMilliseconds = 350
    /// 커서 앞에서 프롬프트로 쓰는 최대 문자 수 (저널 = Fast 모드, PLAN §10).
    public static let defaultContextCharacters = 1_200
    /// 소설의 컨텍스트 창 상한 (Smart/Story, PLAN §10) — KV 재사용(PLAN §12)이
    /// 있어야 부담 없는 크기라 M5에서 함께 도입한다.
    nonisolated public static let defaultNovelContextCharacters = 4_000
    /// 본문 줄 간격(pt) 기본값 — 줄 사이에 더해지는 여백. 0이면 폰트 기본 높이만.
    public static let defaultLineSpacing = 11.5
    /// 본문 기본 글자 크기(pt) 기본값 — 디자인 기준. 모든 블록이 이 값에 비례한다.
    public static let defaultFontSize = 18.5
    /// 글자 크기 허용 범위 — ⌘+/⌘−·Settings 공용.
    public static let minFontSize = 14.0
    public static let maxFontSize = 30.0

    public static let shared = CompletionSettings()

    private enum Keys {
        static let enabled = "completion.enabled"
        static let authorization = "completion.authorization"
        static let modelID = "completion.modelID"
        static let promptStyle = "completion.promptStyle"
        static let ghostContextMode = "completion.ghostContextMode"
        static let debounceMilliseconds = "completion.debounceMilliseconds"
        static let maxTokens = "completion.maxTokens"
        static let temperature = "completion.temperature"
        static let topP = "completion.topP"
        static let contextCharacters = "completion.contextCharacters"
        static let novelContextCharacters = "completion.novelContextCharacters"
        static let kvCache = "completion.kvCache"
        static let lineSpacing = "editor.lineSpacing"
        static let fontSize = "editor.fontSize"
        /// 저자 이름은 예측 동작이 아니라 **작품 메타데이터**라 `completion.*`이
        /// 아닌 앱 전역 이름공간(`purlory.*`)에 둔다 — 예측 파라미터 스냅샷
        /// (`CompletionParameters`)에도 들어가지 않는다.
        static let authorName = "purlory.authorName"
        /// Legacy first-model confirmation marker, read once when migrating authorization.
        static let initialModelConfirmed = "purlory.initialModelConfirmed"
    }

    private let defaults: UserDefaults

    /// 자동완성 마스터 스위치 — 끄면 제안 트리거·모델 로드를 모두 멈춘다.
    @Published public var autocompleteEnabled: Bool {
        didSet { defaults.set(autocompleteEnabled, forKey: Keys.enabled) }
    }
    @Published public private(set) var authorization: CompletionAuthorization {
        didSet { defaults.set(authorization.rawValue, forKey: Keys.authorization) }
    }
    @Published public var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }
    @Published public var promptStyle: PromptStyle {
        didSet { defaults.set(promptStyle.rawValue, forKey: Keys.promptStyle) }
    }
    @Published public var debounceMilliseconds: Int {
        didSet { defaults.set(debounceMilliseconds, forKey: Keys.debounceMilliseconds) }
    }
    @Published public var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }
    @Published public var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }
    @Published public var topP: Double {
        didSet { defaults.set(topP, forKey: Keys.topP) }
    }
    @Published public var contextCharacters: Int {
        didSet { defaults.set(contextCharacters, forKey: Keys.contextCharacters) }
    }
    /// 소설 종류 문서의 컨텍스트 창 상한 (PLAN §10).
    @Published public var novelContextCharacters: Int {
        didSet { defaults.set(novelContextCharacters, forKey: Keys.novelContextCharacters) }
    }
    @Published public var ghostContextMode: GhostContextMode {
        didSet { defaults.set(ghostContextMode.rawValue, forKey: Keys.ghostContextMode) }
    }
    /// KV 프리필 재사용 (PLAN §12) — 이상 동작 시 사용자가 끌 수 있는 킬 스위치.
    @Published public var kvCacheEnabled: Bool {
        didSet { defaults.set(kvCacheEnabled, forKey: Keys.kvCache) }
    }
    /// 본문 줄 간격(pt) — 에디터 표시용(추론과 무관). 낮추면 줄이 촘촘해진다.
    @Published public var lineSpacing: Double {
        didSet { defaults.set(lineSpacing, forKey: Keys.lineSpacing) }
    }
    /// 저자 이름(필명) — EPUB 내보내기의 `<dc:creator>`에 실린다. 비워 두면
    /// 저자 정보를 아예 넣지 않는다(빈 저자명보다 없는 편이 낫다).
    @Published public var authorName: String {
        didSet { defaults.set(authorName, forKey: Keys.authorName) }
    }
    /// 본문 기본 글자 크기(pt) — 모든 블록이 이 값에 비례한다(⌘+/⌘−).
    @Published public var editorFontSize: Double {
        didSet {
            let clamped = min(Self.maxFontSize, max(Self.minFontSize, editorFontSize))
            if clamped != editorFontSize { editorFontSize = clamped; return }
            defaults.set(editorFontSize, forKey: Keys.fontSize)
        }
    }
    public init(defaults: UserDefaults = .standard, memoryPolicy: ModelMemoryPolicy = .current) {
        self.defaults = defaults
        let base = CompletionParameters()
        let storedAutocomplete = defaults.object(forKey: Keys.enabled) as? Bool
        let storedAuthorization = defaults.string(forKey: Keys.authorization)
            .flatMap(CompletionAuthorization.init(rawValue:))
        let legacyConfirmed = defaults.object(forKey: Keys.initialModelConfirmed) as? Bool
        if let storedAuthorization {
            self.authorization = storedAuthorization
            self.autocompleteEnabled = storedAuthorization == .enabled
        } else if legacyConfirmed == true {
            let enabled = storedAutocomplete ?? true
            let authorization: CompletionAuthorization = enabled ? .enabled : .disabled
            self.authorization = authorization
            self.autocompleteEnabled = enabled
            defaults.set(authorization.rawValue, forKey: Keys.authorization)
        } else {
            self.authorization = .unconfigured
            self.autocompleteEnabled = false
            defaults.set(CompletionAuthorization.unconfigured.rawValue, forKey: Keys.authorization)
        }
        // Preserve saved selections even if policy now refuses their use.
        self.modelID = defaults.string(forKey: Keys.modelID) ?? memoryPolicy.defaultModelID ?? ""
        self.promptStyle =
            defaults.string(forKey: Keys.promptStyle)
            .flatMap(PromptStyle.init(rawValue:)) ?? base.promptStyle
        self.ghostContextMode = defaults.string(forKey: Keys.ghostContextMode)
            .flatMap(GhostContextMode.init(rawValue:)) ?? .current
        self.debounceMilliseconds =
            defaults.object(forKey: Keys.debounceMilliseconds) as? Int
            ?? Self.defaultDebounceMilliseconds
        self.maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? base.maxTokens
        self.temperature =
            defaults.object(forKey: Keys.temperature) as? Double ?? base.temperature
        self.topP = defaults.object(forKey: Keys.topP) as? Double ?? base.topP
        self.contextCharacters =
            defaults.object(forKey: Keys.contextCharacters) as? Int
            ?? Self.defaultContextCharacters
        self.novelContextCharacters =
            defaults.object(forKey: Keys.novelContextCharacters) as? Int
            ?? Self.defaultNovelContextCharacters
        self.kvCacheEnabled =
            defaults.object(forKey: Keys.kvCache) as? Bool ?? base.kvCacheEnabled
        self.lineSpacing =
            defaults.object(forKey: Keys.lineSpacing) as? Double
            ?? Self.defaultLineSpacing
        self.editorFontSize =
            defaults.object(forKey: Keys.fontSize) as? Double
            ?? Self.defaultFontSize
        self.authorName = defaults.string(forKey: Keys.authorName) ?? ""
    }

    /// Records a deliberate Settings choice and keeps the legacy Boolean in sync.
    public func setCompletionEnabled(_ enabled: Bool) {
        authorization = enabled ? .enabled : .disabled
        autocompleteEnabled = enabled
    }

    /// 추론 엔진으로 넘기는 값 스냅샷.
    public var parameters: CompletionParameters {
        CompletionParameters(
            modelID: modelID,
            promptStyle: promptStyle,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            kvCacheEnabled: kvCacheEnabled,
            ghostContextMode: ghostContextMode
        )
    }
}
