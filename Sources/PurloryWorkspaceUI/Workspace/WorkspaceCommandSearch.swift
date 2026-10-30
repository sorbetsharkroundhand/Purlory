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
    static func items(in project: WritingProject, query: String, typewriter: Bool, focus: Bool,
                      includeSources: Bool = true, limit: Int = 9) -> [WorkspaceCommandItem] {
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
            items.append(.init(id: "file.\(document.id)", title: document.title, detail: "\(WorkspaceWritingStatistics(text: document.body, goal: 500).paragraphs)개 문단 · 나란히 열기 또는 이동", kind: .file, action: .document(document.id)))
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
        // Original offsets are constructed from the original, never from rendered or trimmed text.
        for document in documents where includeSources {
            let body = document.body as NSString
            var cursor = 0
            var fence: Character?
            var math = false
            let revision = SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined()
            while cursor < body.length {
                let paragraph = body.paragraphRange(for: NSRange(location: cursor, length: 0))
                cursor = paragraph.upperBound
                let raw = body.substring(with: paragraph)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    if fence == nil { fence = trimmed.first }
                    else if fence == trimmed.first { fence = nil }
                    continue
                }
                if fence != nil { continue }
                if trimmed == "$$" { math.toggle(); continue }
                if math { continue }
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("```"), !trimmed.hasPrefix("!["), !trimmed.hasPrefix("$$") else { continue }
                if !needle.isEmpty && !raw.localizedCaseInsensitiveContains(needle) && !document.title.localizedCaseInsensitiveContains(needle) && !WorkspaceCommandItem.Kind.source.rawValue.localizedCaseInsensitiveContains(needle) { continue }
                var start = paragraph.location
                if !needle.isEmpty {
                    let match = body.range(of: needle, options: .caseInsensitive, range: paragraph)
                    if match.location != NSNotFound { start = max(paragraph.location, match.location - 100) }
                }
                let chunk = body.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(1024, paragraph.upperBound - start)))
                let quote = body.substring(with: chunk)
                let reference = OriginalSourceReference(key: .init(projectID: project.id, documentID: document.id), revision: revision,
                    evidence: .init(documentID: document.id, quote: quote, utf16Hint: chunk.location), selection: .passage)
                let display = quote.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(.init(id: "source.\(document.id).\(start)", title: String(display.prefix(46)) + (display.count > 46 ? "…" : ""),
                    detail: document.title, kind: .source, action: .source(reference)))
                if needle.isEmpty || items.filter({ $0.kind == .source }).count >= 9 { break }
            }
        }
        return Array(items.lazy.filter { needle.isEmpty || ($0.title + " " + $0.detail + " " + $0.kind.rawValue).localizedCaseInsensitiveContains(needle) }.prefix(limit))
    }
}
