import SwiftUI

/// Native Settings panes prioritize writing controls while retaining the existing settings owner.
/// Each grouped form scrolls within the fixed window, including custom palettes and diagnostics.
public struct SettingsView: View {
    @ObservedObject private var settings: CompletionSettings
    /// 예측 의유 통로 (이슈 #11) — 자동완성 스위치·모델 변경은 settings를 직접
    /// 고치지 않고 컨트롤러의 무효화(세대 상승·스트림 취소·리포트 폐기)를 함께
    /// 발화한다. nil이면 프리뷰처럼 값만 바뀐다.
    private let completion: CompletionController?
    private let projectSession: ProjectSession?
    private let writingDiagnostics: WritingDiagnosticsRuntime?
    /// 실사용 품질 지표 집계 (M7) — .task에서 백그라운드 로드.
    @State private var metrics = AcceptanceMetrics.Summary()
    /// 외형(다크 모드) — 상단바 스위치에서 옮겨 왔다. 키는 그대로 둬서 기존
    /// 사용자의 선택이 유지된다. ""=시스템 따름 · "light" · "dark".
    @AppStorage("purlory.appearance") private var appearance = ""
    @Environment(\.colorScheme) private var colorScheme
    /// 색상 팔레트 — 고르는 즉시 앱 전체에 반영된다 (ContentView도 관찰).
    // 앱 수명 싱글턴 — StateObject 소유 의미 (#60).
    @StateObject private var palette = PaletteSettings.shared
    @State private var advancedPredictionSettingsExpanded = false
    /// 모델 ID 초안 — 커밋(Enter/적용)까지 settings에 쓰지 않는다 (#65 H2).
    @State private var modelIDDraft = ""
    /// 초안 검증 실패 문구 — nil이면 오류 없음.
    @State private var modelIDError: String?
    @State private var ownedModelIDs: [String] = []
    @State private var isChangingModel = false

    public init(
        settings: CompletionSettings = .shared,
        completion: CompletionController? = nil,
        projectSession: ProjectSession? = nil, writingDiagnostics: WritingDiagnosticsRuntime? = nil
    ) {
        self._settings = ObservedObject(wrappedValue: settings)
        self.completion = completion
        self.projectSession = projectSession; self.writingDiagnostics = writingDiagnostics
    }

