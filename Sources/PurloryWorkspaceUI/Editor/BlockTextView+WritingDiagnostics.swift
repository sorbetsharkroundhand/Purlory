import AppKit


struct WritingNativeMappedRange {
    let range: NSRange
    let original: String
}

/// Passive capture only. Publication requires a map prepared by the same serialization.
@MainActor
final class WritingEditorProjectionCapture {
    struct CapturedRow { let native: NSRange; let row: WritingSerializedRow }
    private struct Change { let old: NSRange; let new: NSRange; var delta: Int { new.length - old.length } }
    private struct DeferredEdit {
        let range: NSRange
        let fragments: [String]
        let rows: WritingNativeRowIndex
    }
    private var deferred: [DeferredEdit] = []
    private var projectionTask: Task<Void, Never>?
    private var collectionEpoch: UInt64 = 0
    var runtimeIdentity: (() -> ProjectRuntimeIdentity?)?
    var commitDidChange: ((WritingEditorCommit) -> Void)?
    var sourceDidLoad: (() -> Void)?
    var compositionDidChange: ((WritingDiagnosticRange?) -> Void)?
    private(set) var revision: UInt64 = 0
    private(set) var resetCount = 0
    var serializationInvocationCount = 0
    var lastInputUTF16 = 0
    private(set) var compositionDepth = 0
    private var marked: WritingDiagnosticRange?
    private var base: ProjectRuntimeIdentity?
    private var boundRevision: UInt64?
    private var boundIdentity: ProjectRuntimeIdentity?
    private var dirty: NSRange?
    var currentDirtyRange: NSRange? { dirty }
    private var oldDirty: NSRange?
    private var changes: [Change] = []
    private var bindingIdentity: ProjectRuntimeIdentity?
    private var knownIdentity: ProjectRuntimeIdentity?
    var hasInitializedIdentity: Bool { knownIdentity != nil }
    private var bindingIsCurrent = false
    private var isBinding = false
    private var needsCanonicalLoadCompletion = false

    private func resetStaleDirtyState() {
        dirty = nil
        oldDirty = nil
        changes.removeAll(keepingCapacity: true)
        mappedRevision = nil
    }
    private weak var serializationStorage: NSAttributedString?
    var nativeLookup: ((WritingDiagnosticRange) -> WritingNativeMappedRange?)?
    var mappedRevision: UInt64?
    var mappedIdentity: ProjectRuntimeIdentity?
    var prepared: (revision: UInt64, patch: WritingProjectionPatch)?
    private var loadedDocumentSource: DocumentSource?
    var loadedSource: String? { loadedDocumentSource?.string }
    private var initializing = false
    private var capturingLine: NSRange?
    private var lineHasFeed = false
    private var bodyLength = 0
    private var bodySpans: [InlineMarkdown.SerializedSpan] = []
    private(set) var capturedRows: [CapturedRow] = []
    var nativeRows = WritingNativeRowIndex()
    let sourceProjection = WritingProjectionIndex()
    var publishedProjection: WritingProjectionIndex?

    func rejectUnownedLoad() {
        loadedDocumentSource = nil
        knownIdentity = nil; mappedIdentity = nil; mappedRevision = nil; nativeLookup = nil
        base = nil; boundIdentity = nil; boundRevision = nil; prepared = nil
        projectionTask?.cancel(); projectionTask = nil; deferred.removeAll(); collectionEpoch &+= 1
    }

