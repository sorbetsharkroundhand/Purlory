import AppKit
import PurloryFoundation
import PurloryDocumentEngine
import PurloryIntelligence

extension BlockTextView {
    var writingRuntimeIdentityProvider: (() -> ProjectRuntimeIdentity?)? {
        get { writingProjectionCapture.runtimeIdentity }
        set {
            let wasConfigured = writingProjectionCapture.hasInitializedIdentity
            writingProjectionCapture.runtimeIdentity = newValue
            if newValue == nil {
                writingProjectionCapture.mappedRevision = nil
                writingProjectionCapture.nativeLookup = nil
            } else if !wasConfigured, let source = writingProjectionCapture.loadedSource {
                writingDidLoad(source)
            }
        }
    }
    var writingCommitDidChange: ((WritingEditorCommit) -> Void)? {
        get { writingProjectionCapture.commitDidChange }
        set { writingProjectionCapture.commitDidChange = newValue }
    }
    var writingCompositionDidChange: ((WritingDiagnosticRange?) -> Void)? {
        get { writingProjectionCapture.compositionDidChange }
        set { writingProjectionCapture.compositionDidChange = newValue }
    }
    var writingNativeRevision: UInt64 { writingProjectionCapture.revision }
    var serializationInvocationCount: Int { writingProjectionCapture.serializationInvocationCount }
    var writingProjectionResetCount: Int { writingProjectionCapture.resetCount }
    var writingProjectionLastInputUTF16: Int { writingProjectionCapture.lastInputUTF16 }

    func writingDidLoad(_ source: String) {
        writingProjectionCapture.didLoad(source: source)
        guard writingProjectionCapture.runtimeIdentity?() != nil else { return }
        writingProjectionCapture.beginInitialCollection()
        invalidateSerialCache()
        let canonical = serialize()
        writingProjectionCapture.finishInitialCollection(original: source, canonical: canonical, nativeLength: textStorage?.length ?? 0)
        writingProjectionCapture.sourceDidLoad?()
    }

    func nativeRange(forSource range: WritingDiagnosticRange, revision: UInt64, expectedQuote: String? = nil) -> WritingDiagnosticRange? {
        guard revision == writingNativeRevision, !hasMarkedText(),
              writingProjectionCapture.compositionDepth == 0,
              writingProjectionCapture.mappedRevision == revision,
              writingProjectionCapture.mappedIdentity == writingProjectionCapture.runtimeIdentity?(),
              let mapped = writingProjectionCapture.nativeLookup?(range), let storage = textStorage,
              expectedQuote.map({ mapped.original.utf16.elementsEqual($0.utf16) }) ?? true,
              mapped.range.location >= 0, mapped.range.location <= storage.length,
              mapped.range.length >= 0, mapped.range.length <= storage.length - mapped.range.location,
              (storage.string as NSString).rangeOfComposedCharacterSequences(for: mapped.range) == mapped.range,
              (storage.string as NSString).substring(with: mapped.range).utf16.elementsEqual(mapped.original.utf16) else { return nil }
        return WritingDiagnosticRange(mapped.range)
    }

    func activeEditingSourceParagraphRange(revision: UInt64) -> WritingDiagnosticRange? {
        guard revision == writingNativeRevision, !hasMarkedText(),
              writingProjectionCapture.compositionDepth == 0,
              writingProjectionCapture.mappedRevision == revision,
              writingProjectionCapture.mappedIdentity == writingProjectionCapture.runtimeIdentity?() else { return nil }
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let selected = selectedRange()
        let clamped = min(max(0, selected.location), ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        guard paragraph.length > 0,
              let coverage = writingProjectionCapture.nativeRows.sourceCoverage(of: paragraph) else { return nil }
        return WritingDiagnosticRange(coverage)
    }

    var isWritingDiagnosticsSuppressedByWorkspace: Bool {
        guard let interaction = workspaceInteraction as? WorkspaceEditorInteraction else { return false }
        return interaction.suppressesEditorWritingDiagnostics
    }
}


extension BlockTextView {
    /// No anchor search or document reload: the exact captured map is the only authority.
    func applyWritingCorrection(_ correction: WritingCorrection, identity: ProjectRuntimeIdentity) -> WritingCorrectionResult {
        if hasMarkedText() || writingProjectionCapture.compositionDepth > 0 { return .refused(reason: .composing) }
        let finding = correction.finding
        guard identity == writingRuntimeIdentityProvider?(), identity == finding.stamp.runtime,
              finding.stamp.nativeRevision == writingNativeRevision else { return .refused(reason: .stale) }
        guard finding.diagnostic.alternatives.contains(where: { $0.utf16.elementsEqual(correction.replacement.utf16) }) else {
            return .refused(reason: .stale)
        }
        guard finding.sourceRanges.count == 1, let source = finding.sourceRanges.first,
              finding.evidence.documentID == identity.key.documentID,
              finding.evidence.utf16Hint == source.location else { return .refused(reason: .ambiguous) }
        guard finding.evidence.quote.utf16.elementsEqual(correction.expectedSource.utf16),
              correction.expectedSource.utf16.count == source.length else { return .refused(reason: .unmapped) }
        guard correction.expectedSource.utf16.elementsEqual(correction.expectedNative.utf16),
              correction.hasPlainReplacement else {
            return .refused(reason: .formatting)
        }
        guard let native = nativeRange(forSource: source, revision: finding.stamp.nativeRevision), let storage = textStorage,
              (storage.string as NSString).substring(with: native.nsRange).utf16.elementsEqual(correction.expectedNative.utf16) else {
            return .refused(reason: .unmapped)
        }
        let attributes = storage.attributes(at: native.location, effectiveRange: nil)
        guard attributes[.attachment] == nil, attributes[.purloryMath] == nil, attributes[.purloryCode] == nil, attributes[.link] == nil else {
            return .refused(reason: .formatting)
        }
        var uniform = true
        storage.enumerateAttributes(in: native.nsRange) { other, _, stop in
            if !NSDictionary(dictionary: attributes).isEqual(NSDictionary(dictionary: other)) { uniform = false; stop.pointee = true }
        }
        guard uniform else { return .refused(reason: .formatting) }
        guard window != nil, allowsUndo, let undo = undoManager else { return .refused(reason: .stale) }
        guard undo.isUndoRegistrationEnabled else { return .refused(reason: .stale) }
        breakUndoCoalescing()
        undo.beginUndoGrouping()
        guard shouldChangeText(in: native.nsRange, replacementString: correction.replacement) else {
            undo.endUndoGrouping(); return .refused(reason: .unmapped)
        }
        storage.replaceCharacters(in: native.nsRange, with: NSAttributedString(string: correction.replacement, attributes: attributes))
        setSelectedRange(NSRange(location: native.location + correction.replacement.utf16.count, length: 0))
        didChangeText()
        undo.setActionName("교정 적용")
        undo.endUndoGrouping()
        breakUndoCoalescing()
        window?.makeFirstResponder(self)
        return .applied
    }
}