    public var body: some View {
        TabView {
            writingTab
                .tabItem { Label("글쓰기", systemImage: "pencil") }
            appearanceTab
                .tabItem { Label("모양", systemImage: "paintpalette") }
            predictionTab
                .tabItem { Label("자동완성", systemImage: "sparkles") }
            helpTab
                .tabItem { Label("사용 방법", systemImage: "questionmark.circle") }
            advancedTab
                .tabItem { Label("고급", systemImage: "slider.horizontal.3") }
        }
        // Keep every pane scrollable within the existing native Settings window.
        .frame(width: 500, height: 520)
        .tint(palette.theme(for: colorScheme).blueC)
        .onAppear { syncModelIDDraft() }
        // 프리셋 적용 등 외부 경로로 모델이 바뀌면 초안·오류를 따라 맞춘다.
        .onChange(of: settings.modelID) { _, _ in syncModelIDDraft() }
        .task {
            await AcceptanceMetrics.flush()
            // 파일 집계는 백그라운드에서 — 설정 창이 뜨는 프레임을 안 막는다.
            metrics = await Task.detached(priority: .utility) {
                AcceptanceMetrics.summarize()
            }.value
            guard !Task.isCancelled else { return }  // stale 결과 할당 금지 (#60)
            ownedModelIDs = await ModelInstallationStore.shared.ownedModelIDs()
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section("외형") {
                // 3상태 — 시스템/라이트/다크를 모두 노출한다 (#29).
                // 과거 토글은 "시스템 따름"을 숨겨 선택지를 깎았다.
                Picker("모양", selection: appearanceBinding) {
                    Text("시스템 따름").tag("")
                    Text("라이트").tag("light")
                    Text("다크").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("색상") {
                Toggle("색상 직접 고르기", isOn: $palette.enabled)
                if let warning = palette.contrastWarning {
                    Text(warning)
                        .purloryUIFont(11)
                        .foregroundStyle(PurloryTheme.of(colorScheme).warningC)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("대비 경고: \(warning)"))
                }
                caption(
                    palette.enabled
                        ? "아래에서 고른 색이 배경·툴바·사이드바·배지에 쓰여요 — 글자는 항상 읽히도록 따로 관리돼요."
                        : "지금은 기본 색을 쓰고 있어요. 켜면 라이트·다크 각각 다섯 색을 직접 고를 수 있어요.")
            }

            if palette.enabled {
                paletteSection(dark: false)
                paletteSection(dark: true)
            }
        }
        .formStyle(.grouped)
    }

    /// 색상 팔레트 — 밝기 순 5슬롯을 라이트/다크 각각 고른다.
    ///
    /// 팔레트는 **배경·표면에만** 쓰인다. 글자색은 팔레트와 무관하게 유지되고,
    /// 액센트만 팔레트에서 색상을 물려받아 대비에 맞게 명도를 조정한다 —
    /// 그러지 않으면 밝은 색만 고른 순간 글자가 사라진다.
    @ViewBuilder private func paletteSection(dark: Bool) -> some View {
        Section(dark ? "색상 — 다크 모드" : "색상 — 라이트 모드") {
            ForEach(0..<PurloryPalette.slotCount, id: \.self) { slot in
                ColorPicker(
                    PurloryPalette.slotLabels[slot],
                    selection: paletteBinding(dark: dark, slot: slot),
                    supportsOpacity: false)
            }
            Button("기본값으로 되돌리기") {
                palette.reset(dark: dark)
            }
        }
    }

    /// 슬롯 하나의 색 바인딩 — SwiftUI `Color` ↔ 저장용 hex 왕복.
    private func paletteBinding(dark: Bool, slot: Int) -> Binding<Color> {
        Binding(
            get: {
                let current = dark ? palette.dark : palette.light
                return Color(nsColor: current.color(slot))
            },
            set: { newValue in
                let hex = NSColor(newValue).hexValue
                var current = dark ? palette.dark : palette.light
                current.hexes[slot] = hex
                if dark { palette.dark = current } else { palette.light = current }
            }
        )
    }

    // MARK: - 자동완성

    private var predictionTab: some View {
        Form {
            Section("자동완성") {
                Toggle("자동완성 사용", isOn: autocompleteBinding)
                caption(
                    settings.autocompleteEnabled
                        ? "글을 멈추면 이 Mac에서 이어질 내용을 제안해요."
                        : "꺼져 있어도 편집·저장·검색·내보내기는 그대로 사용할 수 있어요."
                )

                Picker("모델", selection: userFacingModelBinding) {
                    ForEach(ModelChoice.all) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                    if !ModelChoice.all.contains(where: { $0.id == settings.modelID }) {
                        Text(settings.modelID.isEmpty ? "사용 가능한 모델 없음" : "사용 불가 · 보관된 선택")
                            .tag(settings.modelID).disabled(true)
                    }
                }
                .disabled(isChangingModel || ModelChoice.all.isEmpty)
                caption(modelSelectionCaption)

                Stepper(
                    "제안 길이: \(settings.maxTokens)",
                    value: $settings.maxTokens,
                    in: 4...32,
                    step: 2
                )
                caption("한 번에 보여줄 제안의 최대 길이예요.")
            }

            Section("모델 파일") {
                if isChangingModel { ProgressView("모델 파일 정리 중…") }
                ForEach(Array(Set(ownedModelIDs + [settings.modelID]).filter { !$0.isEmpty }).sorted(), id: \.self) { id in
                    HStack {
                        Text(ModelChoice.matching(id)?.name ?? ModelChip.shortID(id))
                        Spacer()
                        Button("파일 삭제", role: .destructive) { removeModelFiles(id) }
                            .disabled(isChangingModel || completion == nil)
                    }
                }
                caption("모델 파일만 삭제합니다. 원고와 작품 정보는 그대로 유지합니다.")
                if let modelIDError { Text(modelIDError).foregroundStyle(.red).font(.caption) }
            }

            Section {
                DisclosureGroup(
                    "고급 설정",
                    isExpanded: $advancedPredictionSettingsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("모델 저장소")
                                .purloryUIFont(12, .semibold)
                            TextField(
                                "Hugging Face 저장소 ID (namespace/model)",
                                text: $modelIDDraft
                            )
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .onSubmit(commitModelIDDraft)
                            if let modelIDError {
                                Text(modelIDError)
                                    .purloryUIFont(11)
                                    .foregroundStyle(PurloryTheme.of(colorScheme).dangerC)
                                    .accessibilityLabel(Text("모델 ID 오류: \(modelIDError)"))
                            }
                            HStack {
                                Menu("저장소 프리셋") {
                                    ForEach(ModelChoice.all) { choice in
                                        Button(choice.name) {
                                            changeModel(choice.id)
                                        }
                                    }
                                }
                                .disabled(ModelChoice.all.isEmpty)
                                Spacer()
                                Button("적용", action: commitModelIDDraft)
                                    .disabled(
                                        isChangingModel || modelIDDraft.trimmingCharacters(in: .whitespaces)
                                            == settings.modelID
                                    )
                            }
                        }

                        Divider()

                        Picker("프롬프트 방식", selection: $settings.promptStyle) {
                            ForEach(PromptStyle.allCases, id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Stepper(
                            "제안 대기: \(settings.debounceMilliseconds)ms",
                            value: $settings.debounceMilliseconds,
                            in: 150...1_000,
                            step: 50
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $settings.temperature, in: 0...1) {
                                Text(String(format: "온도: %.2f", settings.temperature))
                            }
                            caption("낮을수록 일관되고, 높을수록 다양한 제안을 만들어요.")
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $settings.topP, in: 0.5...1.0) {
                                Text(String(format: "top-p: %.2f", settings.topP))
                            }
                            caption("생성 후보의 누적 확률 범위를 조절해요.")
                        }

                        Toggle("KV 캐시 재사용", isOn: $settings.kvCacheEnabled)
                        caption("입력 중 프리필을 재사용합니다. 문제가 있을 때만 꺼 보세요.")
                    }
                    .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var userFacingModelBinding: Binding<String> {
        Binding(
            get: { settings.modelID },
            set: { id in
                guard id != settings.modelID else { return }
                changeModel(id)
            }
        )
    }

    private var modelSelectionCaption: String {
        if ModelChoice.all.isEmpty { return "사용 가능한 모델이 없습니다. 원고 편집은 계속할 수 있습니다." }
        guard ModelChoice.all.contains(where: { $0.id == settings.modelID }),
              let choice = ModelChoice.matching(settings.modelID) else {
            return "보관된 선택은 이 Mac에서 사용할 수 없습니다. 다른 모델을 선택하세요."
        }
        return ModelChip.userFacingSummary(for: choice) + " · 처음 사용할 때 내려받아요."
    }

    // MARK: - Writing

    private var writingTab: some View {
        Form {
            Section("본문") {
                Stepper(
                    "글자 크기: \(Int(settings.editorFontSize.rounded()))pt",
                    value: $settings.editorFontSize,
                    in: CompletionSettings.minFontSize...CompletionSettings.maxFontSize,
                    step: 1
                )
                caption("본문·제목이 이 크기에 비례해요 (⌘+ / ⌘− / ⌘0).")
                Stepper(
                    "줄 간격: \(Int(settings.lineSpacing.rounded()))pt",
                    value: $settings.lineSpacing,
                    in: 0...20,
                    step: 1
                )
                caption("줄 사이 여백을 조절해요 — 낮추면 촘촘하게, 높이면 시원하게.")
            }

            if let projectSession, let writingDiagnostics {
                WritingDiagnosticsSettingsView(session: projectSession, runtime: writingDiagnostics)
            } else {
                Section("문장 교정") {
                    Text("프로젝트를 열면 교정 설정을 바꿀 수 있어요.").purloryUIFont(11).foregroundStyle(.secondary)
                }
            }

            Section("저자") {
                TextField("저자 이름 (필명)", text: $settings.authorName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                caption("EPUB으로 내보낼 때 저자로 실려요 — 비워 두면 저자 정보 없이 내보내요.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 사용 방법 (단축키·마크다운)

    /// 상단바 도움말 버튼을 대신한다. 여기 적는 단축키는 전부 코드에 실제로
    /// 있는 것만 (AppCommands·BlockTextView 기준).
    private var helpTab: some View {
        Form {
            Section("제안 다루기") {
                shortcut("Tab", "제안 전체 수락")
                shortcut("→", "제안을 한 단어만 수락")
                shortcut("Esc", "제안 무시")
            }

            Section("글쓰기") {
                shortcut("⌘B / ⌘I / ⇧⌘C", "굵게 · 기울임 · 인라인 코드")
                shortcut("⌥⌘1~3 / ⌥⌘0", "제목 1~3 · 본문")
                shortcut("⇧⌘I", "이미지 삽입 (붙여넣기·드래그 드롭도 돼요)")
                shortcut("⌘+ / ⌘− / ⌘0", "글자 크게 · 작게 · 기본")
            }

            Section("찾기·이동") {
                shortcut("⌘F / ⌘G / ⇧⌘G", "문서에서 찾기 · 다음 · 이전")
                shortcut("⌘K / ⇧⌘K", "원문 검색 · 이전 집필 위치로 돌아가기")
                shortcut("⇧⌘F", "프로젝트·라이브러리 검색")
            }

            Section("문서·창") {
                shortcut("⌘N", "새 문서")
                shortcut("⇧⌘N / ⌥⌘N", "새 Fiction 프로젝트 · 새 General 프로젝트")
                shortcut("⌘S", "저장")
                shortcut("⌃⌘S", "파일 목록 접기/펴기")
                shortcut("⇧⌘D", "집중 모드")
                shortcut("⇧⌘E / ⌘P", "Markdown 내보내기 · 인쇄")
                caption("문서 이름 바꾸기와 EPUB 내보내기는 파일 메뉴에서 할 수 있어요.")
            }

            Section("마크다운 서식") {
                MarkdownCheatSheet(theme: PurloryTheme.of(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    /// Experimental context controls and local diagnostics keep their existing bindings and actions.
    private var advancedTab: some View {
        Form {
            Section("이해 범위") {
                Picker("제안 문맥 비교", selection: Binding(get: { settings.ghostContextMode }, set: { mode in
                    if let completion { completion.changeContextMode(to: mode) }
                    else { settings.ghostContextMode = mode }
                })) {
                    ForEach(GhostContextMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                caption("A/B는 요약을 넣지 않아요. 모델이 준비되면 원문 범위를 넓히되, 모델의 한도 안에서 읽어요. 기본은 C예요.")
                Stepper(
                    "소설 컨텍스트: \(settings.novelContextCharacters)자",
                    value: $settings.novelContextCharacters,
                    in: 1_200...12_000,
                    step: 400
                )
                caption("소설 종류 문서가 커서 앞에서 읽는 최대 분량 — 넓을수록 멀리 기억하지만 첫 제안이 느려질 수 있어요.")
            }

            Section("품질 지표 (로컬 전용)") {
                if metrics.shown == 0 {
                    caption("아직 기록이 없어요 — 제안이 뜨고 수락/거절될 때마다 이 Mac에만 기록돼요.")
                } else {
                    LabeledContent("제안 노출", value: "\(metrics.shown)회")
                    LabeledContent(
                        "전체 수락 (Tab)",
                        value: "\(metrics.acceptedFull)회 · \(metrics.acceptanceRate)%")
                    LabeledContent("단어 수락 (→)", value: "\(metrics.acceptedWord)회")
                    ForEach(metrics.byMode.keys.sorted(), id: \.self) { mode in
                        let stats = metrics.byMode[mode] ?? (0, 0)
                        LabeledContent(
                            "· \(mode)",
                            value: "노출 \(stats.shown) · 수락 \(stats.accepted)")
                        .font(.caption)
                    }
                    ForEach(GhostContextMode.allCases.filter { metrics.byContextMode[$0] != nil }, id: \.self) { mode in
                        let stats = metrics.byContextMode[mode]!
                        LabeledContent(mode.label, value: "노출 \(stats.shown) · 수락 \(stats.acceptedFull) · 거절 \(stats.dismissed)")
                        if let latency = stats.latencyP50Ms {
                            LabeledContent("생성 지연 중위값", value: "\(latency)ms").font(.caption)
                        }
                    }
                    caption("수락과 지연을 함께 살펴보세요. 같은 모델의 결과끼리 비교해야 해요. 예전 기록에는 A/B/C 구분이 없어요.")
                }
                Button("지표 삭제") {
                    AcceptanceMetrics.reset()
                    metrics = .init()
                }
                caption("어떤 지표도 기기 밖으로 나가지 않아요 (~/Documents/Purlory/metrics.jsonl).")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 예측 의유 바인딩 (이슈 #11)

    /// 컨트롤러가 있으면 의유 API로, 없으면(프리뷰) 직접 쓴다.
    private func changeModel(_ id: String) {
        do {
            guard let manifest = PinnedModelCatalog.manifest(for: id) else { throw ModelInstallError.metadata }
            try ModelMemoryPolicy.current.requireLoad(manifest: manifest)
        } catch { modelIDError = error.localizedDescription; return }
        guard let completion else {
            settings.modelID = id
            return
        }
        guard !isChangingModel else { return }
        isChangingModel = true
        Task {
            do { try await completion.replaceModel(with: id); modelIDError = nil }
            catch { modelIDError = error.localizedDescription }
            ownedModelIDs = await ModelInstallationStore.shared.ownedModelIDs()
            isChangingModel = false
        }
    }
    private func removeModelFiles(_ id: String) {
        guard let completion, !isChangingModel else { return }
        isChangingModel = true
        Task {
            do { try await completion.removeModel(id); modelIDError = nil }
            catch { modelIDError = error.localizedDescription }
            ownedModelIDs = await ModelInstallationStore.shared.ownedModelIDs()
            isChangingModel = false
        }
    }

    private var autocompleteBinding: Binding<Bool> {
        Binding(
            get: { settings.autocompleteEnabled },
            set: { enabled in
                guard let completion else {
                    settings.setCompletionEnabled(enabled)
                    return
                }
                completion.setAutocompleteEnabled(enabled)
            })
    }

    /// 초안을 검증해 유효한 새 ID일 때만 changeModel을 **한 번** 호출한다 (#65 H2).
    /// 같은 ID는 무해(무동작), 잘못된 ID는 인라인 오류로 현재 모델을 건드리지 않는다.
    private func commitModelIDDraft() {
        switch ModelIDCommit.validate(modelIDDraft) {
        case .failure(let error):
            modelIDError = error.message
        case .success(let id):
            modelIDError = nil
            guard id != settings.modelID else { return }
            changeModel(id)
        }
    }

    /// 프리셋·외부 경로로 모델이 바뀌면 초안을 따라 맞춘다.
    private func syncModelIDDraft() {
        modelIDDraft = settings.modelID
        modelIDError = nil
    }

    // MARK: - 공용 조각

    /// 설명 한 줄 — 컨트롤 아래 붙는 보조 문구.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 단축키 한 줄 — 키는 고정폭으로 읽기 쉽게.
    private func shortcut(_ keys: String, _ label: String) -> some View {
        LabeledContent {
            Text(keys).font(PurloryFonts.monoUI(11, .semibold))
        } label: {
            Text(label)
        }
    }

    /// 외형 3상태 바인딩 — ""(시스템)/light/dark (#29).
    private var appearanceBinding: Binding<String> {
        Binding(
            get: { appearance },
            set: { appearance = $0 }
        )
    }
}

#if canImport(PreviewsMacros)
#Preview {
    SettingsView(settings: CompletionSettings())
}
#endif
