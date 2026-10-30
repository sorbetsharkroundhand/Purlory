import AppKit

extension BlockTextView {
    func invalidateMediaIndex() {
        mediaParagraphIndex = nil
        mediaLastSelectionRange = nil
        mediaDirtyRanges = [NSRange(location: 0, length: textStorage?.length ?? 0)]
    }

    func indexedMediaParagraphs(in range: NSRange) -> [ParagraphRenderIndex.Paragraph] {
        guard let storage = textStorage else { return [] }
        if storage.delegate == nil { storage.delegate = self }
        if mediaParagraphIndex?.utf16Length != storage.length {
            mediaParagraphIndex = ParagraphRenderIndex(records: mediaRecords(in: NSRange(location: 0, length: storage.length)))
            mediaIndexBuildCount += 1
            mediaDirtyRanges = [NSRange(location: 0, length: storage.length)]
        }
        return mediaParagraphIndex?.paragraphs(in: range) ?? []
    }

    func takeMediaDirtyRanges() -> [NSRange] {
        defer { mediaDirtyRanges = [] }
        return mediaDirtyRanges
    }

    /// Observe both text and block attributes on the authoritative storage delegate.
    /// Character edits splice the touched paragraphs plus immediate neighbors; style
    /// writes with unchanged block metadata do not dirty the next render again.
    func updateMediaRenderIndex(mask: NSTextStorageEditActions, range edited: NSRange, delta: Int) {
        guard let storage = textStorage, let index = mediaParagraphIndex else { return }
        guard index.utf16Length + delta == storage.length,
              edited.location <= index.utf16Length, edited.length >= delta else { invalidateMediaIndex(); return }
        let oldEdit = NSRange(location: edited.location, length: edited.length - delta)
        guard oldEdit.upperBound <= index.utf16Length else { invalidateMediaIndex(); return }
        let touched = index.paragraphs(in: oldEdit)
        var start = touched.first?.range.location ?? 0
        var end = touched.last?.range.upperBound ?? 0
        if start > 0 { start = index.paragraphs(in: NSRange(location: start - 1, length: 0)).first?.range.location ?? start }
        if end < index.utf16Length { end = index.paragraphs(in: NSRange(location: end, length: 0)).first?.range.upperBound ?? end }
        let ns = storage.string as NSString
        let postStart = min(start, ns.length), postLength = max(0, min(end - start + delta, ns.length - postStart))
        let newRange = ns.length == 0 ? NSRange(location: 0, length: 0)
            : ns.paragraphRange(for: NSRange(location: postStart, length: postLength))
        guard newRange.length >= delta else { invalidateMediaIndex(); return }
        let oldRange = NSRange(location: newRange.location, length: newRange.length - delta)
        let records = mediaRecords(in: newRange)
        lastMediaIndexUpdateParagraphs = records.count
        let charactersChanged = mask.contains(.editedCharacters)
        if !charactersChanged, index.paragraphs(in: oldRange).map(\.record) == records { return }
        guard index.replace(oldRange, with: records), index.utf16Length == ns.length else { invalidateMediaIndex(); return }
        if charactersChanged {
            rebaseRenderedMedia(replacing: oldEdit, withLength: edited.length)
            mediaDirtyRanges = mediaDirtyRanges.map { rebaseMediaRange($0, replacing: oldEdit, withLength: edited.length) }
        }
        mediaDirtyRanges = mergedMediaRanges(mediaDirtyRanges + [newRange])
    }

    private func mediaRecords(in range: NSRange) -> [ParagraphRenderIndex.Record] {
        guard let storage = textStorage else { return [] }
        let ns = storage.string as NSString
        var records: [ParagraphRenderIndex.Record] = [], location = range.location
        while location < min(range.upperBound, ns.length) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.upperBound > location else { break }
            let delimiter = storage.attribute(.purloryMathDelim, at: paragraph.location, effectiveRange: nil) as? String
            records.append(.init(length: paragraph.length, block: blockInfo(in: paragraph).block,
                                 open: delimiter == "open", close: delimiter == "close"))
            location = paragraph.upperBound
        }
        return records
    }

    /// Map an outstanding dirty scope through the next character edit before merging.
    func rebaseMediaRange(_ range: NSRange, replacing edit: NSRange, withLength length: Int) -> NSRange {
        let delta = length - edit.length, total = textStorage?.length ?? 0
        let start: Int
        if range.location < edit.location { start = range.location }
        else if range.location >= edit.upperBound { start = range.location + delta }
        else { start = edit.location }
        let end: Int
        if range.upperBound <= edit.location { end = range.upperBound }
        else if range.upperBound >= edit.upperBound { end = range.upperBound + delta }
        else { end = edit.location + length }
        let clampedStart = min(max(0, start), total), clampedEnd = min(max(clampedStart, end), total)
        return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
    }

    func mergedMediaRanges(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, last.upperBound >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        return merged
    }
}
