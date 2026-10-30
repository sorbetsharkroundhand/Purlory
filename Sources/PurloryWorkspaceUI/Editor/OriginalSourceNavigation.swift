import AppKit
import Combine
import CryptoKit

/// A literal original reference has no authority to edit or to select an editor runtime.
struct OriginalSourceReference: Equatable, Sendable {
    enum Selection: Equatable, Sendable { case caret, passage }
    let key: ProjectDocumentKey
    let revision: String
    let evidence: EvidenceAnchor
    let selection: Selection
    static func exact(_ evidence: EvidenceAnchor, in project: WritingProject) -> Self? {
        guard !project.trashedDocumentIDs.contains(evidence.documentID),
            let document = project.documents.first(where: { $0.id == evidence.documentID }),
            let range = SourceAnchor.uniqueOriginalRange(for: evidence.quote, in: document.body,
                within: NSRange(location: 0, length: document.body.utf16.count)), range.length <= 2048 else { return nil }
        var anchor = evidence; anchor.utf16Hint = range.location
        return .init(key: .init(projectID: project.id, documentID: document.id),
            revision: SHA256.hash(data: Data(document.body.utf8)).map { String(format: "%02x", $0) }.joined(),
            evidence: anchor, selection: .passage)
    }
    func matchesSource(_ source: String) -> Bool {
        let text = source as NSString, quote = Array(evidence.quote.utf16)
        guard evidence.documentID == key.documentID, (1...2048).contains(quote.count),
              let start = evidence.utf16Hint, start >= 0, start <= text.length, quote.count <= text.length - start,
              SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined() == revision else { return false }
        // NSString.substring repairs surrogate halves; compare the actual original units instead.
        return quote.enumerated().allSatisfy { text.character(at: start + $0.offset) == $0.element }
    }
}
struct OriginalSourceTarget: Equatable, Sendable {
    let identity: ProjectRuntimeIdentity
    let reference: OriginalSourceReference
    func matchesSource(_ source: String) -> Bool {
        identity.key == reference.key && reference.matchesSource(source)
    }
}

/// Navigation preserves inspection; any project mutation retires it, including source ABA.
@MainActor
final class ProjectSourceInspection {
    struct Token: Equatable, Sendable {
        let projectID: WritingProjectID
        fileprivate let owner: UUID
        fileprivate let epoch: UInt64
    }
    private weak var session: ProjectSession?
    private let owner = UUID()
    private var epoch: UInt64 = 0
    private var subscriptions: Set<AnyCancellable> = []
    init(session: ProjectSession) {
        self.session = session
        session.$activeProject.dropFirst().sink { [weak self] _ in self?.retire() }.store(in: &subscriptions)
        session.$isTransitioning.dropFirst().sink { [weak self] value in if value { self?.retire() } }.store(in: &subscriptions)
        session.$phase.dropFirst().sink { [weak self] value in if value != .ready { self?.retire() } }.store(in: &subscriptions)
    }
    func capture() -> Token? {
        guard let session, session.isEditorEditable, let project = session.activeProject else { return nil }
        return .init(projectID: project.id, owner: owner, epoch: epoch)
    }
    func isCurrent(_ token: Token, in session: ProjectSession) -> Bool {
        self.session === session && session.isEditorEditable && token.owner == owner && token.epoch == epoch
            && token.projectID == session.activeProject?.id
    }
    func retire() { epoch &+= 1 }
}

@MainActor
extension ProjectEditorRequests {
    @discardableResult
    func jump(to reference: OriginalSourceReference, inspection: ProjectSourceInspection,
              token: ProjectSourceInspection.Token, in session: ProjectSession) -> Bool {
        guard inspection.isCurrent(token, in: session), token.projectID == reference.key.projectID,
              let project = session.activeProject, !project.trashedDocumentIDs.contains(reference.key.documentID),
              let document = project.documents.first(where: { $0.id == reference.key.documentID }),
              reference.matchesSource(document.body), let runtime = session.runtimeIdentity,
              nativeEditor?.ownsOriginalSource(runtime) == true, let point = captureSourcePosition(in: session) else {
            sourceNavigationError = "원문이나 검토 대상이 바뀌었어요. 새 항목을 확인해 주세요."
            return false
        }
        session.selectDocument(reference.key.documentID)
        guard inspection.isCurrent(token, in: session), let identity = session.runtimeIdentity,
              identity.key == reference.key, let current = session.selectedDocument?.body,
              reference.matchesSource(current) else {
            sourceNavigationError = "원문 위치를 확인할 수 없어요. 새 항목을 확인해 주세요."
            return false
        }
        if sourceReturnPoint?.key.projectID != point.key.projectID { sourceReturnPoint = point }
        sourceNavigationError = nil
        issueSourceNavigation(.original(.init(identity: identity, reference: reference)))
        return true
    }
}