    func didLoad(source: String) {
        projectionTask?.cancel(); projectionTask = nil; deferred.removeAll(); collectionEpoch &+= 1
        revision &+= 1; resetCount += 1
        dirty = nil; base = nil; boundRevision = nil; boundIdentity = nil
        nativeLookup = nil; prepared = nil; marked = nil
        mappedRevision = nil; mappedIdentity = nil
        loadedDocumentSource = DocumentSource(source)
        oldDirty = nil; changes.removeAll(); knownIdentity = runtimeIdentity?()
    }
    func beginInitialCollection() { initializing = true }
    func beginSerialization(storage: NSAttributedString?) {
        serializationStorage = storage
        capturedRows.removeAll(keepingCapacity: true)
    }
    func beginLine(_ range: NSRange, hasLineFeed: Bool) {
        capturingLine = nil
        guard runtimeIdentity?() != nil,
              initializing || dirty.map({ range.location <= $0.upperBound + 1 && range.upperBound >= max(0, $0.location - 1) }) == true else { return }
        capturingLine = range; lineHasFeed = hasLineFeed
        bodyLength = 0; bodySpans.removeAll(keepingCapacity: true)
    }
    var capturesCurrentLine: Bool { capturingLine != nil }
    func recordSpan(_ span: InlineMarkdown.SerializedSpan) {
        guard let range = capturingLine else { return }
        bodyLength = span.source.upperBound
        bodySpans.append(.init(source: span.source, body: span.body,
                              native: NSRange(location: span.native.location - range.location, length: span.native.length), style: span.style,
                              prefix: span.prefix, suffix: span.suffix, opaqueID: span.opaqueID))
    }
    func recordRawBody() {
        guard let range = capturingLine else { return }
        let length = range.length - (lineHasFeed ? 1 : 0)
        bodyLength = length
        if length > 0 {
            bodySpans = [.init(source: NSRange(location: 0, length: length), body: NSRange(location: 0, length: length),
                               native: NSRange(location: 0, length: length), style: .init())]
        }
    }
    func finishLine(text: String, prefix: String, suffix: String, isCode: Bool, eligible: Bool, literal: Bool = false) {
        guard let native = capturingLine else { return }
        defer { capturingLine = nil }
        let width = prefix.utf16.count
        let spans: [InlineMarkdown.SerializedSpan] = literal ? [] : bodySpans.map { span in
            .init(source: NSRange(location: span.source.location + width, length: span.source.length),
                  body: span.body.map { NSRange(location: $0.location + width, length: $0.length) }, native: span.native, style: span.style,
                  prefix: span.prefix, suffix: span.suffix, opaqueID: span.opaqueID)
        }
        let attributes = native.location < (serializationStorage?.length ?? 0)
            ? serializationStorage?.attributes(at: native.location, effectiveRange: nil) ?? [:] : [:]
        let row = WritingSerializedRow(text: text, textLength: width + (literal ? 0 : bodyLength) + suffix.utf16.count,
            nativeContentLength: native.length - (lineHasFeed ? 1 : 0), hasLineFeed: lineHasFeed,
            isCode: isCode, eligible: eligible, prefix: prefix, suffix: suffix,
            blockStyle: WritingSerializedBlockStyle(attributes), spans: spans)
        capturedRows.append(CapturedRow(native: native, row: row))
    }
    func finishInitialCollection(original: String, canonical: String, nativeLength: Int) {
        initializing = false
        nativeRows.reset(rows: capturedRows.map(\.row))
        sourceProjection.reset(source: canonical)
        let equal = original.utf16.elementsEqual(canonical.utf16)
        needsCanonicalLoadCompletion = !equal
        if equal { publishedProjection = sourceProjection.snapshot() }
        else {
            let originalIndex = WritingProjectionIndex()
            originalIndex.reset(source: original)
            publishedProjection = originalIndex
        }
        guard equal, nativeRows.nativeLength == nativeLength, nativeRows.sourceLength == sourceProjection.sourceLength else { return }
        mappedRevision = revision; mappedIdentity = runtimeIdentity?()
        nativeLookup = { [weak self] range in self?.lookup(range) }
    }
    private func lookup(_ range: WritingDiagnosticRange) -> WritingNativeMappedRange? {
        guard range.location >= 0, range.length > 0, range.location <= sourceProjection.sourceLength,
              range.length <= sourceProjection.sourceLength - range.location,
              let native = nativeRows.nativeRange(forSource: range.nsRange) else { return nil }
        var cursor = range.location, original = ""
        while cursor < range.location + range.length {
            guard let piece = sourceProjection.sourcePiece(containing: cursor) else { return nil }
            let end = min(range.location + range.length, piece.range.location + piece.range.length)
            var covered = cursor
            for segment in piece.block.segments {
                let absolute = NSRange(location: piece.range.location + segment.source.location, length: segment.source.length)
                let clipped = NSIntersectionRange(absolute, NSRange(location: cursor, length: end - cursor))
                if clipped.length > 0 {
                    guard segment.eligible, !segment.unsupported, clipped.location == covered else { return nil }
                    covered = clipped.upperBound
                }
            }
            guard covered == end else { return nil }
            original += (piece.block.sourceText as NSString).substring(with: NSRange(location: cursor - piece.range.location, length: end - cursor))
            cursor = end
        }
        return WritingNativeMappedRange(range: native, original: original)
    }
    private func originalPoint(_ point: Int, end: Bool) -> Int {
        var result = point
        for change in changes.reversed() {
            if result > change.new.upperBound { result -= change.delta }
            else if result >= change.new.location { result = end ? change.old.upperBound : change.old.location }
        }
        return result
    }
    private func movedPoint(_ point: Int, through change: Change, end: Bool) -> Int {
        if point > change.old.upperBound { return point + change.delta }
        if point >= change.old.location { return end ? change.new.upperBound : change.new.location }
        return point
    }
    private func authorStyle(_ attributes: [NSAttributedString.Key: Any]) -> MarkdownInlineScanner.Style {
        var result = MarkdownInlineScanner.Style()
        result.code = attributes[.purloryCode] as? Bool == true
        if !result.code {
            result.bold = attributes[.purloryBold] as? Bool == true
            result.italic = attributes[.purloryItalic] as? Bool == true
            result.strikethrough = attributes[.purloryStrikethrough] as? Bool == true
            result.highlight = attributes[.purloryHighlight] as? Bool == true
        }
        result.color = attributes[.purloryColor] as? String
        result.fontSize = attributes[.purloryFontSize] as? Double
        return result
    }
    func hasUnchangedAuthorMetadata(_ storage: NSAttributedString, range: NSRange) -> Bool {
        oldDirty == nil && dirty == nil && matchesAuthorMetadata(storage, range: range)
    }
    private func matchesAuthorMetadata(_ storage: NSAttributedString, range: NSRange) -> Bool {
        guard storage.length == nativeRows.nativeLength, range.location <= storage.length,
              range.length <= storage.length - range.location else { return false }
        var matches = true
        storage.enumerateAttributes(in: range, options: []) { attributes, run, stop in
            var cursor = run.location
            while cursor < run.upperBound && matches {
                guard let located = nativeRows.row(containingNative: cursor) else { matches = false; break }
                let first = storage.attributes(at: located.nativeRange.location, effectiveRange: nil)
                guard WritingSerializedBlockStyle(first) == located.row.blockStyle else { matches = false; break }
                let relative = cursor - located.nativeRange.location
                if !located.row.eligible || relative >= located.row.nativeContentLength {
                    cursor = min(run.upperBound, located.nativeRange.upperBound)
                    continue
                }
                guard let span = located.row.spans.first(where: { NSLocationInRange(relative, $0.native) }) else { matches = false; break }
                if let opaque = span.opaqueID {
                    guard let atom = attributes[.attachment] as? MathAtomAttachment, ObjectIdentifier(atom) == opaque else { matches = false; break }
                } else if authorStyle(attributes) != span.style { matches = false; break }
                cursor = min(run.upperBound, located.nativeRange.location + span.native.upperBound)
            }
            if !matches { stop.pointee = true }
        }
        return matches
    }
    private func readSource(_ range: NSRange) -> String? {
        guard range.location <= sourceProjection.sourceLength,
              range.length <= sourceProjection.sourceLength - range.location else { return nil }
        var result = "", cursor = range.location
        while cursor < range.upperBound {
            guard let piece = sourceProjection.sourcePiece(containing: cursor) else { return nil }
            let end = min(range.upperBound, piece.range.location + piece.range.length)
            result += (piece.block.sourceText as NSString).substring(with: NSRange(location: cursor - piece.range.location, length: end - cursor))
            cursor = end
        }
        return result
    }
    private func frames(_ row: WritingSerializedRow) -> [InlineMarkdown.SerializedSpan] {
        var result: [InlineMarkdown.SerializedSpan] = []
        for span in row.spans {
            if span.prefix.isEmpty && span.suffix.isEmpty && span.opaqueID == nil,
               let previous = result.last, previous.prefix.isEmpty && previous.suffix.isEmpty && previous.opaqueID == nil,
               previous.style == span.style, previous.native.upperBound == span.native.location {
                result.removeLast()
                result.append(.init(source: NSUnionRange(previous.source, span.source),
                    body: NSRange(location: previous.body!.location, length: previous.native.length + span.native.length),
                    native: NSUnionRange(previous.native, span.native), style: span.style))
            } else { result.append(span) }
        }
        return result
    }
    private func literalFramesMatch(old: WritingNativeRowIndex.Located, new: CapturedRow, change: Change) -> Bool {
        guard old.row.blockStyle == new.row.blockStyle, old.row.prefix == new.row.prefix,
              old.row.suffix == new.row.suffix, old.row.isCode == new.row.isCode, old.row.eligible == new.row.eligible else { return false }
        let before = frames(old.row), after = frames(new.row)
        let relative = NSRange(location: change.old.location - old.nativeRange.location, length: change.old.length)
        guard before.count == after.count,
              let active = before.firstIndex(where: { $0.body != nil && relative.location >= $0.native.location && relative.upperBound <= $0.native.upperBound }) else { return false }
        for i in before.indices {
            let a = before[i], b = after[i]
            guard a.style == b.style, a.prefix == b.prefix, a.suffix == b.suffix, a.opaqueID == b.opaqueID else { return false }
            let expected = i == active ? NSRange(location: a.native.location, length: a.native.length + change.delta)
                : NSRange(location: a.native.location + (i > active ? change.delta : 0), length: a.native.length)
            guard expected == b.native else { return false }
        }
        return true
    }
    private static let syntaxPunctuation = CharacterSet(charactersIn: "[](){}!$`*_~=<>\\\n")
    private static let syntaxDelimiters = CharacterSet(charactersIn: "[](){}!$`*_~=<>\\\"'")
    private static let linkSyntaxSensitive = CharacterSet(charactersIn: " \t\"'")
    private static let boundarySensitive = CharacterSet(charactersIn: "[](){}!$`*_~=<>\\\n \t\"'")

