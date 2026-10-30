import SwiftUI

struct DocumentOutlineView: View {
    @ObservedObject var controller: DocumentOutlineController
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var session: ProjectSession
    let theme: PurloryTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prepared = controller.prepared, prepared.identity == session.runtimeIdentity {
                if prepared.projection.headings.isEmpty {
                    notice("제목이 있는 문단이 여기에 보여요.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(prepared.projection.headings) { heading in
                                let current = controller.currentHeadingID == heading.id
                                Button {
                                    requests.jump(to: heading, prepared: prepared, in: session)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(verbatim: heading.title).lineLimit(3)
                                        Spacer(minLength: 0)
                                        if current { Text("현재").purloryUIFont(10).foregroundStyle(theme.ink2C) }
                                    }
                                    .purloryUIFont(12, current ? .semibold : .regular)
                                    .foregroundStyle(theme.inkC)
                                    .padding(.vertical, 8).padding(.horizontal, 8)
                                    .padding(.leading, CGFloat(heading.level - 1) * 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(current ? theme.activeBgC : .clear,
                                        in: RoundedRectangle(cornerRadius: PurloryRadius.sm))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("제목 \(heading.level)단계, \(heading.title)")
                                .accessibilityValue(current ? "현재 위치" : "")
                            }
                        }
                    }
                }
            } else {
                notice(statusText)
            }
            if let error = requests.sourceNavigationError { notice(error) }
            Spacer(minLength: 0)
            if requests.sourceReturnPoint != nil {
                Button("집필 위치로 돌아가기") { requests.returnToWriting(in: session) }
                    .purloryUIFont(11).accessibilityIdentifier("purlory.document-outline.return")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspacePaperSurface(theme: theme, identifier: "purlory.document-outline"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("purlory.document-outline")
        .accessibilityLabel("문서 개요")
    }

    private var statusText: String {
        switch controller.status {
        case .checking: "개요를 준비하고 있어요."
        case .paused: "집필을 위해 개요 갱신을 잠시 쉬고 있어요."
        case .unavailable: "개요를 준비하지 못했어요. 원고를 편집하면 다시 확인해요."
        case .idle: "제목이 있는 문단이 여기에 보여요."
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).purloryUIFont(11).foregroundStyle(theme.ink3C)
    }
}
