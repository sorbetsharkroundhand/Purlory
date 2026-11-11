import Foundation
import CryptoKit

struct WorkspaceCommandItem: Identifiable, Sendable {
    enum Kind: String, Sendable { case command = "명령", file = "파일", character = "인물", source = "원문" }
    enum Action: Sendable {
        case typewriter, focus, openAll, theme, document(WritingDocumentID), tool(WorkspaceTileID)
        case character(WritingDocumentID, UUID), source(OriginalSourceReference)
    }
    let id: String
    let title: String
    let detail: String
    let kind: Kind
    let action: Action
}

enum WorkspaceCommandSearch {
    private struct CachedSourceMetadata: Sendable {
        let source: DocumentSource
        let revision: String
        let excludedRanges: [NSRange]
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var sourceCache: [WritingDocumentID: CachedSourceMetadata] = [:]
    nonisolated(unsafe) static var revisionHashCount = 0

    static func search(
        in project: WritingProject,
        query: String,
        typewriter: Bool = false,
        focus: Bool = false,
        includeSources: Bool = true,
        limit: Int = 9
    ) -> [WorkspaceCommandItem] {
        items(
            in: project,
            query: query,
            typewriter: typewriter,
            focus: focus,
            includeSources: includeSources,
            limit: limit
        )
    }