    private static func isSyntaxDelimiter(_ unit: UInt16) -> Bool {
        UnicodeScalar(unit).map { syntaxDelimiters.contains($0) } ?? false
    }

    private static func isBoundarySensitive(_ unit: UInt16) -> Bool {
        UnicodeScalar(unit).map { boundarySensitive.contains($0) } ?? false
    }

    private func projectionFootprint(for range: NSRange) -> NSRange? {
        if sourceProjection.sourceLength == 0 { return NSRange(location: 0, length: 0) }
        guard let a = sourceProjection.sourcePiece(containing: range.location),
              let b = sourceProjection.sourcePiece(containing: max(range.location, range.upperBound - 1)) else {
            return nil
        }
        return NSRange(location: a.range.location, length: b.range.location + b.range.length - a.range.location)
    }

    private func updateProjection(storage: NSAttributedString, ownerChanged: Bool) -> Bool {
        lastInputUTF16 = 0
        guard oldDirty != nil else {
            guard !needsCanonicalLoadCompletion || ownerChanged else { return false }
            needsCanonicalLoadCompletion = false
            return true
        }
        guard let first = capturedRows.first, let last = capturedRows.last else { return false }
        let oldStart = originalPoint(first.native.location, end: false)
        let oldEnd = originalPoint(last.native.upperBound, end: true)
        let oldNative: NSRange
        if nativeRows.nativeLength == 0 { oldNative = NSRange(location: 0, length: 0) }
        else {
            guard let a = nativeRows.row(containingNative: oldStart),
                  let b = nativeRows.row(containingNative: max(oldStart, oldEnd - 1)) else { return false }
            oldNative = NSRange(location: a.nativeRange.location, length: b.nativeRange.upperBound - a.nativeRange.location)
        }
        let draft = nativeRows.snapshot()
        guard draft.replace(oldNative, with: capturedRows.map(\.row)), draft.nativeLength == storage.length else { return false }
        var replacement: (range: NSRange, text: String)?
        var literalContext: (footprint: NSRange, context: String, removed: String, inherited: [WritingProseProjection.Run])?
        if projectionTask == nil, deferred.isEmpty, changes.count == 1, capturedRows.count == 1, let change = changes.first,
           change.new.length <= 4096, change.old.length <= 4096,
           let oldRow = nativeRows.row(containingNative: change.old.location),
           literalFramesMatch(old: oldRow, new: first, change: change),
           let a = nativeRows.sourceOffset(forNative: change.old.location),
           let b = nativeRows.sourceOffset(forNative: change.old.upperBound),
           let c = draft.sourceOffset(forNative: change.new.location),
           let d = draft.sourceOffset(forNative: change.new.upperBound), a == c,
           b - a == change.old.length, d - c == change.new.length,
           draft.sourceLength - nativeRows.sourceLength == change.delta {
            let range = NSRange(location: a, length: b - a)
            let inserted = (storage.string as NSString).substring(with: change.new)
            if inserted.rangeOfCharacter(from: Self.syntaxPunctuation) == nil,
               let removed = readSource(range),
               removed.rangeOfCharacter(from: Self.syntaxPunctuation) == nil,
               let footprint = projectionFootprint(for: range),
               footprint.length <= 8192,
               let context = readSource(footprint),
               let inherited = inheritedRuns(in: footprint, context: context, replacing: range, removed: removed, inserted: inserted) {
                replacement = (range, inserted)
                literalContext = (footprint, context, removed, inherited)
            }
        }
        if replacement == nil {
            let coverage: NSRange
            if nativeRows.nativeLength == 0 { coverage = NSRange(location: 0, length: 0) }
            else if let existing = nativeRows.sourceCoverage(of: oldNative) { coverage = existing }
            else { return false }
            var fragments: [String] = [], previousCode = first.native.location > 0
                ? draft.row(containingNative: first.native.location - 1)?.row.isCode ?? false : false
            for captured in capturedRows {
                if previousCode != captured.row.isCode {
                    let lang = captured.row.isCode ? (captured.row.blockStyle.codeLang ?? "") : ""
                    fragments.append("```\(lang)\n")
                }
                fragments.append(captured.row.text)
                if captured.row.hasLineFeed { fragments.append("\n") }
                previousCode = captured.row.isCode
            }
            if last.native.upperBound == draft.nativeLength {
                if previousCode { fragments.append(last.row.hasLineFeed ? "```\n" : "\n```") }
            } else if let next = draft.row(containingNative: last.native.upperBound), next.row.isCode != previousCode {
                let lang = next.row.isCode ? (next.row.blockStyle.codeLang ?? "") : ""
                fragments.append("```\(lang)\n")
            }
            let width = capturedRows.reduce(0, { $0 + $1.row.baseSourceLength })
            if projectionTask != nil || !deferred.isEmpty || width > 4096 || coverage.length > 4096 {
                guard ownerChanged else { return false }
                deferred.append(DeferredEdit(range: coverage, fragments: fragments, rows: draft))
                nativeRows = draft; oldDirty = nil; dirty = nil; changes.removeAll(keepingCapacity: true)
                return true
            }
            let text = fragments.joined()
            guard text.utf16.count - coverage.length == draft.sourceLength - nativeRows.sourceLength else { return false }
            replacement = (coverage, text)
        }
        guard let replacement else { return false }
        let oldText: String
        if let literal = literalContext {
            oldText = literal.removed
        } else {
            guard let resolvedOldText = readSource(replacement.range) else { return false }
            oldText = resolvedOldText
        }
        let sourceChanged = needsCanonicalLoadCompletion || !oldText.utf16.elementsEqual(replacement.text.utf16)
        guard ownerChanged || !sourceChanged else { return false }
        let footprint: NSRange
        let context: String
        let inherited: [WritingProseProjection.Run]?
        if let literal = literalContext {
            footprint = literal.footprint
            context = literal.context
            inherited = literal.inherited
        } else {
            guard let resolvedFootprint = projectionFootprint(for: replacement.range),
                  resolvedFootprint.length <= 8192,
                  let resolvedContext = readSource(resolvedFootprint) else { return false }
            footprint = resolvedFootprint
            context = resolvedContext
            let prefixRange = NSRange(location: footprint.location,
                                      length: replacement.range.location - footprint.location)
            let suffixRange = NSRange(location: replacement.range.upperBound,
                                      length: footprint.upperBound - replacement.range.upperBound)
            let delta = replacement.text.utf16.count - replacement.range.length
            guard let prefixRuns = existingRuns(in: prefixRange, shift: -footprint.location),
                  let suffixRuns = existingRuns(in: suffixRange, shift: -footprint.location + delta) else {
                return false
            }
            var combined: [WritingProseProjection.Run] = []
            combined.reserveCapacity(prefixRuns.count + suffixRuns.count + 4)
            for run in prefixRuns { appendCoalescedRun(run, to: &combined) }
            for run in inlineRunsForCompleteLines(replacement.text, offset: prefixRange.length) {
                appendCoalescedRun(run, to: &combined)
            }
            for run in suffixRuns { appendCoalescedRun(run, to: &combined) }
            inherited = combined
        }
        let changed = (context as NSString).replacingCharacters(in: NSRange(location: replacement.range.location - footprint.location,
                                                                          length: replacement.range.length), with: replacement.text)
        lastInputUTF16 = changed.utf16.count
        let blocks = projectedPieces(changed, sourceOffset: footprint.location, rows: draft, inherited: inherited)
        guard sourceProjection.sourceLength + changed.utf16.count - footprint.length == draft.sourceLength,
              sourceProjection.apply(.init(oldSourceRange: .init(footprint), replacement: blocks)) else { return false }
        nativeRows = draft; needsCanonicalLoadCompletion = false
        self.oldDirty = nil; dirty = nil; changes.removeAll(keepingCapacity: true)
        return true
    }
    private func appendCoalescedRun(_ run: WritingProseProjection.Run, to runs: inout [WritingProseProjection.Run]) {
        if run.eligible, let last = runs.last, last.eligible,
           last.unsupported == run.unsupported, last.source.upperBound == run.source.location {
            runs[runs.count - 1] = WritingProseProjection.Run(
                source: NSRange(location: last.source.location, length: last.source.length + run.source.length),
                eligible: true,
                unsupported: last.unsupported
            )
        } else {
            runs.append(run)
        }
    }
    private enum InheritedState: Equatable {
        case omitted
        case segment(eligible: Bool, unsupported: Bool)
    }
    private struct InheritedStateInterval {
        let range: NSRange
        let state: InheritedState
    }

