import SwiftUI

/// Shared local completion controls for the editor toolbar and spatial document headers.
struct ModelChip: View {
    @ObservedObject var completion: CompletionController
    @ObservedObject var settings: CompletionSettings
    let theme: PurloryTheme
    var compact = false
    var embedded = false
    var onOpen: (() -> Void)? = nil

    @Environment(\.openSettings) private var openSettings
    @State private var menuOpen = false
    @State private var hoveredID: String?
    @State private var chipHovered = false
    /// 모델 가중치 프리페치 — 드롭다운 행의 다운로드 버튼·진행률 담당.
    @StateObject private var downloads = ModelDownloadManager.shared

    var body: some View {
        if embedded { dropdown } else { chip }
    }

    private var chip: some View {
        Button {
            if !menuOpen { onOpen?() }
            menuOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                if completion.isPredicting {
                    PulsingDots(color: theme.blueC)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)  // 의미는 아래 AX 값이 말한다 (#59-3).
                }
                if compact {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.ink2C)
                        .accessibilityHidden(true)
                } else {
                    Text(statusLabel)
                        .font(PurloryFonts.monoUI(11, .semibold))
                        .foregroundStyle(theme.ink2C)
                        .lineLimit(1)
                    Text("▼")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.ink3C)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, compact ? 9 : 11)
            .background(
                RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                    .fill(chipHovered ? theme.hoverC : theme.chipC)
            )
            .focusedValue(\.hasPurloryEditor, true)
            .overlay(
                RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                    .strokeBorder(theme.chipBorderC)
            )
        }
        .buttonStyle(.plain)
        .onHover { chipHovered = $0 }
        .accessibilityLabel("자동완성")
        .accessibilityValue(engineStateAXValue)
        .help(statusLabel)
        .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
            dropdown
        }
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("자동완성")
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                Text("글을 멈추면 다음 내용을 이 Mac에서 제안합니다.")
                    .purloryUIFont(10.5)
                    .foregroundStyle(theme.ink3C)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 10)
            theme.sepC.frame(height: 1)
            VStack(spacing: 0) {
                ForEach(ModelChoice.all) { choice in
                    row(choice)
                }
                if !settings.modelID.isEmpty, !ModelChoice.all.contains(where: { $0.id == settings.modelID }) {
                    customRow
                }
                if case .failed = completion.engineState {
                    theme.sepC.frame(height: 1).padding(.vertical, 4)
                    Button("모델 다시 로드") { completion.retryEngineLoad() }
                        .disabled(completion.isMemoryPressurePaused)
                        .buttonStyle(.plain)
                        .purloryUIFont(12, .medium)
                        .foregroundStyle(theme.blueC)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .padding(6)
            if ModelChoice.all.isEmpty {
                Text("사용 가능한 모델이 없습니다. 원고 편집은 계속할 수 있습니다.")
                    .purloryUIFont(11).foregroundStyle(theme.ink2C)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if completion.isMemoryPressurePaused {
                Text(CompletionController.memoryPressureMessage)
                    .purloryUIFont(11).foregroundStyle(theme.ink2C)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let error = completion.modelOperationError {
                Text(error).purloryUIFont(11).foregroundStyle(theme.dangerC)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            downloadFailureFooter
            theme.sepC.frame(height: 1)
            autocompleteToggle
            theme.sepC.frame(height: 1)
            predictionLengthRow
            theme.sepC.frame(height: 1)
            advancedModelSettingsButton
        }
        .frame(width: embedded ? nil : 292)
        // 열 때마다 로컬 캐시를 다시 확인한다 — 엔진 로드로 받아진 모델도 반영.
        .onAppear { downloads.refresh(ModelChoice.all.map(\.id)) }
    }

    /// 예측 길이(최대 토큰) 조절 — SettingsView(⌘,)의 스테퍼와 같은 값·범위.
    /// 값은 다음 제안부터 적용된다 (parameters 스냅샷 경계).
    private var predictionLengthRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("예측 길이")
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                Text("한 번에 제안하는 최대 토큰")
                    .purloryUIFont(11.5)
                    .foregroundStyle(theme.ink2C)
            }
            Spacer(minLength: 0)
            StepIconButton(systemName: "minus", theme: theme, help: "짧게") {
                settings.maxTokens = max(4, settings.maxTokens - 2)
            }
            Text("\(settings.maxTokens)")
                .font(PurloryFonts.monoUI(12, .semibold))
                .foregroundStyle(theme.inkC)
                .frame(minWidth: 22)
            StepIconButton(systemName: "plus", theme: theme, help: "길게") {
                settings.maxTokens = min(32, settings.maxTokens + 2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    /// 드롭다운 하단의 자동완성 마스터 스위치 — 끄면 제안·모델 로드 중단.
    private var autocompleteToggle: some View {
        Button {
            completion.setAutocompleteEnabled(!settings.autocompleteEnabled)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("자동완성")
                        .purloryUIFont(13, .semibold)
                        .foregroundStyle(theme.inkC)
                    Text(settings.autocompleteEnabled
                        ? "글을 멈추면 이어질 내용을 제안해요"
                        : "꺼짐 — 제안하지 않아요")
                        .purloryUIFont(11.5)
                        .foregroundStyle(theme.ink2C)
                }
                Spacer(minLength: 0)
                GlassSwitch(isOn: settings.autocompleteEnabled, theme: theme)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("자동완성 켜기/끄기")
        .accessibilityLabel(Text("자동완성"))
    }

    /// 모델 행 — **실제 Button**이라 Tab 포커스·Enter 활성화·VO 버튼 역할을 갖는다
    /// (#25). 다운로드 액세서리는 trailing overlay의 독립 Button으로 올려,
    /// 버튼 중첩 충돌 없이(overlay가 히트를 먼저 가져간다) 두 동작을 분리한다.
    /// 실패 원인은 AX value로 읽혀 색·help에만 의존하지 않는다.
    private func row(_ choice: ModelChoice) -> some View {
        let selected = settings.modelID == choice.id
        return Button {
            pick(choice.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name)
                        .purloryUIFont(13, .semibold)
                        .foregroundStyle(theme.inkC)
                    Text(Self.userFacingSummary(for: choice))
                        .purloryUIFont(11)
                        .foregroundStyle(theme.ink2C)
                }
                Spacer(minLength: 0)
                Text(selected ? "✓" : "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.blueC)
                    .frame(width: 16)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                    .fill(selected
                        ? theme.activeBgC
                        : (hoveredID == choice.id ? theme.hoverC : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? choice.id : nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(choice.name) 모델"))
        .accessibilityValue(Text(selected ? "선택됨" : Self.userFacingSummary(for: choice)))
        .accessibilityHint(Text("이 모델로 전환"))
        .overlay(alignment: .trailing) {
            downloadAccessory(choice)
                .padding(.trailing, 30)   // ✓ 칼럼 폭만큼 비켜난다
                .padding(.leading, 8)
        }
    }

    /// 다운로드 실패 원인 가시 푸터 (#25 완료 조건 3) — help 뒤에 숨기지 않는다.
    @ViewBuilder
    private var downloadFailureFooter: some View {
        let failure = downloads.states.first { state in
            if case .failed = state.value { return true }
            return false
        }
        if let failure {
            if case .failed(let message) = failure.value {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ModelChip.displayName(failure.key)) 다운로드 실패")
                        .purloryUIFont(11, .semibold)
                        .foregroundStyle(theme.dangerC)
                    Text(Self.recoveryAdvice(for: message))
                        .purloryUIFont(10.5)
                        .foregroundStyle(theme.ink2C)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.pillC)
            }
        }
    }

    /// 오류 메시지 → 다음 행동 제안 (#25). 결정적 매핑 — 네트워크/디스크/형식.
    static func recoveryAdvice(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("network") || lowered.contains("인터넷") || lowered.contains("연결") {
            return "네트워크 상태를 확인한 뒤 다시 시도해 주세요."
        }
        if lowered.contains("disk") || lowered.contains("space") || lowered.contains("공간")
            || lowered.contains("no space")
        {
            return "디스크 여유 공간을 확보한 뒤 다시 시도해 주세요."
        }
        if lowered.contains("404") || lowered.contains("not found") || lowered.contains("찾을 수 없") {
            return "저장소 id가 맞는지 확인해 주세요 (설정에서 직접 입력한 경우 오타 확인)."
        }
        return "잠시 후 다시 시도해 주세요."
    }

    /// 행 우측의 다운로드 상태 — 안 받았으면 받기 버튼, 진행 중엔 %, 받았으면 체크.
    /// 미리 받아 두면 그 모델로 전환할 때 다운로드 없이 바로 로드된다.
    @ViewBuilder
    private func downloadAccessory(_ choice: ModelChoice) -> some View {
        switch downloads.states[choice.id] {
        case .verifying:
            Button { downloads.cancel(choice.id) } label: {
                ProgressView().controlSize(.small)
            }
            .buttonStyle(.plain)
            .help("모델 파일 확인 중 — 누르면 취소")
            .accessibilityLabel(Text("모델 파일 확인 취소"))
        case .downloading(let fraction):
            Button {
                downloads.cancel(choice.id)
            } label: {
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(PurloryFonts.monoUI(10, .semibold))
                    .foregroundStyle(theme.blueC)
            }
            .buttonStyle(.plain)
            .help("다운로드 중 — 누르면 취소")
                .accessibilityLabel(Text("다운로드 취소"))
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.ink3C)
                .help("다운로드됨 — 전환 시 바로 로드")
                    .accessibilityLabel(Text("다운로드됨 — 이 모델로 전환"))
        case .failed(let message):
            Button {
                downloads.download(choice.id)
            } label: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.ink2C)
            }
            .buttonStyle(.plain)
            .help("실패 — 다시 시도 (\(message))")
                    .accessibilityLabel(Text("모델 다운로드 실패 — 다시 시도"))
                    .accessibilityValue(Text(message))
        case .notDownloaded, .none:
            Button {
                downloads.download(choice.id)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.blueC)
            }
            .buttonStyle(.plain)
            .help("모델 미리 받기 (\(choice.sizeLabel))")
                    .accessibilityLabel(Text("\(choice.name) 모델 미리 받기"))
        }
    }

    /// Preserve visibility of a saved selection without offering an unsupported switch.
    private var customRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("보관된 모델 선택")
                    .purloryUIFont(12, .semibold)
                    .foregroundStyle(theme.inkC)
                Text("이 Mac에서 사용할 수 없음 · 설정에서 관리")
                    .purloryUIFont(10.5)
                    .foregroundStyle(theme.ink3C)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.blueC)
                .frame(width: 16)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                .fill(theme.activeBgC)
        )
    }

    private var advancedModelSettingsButton: some View {
        Button {
            menuOpen = false
            openSettings()
        } label: {
            HStack {
                Label("설정 열기", systemImage: "gearshape")
                    .purloryUIFont(11.5, .medium)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(theme.ink2C)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("자동완성과 모델 옵션이 있는 설정 창 열기")
    }

    private func pick(_ id: String) {
        menuOpen = false
        guard id != settings.modelID, ModelChoice.all.contains(where: { $0.id == id }) else { return }
        Task { try? await completion.replaceModel(with: id) }
    }

    private var statusLabel: String {
        "자동완성 · \(stateText)"
    }

    private var stateText: String {
        if completion.isMemoryPressurePaused { return "메모리 부족" }
        if completion.isManagingModel { return "모델 변경 중" }
        if !settings.autocompleteEnabled { return "꺼짐" }
        if completion.isPredicting { return "예측 중" }
        switch completion.engineState {
        case .idle: return "대기"
        case .downloading(let fraction): return String(format: "다운로드 %.0f%%", fraction * 100)
        case .loading: return "로드 중"
        case .ready: return completion.suggestion != nil ? "제안 준비됨" : "대기"
        case .failed: return "오류"
        }
    }

    private var dotColor: Color {
        if completion.isMemoryPressurePaused { return theme.warningC }
        if !settings.autocompleteEnabled { return theme.ink3C }
        return switch completion.engineState {
        case .idle: theme.ink3C
        case .downloading, .loading: theme.warningC
        case .ready: completion.suggestion != nil ? theme.inkC : theme.ink3C
        case .failed: theme.dangerC
        }
    }

    /// 상태점의 의미를 텍스트로 — 색만 보고 판단하지 않게 (#59-3).
    fileprivate var engineStateAXValue: String {
        if completion.isMemoryPressurePaused { return CompletionController.memoryPressureMessage }
        if !settings.autocompleteEnabled { return "자동완성 꺼짐" }
        switch completion.engineState {
        case .idle: return "대기"
        case .downloading(let fraction):
            return String(format: "다운로드 %.0f%%", fraction * 100)
        case .loading: return "모델 로드 중"
        case .ready: return completion.suggestion != nil ? "제안 준비됨" : "준비됨"
        case .failed: return "오류"
        }
    }

    static func userFacingSummary(for choice: ModelChoice) -> String {
        choice.detail
    }

    static func displayName(_ modelID: String) -> String {
        ModelChoice.matching(modelID)?.name ?? "사용자 지정 모델"
    }

    static func shortID(_ modelID: String) -> String {
        modelID.components(separatedBy: "/").last ?? modelID
    }
}

/// 드롭다운의 작은 ± 스텝 버튼 — HoverIconButton 위임 (#61 PR3).
private struct StepIconButton: View {
    let systemName: String
    let theme: PurloryTheme
    let help: String
    let action: () -> Void

    var body: some View {
        HoverIconButton(
            theme: theme, help: help,
            contentWidth: 22, contentHeight: 22, cornerRadius: PurloryRadius.sm,
            action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
        }
    }
}
