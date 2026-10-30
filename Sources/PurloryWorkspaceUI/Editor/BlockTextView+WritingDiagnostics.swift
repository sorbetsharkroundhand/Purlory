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
    private var oldDirty: NSRange?
    private var changes: [Change] = []
    private var bindingIdentity: ProjectRuntimeIdentity?
    private var knownIdentity: ProjectRuntimeIdentity?
    private var bindingIsCurrent = false
    private var isBinding = false
    private var needsCanonicalLoadCompletion = false
    private weak var serializationStorage: NSAttributedString?
    var nativeLookup: ((WritingDiagnosticRange) -> WritingNativeMappedRange?)?
    var mappedRevision: UInt64?
    var mappedIdentity: ProjectRuntimeIdentity?
    var prepared: (revision: UInt64, patch: WritingProjectionPatch)?
    private(set) var loadedSource: String?
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
        loadedSource = source
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
        var literalReplacement = false
        let punctuation = CharacterSet(charactersIn: "[]()!$`*_~=<>\\\n")
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
            if inserted.rangeOfCharacter(from: punctuation) == nil, let removed = readSource(range),
               removed.rangeOfCharacter(from: punctuation) == nil {
                replacement = (range, inserted); literalReplacement = true
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
        guard let replacement, let oldText = readSource(replacement.range) else { return false }
        let sourceChanged = needsCanonicalLoadCompletion || !oldText.utf16.elementsEqual(replacement.text.utf16)
        guard ownerChanged || !sourceChanged else { return false }
        let footprint: NSRange
        if sourceProjection.sourceLength == 0 { footprint = NSRange(location: 0, length: 0) }
        else {
            guard let a = sourceProjection.sourcePiece(containing: replacement.range.location),
                  let b = sourceProjection.sourcePiece(containing: max(replacement.range.location, replacement.range.upperBound - 1)) else { return false }
            footprint = NSRange(location: a.range.location, length: b.range.location + b.range.length - a.range.location)
        }
        guard footprint.length <= 8192, let context = readSource(footprint) else { return false }
        let changed = (context as NSString).replacingCharacters(in: NSRange(location: replacement.range.location - footprint.location,
                                                                          length: replacement.range.length), with: replacement.text)
        lastInputUTF16 = changed.utf16.count
        let inherited = literalReplacement ? inheritedRuns(in: footprint, replacing: replacement.range,
                                                          length: replacement.text.utf16.count) : nil
        let blocks = projectedPieces(changed, sourceOffset: footprint.location, rows: draft, inherited: inherited)
        guard sourceProjection.sourceLength + changed.utf16.count - footprint.length == draft.sourceLength,
              sourceProjection.apply(.init(oldSourceRange: .init(footprint), replacement: blocks)) else { return false }
        nativeRows = draft; needsCanonicalLoadCompletion = false
        self.oldDirty = nil; dirty = nil; changes.removeAll(keepingCapacity: true)
        return true
    }
    /// Reuse proven grammar scopes for a literal edit, including an excluded URL spanning pieces.
    private func inheritedRuns(in footprint: NSRange, replacing old: NSRange, length: Int) -> [WritingProseProjection.Run] {
        var runs: [WritingProseProjection.Run] = [], cursor = footprint.location, inserted = false
        let delta = length - old.length
        while cursor < footprint.upperBound, let piece = sourceProjection.sourcePiece(containing: cursor) {
            for segment in piece.block.segments {
                let global = NSRange(location: piece.range.location + segment.source.location, length: segment.source.length)
                let before = NSIntersectionRange(global, NSRange(location: footprint.location, length: old.location - footprint.location))
                if before.length > 0 { runs.append(.init(source: NSRange(location: before.location - footprint.location, length: before.length), eligible: segment.eligible, unsupported: segment.unsupported)) }
                if !inserted, length > 0, old.location >= global.location, old.upperBound <= global.upperBound {
                    runs.append(.init(source: NSRange(location: old.location - footprint.location, length: length), eligible: segment.eligible, unsupported: segment.unsupported))
                    inserted = true
                }
                let after = NSIntersectionRange(global, NSRange(location: old.upperBound, length: footprint.upperBound - old.upperBound))
                if after.length > 0 { runs.append(.init(source: NSRange(location: after.location + delta - footprint.location, length: after.length), eligible: segment.eligible, unsupported: segment.unsupported)) }
            }
            cursor = piece.range.location + piece.range.length
        }
        return runs.sorted { $0.source.location < $1.source.location }
    }
    private func projectedPieces(_ source: String, sourceOffset: Int, rows: WritingNativeRowIndex,
                                 inherited: [WritingProseProjection.Run]? = nil, unresolved: [NSRange] = []) -> [WritingProseBlock] {
        let ns = source as NSString
        var boundedSyntax: [WritingProseProjection.Run] = [], cursor = 0
        if inherited == nil {
            while cursor < ns.length {
                let newline = ns.range(of: "\n", range: NSRange(location: cursor, length: ns.length - cursor))
                let end = newline.location == NSNotFound ? ns.length : newline.location
                boundedSyntax += WritingProseProjection.inlineRuns(ns.substring(with: NSRange(location: cursor, length: end - cursor)), offset: cursor)
                if end < ns.length { boundedSyntax.append(.init(source: NSRange(location: end, length: 1), eligible: true)) }
                cursor = end + 1
            }
        }
        var result: [WritingProseBlock] = []
        for piece in WritingWindowSplitter.pieces(in: source, maximum: 2048) {
            let bounds = piece.nsRange, text = ns.substring(with: bounds), local = text as NSString
            if bounds.length > 2048 {
                result.append(WritingProseBlock(sourceText: text, proseText: "\n",
                    segments: [.init(source: NSRange(location: 0, length: bounds.length), prose: NSRange(location: 0, length: 1), eligible: false, unsupported: true)]))
                continue
            }
            let base = sourceOffset + bounds.location
            let scope = rows.sourceIntervals(in: NSRange(location: base, length: bounds.length))
            let masks = scope.eligible.map { NSRange(location: $0.location - base, length: $0.length) }
            var blocked = scope.blocked.map { NSRange(location: $0.location - base, length: $0.length) }
            var unsupported = unresolved.compactMap { range -> NSRange? in
                let clipped = NSIntersectionRange(range, bounds)
                return clipped.length > 0 ? NSRange(location: clipped.location - bounds.location, length: clipped.length) : nil
            }
            blocked += unsupported
            let syntax: [WritingProseProjection.Run] = (inherited ?? boundedSyntax).compactMap {
                let clipped = NSIntersectionRange($0.source, bounds)
                return clipped.length > 0 ? .init(source: NSRange(location: clipped.location - bounds.location, length: clipped.length), eligible: $0.eligible, unsupported: $0.unsupported) : nil
            }
            var eligible: [NSRange] = []
            for run in syntax {
                if !run.eligible {
                    blocked.append(run.source)
                    if run.unsupported { unsupported.append(run.source) }
                    continue
                }
                for mask in masks {
                    let clipped = NSIntersectionRange(run.source, mask)
                    if clipped.length > 0 { eligible.append(clipped) }
                }
            }
            var merged: [NSRange] = []
            for range in blocked.sorted(by: { $0.location < $1.location }) {
                if let previous = merged.last, range.location <= previous.upperBound {
                    merged[merged.count - 1] = NSUnionRange(previous, range)
                } else { merged.append(range) }
            }
            // A nested native/syntax exclusion wins over an otherwise eligible body.
            let allowed = eligible.flatMap { range -> [NSRange] in
                var pieces = [range]
                for barrier in merged {
                    pieces = pieces.flatMap { piece -> [NSRange] in
                        let overlap = NSIntersectionRange(piece, barrier)
                        guard overlap.length > 0 else { return [piece] }
                        var kept: [NSRange] = []
                        if piece.location < overlap.location { kept.append(NSRange(location: piece.location, length: overlap.location - piece.location)) }
                        if overlap.upperBound < piece.upperBound { kept.append(NSRange(location: overlap.upperBound, length: piece.upperBound - overlap.upperBound)) }
                        return kept
                    }
                }
                return pieces
            }
            var runs = allowed.map { WritingProseProjection.Run(source: $0, eligible: true) }
            runs += merged.map { WritingProseProjection.Run(source: $0, eligible: false) }
            runs.sort { $0.source.location < $1.source.location }
            var prose = "", length = 0, segments: [WritingProseSegment] = []
            for run in runs {
                let content = run.eligible ? local.substring(with: run.source) : "\n"
                let size = run.eligible ? run.source.length : 1
                segments.append(.init(source: run.source, prose: NSRange(location: length, length: size), eligible: run.eligible,
                                      unsupported: unsupported.contains { NSIntersectionRange($0, run.source).length > 0 }))
                prose += content; length += size
            }
            result.append(WritingProseBlock(sourceText: text, proseText: prose, segments: segments))
        }
        return result
    }
    /// An unbounded raw reference is unassessed through its line, never guessed from a URL tail.
    /// Complete references inside a bounded piece still use the shared exact grammar.
    private func unresolvedReferences(in text: String, carried: inout Bool) -> [NSRange] {
        let ns = text as NSString, links = WritingProseProjection.links(in: text)
        var cursor = 0, start: Int? = carried ? 0 : nil, result: [NSRange] = []
        while cursor < ns.length {
            if ns.character(at: cursor) == 10 {
                if let begin = start, cursor > begin { result.append(NSRange(location: begin, length: cursor - begin)) }
                carried = false; start = nil
            } else if start == nil && ns.character(at: cursor) == 91 {
                if let complete = links.first(where: { NSLocationInRange(cursor, $0.source) }) {
                    cursor = complete.source.upperBound; continue
                }
                start = cursor; carried = true
            }
            cursor += 1
        }
        if let start, ns.length > start { result.append(NSRange(location: start, length: ns.length - start)) }
        return result
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
            changes.append(change)
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
        defer { isBinding = false }
        guard bindingIsCurrent, let current = runtimeIdentity?(), current.key == bindingIdentity?.key else { return }
        guard updateProjection(storage: storage, ownerChanged: current != bindingIdentity) else { return }
        loadedSource = source; knownIdentity = current
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
        guard snapshot.identity.key == knownIdentity?.key else {
            knownIdentity = nil; mappedRevision = nil; mappedIdentity = nil
            projectionTask?.cancel(); projectionTask = nil; deferred.removeAll(); collectionEpoch &+= 1
            return
        }
        guard oldDirty == nil, dirty == nil, projectionTask == nil, deferred.isEmpty,
              let loadedSource, loadedSource.utf16.elementsEqual(snapshot.body.utf16) else {
            mappedRevision = nil; return
        }
        knownIdentity = snapshot.identity
        if boundIdentity != nil { boundIdentity = snapshot.identity }
        if mappedRevision == revision { mappedIdentity = snapshot.identity }
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
    /// Large structural changes consume the already-serialized rows in bounded, yielding pieces.
    /// Subsequent edits queue against native prefix totals; no old task publishes a newer revision.
    private func startDeferredProjection() {
        guard projectionTask == nil else { return }
        let epoch = collectionEpoch
        projectionTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { if collectionEpoch == epoch { projectionTask = nil } }
            while !deferred.isEmpty {
                guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return }
                let edit = deferred.removeFirst()
                let footprint: NSRange
                if sourceProjection.sourceLength == 0 { footprint = NSRange(location: 0, length: 0) }
                else {
                    guard let a = sourceProjection.sourcePiece(containing: edit.range.location),
                          let b = sourceProjection.sourcePiece(containing: max(edit.range.location, edit.range.upperBound - 1)) else { return }
                    footprint = NSRange(location: a.range.location, length: b.range.location + b.range.length - a.range.location)
                }
                guard let prefix = readSource(NSRange(location: footprint.location, length: edit.range.location - footprint.location)),
                      let suffix = readSource(NSRange(location: edit.range.upperBound, length: footprint.upperBound - edit.range.upperBound)) else { return }
                var blocks: [WritingProseBlock] = [], buffer = "", size = 0, offset = footprint.location
                var unresolvedReference = false
                // Source strings are shared with the existing serialization cache. Never join a giant row.
                for fragment in [prefix] + edit.fragments + [suffix] {
                    for character in fragment {
                        let text = String(character), width = text.utf16.count
                        if size > 0 && size + width > 2048 {
                            let unresolved = unresolvedReferences(in: buffer, carried: &unresolvedReference)
                            blocks += projectedPieces(buffer, sourceOffset: offset, rows: edit.rows, unresolved: unresolved)
                            offset += size; buffer = ""; size = 0
                            await Task.yield()
                            guard !Task.isCancelled, collectionEpoch == epoch, knownIdentity == runtimeIdentity?() else { return }
                        }
                        buffer += text; size += width
                    }
                }
                if size > 0 {
                    let unresolved = unresolvedReferences(in: buffer, carried: &unresolvedReference)
                    blocks += projectedPieces(buffer, sourceOffset: offset, rows: edit.rows, unresolved: unresolved)
                }
                guard sourceProjection.apply(.init(oldSourceRange: .init(footprint), replacement: blocks)) else { return }
            }
            guard sourceProjection.sourceLength == nativeRows.sourceLength else { return }
            needsCanonicalLoadCompletion = false
            finishBindingProjection()
        }
    }
    func beginComposition() { compositionDepth += 1 }
    func endComposition(_ range: NSRange?) {
        compositionDepth -= 1
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
            let wasConfigured = writingProjectionCapture.runtimeIdentity != nil
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

    func nativeRange(forSource range: WritingDiagnosticRange, revision: UInt64) -> WritingDiagnosticRange? {
        guard revision == writingNativeRevision, !hasMarkedText(),
              writingProjectionCapture.compositionDepth == 0,
              writingProjectionCapture.mappedRevision == revision,
              writingProjectionCapture.mappedIdentity == writingProjectionCapture.runtimeIdentity?(),
              let mapped = writingProjectionCapture.nativeLookup?(range), let storage = textStorage,
              mapped.range.location >= 0, mapped.range.location <= storage.length,
              mapped.range.length >= 0, mapped.range.length <= storage.length - mapped.range.location,
              (storage.string as NSString).rangeOfComposedCharacterSequences(for: mapped.range) == mapped.range,
              (storage.string as NSString).substring(with: mapped.range).utf16.elementsEqual(mapped.original.utf16) else { return nil }
        return WritingDiagnosticRange(mapped.range)
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