    private func inheritedState(
        atInsertion offset: Int,
        states: [InheritedStateInterval],
        context: String,
        footprintStart: Int
    ) -> InheritedState? {
        let eligibleProse = InheritedState.segment(eligible: true, unsupported: false)

        if let interior = states.first(where: { $0.range.location < offset && offset < $0.range.upperBound }) {
            if interior.state == eligibleProse {
                return eligibleProse
            }
            if case .segment(_, true) = interior.state {
                return nil
            }
            let local = offset - footprintStart
            let ns = context as NSString
            guard local > 0, local < ns.length else { return nil }
            let beforeUnit = ns.character(at: local - 1)
            let afterUnit = ns.character(at: local)
            guard !Self.isBoundarySensitive(beforeUnit), !Self.isBoundarySensitive(afterUnit) else {
                return nil
            }
            return interior.state
        }

        let left = states.first(where: { $0.range.upperBound == offset })
        let right = states.first(where: { $0.range.location == offset })

        if let left, let right {
            if left.state == eligibleProse || right.state == eligibleProse {
                return eligibleProse
            }
            return nil
        }

        if let right, left == nil {
            if right.state == eligibleProse {
                return eligibleProse
            }
            if offset > 0, let previousPiece = sourceProjection.sourcePiece(containing: offset - 1) {
                let trailingState: InheritedState
                if let last = previousPiece.block.segments.last,
                   last.source.upperBound == previousPiece.range.length {
                    trailingState = .segment(eligible: last.eligible, unsupported: last.unsupported)
                } else {
                    trailingState = .omitted
                }
                if trailingState == eligibleProse {
                    return eligibleProse
                }
                if right.state == .omitted,
                   trailingState == .omitted || trailingState == .segment(eligible: false, unsupported: false),
                   let lastUnit = previousPiece.block.sourceText.utf16.last,
                   let firstUnit = context.utf16.first,
                   !Self.isBoundarySensitive(lastUnit),
                   !Self.isBoundarySensitive(firstUnit) {
                    return .omitted
                }
            }
            return nil
        }

        if let left, right == nil {
            return left.state == eligibleProse ? eligibleProse : nil
        }

        return nil
    }

