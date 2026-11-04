import SwiftUI
import UniformTypeIdentifiers

struct DocumentOutlineView: View {
    @ObservedObject var controller: DocumentOutlineController
    @ObservedObject var requests: ProjectEditorRequests
    @Bindable var session: ProjectSession
    let theme: PurloryTheme
    @State private var draggedHeadingID: Int?
    @State private var dropTargetHeadingID: Int?

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
                                let isDropTarget = dropTargetHeadingID == heading.id
                                Button {
                                    requests.jump(to: heading, prepared: prepared, in: session)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(verbatim: heading.title).lineLimit(3)
                                            Spacer(minLength: 0)
                                            if current { Text("현재").purloryUIFont(10).foregroundStyle(theme.ink2C) }
                                        }
                                        .purloryUIFont(12, current ? .semibold : .regular)
                                        .foregroundStyle(theme.inkC)
                                        if !heading.synopsisPreview.isEmpty {
                                            Text(verbatim: heading.synopsisPreview)
                                                .purloryUIFont(10.5)
                                                .foregroundStyle(theme.ink3C)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 8).padding(.horizontal, 8)
                                    .padding(.leading, CGFloat(heading.level - 1) * 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(current ? theme.activeBgC : .clear,
                                        in: RoundedRectangle(cornerRadius: PurloryRadius.sm))
                                    .overlay(alignment: .bottom) {
                                        if isDropTarget {
                                            Rectangle()
                                                .fill(theme.novelC)
                                                .frame(height: 1.5)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onDrag {
                                    draggedHeadingID = heading.id
                                    return NSItemProvider(object: String(heading.id) as NSString)
                                }
                                .onDrop(
                                    of: [UTType.plainText],
                                    delegate: OutlineHeadingDropDelegate(
                                        target: heading,
                                        headings: prepared.projection.headings,
                                        draggedHeadingID: $draggedHeadingID,
                                        dropTargetHeadingID: $dropTargetHeadingID,
                                        onMove: { sourceHeading, targetHeading, after in
                                            try? WorkspaceParagraphTransfer.moveSceneSection(
                                                source: sourceHeading,
                                                target: targetHeading,
                                                after: after,
                                                key: prepared.identity.key,
                                                in: session,
                                                requests: requests
                                            )
                                        }
                                    )
                                )
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

@MainActor
private struct OutlineHeadingDropDelegate: DropDelegate {
    let target: DocumentOutlineProjection.Heading
    let headings: [DocumentOutlineProjection.Heading]
    @Binding var draggedHeadingID: Int?
    @Binding var dropTargetHeadingID: Int?
    let onMove: (DocumentOutlineProjection.Heading, DocumentOutlineProjection.Heading, Bool) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedHeadingID != nil, draggedHeadingID != target.id else { return }
        dropTargetHeadingID = target.id
    }

    func dropExited(info: DropInfo) {
        if dropTargetHeadingID == target.id {
            dropTargetHeadingID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedHeadingID = nil
            dropTargetHeadingID = nil
        }
        guard let sourceID = draggedHeadingID,
              sourceID != target.id,
              let sourceHeading = headings.first(where: { $0.id == sourceID }) else {
            return false
        }
        onMove(sourceHeading, target, true)
        return true
    }
}
