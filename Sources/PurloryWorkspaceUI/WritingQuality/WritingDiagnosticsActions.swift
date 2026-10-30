import AppKit

struct WritingCorrection: Sendable {
    let finding: WritingDiagnosticsFinding
    let expectedSource: String
    let expectedNative: String
    let replacement: String

    /// A word/phrase action cannot introduce native Markdown structure or controls.
    var hasPlainReplacement: Bool {
        let syntax = CharacterSet(charactersIn: #"`*_~$#<>[]\"#)
        guard replacement.utf16.count <= 4096,
              !replacement.unicodeScalars.contains(where: {
                  syntax.contains($0) || CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { return false }
        return replacement.range(of: #"^\s*(?:[-+]|\d+\.)(?:\s|$)"#, options: .regularExpression) == nil
    }
}

enum WritingCorrectionRefusal: Sendable, Equatable { case stale, composing, unmapped, ambiguous, formatting }
enum WritingCorrectionResult: Sendable, Equatable {
    case applied
    case refused(reason: WritingCorrectionRefusal)
}


/// Explicit user actions resolve the current finding, alternative and native owner together.
@MainActor
final class WritingDiagnosticsActions {
    private let controller: WritingDiagnosticsController
    private let editor: () -> BlockTextView?
    private let currentSnapshot: () -> ProjectDocumentSnapshot?
    private let session: ProjectSession?
    init(controller: WritingDiagnosticsController, editor: @escaping () -> BlockTextView?,
         currentSnapshot: @escaping () -> ProjectDocumentSnapshot?, session: ProjectSession? = nil) {
        self.controller = controller; self.editor = editor; self.currentSnapshot = currentSnapshot; self.session = session
    }
    static func sameEvidence(_ lhs: EvidenceAnchor, _ rhs: EvidenceAnchor) -> Bool {
        lhs.documentID == rhs.documentID && lhs.sceneHash == rhs.sceneHash && lhs.utf16Hint == rhs.utf16Hint
            && lhs.quote.utf16.elementsEqual(rhs.quote.utf16)
    }
    /// Explicit navigation uses the finding's captured ranges, never a quote search.
    func navigate(findingID: String, evidence: EvidenceAnchor, requests: ProjectEditorRequests) -> Bool {
        guard let finding = controller.currentFinding(id: findingID), let snapshot = currentSnapshot(),
              let session, snapshot.identity == finding.stamp.runtime, session.runtimeIdentity == snapshot.identity,
              let editor = editor(), requests.nativeEditor === editor, !editor.hasMarkedText(),
              editor.writingDocumentIdentity == .project(snapshot.identity.key),
              editor.writingRuntimeIdentityProvider?() == snapshot.identity,
              editor.writingNativeRevision == finding.stamp.nativeRevision else { return false }
        let ranges: [WritingDiagnosticRange]
        if Self.sameEvidence(finding.evidence, evidence) { ranges = finding.sourceRanges }
        else if let index = finding.relatedEvidence.firstIndex(where: { Self.sameEvidence($0, evidence) }),
                finding.relatedSourceRanges.indices.contains(index) { ranges = finding.relatedSourceRanges[index] }
        else { return false }
        let source = snapshot.body as NSString, count = evidence.quote.utf16.count
        guard evidence.documentID == snapshot.identity.key.documentID, let offset = evidence.utf16Hint,
              offset >= 0, offset <= source.length, count > 0, count <= source.length - offset,
              source.substring(with: NSRange(location: offset, length: count)).utf16.elementsEqual(evidence.quote.utf16),
              !ranges.isEmpty else { return false }
        let mapped = ranges.compactMap { editor.nativeRange(forSource: $0, revision: finding.stamp.nativeRevision) }
        guard mapped.count == ranges.count, let start = mapped.map(\.location).min(),
              let end = mapped.map({ $0.location + $0.length }).max(), end > start,
              let point = requests.captureSourcePosition(in: session) else { return false }
        if requests.sourceReturnPoint?.key.projectID != point.key.projectID { requests.sourceReturnPoint = point }
        requests.sourceNavigationError = nil
        editor.restoreSelection(to: NSRange(location: start, length: end - start))
        editor.window?.makeFirstResponder(editor); editor.refreshActiveLineHighlight()
        return true
    }
    @discardableResult
    func perform(_ action: MarginAction, findingID: String) throws -> WritingCorrectionResult? {
        guard let finding = controller.currentFinding(id: findingID), let snapshot = currentSnapshot(),
              snapshot.identity == finding.stamp.runtime, editor()?.hasMarkedText() != true,
              let binding = WritingDiagnosticsPresentation.bindings(for: finding).first(where: { $0.action == action }) else {
            throw WritingDiagnosticsActionError.stale
        }
        if case .apply(let index) = binding.operation { return apply(findingID: findingID, alternativeIndex: index) }
        guard let session, session.runtimeIdentity == snapshot.identity,
              case .ready(var record) = WritingStyleRepository.read(snapshot) else { throw WritingDiagnosticsActionError.stale }
        switch binding.operation {
        case .apply: break
        case .disableRule: record.profile.ignoredRuleIDs.insert(finding.diagnostic.ruleID)
        case .learnWord(let word): record.profile.learnedWords.insert(word)
        case .intentional:
            guard let first = finding.sourceRanges.first, let last = finding.sourceRanges.last else { throw WritingDiagnosticsActionError.stale }
            let range = WritingDiagnosticRange(location: first.location, length: last.location + last.length - first.location)
            let occurrence = try WritingStyleRepository.captureIntentional(ruleID: finding.diagnostic.ruleID, range: range, in: snapshot)
            guard occurrence.evidence.quote.utf16.elementsEqual(finding.evidence.quote.utf16) else { throw WritingDiagnosticsActionError.stale }
            guard controller.rememberExplicitSourceRevision(occurrence.sourceRevision, stamp: finding.stamp) else {
                throw WritingDiagnosticsActionError.stale
            }
            if !record.intentionalOccurrences.contains(occurrence) { record.intentionalOccurrences.append(occurrence) }
        }
        try WritingStyleRepository.update(record, in: session, identity: snapshot.identity)
        return nil
    }
    func apply(findingID: String, alternativeIndex: Int) -> WritingCorrectionResult {
        func refuse(_ reason: WritingCorrectionRefusal) -> WritingCorrectionResult {
            controller.requestRecheck(findingID: findingID)
            return .refused(reason: reason)
        }
        guard let editor = editor() else { return refuse(.stale) }
        if editor.hasMarkedText() { return refuse(.composing) }
        guard let finding = controller.currentFinding(id: findingID), let snapshot = currentSnapshot(),
              snapshot.identity == finding.stamp.runtime, editor.writingRuntimeIdentityProvider?() == snapshot.identity,
              editor.writingNativeRevision == finding.stamp.nativeRevision,
              finding.diagnostic.alternatives.indices.contains(alternativeIndex) else { return refuse(.stale) }
        guard finding.sourceRanges.count == 1, let source = finding.sourceRanges.first else { return refuse(.ambiguous) }
        guard let native = editor.nativeRange(forSource: source, revision: finding.stamp.nativeRevision) else { return refuse(.unmapped) }
        let expectedNative = (editor.string as NSString).substring(with: native.nsRange)
        let correction = WritingCorrection(finding: finding, expectedSource: finding.evidence.quote, expectedNative: expectedNative,
            replacement: finding.diagnostic.alternatives[alternativeIndex])
        let result = editor.applyWritingCorrection(correction, identity: snapshot.identity)
        if case .refused = result { controller.requestRecheck(findingID: findingID) }
        return result
    }
}

enum WritingDiagnosticsActionError: Error { case stale }
