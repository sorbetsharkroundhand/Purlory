import SwiftUI

/// Explicit manual indexing trigger and phase status display shared across workspace cards and writer tools.
struct ManualIndexButton: View {
    @Bindable var indexer: BackgroundIndexer
    let theme: PurloryTheme

    var body: some View {
        switch indexer.manualPhase {
        case .idle:
            menu
        case .queued:
            phaseText("준비 중…", color: theme.ink3C)
        case .reading(let done, let total):
            HStack(spacing: 6) {
                Text("읽는 중 \(done)/\(total)")
                    .font(PurloryFonts.monoUI(10))
                    .foregroundStyle(theme.ink2C)
                Button {
                    indexer.cancelManualPass()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.ink3C)
                }
                .buttonStyle(.plain)
                .help("읽기 중단 — 여기까지 읽은 것은 저장돼 있어요")
                .accessibilityLabel(Text("읽기 중단"))
            }
            .accessibilityElement(children: .combine)
        case .blocked(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(reason)
                    .purloryUIFont(9.5)
                    .foregroundStyle(theme.warningC)
                    .fixedSize(horizontal: false, vertical: true)
                retryButton(label: "다시 시도")
            }
        case .stalled(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .purloryUIFont(9.5)
                    .foregroundStyle(theme.dangerC)
                    .fixedSize(horizontal: false, vertical: true)
                retryButton(label: "다시 시도")
            }
        case .completedNew:
            phaseText("새로 읽었어요", color: theme.ink3C)
        case .completedNoChange:
            phaseText("변한 게 없어요 — 이미 최신이에요", color: theme.ink3C)
        case .cancelled:
            phaseText("중단했어요 — 여기까지는 저장됐어요", color: theme.ink3C)
        }
    }

    private var menu: some View {
        Menu {
            Button {
                indexer.requestPass()
            } label: {
                Label("지금 읽기 — 바뀐 부분만", systemImage: "sparkles")
            }
            Button {
                indexer.requestFullPass()
            } label: {
                Label("처음부터 다시 읽기", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label("지금 읽기", systemImage: "sparkles")
                .purloryUIFont(10.5, .medium)
                .foregroundStyle(theme.novelC)
        } primaryAction: {
            indexer.requestPass()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("클릭: 바뀐 씬만 읽기 · 메뉴: 전체 다시 읽기 (직접 수정한 내용은 보존돼요)")
        .accessibilityLabel(Text("지금 읽기"))
    }

    private func retryButton(label: String) -> some View {
        Button(label) { indexer.requestPass() }
            .purloryUIFont(10, .semibold)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel(Text("다시 시도"))
    }

    private func phaseText(_ text: String, color: Color) -> some View {
        Text(text)
            .purloryUIFont(10)
            .foregroundStyle(color)
            .lineLimit(1)
            .help(text)
    }
}
