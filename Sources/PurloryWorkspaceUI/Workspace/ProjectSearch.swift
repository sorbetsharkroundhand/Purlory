import Foundation

public struct ProjectSearchResult: Equatable, Identifiable, Sendable {
    public let projectID: WritingProjectID
    public let documentID: WritingDocumentID
    public let title: String
    public let snippet: String?
    public let query: String

    public var id: WritingDocumentID { documentID }

    public init(
        projectID: WritingProjectID,
        documentID: WritingDocumentID,
        title: String,
        snippet: String?,
        query: String
    ) {
        self.projectID = projectID
        self.documentID = documentID
        self.title = title
        self.snippet = snippet
        self.query = query
    }
}

public enum ProjectSearch {
    public static func results(query rawQuery: String, in project: WritingProject, index: ProjectSourceIndex) async -> [ProjectSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        let preparation = try? await index.prepare(terms: [query], in: project)
        guard !Task.isCancelled else { return [] }
        return results(query: query, in: project, candidates: preparation?.candidates[query])
    }

    public static func results(
        query rawQuery: String,
        in project: WritingProject
    ) -> [ProjectSearchResult] {
        results(query: rawQuery, in: project, candidates: nil)
    }

    private static func results(query rawQuery: String, in project: WritingProject,
                                candidates: Set<WritingDocumentID>?) -> [ProjectSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let documents = project.documents
        return documents.compactMap { document in
            guard !project.trashedDocumentIDs.contains(document.id),
                document.title.range(of: query, options: .caseInsensitive) != nil
                    || (candidates?.contains(document.id) != false && document.body.range(of: query, options: .caseInsensitive) != nil)
            else { return nil }

            return ProjectSearchResult(
                projectID: project.id,
                documentID: document.id,
                title: document.title,
                snippet: SourceAnchor.searchSnippet(document.body, query: query),
                query: query)
        }
    }
}
