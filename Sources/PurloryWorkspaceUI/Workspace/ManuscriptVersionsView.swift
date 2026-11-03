import AppKit
import SwiftUI

/// Progressive-disclosure version control for manuscripts:
/// 1. Save Version  2. Compare Versions  3. Split Branch  4. Merge Drafts  5. Restore Version.
/// Branch switching and merging stay hidden until the writer creates a second flow.
struct ManuscriptVersionsView: View {
    @Bindable var session: ProjectSession
    let requests: ProjectEditorRequests
    let theme: PurloryTheme
    let close: () -> Void
    @State private var versions: [ManuscriptVersion] = []
    @State private var branchState = ManuscriptBranchState(documentID: WritingDocumentID())
    @State private var comparison: ManuscriptComparison?
    @State private var mergePreview: (branch: String, merge: ManuscriptThreeWayMerge)?
    @State private var mergeResolutions: [Int: ManuscriptThreeWayMerge.Resolution] = [:]
    @State private var label = ""
    @State private var newBranchName = ""
    @State private var showingBranchPrompt = false
    @State private var message: String?
    @State private var saving = false

    private var availableBranches: [String] {
        var names = branchState.branches.map(\.name)
        for v in versions where !names.contains(v.branchName) { names.append(v.branchName) }
        if names.isEmpty { names.append(ManuscriptVersion.defaultBranchName) }
        return names
    }
    private var hasMultipleBranches: Bool { availableBranches.count > 1 }
    private var visibleVersions: [ManuscriptVersion] {
        guard hasMultipleBranches else { return versions }
        return versions.filter { $0.branchName == branchState.activeBranch }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("원고 기록").purloryUIFont(16, .semibold)
                if hasMultipleBranches {
                    Menu {
                        ForEach(availableBranches, id: \.self) { branch in
                            Button {
                                switchBranch(to: branch)
                            } label: {
                                if branch == branchState.activeBranch {
                                    Label(branch, systemImage: "checkmark")
                                } else {
                                    Text(branch)
                                }
                            }
                        }
                    } label: {
                        Label(branchState.activeBranch, systemImage: "arrow.triangle.branch")
                            .purloryUIFont(11, .medium)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(theme.activeBgC, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("purlory.versions.branch-picker")

                    Menu {
                        ForEach(availableBranches.filter { $0 != branchState.activeBranch }, id: \.self) { other in
                            Button("‘\(other)’ 합치기…") { startMerge(from: other) }
                        }
                    } label: {
                        Label("원고 합치기", systemImage: "arrow.triangle.merge")
                            .purloryUIFont(11, .medium)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("purlory.versions.merge-menu")
                }
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("purlory.versions.close")
            }
            Text("중요한 시점의 원고를 남겨두고 비교하거나, 다른 전개를 부담 없이 시험해 볼 수 있습니다.")
                .foregroundStyle(theme.ink2C)
            HStack(spacing: 8) {
                TextField("기록 메모 (비워두면 자동 이름)", text: $label).textFieldStyle(.roundedBorder)
                Button("버전 저장") { capture(scene: false) }
                    .accessibilityIdentifier("purlory.versions.capture-document")
                Button("현재 장면만 저장") { capture(scene: true) }
                    .disabled(sceneOffset == nil)
                    .accessibilityIdentifier("purlory.versions.capture-scene")
            }.disabled(saving || !session.isEditorEditable)

            if showingBranchPrompt {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(theme.novelC)
                    TextField("새 흐름 이름 (예: 다른 결말, 대안 초고)", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("purlory.versions.branch-name")
                    Button("갈림길 만들기") { createBranch() }
                        .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                        .accessibilityIdentifier("purlory.versions.branch-confirm")
                    Button("취소") { showingBranchPrompt = false; newBranchName = "" }
                }
                .padding(8)
                .background(theme.hoverC, in: RoundedRectangle(cornerRadius: 8))
            }

            if let message { Text(message).foregroundStyle(theme.ink2C).textSelection(.enabled) }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if visibleVersions.isEmpty {
                            Text("아직 저장한 기록이 없습니다.").foregroundStyle(theme.ink2C)
                        }
                        ForEach(visibleVersions) { version in
                            Button { compare(version) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Circle().fill(comparison?.version.id == version.id ? theme.novelC : theme.ink2C)
                                            .frame(width: 6, height: 6)
                                        Text(version.label).fontWeight(.medium).lineLimit(1)
                                    }
                                    Text((version.scope == .document ? "문서 · " : "장면 · ")
                                         + (hasMultipleBranches ? "\(version.branchName) · " : "")
                                         + version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(theme.ink2C).purloryUIFont(10)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(comparison?.version.id == version.id ? theme.activeBgC : theme.hoverC,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel("\(version.label) 비교")
                                .accessibilityIdentifier("purlory.versions.compare.\(version.id.uuidString)")
                        }
                    }
                }.frame(width: 195)
                Divider()
                if let mergePreview {
                    mergeWorkbench(mergePreview.branch, merge: mergePreview.merge)
                } else if let comparison {
                    comparisonWorkbench(comparison)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("왼쪽 기록을 선택하면 저장된 원문과 현재 원고를 비교합니다.")
                            .foregroundStyle(theme.ink2C)
                        if !showingBranchPrompt {
                            Button {
                                showingBranchPrompt = true
                            } label: {
                                Label("현재 원고에서 다른 흐름(갈림길) 나누기…", systemImage: "arrow.triangle.branch")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(theme.novelC)
                            .accessibilityIdentifier("purlory.versions.branch-create")
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }.frame(maxHeight: .infinity)
        }.padding(20).frame(width: 820, height: 570).purloryUIFont(12)
            .foregroundStyle(theme.inkC).background(theme.editorSurfaceC)
            .accessibilityElement(children: .contain)
            .onAppear { refresh() }
            .onChange(of: session.runtimeIdentity?.key) { _, _ in comparison = nil; mergePreview = nil; refresh() }
    }

    @ViewBuilder
    private func comparisonWorkbench(_ comparison: ManuscriptComparison) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(comparison.changes.count)개 변경 구간").fontWeight(.medium)
                Spacer()
                if comparison.version.scope == .document {
                    Button {
                        showingBranchPrompt = true
                    } label: {
                        Label("여기서 갈림길 나누기", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(saving || !session.isEditorEditable)
                    .accessibilityIdentifier("purlory.versions.branch-from-version")
                }
                Button(comparison.version.scope == .document ? "문서 전체 복원" : "장면 전체 복원") { restore(comparison) }
                    .disabled(!canRestore(comparison) || comparison.changes.isEmpty)
                    .accessibilityIdentifier("purlory.versions.restore-all")
            }
            if comparison.identity != session.runtimeIdentity {
                Text("원고가 바뀌었습니다. 왼쪽 기록을 선택해 다시 비교해 주세요.").foregroundStyle(theme.ink2C)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if comparison.changes.isEmpty { Text("현재 원고와 같습니다.") }
                    ForEach(comparison.changes) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                originalColumn("저장된 원문", change.saved)
                                originalColumn("현재 원문", change.current)
                            }
                            Button("이 변경 구간 복원") { restore(comparison, change: change.id) }
                                .disabled(!canRestore(comparison))
                        }.padding(10).background(theme.hoverC, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mergeWorkbench(_ branch: String, merge: ManuscriptThreeWayMerge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("‘\(branch)’ 흐름을 ‘\(branchState.activeBranch)’에 합치기").fontWeight(.semibold)
                Spacer()
                Button("취소") { mergePreview = nil; mergeResolutions = [:] }
                Button("합치기 적용") { confirmMerge(from: branch) }
                    .disabled(saving || !session.isEditorEditable)
                    .accessibilityIdentifier("purlory.versions.merge-apply")
            }
            if merge.conflicts.isEmpty {
                Text("겹치는 문단 충돌 없이 자동으로 깔끔하게 합칠 수 있습니다.")
                    .foregroundStyle(theme.ink2C)
                ScrollView {
                    Text(merge.resolvedText())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.hoverC, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("\(merge.conflicts.count)개 문단에서 두 흐름의 내용이 다릅니다. 남길 문단을 선택해 주세요.")
                    .foregroundStyle(theme.ink2C)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(merge.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 12) {
                                    originalColumn("현재 흐름 (\(branchState.activeBranch))", conflict.ours)
                                    originalColumn("합칠 흐름 (\(branch))", conflict.theirs)
                                }
                                Picker("선택", selection: Binding(
                                    get: { mergeResolutions[conflict.id] ?? .ours },
                                    set: { mergeResolutions[conflict.id] = $0 }
                                )) {
                                    Text("현재 흐름 유지").tag(ManuscriptThreeWayMerge.Resolution.ours)
                                    Text("합칠 흐름 선택").tag(ManuscriptThreeWayMerge.Resolution.theirs)
                                    Text("둘 다 이어붙이기").tag(ManuscriptThreeWayMerge.Resolution.both)
                                }
                                .pickerStyle(.segmented)
                            }.padding(10).background(theme.hoverC, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func originalColumn(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).purloryUIFont(10, .semibold).foregroundStyle(theme.ink2C)
            Text(text.isEmpty ? "(없음)" : text).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var sceneOffset: Int? {
        guard let source = session.selectedDocumentSnapshot, let editor = requests.editor(for: source.identity.key),
              !editor.hasMarkedText(), editor.serialize().utf16.elementsEqual(source.body.utf16) else { return nil }
        return editor.writingProjectionCapture.nativeRows.sourceOffset(forNative: editor.selectedRange().location)
    }
    private func canRestore(_ comparison: ManuscriptComparison) -> Bool {
        session.isEditorEditable && comparison.identity == session.runtimeIdentity && !saving
            && requests.editor(for: comparison.identity.key)?.undoManager != nil
    }
    private func refresh() {
        guard let source = session.selectedDocumentSnapshot else { versions = []; return }
        branchState = ManuscriptBranchState.load(in: source.userData, documentID: source.identity.key.documentID)
        do { versions = try ManuscriptVersion.list(in: source.userData, documentID: source.identity.key.documentID) }
        catch { message = ManuscriptVersionError.invalidRecord.localizedDescription }
    }
    private func capture(scene: Bool) {
        let offset = scene ? sceneOffset : nil
        guard !scene || offset != nil else { return }
        let identity = session.runtimeIdentity, versionLabel = label
        saving = true; message = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                guard session.runtimeIdentity == identity else { throw ProjectSessionError.staleRuntime }
                _ = try await ManuscriptVersionActions.capture(session: session, requests: requests, sceneAt: offset, label: versionLabel)
                label = ""; message = "원고 기록을 저장했습니다."; refresh()
            } catch { message = error.localizedDescription }
        }
    }
    private func createBranch() {
        let targetName = newBranchName
        let base = comparison?.version
        let identity = session.runtimeIdentity
        saving = true; message = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                guard session.runtimeIdentity == identity else { throw ProjectSessionError.staleRuntime }
                _ = try await ManuscriptVersionActions.createBranch(name: targetName, from: base, session: session, requests: requests)
                newBranchName = ""; showingBranchPrompt = false; comparison = nil
                message = "‘\(targetName)’ 흐름으로 분기했습니다."; refresh()
            } catch { message = error.localizedDescription }
        }
    }
    private func switchBranch(to branch: String) {
        saving = true; message = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await ManuscriptVersionActions.switchBranch(to: branch, session: session, requests: requests)
                comparison = nil; mergePreview = nil
                message = "‘\(branch)’ 흐름으로 전환했습니다."; refresh()
            } catch { message = error.localizedDescription }
        }
    }
    private func startMerge(from branch: String) {
        guard let source = session.selectedDocumentSnapshot else { return }
        do {
            let preview = try ManuscriptVersionActions.previewMerge(from: branch, in: source)
            mergeResolutions = [:]
            mergePreview = (branch, preview.merge)
            comparison = nil; message = nil
        } catch { message = error.localizedDescription }
    }
    private func confirmMerge(from branch: String) {
        let chosen = mergeResolutions
        saving = true; message = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await ManuscriptVersionActions.applyMerge(from: branch, resolutions: chosen, session: session, requests: requests)
                mergePreview = nil; mergeResolutions = [:]
                message = "‘\(branch)’ 흐름을 현재 원고에 합쳤습니다."; refresh()
            } catch { message = error.localizedDescription }
        }
    }
    private func compare(_ version: ManuscriptVersion) {
        guard let source = session.selectedDocumentSnapshot else { return }
        do { mergePreview = nil; comparison = try version.comparison(with: source); message = nil }
        catch { comparison = nil; message = error.localizedDescription }
    }
    private func restore(_ comparison: ManuscriptComparison, change: Int? = nil) {
        do {
            try ManuscriptVersionActions.restore(comparison, change: change, session: session, requests: requests)
            self.comparison = nil; message = "복원했습니다. 편집기의 실행 취소로 되돌릴 수 있습니다."
        } catch { message = error.localizedDescription }
    }
}
