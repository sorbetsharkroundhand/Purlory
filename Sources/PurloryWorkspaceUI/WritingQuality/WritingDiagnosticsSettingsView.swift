import SwiftUI

/// Project decisions use the prepared record, never an analysis task or global preferences.
struct WritingDiagnosticsSettingsView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var runtime: WritingDiagnosticsRuntime
    @State private var word = ""
    @State private var errorMessage: String?

    var body: some View {
        Section("문장 교정") {
            if let snapshot = session.selectedDocumentSnapshot,
               let prepared = runtime.controller.preparedStyle, prepared.identity == snapshot.identity {
                switch prepared.load {
                case .ready(let record): controls(record, identity: snapshot.identity).disabled(!session.isEditorEditable)
                case .unreadable(_, let reason): Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("프로젝트에서 문서를 열면 교정 설정을 바꿀 수 있어요.").font(.caption).foregroundStyle(.secondary)
            }
            WritingDiagnosticsStatusView(runtime: runtime)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: session.runtimeIdentity?.key.projectID) { _, _ in word = ""; errorMessage = nil }
    }
    @ViewBuilder
    private func controls(_ record: WritingStyleRecord, identity: ProjectRuntimeIdentity) -> some View {
        sensitivity("반복 표현", value: record.profile.repetitionSensitivity, identity: identity, keyPath: \.repetitionSensitivity)
        sensitivity("대화문 반복", value: record.profile.dialogueSensitivity, identity: identity, keyPath: \.dialogueSensitivity)
        Picker("검사 언어", selection: Binding(get: { record.languageTag ?? "ko" }, set: { value in
            update(identity) { $0.languageTag = value }
        })) {
            if !["ko", "en", "ja"].contains(record.languageTag ?? "ko") {
                Text("저장된 언어").tag(record.languageTag ?? "ko").disabled(true)
            }
            Text("한국어").tag("ko")
            Text("English").tag("en")
            Text("日本語").tag("ja")
        }
        Text("교정 설정과 기억한 단어는 이 프로젝트에 저장해요.").font(.caption).foregroundStyle(.secondary)
        HStack {
            TextField("기억할 단어", text: $word).autocorrectionDisabled()
                .onSubmit { learnWord(identity) }
            Button("기억하기") { learnWord(identity) }
                .disabled(WritingDiagnosticsPresentation.learnableWord(word) == nil)
        }
        if !record.profile.learnedWords.isEmpty {
            DisclosureGroup("기억한 단어 \(record.profile.learnedWords.count)개") {
                ForEach(record.profile.learnedWords.sorted(), id: \.self) { learned in
                    HStack {
                        Text(learned); Spacer()
                        Button("잊기") { update(identity) { $0.profile.learnedWords.remove(learned) } }
                            .accessibilityLabel("‘\(learned)’ 잊기")
                    }
                }
            }
        }
        if !record.profile.ignoredRuleIDs.isEmpty || !record.intentionalOccurrences.isEmpty {
            DisclosureGroup("유지하기로 한 표현과 검사") {
                Text("끄기로 한 검사 \(record.profile.ignoredRuleIDs.count)개 · 의도한 표현 \(record.intentionalOccurrences.count)개")
                    .font(.caption).foregroundStyle(.secondary)
                Button("끄기로 한 검사 다시 사용") { update(identity) { $0.profile.ignoredRuleIDs.removeAll() } }
                    .disabled(record.profile.ignoredRuleIDs.isEmpty)
                Button("의도한 표현 다시 확인") { update(identity) { $0.intentionalOccurrences.removeAll() } }
                    .disabled(record.intentionalOccurrences.isEmpty)
            }
        }
    }
    private func sensitivity(_ label: String, value: WritingQualitySensitivity, identity: ProjectRuntimeIdentity,
                             keyPath: WritableKeyPath<WritingStyleProfile, WritingQualitySensitivity>) -> some View {
        Picker(label, selection: Binding(get: { value }, set: { next in update(identity) { $0.profile[keyPath: keyPath] = next } })) {
            Text("끄기").tag(WritingQualitySensitivity.off)
            Text("적게").tag(WritingQualitySensitivity.low)
            Text("보통").tag(WritingQualitySensitivity.standard)
            Text("민감하게").tag(WritingQualitySensitivity.high)
        }
    }
    private func learnWord(_ identity: ProjectRuntimeIdentity) {
        guard let learned = WritingDiagnosticsPresentation.learnableWord(word) else { errorMessage = "단어만 입력해 주세요."; return }
        if update(identity, change: { $0.profile.learnedWords.insert(learned) }) { word = "" }
    }
    @discardableResult
    private func update(_ identity: ProjectRuntimeIdentity, change: (inout WritingStyleRecord) -> Void) -> Bool {
        guard session.runtimeIdentity == identity, let prepared = runtime.controller.preparedStyle,
              prepared.identity == identity, case .ready(var record) = prepared.load else {
            errorMessage = "프로젝트나 설정이 바뀌었습니다. 다시 확인해 주세요."; return false
        }
        change(&record)
        do {
            try WritingStyleRepository.update(record, in: session, identity: identity); errorMessage = nil; return true
        } catch {
            errorMessage = "교정 설정을 바꾸지 못했습니다. 저장된 원본은 보존됩니다."; return false
        }
    }
}

struct WritingDiagnosticsStatusView: View {
    @ObservedObject var runtime: WritingDiagnosticsRuntime
    @State private var detailsVisible = false
    var body: some View {
        HStack(spacing: 8) {
            if runtime.controller.state.status == .checking { ProgressView().controlSize(.small).accessibilityLabel("교정 확인 중") }
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("자세히") { detailsVisible.toggle() }.font(.caption)
                .popover(isPresented: $detailsVisible) { Text(details).font(.callout).padding().frame(width: 260) }
            if runtime.controller.state.status == .partial || runtime.controller.state.status == .unavailable {
                Button("다시 확인") { runtime.retry() }.font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("문장 교정 · " + title)
        if let message = runtime.actionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
    }
    private var title: String {
        switch runtime.controller.state.status {
        case .idle: runtime.controller.state.coverage.isComplete ? "교정 확인됨" : "교정 대기"
        case .checking: "교정 확인 중"
        case .partial: "교정 일부 확인"
        case .paused: "교정 잠시 쉬는 중"
        case .unavailable: "교정 확인 필요"
        }
    }
    private var details: String {
        switch runtime.controller.state.availability {
        case .unsupportedLanguage: "이 언어의 교정 검사는 아직 준비되지 않았어요."
        case .unavailableProfile: "저장된 교정 설정을 읽을 수 없어 원본을 보존하고 있어요. 문서는 계속 편집할 수 있어요."
        case .unavailableResource, .unavailableProvider: "교정 검사기를 사용할 수 없어요. 문서는 계속 편집하고 저장할 수 있어요."
        case .unsupportedInput: "일부 표현은 확인하지 못했어요. 확인한 부분의 제안만 표시해요."
        case .pausedPolicy: "글쓰기와 제안 작업에 여유가 생기면 검사를 이어가요. 전원과 기기 상태에 따라 잠시 쉴 수 있어요."
        case .available: runtime.controller.state.status == .partial
            ? "아직 확인하지 못한 부분이 있어요. 다시 확인할 수 있어요."
            : "지원하는 맞춤법·띄어쓰기와 반복 표현, 문장 패턴을 확인해요. 수정은 제안을 선택할 때만 적용해요."
        }
    }
}
