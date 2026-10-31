import AppKit
import SwiftUI

/// An explicit writing tool: reading saved originals never changes the live manuscript.
struct ManuscriptVersionsView: View {
    @Bindable var session: ProjectSession
    let requests: ProjectEditorRequests
    let theme: PurloryTheme
    let close: () -> Void
    @State private var versions: [ManuscriptVersion] = []
    @State private var comparison: ManuscriptComparison?
    @State private var label = ""
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("원고 기록").purloryUIFont(16, .semibold)
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("purlory.versions.close")
            }
            Text("현재 문서 또는 제목으로 나뉜 장면을 보관합니다. 원문을 비교하고 문단별로 되돌릴 수 있습니다.")
                .foregroundStyle(theme.ink2C)
            HStack {
                TextField("기록 이름 (선택)", text: $label).textFieldStyle(.roundedBorder)
                Button("문서 저장") { capture(scene: false) }
                    .accessibilityIdentifier("purlory.versions.capture-document")
                Button("현재 장면 저장") { capture(scene: true) }
                    .disabled(sceneOffset == nil).accessibilityIdentifier("purlory.versions.capture-scene")
            }.disabled(saving || !session.isEditorEditable)
            if let message { Text(message).foregroundStyle(theme.ink2C).textSelection(.enabled) }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if versions.isEmpty { Text("아직 저장한 기록이 없습니다.").foregroundStyle(theme.ink2C) }
                        ForEach(versions) { version in
                            Button { compare(version) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(version.label).fontWeight(.medium)
                                    Text((version.scope == .document ? "문서 · " : "장면 · ") + version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(theme.ink2C).purloryUIFont(10)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(comparison?.version.id == version.id ? theme.activeBgC : theme.hoverC,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel("\(version.label) 비교")
                                .accessibilityIdentifier("purlory.versions.compare.\(version.id.uuidString)")
                        }
                    }
                }.frame(width: 185)
                Divider()
                if let comparison {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(comparison.changes.count)개 변경 구간").fontWeight(.medium)
                            Spacer()
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
                } else {
                    Text("왼쪽 기록을 선택하면 저장된 원문과 현재 원고를 비교합니다.")
                        .foregroundStyle(theme.ink2C).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxHeight: .infinity)
        }.padding(20).frame(width: 820, height: 570).purloryUIFont(12)
            .foregroundStyle(theme.inkC).background(theme.editorSurfaceC)
            .accessibilityElement(children: .contain)
            .onAppear { refresh() }
            .onChange(of: session.runtimeIdentity?.key) { _, _ in comparison = nil; refresh() }
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
    private func compare(_ version: ManuscriptVersion) {
        guard let source = session.selectedDocumentSnapshot else { return }
        do { comparison = try version.comparison(with: source); message = nil }
        catch { comparison = nil; message = error.localizedDescription }
    }
    private func restore(_ comparison: ManuscriptComparison, change: Int? = nil) {
        do {
            try ManuscriptVersionActions.restore(comparison, change: change, session: session, requests: requests)
            self.comparison = nil; message = "복원했습니다. 편집기의 실행 취소로 되돌릴 수 있습니다."
        } catch { message = error.localizedDescription }
    }
}