@MainActor
extension BlockTextView {
    func ownsOriginalSource(_ identity: ProjectRuntimeIdentity) -> Bool {
        writingDocumentIdentity == .project(identity.key) && writingRuntimeIdentityProvider?() == identity
            && !hasMarkedText() && writingProjectionCapture.compositionDepth == 0
            && writingProjectionCapture.mappedIdentity == identity
            && writingProjectionCapture.mappedRevision == writingNativeRevision
    }
    func originalSourcePosition(identity: ProjectRuntimeIdentity) -> Int? {
        guard ownsOriginalSource(identity) else { return nil }
        return writingProjectionCapture.nativeRows.sourceOffset(forNative: selectedRange().location)
    }
    func applyOriginalSource(_ target: OriginalSourceTarget) -> Bool {
        guard ownsOriginalSource(target.identity), target.matchesSource(serialize()),
              let source = target.reference.evidence.utf16Hint else { return false }
        if target.reference.selection == .caret {
            if let row = writingProjectionCapture.nativeRows.row(containingSource: source), row.textStart == source {
                restoreSelection(to: NSRange(location: row.nativeRange.location, length: 0))
                return true
            }
        }
        let range = NSRange(location: source, length: target.reference.evidence.quote.utf16.count)
        guard let native = writingProjectionCapture.nativeRows.inspectionRange(forSource: range),
              native.location >= 0, native.upperBound <= string.utf16.count,
              (string as NSString).rangeOfComposedCharacterSequences(for: native) == native else { return false }
        restoreSelection(to: target.reference.selection == .caret ? NSRange(location: native.location, length: 0) : native)
        return true
    }
}

extension WritingNativeRowIndex {
    /// Read-only inspection may span Markdown markers and lines. Correction mapping stays strict.
    func inspectionRange(forSource range: NSRange) -> NSRange? {
        guard (1...2048).contains(range.length), range.location >= 0, range.location <= sourceLength,
              range.length <= sourceLength - range.location else { return nil }
        var cursor = range.location, result: NSRange?
        func append(_ native: NSRange) -> Bool {
            guard native.length > 0 else { return true }
            if let previous = result {
                guard previous.upperBound == native.location else { return false }
                result = NSRange(location: previous.location, length: native.upperBound - previous.location)
            } else { result = native }
            return true
        }
        while cursor < range.upperBound {
            guard let located = row(containingSource: cursor), located.row.eligible, !located.row.isCode,
                  cursor >= located.textStart else { return nil }
            for span in located.row.spans {
                let original = NSRange(location: located.textStart + span.source.location, length: span.source.length)
                guard NSIntersectionRange(original, range).length > 0 else { continue }
                guard let body = span.body, body.length == span.native.length else { return nil }
                let clipped = NSIntersectionRange(NSRange(location: located.textStart + body.location, length: body.length), range)
                if clipped.length > 0 {
                    let native = NSRange(location: located.nativeRange.location + span.native.location + clipped.location - located.textStart - body.location,
                        length: clipped.length)
                    guard append(native) else { return nil }
                }
            }
            if located.row.hasLineFeed {
                let newline = located.textStart + located.row.textLength
                if range.location <= newline && newline < range.upperBound {
                    guard append(NSRange(location: located.nativeRange.location + located.row.nativeContentLength, length: 1)) else { return nil }
                }
            }
            let next = located.textStart + located.row.baseSourceLength
            guard next > cursor else { return nil }; cursor = next
        }
        return result
    }
}
