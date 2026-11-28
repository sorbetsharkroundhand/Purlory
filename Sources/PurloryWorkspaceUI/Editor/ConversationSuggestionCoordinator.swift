import Foundation
import PurloryIntelligence
import PurloryFoundation

/// Manages idle dialogue-block detection, suggestion identity scoping, and dismissal memory for `CompletionController`.
@MainActor
final class ConversationSuggestionCoordinator {
    private var task: Task<Void, Never>?
    private var suggestionIdentity: ProjectRuntimeIdentity?
    private var dismissedHashes: Set<String> = []
    private(set) var current: ConversationDetector.Block?

    func schedule(
        prefix: String,
        caretLocation: Int,
        idleDelay: Duration,
        capturedIdentity: ProjectRuntimeIdentity?,
        isStillValid: @escaping @MainActor () -> Bool,
        recordedHashes: @escaping @MainActor () -> Set<String>,
        onPublish: @escaping @MainActor (ConversationDetector.Block) -> Void
    ) {
        cancelTask()
        task = Task { [weak self] in
            try? await Task.sleep(for: idleDelay)
            guard !Task.isCancelled, let self, isStillValid() else { return }
            let text = prefix as NSString
            guard var block = ConversationDetector.blockEnding(at: text.length, in: text) else { return }
            let prefixStart = caretLocation - text.length
            block.utf16Range =
                (block.utf16Range.lowerBound + prefixStart)..<(block.utf16Range.upperBound + prefixStart)
            guard !self.dismissedHashes.contains(block.contentHash),
                  !recordedHashes().contains(block.contentHash)
            else { return }
            self.suggestionIdentity = capturedIdentity
            self.current = block
            onPublish(block)
        }
    }

    func accept(
        currentIdentity: ProjectRuntimeIdentity?,
        requiresIdentityMatch: Bool,
        onClear: () -> Void,
        onRecord: (RecordedConversation) -> Void
    ) -> Bool {
        guard let block = current else { return false }
        if requiresIdentityMatch,
           currentIdentity == nil || currentIdentity != suggestionIdentity {
            clear(onClear: onClear)
            return false
        }
        clear(onClear: onClear)
        onRecord(ConversationDetector.record(from: block, utterances: []))
        return true
    }

    func dismiss(remember: Bool, onClear: () -> Void) {
        if remember, let block = current {
            dismissedHashes.insert(block.contentHash)
        }
        cancelTask()
        clear(onClear: onClear)
    }

    func resetForDocumentSwitch(onClear: () -> Void) {
        dismiss(remember: false, onClear: onClear)
        dismissedHashes.removeAll()
    }

    func cancelTask() {
        task?.cancel()
        task = nil
    }

    func clear(onClear: () -> Void) {
        suggestionIdentity = nil
        guard current != nil else { return }
        current = nil
        onClear()
    }
}
