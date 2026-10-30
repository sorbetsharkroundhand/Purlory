import AppKit

@MainActor
enum ProjectRecoveryPanel {
    private static var isPresenting = false

    @discardableResult
    static func present(session: ProjectSession) async -> Bool {
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        do {
            return try await ProjectRecoveryFlow(session: session).run { preview in
                return makePreviewAlert(preview).runModal() == .alertFirstButtonReturn
            }
        } catch {
            session.reportError(error)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "이전 저장본을 복구하지 못했습니다"
            alert.informativeText = "\(singleLine(error.localizedDescription, limit: 240))\n\n현재 데이터는 보존되었습니다. 저장본을 다시 확인한 뒤 시도해주세요."
            alert.addButton(withTitle: "확인")
            alert.runModal()
            return false
        }
    }

    static func makePreviewAlert(_ preview: ProjectBackupPreview) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "이전 저장본 확인"
        let documents = preview.project.documents.filter { !preview.project.trashedDocumentIDs.contains($0.id) }
        let titles = documents.prefix(3).map { singleLine($0.title, limit: 80) }.joined(separator: " · ")
        let excerpt = documents.first.map { String($0.body.prefix(180)) } ?? ""
        alert.informativeText = "\(singleLine(preview.project.title, limit: 120))\n문서 \(documents.count)개 · 이미지 \(preview.assetCount)개\n\n이전 저장본을 새 프로젝트 사본으로 엽니다. 현재 프로젝트와 손상된 원본은 그대로 보관됩니다."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = false
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        text.font = NSFont.systemFont(ofSize: 12)
        text.string = "\(titles)\n\n\(excerpt)"
        text.setAccessibilityIdentifier("purlory.recovery.preview-text")
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "복구 사본 열기")
        alert.addButton(withTitle: "취소")
        alert.buttons[0].setAccessibilityIdentifier("purlory.recovery.open-copy")
        alert.buttons[1].setAccessibilityIdentifier("purlory.recovery.cancel")
        return alert
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        let sample = text.prefix(limit + 1)
        let line = String(sample.prefix(limit).map { $0.isWhitespace ? Character(" ") : $0 })
        return line + (sample.count > limit ? "…" : "")
    }
}
