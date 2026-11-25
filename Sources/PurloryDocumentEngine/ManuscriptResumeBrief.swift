import Foundation

/// Summarizes where the writer left off in a manuscript and surfaces quick notes linked to it.
public struct ManuscriptResumeBrief: Equatable, Sendable {
    public let documentID: WritingDocumentID
    public let documentTitle: String
    public let activeBranch: String
    public let hasMultipleBranches: Bool
    public let currentSceneHeading: String?
    public let trailingExcerpt: String
    public let linkedNotes: [String]
    public let latestVersionLabel: String?
    public let hasUnsavedVersionChanges: Bool

    public init(
        documentID: WritingDocumentID,
        documentTitle: String,
        activeBranch: String,
        hasMultipleBranches: Bool,
        currentSceneHeading: String?,
        trailingExcerpt: String,
        linkedNotes: [String],
        latestVersionLabel: String?,
        hasUnsavedVersionChanges: Bool
    ) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.activeBranch = activeBranch
        self.hasMultipleBranches = hasMultipleBranches
        self.currentSceneHeading = currentSceneHeading
        self.trailingExcerpt = trailingExcerpt
        self.linkedNotes = linkedNotes
        self.latestVersionLabel = latestVersionLabel
        self.hasUnsavedVersionChanges = hasUnsavedVersionChanges
    }

    public static func build(
        for documentID: WritingDocumentID,
        in project: WritingProject,
        cursorOffset: Int? = nil
    ) -> Self? {
        guard !project.trashedDocumentIDs.contains(documentID),
              let document = project.documents.first(where: { $0.id == documentID }),
              document.kind == .manuscript else { return nil }

        let branchState = ManuscriptBranchState.load(in: project.userData, documentID: documentID)
        let versions = (try? ManuscriptVersion.list(in: project.userData, documentID: documentID)) ?? []
        var branchNames = branchState.branches.map(\.name)
        for v in versions where !branchNames.contains(v.branchName) { branchNames.append(v.branchName) }
        if branchNames.isEmpty { branchNames.append(ManuscriptVersion.defaultBranchName) }

        let source = document.source
        let activeHead = branchState.resolveDocumentHead(for: branchState.activeBranch, in: versions)
        let hasUnsaved: Bool
        if let activeHead {
            hasUnsaved = !source.utf8Equals(activeHead.text)
        } else {
            hasUnsaved = Self.containsNonWhitespace(in: source)
        }

        let clampedOffset = cursorOffset.map { max(0, min($0, source.utf16Length)) }
        let currentHeading = Self.resolveCurrentHeading(in: source, clampedOffset: clampedOffset)
        let relevantParagraph = clampedOffset.flatMap {
            Self.lastRelevantParagraph(in: source, maxStartOffset: $0)
        } ?? Self.lastRelevantParagraph(in: source, maxStartOffset: nil) ?? ""
        let singleLine = relevantParagraph
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = singleLine.count > 90 ? String(singleLine.prefix(90)) + "…" : singleLine

        let tagPrefix = "[\(document.title)]"
        var extractedNotes: [String] = []
        for noteDoc in project.documents where noteDoc.kind == .note && !project.trashedDocumentIDs.contains(noteDoc.id) {
            extractedNotes.append(contentsOf: noteDoc.source.extractTaggedNoteLines(tagPrefix: tagPrefix))
        }

        return Self(
            documentID: documentID,
            documentTitle: document.title,
            activeBranch: branchState.activeBranch,
            hasMultipleBranches: branchNames.count > 1,
            currentSceneHeading: currentHeading,
            trailingExcerpt: excerpt,
            linkedNotes: Array(extractedNotes.reversed()),
            latestVersionLabel: activeHead?.label,
            hasUnsavedVersionChanges: hasUnsaved
        )
    }

    private static func containsNonWhitespace(in source: DocumentSource) -> Bool {
        source.containsNonWhitespace()
    }

    private static func resolveCurrentHeading(in source: DocumentSource, clampedOffset: Int?) -> String? {
        guard source.utf16Length > 0 else { return nil }
        if let clampedOffset {
            if let before = scanHeadingBackward(in: source, maxStartOffset: clampedOffset) {
                return before
            }
            let prefix = source.clampedSlice(in: NSRange(location: 0, length: min(source.utf16Length, 8_192)))
            var lineStart = prefix.startIndex
            var hasNonWhitespaceBeforeFirstHeading = false
            while lineStart < prefix.endIndex {
                let lineEnd = prefix[lineStart...].firstIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.endIndex
                let line = prefix[lineStart..<lineEnd]
                if DocumentOutline.headingLine(line) != nil { break }
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasNonWhitespaceBeforeFirstHeading = true
                    break
                }
                lineStart = lineEnd
            }
            if hasNonWhitespaceBeforeFirstHeading {
                return nil
            }
        }
        return scanHeadingBackward(in: source, maxStartOffset: nil)
    }

    private static func scanHeadingBackward(in source: DocumentSource, maxStartOffset: Int?) -> String? {
        let total = source.utf16Length
        guard total > 0 else { return nil }
        let step = 16_384
        let overlap = 512
        var windowEnd = min(total, (maxStartOffset ?? total) + overlap)
        while windowEnd > 0 {
            let rawStart = max(0, windowEnd - step)
            let slice = source.clampedSlice(in: NSRange(location: rawStart, length: windowEnd - rawStart))
            var lineStart = slice.startIndex
            var utf16Pos = rawStart
            if rawStart > 0, let firstNewline = slice.firstIndex(of: "\n") {
                let nextStart = slice.index(after: firstNewline)
                utf16Pos += slice[..<nextStart].utf16.count
                lineStart = nextStart
            }
            var found: String?
            while lineStart < slice.endIndex {
                let lineEnd = slice[lineStart...].firstIndex(of: "\n").map { slice.index(after: $0) } ?? slice.endIndex
                if let maxStartOffset, utf16Pos > maxStartOffset { break }
                let line = slice[lineStart..<lineEnd]
                if let (_, title) = DocumentOutline.headingLine(line) {
                    found = title
                }
                utf16Pos += line.utf16.count
                lineStart = lineEnd
            }
            if let found { return found }
            if rawStart == 0 { break }
            windowEnd = min(windowEnd - 1, rawStart + overlap)
        }
        return nil
    }

    private static func lastRelevantParagraph(in source: DocumentSource, maxStartOffset: Int?) -> String? {
        let total = source.utf16Length
        guard total > 0 else { return nil }
        let step = 16_384
        let overlap = 2_048
        var windowEnd = min(total, (maxStartOffset ?? total) + overlap)
        while windowEnd > 0 {
            let rawStart = max(0, windowEnd - step)
            let slice = source.clampedSlice(in: NSRange(location: rawStart, length: windowEnd - rawStart))
            let paragraphs = ManuscriptComparison.paragraphs(slice)
            let usable = rawStart > 0 && paragraphs.count > 1 ? Array(paragraphs.dropFirst()) : paragraphs
            let candidates = usable.compactMap { item -> (text: String, start: Int)? in
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return (text: trimmed, start: rawStart + item.start)
            }
            if let maxStartOffset {
                if let match = candidates.last(where: { $0.start <= maxStartOffset }) {
                    return match.text
                }
            } else if let match = candidates.last {
                return match.text
            }
            if rawStart == 0 { break }
            windowEnd = min(windowEnd - 1, rawStart + overlap)
        }
        return nil
    }
}