    static func items(in project: WritingProject, query: String, typewriter: Bool, focus: Bool,
                      includeSources: Bool = true, limit: Int = 9, allowCancellation: Bool = false) -> [WorkspaceCommandItem] {
        guard limit > 0 else { return [] }
        var items: [WorkspaceCommandItem] = [
            .init(id: "typewriter", title: "타자기 중앙 스크롤 \(typewriter ? "끄기" : "켜기")", detail: "현재 문단을 화면 눈높이 중앙에 유지", kind: .command, action: .typewriter),
            .init(id: "focus", title: "문단 집중 디밍 \(focus ? "끄기" : "켜기")", detail: "집필 중인 문단 외 주변 문단 흐리게", kind: .command, action: .focus),
            .init(id: "all", title: "모든 파일 나란히 펼치기", detail: "프로젝트의 모든 문서를 나란히 비교", kind: .command, action: .openAll),
            .init(id: "theme", title: "라이트 / 다크 테마 전환", detail: "에디토리얼 양피지 · 흑연 테마 전환", kind: .command, action: .theme)
        ]
        if !includeSources {
            for (tile, title) in [(WorkspaceTileID.navigator, "문서 목록"), (.characters, "인물·작품 정보"),
                                  (.narrative, "서사 흐름"), (.margin, "마진 노트"),
                                  (.context, "제안에 쓰인 내용"), (.inspector, "주머니 서식·기능 펼치기")] {
                items.append(.init(id: "tool.\(tile.id)", title: title, detail: "주머니에서 도구 열기",
                    kind: .command, action: .tool(tile)))
            }
        }
        let documents = project.documents.filter { !project.trashedDocumentIDs.contains($0.id) }
        for document in documents {
            items.append(.init(id: "file.\(document.id)", title: document.title, detail: "\(WorkspaceWritingStatistics(source: document.source, goal: 500).paragraphs)개 문단 · 나란히 열기 또는 이동", kind: .file, action: .document(document.id)))
        }
        var seen: Set<UUID> = []
        for document in documents {
            if let data = try? WriterDocumentData.decode(project.userData[WriterDocumentData.key(for: document.id)], documentID: document.id) {
                for card in data.characters where !card.name.isEmpty && card.autoRegistered != true && seen.insert(card.id).inserted {
                    items.append(.init(id: "character.\(card.id)", title: card.name + ((card.role?.isEmpty == false) ? " (\(card.role!))" : ""), detail: card.note, kind: .character, action: .character(document.id, card.id)))
                }
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        items = items.filter {
            needle.isEmpty || ($0.title + " " + $0.detail + " " + $0.kind.rawValue).localizedCaseInsensitiveContains(needle)
        }
        if !includeSources || items.count >= limit {
            return Array(items.prefix(limit))
        }
        let maxSourceItems = min(9, limit - items.count)
        var sourceCount = 0
        let kindMatchesNeedle = !needle.isEmpty && WorkspaceCommandItem.Kind.source.rawValue.localizedCaseInsensitiveContains(needle)
        // Original offsets are constructed from the original, never from rendered or trimmed text.
        for document in documents where sourceCount < maxSourceItems {
            if allowCancellation && Task.isCancelled { return [] }
            let meta = metadata(for: document)
            let body = document.body as NSString
            let broadDocumentMatch = needle.isEmpty || kindMatchesNeedle || document.title.localizedCaseInsensitiveContains(needle)
            if broadDocumentMatch {
                var cursor = 0
                while cursor < body.length {
                    if allowCancellation && Task.isCancelled { return [] }
                    if let excluded = excludedRange(atOrContaining: cursor, in: meta.excludedRanges) {
                        cursor = max(cursor + 1, excluded.upperBound)
                        continue
                    }
                    let paragraph = body.paragraphRange(for: NSRange(location: cursor, length: 0))
                    cursor = max(cursor + 1, paragraph.upperBound)
                    if isExcluded(paragraph, in: meta.excludedRanges) { continue }
                    let raw = body.substring(with: paragraph)
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard isEligibleParagraph(trimmed) else { continue }
                    let match = needle.isEmpty ? NSRange(location: NSNotFound, length: 0)
                        : body.range(of: needle, options: .caseInsensitive, range: paragraph)
                    items.append(makeSourceItem(
                        projectID: project.id,
                        document: document,
                        body: body,
                        revision: meta.revision,
                        paragraph: paragraph,
                        match: match,
                        needle: needle
                    ))
                    sourceCount += 1
                    if needle.isEmpty || sourceCount >= maxSourceItems { break }
                }
            } else {
                var cursor = 0
                while cursor < body.length {
                    if allowCancellation && Task.isCancelled { return [] }
                    let match = body.range(
                        of: needle,
                        options: .caseInsensitive,
                        range: NSRange(location: cursor, length: body.length - cursor)
                    )
                    guard match.location != NSNotFound else { break }
                    let paragraph = body.paragraphRange(for: NSRange(location: match.location, length: 0))
                    cursor = max(paragraph.upperBound, match.upperBound)
                    if isExcluded(paragraph, in: meta.excludedRanges) { continue }
                    let raw = body.substring(with: paragraph)
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard isEligibleParagraph(trimmed) else { continue }
                    items.append(makeSourceItem(
                        projectID: project.id,
                        document: document,
                        body: body,
                        revision: meta.revision,
                        paragraph: paragraph,
                        match: match,
                        needle: needle
                    ))
                    sourceCount += 1
                    if sourceCount >= maxSourceItems { break }
                }
            }
        }
        return Array(items.lazy.filter {
            needle.isEmpty
                || $0.kind == .source
                || ($0.title + " " + $0.detail + " " + $0.kind.rawValue).localizedCaseInsensitiveContains(needle)
        }.prefix(limit))
    }

    private static func isEligibleParagraph(_ trimmed: String) -> Bool {
        !trimmed.isEmpty
            && !trimmed.hasPrefix("#")
            && !trimmed.hasPrefix("```")
            && !trimmed.hasPrefix("~~~")
            && !trimmed.hasPrefix("![")
            && !trimmed.hasPrefix("$$")
    }

    private static func makeSourceItem(
        projectID: WritingProjectID,
        document: WritingDocument,
        body: NSString,
        revision: String,
        paragraph: NSRange,
        match: NSRange,
        needle: String
    ) -> WorkspaceCommandItem {
        var start = paragraph.location
        if !needle.isEmpty, match.location != NSNotFound {
            start = max(paragraph.location, match.location - 100)
        }
        let chunk = body.rangeOfComposedCharacterSequences(
            for: NSRange(location: start, length: min(1024, paragraph.upperBound - start))
        )
        let quote = body.substring(with: chunk)
        let reference = OriginalSourceReference(
            key: .init(projectID: projectID, documentID: document.id),
            revision: revision,
            evidence: .init(documentID: document.id, quote: quote, utf16Hint: chunk.location),
            selection: .passage
        )
        let display = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            id: "source.\(document.id).\(start)",
            title: sourceTitle(display: display, needle: needle),
            detail: document.title,
            kind: .source,
            action: .source(reference)
        )
    }

    private static func sourceTitle(display: String, needle: String) -> String {
        guard display.count > 46 else { return display }
        let prefix = String(display.prefix(46))
        guard !needle.isEmpty, !prefix.localizedCaseInsensitiveContains(needle),
              let match = display.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                  ?? display.range(of: needle, options: .caseInsensitive) else {
            return prefix + "…"
        }
        let matchStart = display.distance(from: display.startIndex, to: match.lowerBound)
        let matchLength = display.distance(from: match.lowerBound, to: match.upperBound)
        let windowLength = max(46, matchLength)
        let leadingContext = max(0, (windowLength - matchLength) / 2)
        let startOffset = max(0, min(matchStart - leadingContext, max(0, display.count - windowLength)))
        let startIndex = display.index(display.startIndex, offsetBy: startOffset)
        let endIndex = display.index(startIndex, offsetBy: min(windowLength, display.count - startOffset))
        let excerpt = String(display[startIndex..<endIndex])
        return (startOffset > 0 ? "…" : "") + excerpt + (endIndex < display.endIndex ? "…" : "")
    }

    private static func metadata(for document: WritingDocument) -> CachedSourceMetadata {
        cacheLock.lock()
        if let cached = sourceCache[document.id], cached.source == document.source {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let bodyString = document.body
        let body = bodyString as NSString
        let revision = SHA256.hash(data: Data(bodyString.utf8)).map { String(format: "%02x", $0) }.joined()
        var excludedRanges: [NSRange] = []
        if body.range(of: "```").location != NSNotFound
            || body.range(of: "~~~").location != NSNotFound
            || body.range(of: "$$").location != NSNotFound {
            var cursor = 0
            var fence: Character?
            var math = false
            while cursor < body.length {
                let paragraph = body.paragraphRange(for: NSRange(location: cursor, length: 0))
                cursor = max(cursor + 1, paragraph.upperBound)
                let raw = body.substring(with: paragraph)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    if fence == nil { fence = trimmed.first }
                    else if fence == trimmed.first { fence = nil }
                    appendExcludedRange(paragraph, to: &excludedRanges)
                    continue
                }
                if fence != nil {
                    appendExcludedRange(paragraph, to: &excludedRanges)
                    continue
                }
                if trimmed == "$$" {
                    math.toggle()
                    appendExcludedRange(paragraph, to: &excludedRanges)
                    continue
                }
                if math {
                    appendExcludedRange(paragraph, to: &excludedRanges)
                    continue
                }
            }
        }
        let built = CachedSourceMetadata(source: document.source, revision: revision, excludedRanges: excludedRanges)
        cacheLock.lock()
        revisionHashCount += 1
        if sourceCache.count >= 64, sourceCache[document.id] == nil, let firstKey = sourceCache.keys.first {
            sourceCache.removeValue(forKey: firstKey)
        }
        sourceCache[document.id] = built
        cacheLock.unlock()
        return built
    }

    private static func appendExcludedRange(_ range: NSRange, to ranges: inout [NSRange]) {
        if let last = ranges.last, last.upperBound == range.location {
            ranges[ranges.count - 1] = NSRange(location: last.location, length: last.length + range.length)
        } else {
            ranges.append(range)
        }
    }

    private static func excludedRange(atOrContaining location: Int, in ranges: [NSRange]) -> NSRange? {
        for range in ranges {
            if range.upperBound <= location { continue }
            if range.location <= location && location < range.upperBound { return range }
            if range.location > location { break }
        }
        return nil
    }

    private static func isExcluded(_ range: NSRange, in ranges: [NSRange]) -> Bool {
        for excluded in ranges {
            if excluded.upperBound <= range.location { continue }
            if NSIntersectionRange(excluded, range).length > 0 { return true }
            if excluded.location >= range.upperBound { break }
        }
        return false
    }
}
