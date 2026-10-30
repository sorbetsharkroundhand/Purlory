import AppKit

@MainActor
final class AskQuestionView: NSView, NSTextFieldDelegate {
    let model: AskPurloryController
    let questionField = NSTextField()
    let sendButton = NSButton(title: "질문", target: nil, action: nil)
    let cancelButton = NSButton(title: "답변 중단", target: nil, action: nil)
    let backButton = NSButton(title: "검색 결과로", target: nil, action: nil)
    let answerView = AskAnswerView(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let scopeLabel = NSTextField(wrappingLabelWithString: "")
    private let scope: SourceSearchScope
    var onBack: (() -> Void)?
    var onInvalidated: (() -> Void)?
    init(model: AskPurloryController, scope: SourceSearchScope) {
        self.model = model; self.scope = scope; super.init(frame: .zero)
        questionField.placeholderString = "찾은 원문에서 궁금한 점"; questionField.delegate = self
        questionField.setAccessibilityLabel("원문에 질문"); questionField.setAccessibilityIdentifier("purlory.ask.question")
        for (button, name, action) in [(sendButton, "send", #selector(submit)), (cancelButton, "cancel", #selector(cancelAnswer)), (backButton, "back", #selector(back))] {
            button.target = self; button.action = action; button.setAccessibilityIdentifier("purlory.ask.\(name)")
        }
        let controls = NSStackView(views: [questionField, sendButton, cancelButton]); controls.orientation = .horizontal
        let heading = NSTextField(labelWithString: "Ask Purlory · 검색 원문을 바탕으로 한 AI 답변")
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [heading, scopeLabel, controls, answerView, status, backButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor), answerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            answerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        model.didChange = { [weak self] in self?.reload() }
        answerView.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.isRunning { self.model.cancel() } else { self.onBack?() }
        }
        reload()
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { if model.isRunning { model.cancel() } else { onBack?() }; return true }
        return false
    }
    @objc private func submit() {
        guard (questionField.currentEditor() as? NSTextView)?.hasMarkedText() != true, model.canAsk else { return }
        model.ask(question: questionField.stringValue)
    }
    @objc private func cancelAnswer() { model.cancel() }
    @objc private func back() { onBack?() }
    func showNavigationError() { status.stringValue = "원문을 열 수 없어요. 입력을 마치거나 다시 검색해 주세요." }
    private func reload() {
        if model.status == .invalidated { answerView.update(packet: nil, blocks: []); onInvalidated?(); return }
        sendButton.isEnabled = model.canAsk && !model.isRunning && !questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancelButton.isEnabled = model.isRunning; questionField.isEnabled = !model.isRunning
        answerView.update(packet: model.packet, blocks: model.blocks)
        let name = scope == .here ? "여기" : scope == .chapter ? "챕터" : "프로젝트"
        scopeLabel.stringValue = model.packet.map { "\(name) · \($0.sources.count)개 원문" } ?? "\(name) · 검색 결과에서 최대 8개 원문"
        let labels: [AskPurloryController.Status: String] = [.idle: "질문을 보내면 선택한 로컬 모델이 원문에서 답변해요.", .preparing: "원문 준비 중…",
            .answering: "답변 중…", .complete: "답변의 원문을 함께 확인해 주세요.", .insufficient: "이 원문만으로는 답변하기 어려워요.",
            .cancelled: "중단했어요. 확인된 답변은 남겨 두었어요.", .paused: model.canAsk ? "다시 질문할 수 있어요." : "글쓰기와 기기 상태를 위해 잠시 쉬고 있어요.",
            .unavailable: "AI가 켜지고 선택한 로컬 모델이 준비되면 질문할 수 있어요.", .failed: "답변을 확인할 수 없어요. 범위를 바꿔 다시 시도해 주세요."]
        status.stringValue = model.errorMessage ?? labels[model.status] ?? ""
    }
}