    /// Reuse proven grammar scopes for a literal edit, including an excluded URL spanning pieces.
    /// Returns nil when syntax boundaries or link-sensitive characters require a full-row reparse.
    private func inheritedRuns(
        in footprint: NSRange,
        context: String,
        replacing old: NSRange,
        removed: String,
        inserted: String
    ) -> [WritingProseProjection.Run]? {
        guard footprint.length > 0 else { return nil }
        let length = inserted.utf16.count
        var rawRuns: [WritingProseProjection.Run] = []
        var states: [InheritedStateInterval] = []
        var cursor = footprint.location
        let delta = length - old.length

        func appendState(_ range: NSRange, _ state: InheritedState) {
            guard range.length > 0 else { return }
            if let last = states.last, last.state == state, last.range.upperBound == range.location {
                states[states.count - 1] = InheritedStateInterval(
                    range: NSRange(location: last.range.location, length: last.range.length + range.length),
                    state: state
                )
            } else {
                states.append(InheritedStateInterval(range: range, state: state))
            }
        }

        while cursor < footprint.upperBound, let piece = sourceProjection.sourcePiece(containing: cursor) {
            guard piece.range.length > 0 else { return nil }
            var localCursor = piece.range.location
            let pieceEnd = piece.range.location + piece.range.length
            for segment in piece.block.segments {
                let global = NSRange(location: piece.range.location + segment.source.location, length: segment.source.length)
                if global.location > localCursor {
                    appendState(NSRange(location: localCursor, length: global.location - localCursor), .omitted)
                }
                appendState(global, .segment(eligible: segment.eligible, unsupported: segment.unsupported))
                localCursor = global.upperBound

                let before = NSIntersectionRange(global, NSRange(location: footprint.location, length: old.location - footprint.location))
                if before.length > 0 {
                    rawRuns.append(.init(
                        source: NSRange(location: before.location - footprint.location, length: before.length),
                        eligible: segment.eligible,
                        unsupported: segment.unsupported
                    ))
                }
                let after = NSIntersectionRange(global, NSRange(location: old.upperBound, length: footprint.upperBound - old.upperBound))
                if after.length > 0 {
                    rawRuns.append(.init(
                        source: NSRange(location: after.location + delta - footprint.location, length: after.length),
                        eligible: segment.eligible,
                        unsupported: segment.unsupported
                    ))
                }
            }
            if pieceEnd > localCursor {
                appendState(NSRange(location: localCursor, length: pieceEnd - localCursor), .omitted)
            }
            cursor = pieceEnd
        }
        guard cursor == footprint.upperBound else { return nil }

        let eligibleProse = InheritedState.segment(eligible: true, unsupported: false)
        let contextNS = context as NSString
        let localOldStart = old.location - footprint.location
        let localOldEnd = old.upperBound - footprint.location

        let beforeUnit: UInt16?
        if localOldStart > 0 {
            beforeUnit = contextNS.character(at: localOldStart - 1)
        } else if footprint.location > 0 {
            beforeUnit = sourceProjection.sourcePiece(containing: footprint.location - 1)?.block.sourceText.utf16.last
        } else {
            beforeUnit = nil
        }
        let afterUnit: UInt16?
        if localOldEnd < contextNS.length {
            afterUnit = contextNS.character(at: localOldEnd)
        } else if footprint.upperBound < sourceProjection.sourceLength {
            afterUnit = sourceProjection.sourcePiece(containing: footprint.upperBound)?.block.sourceText.utf16.first
        } else {
            afterUnit = nil
        }
        if beforeUnit.map(Self.isSyntaxDelimiter) == true || afterUnit.map(Self.isSyntaxDelimiter) == true {
            return nil
        }

        let prevNL = localOldStart > 0
            ? contextNS.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: localOldStart)).location
            : NSNotFound
        let lineStartLocal = prevNL == NSNotFound ? 0 : prevNL + 1
        let nextNL = localOldEnd < contextNS.length
            ? contextNS.range(of: "\n", options: [], range: NSRange(location: localOldEnd, length: contextNS.length - localOldEnd)).location
            : NSNotFound
        let lineEndLocal = nextNL == NSNotFound ? contextNS.length : nextNL
        let lineLocal = NSRange(location: lineStartLocal, length: lineEndLocal - lineStartLocal)

        // Any edit on a line containing `$` or `<` can toggle MathScanner currency/whitespace rules,
        // `<font ...>` attribute validity, or `<...>` angle link destinations without adding punctuation.
        if contextNS.range(of: "$", options: .literal, range: lineLocal).location != NSNotFound
            || contextNS.range(of: "<", options: .literal, range: lineLocal).location != NSNotFound {
            return nil
        }

        let touchesLinkSyntax = inserted.rangeOfCharacter(from: Self.linkSyntaxSensitive) != nil
            || removed.rangeOfCharacter(from: Self.linkSyntaxSensitive) != nil
        let isPureDeletion = old.length > 0 && length == 0
        if touchesLinkSyntax || isPureDeletion {
            let lineGlobal = NSRange(location: footprint.location + lineStartLocal, length: lineLocal.length)
            let lineHasNonProse = states.contains {
                $0.state != eligibleProse && NSIntersectionRange($0.range, lineGlobal).length > 0
            }
            let lineHasLinkOpen = contextNS.range(of: "](", options: .literal, range: lineLocal).location != NSNotFound
            let startsMidLine: Bool
            if lineStartLocal == 0 && footprint.location > 0,
               let prevPiece = sourceProjection.sourcePiece(containing: footprint.location - 1) {
                startsMidLine = prevPiece.block.sourceText.utf16.last != 10
            } else {
                startsMidLine = false
            }
            let endsMidLine: Bool
            if lineEndLocal == contextNS.length && footprint.upperBound < sourceProjection.sourceLength {
                endsMidLine = contextNS.length == 0 || contextNS.character(at: contextNS.length - 1) != 10
            } else {
                endsMidLine = false
            }
            let midLineHasClosingParen = startsMidLine
                && contextNS.range(of: ")", options: .literal, range: lineLocal).location != NSNotFound
            if lineHasNonProse || lineHasLinkOpen || (startsMidLine && (midLineHasClosingParen || endsMidLine)) {
                return nil
            }
        }

        var resolved: InheritedState?
        if old.length > 0 {
            let overlapping = states.filter { NSIntersectionRange($0.range, old).length > 0 }
            guard let first = overlapping.first, let last = overlapping.last,
                  first.range.location <= old.location, old.upperBound <= last.range.upperBound else {
                return nil
            }
            if overlapping.contains(where: {
                if case .segment(_, true) = $0.state { return true }
                return false
            }) {
                return nil
            }
            if overlapping.count == 1 {
                resolved = first.state
            } else if !overlapping.contains(where: {
                if case .segment(eligible: true, _) = $0.state { return true }
                return false
            }) {
                let hasSegment = overlapping.contains {
                    if case .segment = $0.state { return true }
                    return false
                }
                resolved = hasSegment ? .segment(eligible: false, unsupported: false) : .omitted
            } else {
                return nil
            }
        } else if length > 0 {
            guard let state = inheritedState(
                atInsertion: old.location,
                states: states,
                context: context,
                footprintStart: footprint.location
            ) else {
                return nil
            }
            resolved = state
        }

        if length > 0, case .segment(let eligible, let unsupported) = resolved {
            rawRuns.append(.init(
                source: NSRange(location: old.location - footprint.location, length: length),
                eligible: eligible,
                unsupported: unsupported
            ))
        }

        rawRuns.sort { $0.source.location < $1.source.location }
        var runs: [WritingProseProjection.Run] = []
        runs.reserveCapacity(rawRuns.count)
        for run in rawRuns { appendCoalescedRun(run, to: &runs) }
        return runs
    }
    private func existingRuns(in range: NSRange, shift: Int) -> [WritingProseProjection.Run]? {
        guard range.length > 0 else { return [] }
        var runs: [WritingProseProjection.Run] = []
        var cursor = range.location
        while cursor < range.upperBound {
            guard let piece = sourceProjection.sourcePiece(containing: cursor), piece.range.length > 0 else {
                return nil
            }
            let pieceEnd = piece.range.location + piece.range.length
            for segment in piece.block.segments {
                let global = NSRange(location: piece.range.location + segment.source.location, length: segment.source.length)
                let clipped = NSIntersectionRange(global, range)
                if clipped.length > 0 {
                    appendCoalescedRun(
                        .init(
                            source: NSRange(location: clipped.location + shift, length: clipped.length),
                            eligible: segment.eligible,
                            unsupported: segment.unsupported
                        ),
                        to: &runs
                    )
                }
            }
            cursor = min(range.upperBound, pieceEnd)
        }
        return runs
    }

    private func inlineRunsForCompleteLines(_ text: String, offset: Int) -> [WritingProseProjection.Run] {
        let ns = text as NSString
        var runs: [WritingProseProjection.Run] = []
        var cursor = 0
        while cursor < ns.length {
            let newline = ns.range(of: "\n", range: NSRange(location: cursor, length: ns.length - cursor))
            let end = newline.location == NSNotFound ? ns.length : newline.location
            var lineRuns = WritingProseProjection.inlineRuns(
                ns.substring(with: NSRange(location: cursor, length: end - cursor)),
                offset: offset + cursor
            )
            if lineRuns.count > 1 { lineRuns.sort { $0.source.location < $1.source.location } }
            for run in lineRuns { appendCoalescedRun(run, to: &runs) }
            if end < ns.length {
                appendCoalescedRun(.init(source: NSRange(location: offset + end, length: 1), eligible: true), to: &runs)
            }
            cursor = end + 1
        }
        return runs
    }

    private func projectedPieces(_ source: String, sourceOffset: Int, rows: WritingNativeRowIndex,
                                 inherited: [WritingProseProjection.Run]? = nil, unresolved: [NSRange] = []) -> [WritingProseBlock] {
        let ns = source as NSString
        let allSyntax: [WritingProseProjection.Run]
        if let inherited {
            var sorted = true
            if inherited.count > 1 {
                for idx in 1..<inherited.count where inherited[idx - 1].source.location > inherited[idx].source.location {
                    sorted = false; break
                }
            }
            allSyntax = sorted ? inherited : inherited.sorted { $0.source.location < $1.source.location }
        } else {
            allSyntax = inlineRunsForCompleteLines(source, offset: 0)
        }
        let sortedUnresolved = unresolved.count > 1
            ? unresolved.sorted { $0.location < $1.location }
            : unresolved
        var firstSyntax = 0
        var firstUnresolved = 0
        var result: [WritingProseBlock] = []
        for piece in WritingWindowSplitter.pieces(in: source, maximum: 2048) {
            let bounds = piece.nsRange, text = ns.substring(with: bounds)
            if bounds.length > 2048 {
                result.append(WritingProseBlock(sourceText: text, proseText: "\n",
                    segments: [.init(source: NSRange(location: 0, length: bounds.length), prose: NSRange(location: 0, length: 1), eligible: false, unsupported: true)]))
                continue
            }
            let base = sourceOffset + bounds.location
            let scope = rows.sourceIntervals(in: NSRange(location: base, length: bounds.length))
            let masks = scope.eligible.map { NSRange(location: $0.location - base, length: $0.length) }
            var blocked = scope.blocked.map { NSRange(location: $0.location - base, length: $0.length) }

            var unsupported: [NSRange] = []
            while firstUnresolved < sortedUnresolved.count && sortedUnresolved[firstUnresolved].upperBound <= bounds.location {
                firstUnresolved += 1
            }
            var uIdx = firstUnresolved
            while uIdx < sortedUnresolved.count && sortedUnresolved[uIdx].location < bounds.upperBound {
                let clipped = NSIntersectionRange(sortedUnresolved[uIdx], bounds)
                if clipped.length > 0 {
                    let local = NSRange(location: clipped.location - bounds.location, length: clipped.length)
                    unsupported.append(local)
                    blocked.append(local)
                }
                uIdx += 1
            }

            while firstSyntax < allSyntax.count && allSyntax[firstSyntax].source.upperBound <= bounds.location {
                firstSyntax += 1
            }
            var eligible: [NSRange] = []
            var maskIndex = 0
            var sIdx = firstSyntax
            while sIdx < allSyntax.count && allSyntax[sIdx].source.location < bounds.upperBound {
                let raw = allSyntax[sIdx]
                let clipped = NSIntersectionRange(raw.source, bounds)
                if clipped.length > 0 {
                    let runSource = NSRange(location: clipped.location - bounds.location, length: clipped.length)
                    if !raw.eligible {
                        blocked.append(runSource)
                        if raw.unsupported { unsupported.append(runSource) }
                    } else {
                        while maskIndex < masks.count && masks[maskIndex].upperBound <= runSource.location {
                            maskIndex += 1
                        }
                        var m = maskIndex
                        while m < masks.count && masks[m].location < runSource.upperBound {
                            let overlap = NSIntersectionRange(runSource, masks[m])
                            if overlap.length > 0 { eligible.append(overlap) }
                            if masks[m].upperBound >= runSource.upperBound { break }
                            m += 1
                        }
                    }
                }
                sIdx += 1
            }

            var merged: [NSRange] = []
            if !blocked.isEmpty {
                merged.reserveCapacity(blocked.count)
                for range in blocked.sorted(by: { $0.location < $1.location }) where range.length > 0 {
                    if let previous = merged.last, range.location <= previous.upperBound {
                        merged[merged.count - 1] = NSUnionRange(previous, range)
                    } else { merged.append(range) }
                }
            }
            // A nested native/syntax exclusion wins over an otherwise eligible body.
            if eligible.count > 1 {
                var eligibleSorted = true
                for idx in 1..<eligible.count where eligible[idx - 1].location > eligible[idx].location {
                    eligibleSorted = false; break
                }
                if !eligibleSorted { eligible.sort { $0.location < $1.location } }
            }
            var allowed: [NSRange] = []
            allowed.reserveCapacity(eligible.count)
            var barrierIndex = 0
            for range in eligible {
                while barrierIndex < merged.count && merged[barrierIndex].upperBound <= range.location {
                    barrierIndex += 1
                }
                var cursor = range.location
                let end = range.upperBound
                var b = barrierIndex
                while b < merged.count && merged[b].location < end {
                    let barrier = merged[b]
                    if barrier.location > cursor {
                        allowed.append(NSRange(location: cursor, length: barrier.location - cursor))
                    }
                    cursor = max(cursor, barrier.upperBound)
                    if cursor >= end { break }
                    b += 1
                }
                if cursor < end {
                    allowed.append(NSRange(location: cursor, length: end - cursor))
                }
            }

            var rawRuns: [WritingProseProjection.Run] = []
            rawRuns.reserveCapacity(allowed.count + merged.count)
            for range in allowed { rawRuns.append(.init(source: range, eligible: true)) }
            for range in merged { rawRuns.append(.init(source: range, eligible: false)) }
            rawRuns.sort { $0.source.location < $1.source.location }
            var runs: [WritingProseProjection.Run] = []
            runs.reserveCapacity(rawRuns.count)
            for run in rawRuns { appendCoalescedRun(run, to: &runs) }

            if runs.count == 1, let only = runs.first, only.eligible,
               only.source == NSRange(location: 0, length: bounds.length), unsupported.isEmpty {
                result.append(WritingProseBlock(sourceText: text, proseText: text,
                    segments: [.init(source: only.source, prose: only.source, eligible: true, unsupported: false)]))
                continue
            }

            var mergedUnsupported: [NSRange] = []
            if !unsupported.isEmpty {
                mergedUnsupported.reserveCapacity(unsupported.count)
                for range in unsupported.sorted(by: { $0.location < $1.location }) where range.length > 0 {
                    if let previous = mergedUnsupported.last, range.location <= previous.upperBound {
                        mergedUnsupported[mergedUnsupported.count - 1] = NSUnionRange(previous, range)
                    } else { mergedUnsupported.append(range) }
                }
            }
            let local = text as NSString
            var prose = "", length = 0, segments: [WritingProseSegment] = []
            segments.reserveCapacity(runs.count)
            var unsupportedIndex = 0
            for run in runs {
                while unsupportedIndex < mergedUnsupported.count
                    && mergedUnsupported[unsupportedIndex].upperBound <= run.source.location {
                    unsupportedIndex += 1
                }
                let isUnsupported = unsupportedIndex < mergedUnsupported.count
                    && mergedUnsupported[unsupportedIndex].location < run.source.upperBound
                let content = run.eligible ? local.substring(with: run.source) : "\n"
                let size = run.eligible ? run.source.length : 1
                segments.append(.init(source: run.source, prose: NSRange(location: length, length: size), eligible: run.eligible,
                                      unsupported: isUnsupported))
                prose += content; length += size
            }
            result.append(WritingProseBlock(sourceText: text, proseText: prose, segments: segments))
        }
        return result
    }

    private func projectOpaqueLongDeferredLine(
        _ line: String,
        sourceOffset: Int,
        rows: WritingNativeRowIndex,
        epoch: UInt64
    ) async -> [WritingProseBlock]? {
        let ns = line as NSString
        var blocks: [WritingProseBlock] = []
        for piece in WritingWindowSplitter.pieces(in: line, maximum: 2048) {
            guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return nil }
            let bounds = piece.nsRange
            blocks += projectedPieces(
                ns.substring(with: bounds),
                sourceOffset: sourceOffset + bounds.location,
                rows: rows,
                inherited: []
            )
            if bounds.upperBound < ns.length {
                await Task.yield()
            }
        }
        return blocks
    }
    /// Stream a single long (>2048 UTF-16) deferred line using the shared full-line O(N) grammar,
    /// then emit <=2048-UTF-16 blocks with yields between pieces so escapes, code/math spans,
    /// nested link labels, and final-piece unclosed destinations match the authoritative grammar.
    private func projectLongDeferredLine(
        _ line: String,
        sourceOffset: Int,
        rows: WritingNativeRowIndex,
        epoch: UInt64
    ) async -> [WritingProseBlock]? {
        guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return nil }
        guard let runs = await WritingProseProjection.deferredLineRuns(in: line, checkpoint: {
            await Task.yield()
            return !Task.isCancelled && self.collectionEpoch == epoch && self.knownIdentity == self.runtimeIdentity?()
        }) else { return nil }
        let ns = line as NSString
        var blocks: [WritingProseBlock] = []
        var firstRun = 0
        for piece in WritingWindowSplitter.pieces(in: line, maximum: 2048) {
            guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return nil }
            let bounds = piece.nsRange
            let pieceText = ns.substring(with: bounds)
            while firstRun < runs.count && runs[firstRun].source.upperBound <= bounds.location {
                firstRun += 1
            }
            var pieceRuns: [WritingProseProjection.Run] = []
            var i = firstRun
            while i < runs.count && runs[i].source.location < bounds.upperBound {
                let run = runs[i]
                let clipped = NSIntersectionRange(run.source, bounds)
                if clipped.length > 0 {
                    let local = NSRange(location: clipped.location - bounds.location, length: clipped.length)
                    if run.eligible || run.unsupported || clipped.location == run.source.location {
                        appendCoalescedRun(
                            .init(source: local, eligible: run.eligible, unsupported: run.unsupported),
                            to: &pieceRuns
                        )
                    }
                }
                i += 1
            }
            blocks += projectedPieces(
                pieceText,
                sourceOffset: sourceOffset + bounds.location,
                rows: rows,
                inherited: pieceRuns
            )
            if bounds.upperBound < ns.length {
                await Task.yield()
            }
        }
        return blocks
    }
    func storageChanged(mask: NSTextStorageEditActions, range: NSRange, delta: Int, storage: NSAttributedString) {
        guard let identity = runtimeIdentity?(), !mask.isEmpty else { return }
        if !mask.contains(.editedCharacters), matchesAuthorMetadata(storage, range: range) { return }
        if base == nil { base = identity }
        revision &+= 1
        let oldRange = NSRange(location: range.location, length: max(0, range.length - delta))
        let start = originalPoint(oldRange.location, end: false), end = originalPoint(oldRange.upperBound, end: true)
        let original = NSRange(location: start, length: max(0, end - start))
        oldDirty = oldDirty.map { NSUnionRange($0, original) } ?? original
        if mask.contains(.editedCharacters) {
            let change = Change(old: oldRange, new: range)
            if let previous = dirty {
                let a = movedPoint(previous.location, through: change, end: false)
                let b = movedPoint(previous.upperBound, through: change, end: true)
                dirty = NSRange(location: a, length: max(0, b - a))
            }
            if let last = changes.last, oldRange.location <= last.new.upperBound, oldRange.upperBound >= last.new.location {
                let before = max(0, last.new.location - oldRange.location)
                let after = max(0, oldRange.upperBound - last.new.upperBound)
                // `last.old.location == last.new.location` holds by construction, so `last.old.location >= before`.
                let coalescedOld = NSRange(location: max(0, last.old.location - before),
                                           length: last.old.length + before + after)
                let start = min(last.new.location, range.location)
                let end = max(range.upperBound, last.new.upperBound + change.delta)
                changes[changes.count - 1] = Change(old: coalescedOld, new: NSRange(location: start, length: max(0, end - start)))
            } else {
                changes.append(change)
            }
        }
        dirty = dirty.map { NSUnionRange($0, range) } ?? range
        boundRevision = nil
        prepared = nil
        mappedRevision = nil
    }
    func willBind() {
        isBinding = true
        if base == nil { base = runtimeIdentity?() }
        bindingIdentity = runtimeIdentity?()
        bindingIsCurrent = bindingIdentity == knownIdentity
    }
    func didBind(source: String, storage: NSAttributedString) {
        didBind(source: DocumentSource(source), storage: storage)
    }
    func didBind(source: DocumentSource, storage: NSAttributedString) {
        defer { isBinding = false }
        guard bindingIsCurrent, let current = runtimeIdentity?(), current.key == bindingIdentity?.key else {
            resetStaleDirtyState()
            return
        }
        guard updateProjection(storage: storage, ownerChanged: current != bindingIdentity) else {
            resetStaleDirtyState()
            return
        }
        loadedDocumentSource = source; knownIdentity = current
        boundRevision = revision; boundIdentity = current
        if !deferred.isEmpty || projectionTask != nil {
            startDeferredProjection()
            return
        }
        finishBindingProjection()
    }
    /// Profile/title transitions can advance ownership without changing source. Verify only at
    /// that explicit snapshot seam; the ordinary binding callback never compares the document.
    func noteSnapshot(_ snapshot: ProjectDocumentSnapshot) {
        guard !isBinding else { return }
        guard snapshot.identity != knownIdentity else { return }
        if knownIdentity == nil {
            guard oldDirty == nil, dirty == nil, projectionTask == nil, deferred.isEmpty,
                  let loadedDocumentSource, loadedDocumentSource == snapshot.source else {
                return
            }
            knownIdentity = snapshot.identity
            if boundIdentity != nil { boundIdentity = snapshot.identity }
            if mappedRevision == revision { mappedIdentity = snapshot.identity }
            return
        }
        guard snapshot.identity.key == knownIdentity?.key else {
            // Identical bytes after an ownership round trip cannot reauthorize a stale editor.
            rejectUnownedLoad()
            return
        }
        guard oldDirty == nil, dirty == nil,
              let loadedDocumentSource, loadedDocumentSource == snapshot.source else {
            mappedRevision = nil; return
        }
        knownIdentity = snapshot.identity
        if boundIdentity != nil { boundIdentity = snapshot.identity }
        if mappedRevision == revision { mappedIdentity = snapshot.identity }
        if projectionTask == nil, !deferred.isEmpty {
            startDeferredProjection()
        }
    }
    private func finishBindingProjection() {
        guard boundRevision == revision, boundIdentity == runtimeIdentity?() else { return }
        mappedRevision = revision; mappedIdentity = boundIdentity
        nativeLookup = { [weak self] range in self?.lookup(range) }
        if let publishedProjection {
            prepared = (revision, sourceProjection.patch(from: publishedProjection)
                ?? WritingProjectionPatch(oldSourceRange: .init(location: 0, length: 0), replacement: []))
        }
        publishIfReady()
    }
    private func abortDeferredProjection(epoch: UInt64) {
        guard collectionEpoch == epoch else { return }
        deferred.removeAll()
        boundRevision = nil
        boundIdentity = nil
        mappedRevision = nil
        prepared = nil
    }
    /// Large structural changes consume the already-serialized rows in bounded, yielding pieces.
    /// Subsequent edits queue against native prefix totals; no old task publishes a newer revision.
    private func startDeferredProjection() {
        guard projectionTask == nil else { return }
        let epoch = collectionEpoch
        projectionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var completed = false
            defer {
                if collectionEpoch == epoch {
                    projectionTask = nil
                    if !completed {
                        abortDeferredProjection(epoch: epoch)
                    }
                }
            }
            while let edit = deferred.first {
                guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return }
                guard let footprint = projectionFootprint(for: edit.range) else { return }
                let prefixRange = NSRange(location: footprint.location, length: edit.range.location - footprint.location)
                let suffixRange = NSRange(location: edit.range.upperBound, length: footprint.upperBound - edit.range.upperBound)
                guard let prefix = readSource(prefixRange),
                      let suffix = readSource(suffixRange),
                      let prefixRuns = existingRuns(in: prefixRange, shift: -footprint.location),
                      let suffixRuns = existingRuns(in: suffixRange, shift: -suffixRange.location) else { return }
                var blocks: [WritingProseBlock] = [], buffer = "", size = 0, offset = footprint.location
                if !prefix.isEmpty {
                    blocks += projectedPieces(prefix, sourceOffset: offset, rows: edit.rows, inherited: prefixRuns)
                    offset += prefix.utf16.count
                }
                // Source strings are shared with the existing serialization cache. Never join a giant row.
                for fragment in edit.fragments {
                    let fragmentLength = fragment.utf16.count
                    guard fragmentLength > 0 else { continue }
                    if fragmentLength > 2048 {
                        if size > 0 {
                            blocks += projectedPieces(buffer, sourceOffset: offset, rows: edit.rows)
                            offset += size; buffer = ""; size = 0
                            await Task.yield()
                            guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return }
                        }
                        let lineBlocks: [WritingProseBlock]?
                        if let located = edit.rows.row(containingSource: offset),
                           (!located.row.eligible || located.row.isCode),
                           located.textStart == offset,
                           located.row.textLength == fragmentLength {
                            lineBlocks = await projectOpaqueLongDeferredLine(
                                fragment,
                                sourceOffset: offset,
                                rows: edit.rows,
                                epoch: epoch
                            )
                        } else {
                            lineBlocks = await projectLongDeferredLine(
                                fragment,
                                sourceOffset: offset,
                                rows: edit.rows,
                                epoch: epoch
                            )
                        }
                        guard let lineBlocks else { return }
                        blocks += lineBlocks
                        offset += fragmentLength
                        await Task.yield()
                        guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return }
                        continue
                    }
                    if size > 0 && size + fragmentLength > 2048 {
                        blocks += projectedPieces(buffer, sourceOffset: offset, rows: edit.rows)
                        offset += size; buffer = ""; size = 0
                        await Task.yield()
                        guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return }
                    }
                    buffer += fragment
                    size += fragmentLength
                }
                if size > 0 {
                    blocks += projectedPieces(buffer, sourceOffset: offset, rows: edit.rows)
                    offset += size
                }
                if !suffix.isEmpty {
                    blocks += projectedPieces(suffix, sourceOffset: offset, rows: edit.rows, inherited: suffixRuns)
                }
                guard sourceProjection.apply(.init(oldSourceRange: .init(footprint), replacement: blocks)) else { return }
                if !deferred.isEmpty { deferred.removeFirst() }
            }
            guard sourceProjection.sourceLength == nativeRows.sourceLength else { return }
            completed = true
            needsCanonicalLoadCompletion = false
            finishBindingProjection()
        }
    }
    func beginComposition() { compositionDepth += 1 }
    func endComposition(_ range: NSRange?) {
        compositionDepth -= 1
        guard compositionDepth == 0 else { return }
        marked = range.map(WritingDiagnosticRange.init)
        compositionDidChange?(marked)
        publishIfReady()
    }
    func publishIfReady() {
        guard compositionDepth == 0, marked == nil, let base, let boundIdentity,
              base.key == boundIdentity.key, boundIdentity == runtimeIdentity?(),
              let prepared, prepared.revision == revision, boundRevision == revision else { return }
        self.base = nil; self.prepared = nil; dirty = nil
        publishedProjection = sourceProjection.snapshot()
        commitDidChange?(WritingEditorCommit(baseIdentity: base, nativeRevision: revision,
                                            patch: prepared.patch, markedRange: nil))
    }
}

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
