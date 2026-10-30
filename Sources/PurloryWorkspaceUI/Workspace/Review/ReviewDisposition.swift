import CryptoKit
import Foundation

/// A scoped read of durable writer choices; source staleness never deletes those choices.
struct ReviewDispositionIndex: Sendable {
    enum State: Equatable, Sendable { case active, intentional, resolved }
    let origin: ProjectDocumentKey
    let records: [WriterDecision]
    static func load(_ document: ProjectDocumentSnapshot) throws -> Self {
        let writer = try WriterDocumentData.decode(document.userData[WriterDocumentData.key(for: document.identity.key.documentID)], documentID: document.identity.key.documentID)
        let records = writer.decisions.filter { $0.targetID.hasPrefix("review.v1.") && ($0.kind == .intentional || $0.kind == .dismissed) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        return .init(origin: document.identity.key, records: records)
    }
    func state(for issue: ReviewIssue) -> State {
        guard issue.identity.key == origin else { return .active }
        guard let latest = records.first(where: { $0.targetID == issue.id }) else { return .active }
        return latest.kind == .intentional ? .intentional : .resolved
    }
}

/// Delegates every mutation to the established #111 writer owner; owns no storage.
@MainActor
enum ReviewDispositionService {
    enum Choice { case intentional, resolved }
    enum Failure: Error, LocalizedError {
        case stale, unknownDecision, emptyStatement
        var errorDescription: String? {
            switch self {
            case .stale: "원문이나 검토 대상이 바뀌었어요. 새 항목을 확인해 주세요."
            case .unknownDecision: "저장된 판정을 확인할 수 없어요. 목록을 다시 확인해 주세요."
            case .emptyStatement: "저장할 판정을 입력해 주세요."
            }
        }
    }
    static func record(_ choice: Choice, issue: ReviewIssue, in session: ProjectSession, identity: ProjectRuntimeIdentity, statement: String? = nil) throws {
        let document = try current(session, identity)
        guard document.mode == .fiction, document.kind == .manuscript, issue.identity == identity,
              SHA256.hash(data: Data(document.body.utf8)).map({ String(format: "%02x", $0) }).joined() == issue.revision else { throw Failure.stale }
        let index = try ReviewDispositionIndex.load(document)
        let kind: WriterDecision.Kind = choice == .intentional ? .intentional : .dismissed
        var record = index.records.first { $0.targetID == issue.id }
            ?? WriterDecision(kind: kind, targetID: issue.id,
                statement: (choice == .intentional ? "이 항목은 의도한 설정입니다. " : "이 항목은 확인을 마쳤습니다. ") + issue.message, evidence: issue.evidence)
        if let statement {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Failure.emptyStatement }
            record.statement = trimmed
        }
        record.kind = kind; record.evidence = issue.evidence
        try ProjectWriterEditing.perform(.decision(record), in: session, identity: identity)
    }
    /// Explicit record removal remains available after its old source disappears.
    static func restore(decisionID: UUID, targetID: String, in session: ProjectSession, identity: ProjectRuntimeIdentity) throws {
        let document = try current(session, identity), index = try ReviewDispositionIndex.load(document)
        guard index.records.contains(where: { $0.id == decisionID && $0.targetID == targetID }) else { throw Failure.unknownDecision }
        try ProjectWriterEditing.perform(.removeDecision(decisionID), in: session, identity: identity)
    }
    private static func current(_ session: ProjectSession, _ identity: ProjectRuntimeIdentity) throws -> ProjectDocumentSnapshot {
        guard session.isEditorEditable, let document = session.selectedDocumentSnapshot, document.identity == identity else { throw Failure.stale }
        return document
    }
}
