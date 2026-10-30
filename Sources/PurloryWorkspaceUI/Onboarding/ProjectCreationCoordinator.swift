import Foundation

public struct ProjectCreationResult: Equatable, Sendable {
    public var projectID: WritingProjectID
    public var documentID: WritingDocumentID

    public init(projectID: WritingProjectID, documentID: WritingDocumentID) {
        self.projectID = projectID
        self.documentID = documentID
    }
}

/// Creates the smallest useful project without depending on model/download state.
@MainActor
public final class ProjectCreationCoordinator {
    private let session: ProjectSession

    public init(session: ProjectSession) {
        self.session = session
    }

    @discardableResult
    public func createProject(
        title: String,
        mode: WritingMode
    ) async throws -> ProjectCreationResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectTitle = trimmed.isEmpty ? "Untitled" : trimmed
        let document = WritingDocument(
            id: WritingDocumentID(),
            title: mode == .fiction ? "Chapter 1" : "Untitled",
            body: "",
            kind: .manuscript)
        let project = WritingProject(
            id: WritingProjectID(),
            title: projectTitle,
            mode: mode,
            documents: [document])

        // ProjectSession publishes only after ProjectStore save/activate/load verification.
        try await session.saveAndActivate(project)
        return ProjectCreationResult(projectID: project.id, documentID: document.id)
    }
}
