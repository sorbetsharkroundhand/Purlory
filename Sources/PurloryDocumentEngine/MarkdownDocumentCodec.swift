import Foundation

/// Source assembly over cached native rows. Fences belong to row boundaries, so a
/// local edit replaces at most its row, the next boundary and the terminal suffix.
package struct MarkdownDocumentCodec {
    package typealias Row = (text: String, isCode: Bool, codeLang: String?)
    package private(set) var source = DocumentSource("")
    private var trailingLineFeed = false
    package init() {}

    package mutating func reset(_ rows: [Row], trailingLineFeed: Bool) {
        self.trailingLineFeed = trailingLineFeed
        source = DocumentSource(chunks: rows.indices.map {
            Self.chunk(at: $0, rows: rows, trailingLineFeed: trailingLineFeed)
        })
    }
    package mutating func update(_ rows: [Row], at index: Int, codeBoundaryChanged: Bool, trailingLineFeed: Bool) {
        guard source.chunkCount == rows.count, rows.indices.contains(index) else {
            reset(rows, trailingLineFeed: trailingLineFeed); return
        }
        var changed = Set([index])
        if codeBoundaryChanged, index + 1 < rows.count { changed.insert(index + 1) }
        if self.trailingLineFeed != trailingLineFeed, let last = rows.indices.last { changed.insert(last) }
        for row in changed.sorted() {
            // Ranks are checked above and replacements retain the row count.
            source = try! source.replacingChunk(at: row,
                with: Self.chunk(at: row, rows: rows, trailingLineFeed: trailingLineFeed))
        }
        self.trailingLineFeed = trailingLineFeed
    }
    private static func chunk(at index: Int, rows: [Row], trailingLineFeed: Bool) -> String {
        let row = rows[index]
        let previousCode = index > 0 && rows[index - 1].isCode
        var text = index > 0 ? "\n" : ""
        if previousCode != row.isCode {
            text += "```" + (row.isCode ? row.codeLang ?? "" : "") + "\n"
        }
        text += row.text
        if index == rows.count - 1 {
            if row.isCode { text += "\n```" }
            if trailingLineFeed { text += "\n" }
        }
        return text
    }
}
