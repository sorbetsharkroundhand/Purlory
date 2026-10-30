import AppKit

struct StoryMapSourceTarget: Equatable, Sendable {
    let identity: ProjectRuntimeIdentity
    let revision: String
    let row: StoryMapProjection.Row
    var original: OriginalSourceTarget {
        .init(identity: identity, reference: .init(key: identity.key, revision: revision, evidence: row.evidence,
            selection: row.kind == .scene ? .caret : .passage))
    }
    func matchesSource(_ source: String) -> Bool {
        let count = row.evidence.quote.utf16.count, offset = row.sourceRange.lowerBound
        guard row.evidence.utf16Hint == offset, offset >= 0, row.sourceRange.upperBound <= source.utf16.count,
              (1...1024).contains(count), count <= row.sourceRange.count,
              row.kind == .scene || count == row.sourceRange.count else { return false }
        return original.matchesSource(source)
    }
}

@MainActor
extension BlockTextView {
    func storyMapSourcePosition(identity: ProjectRuntimeIdentity) -> Int? { originalSourcePosition(identity: identity) }
    func applyStoryMapSource(_ target: StoryMapSourceTarget) -> Bool {
        target.matchesSource(serialize()) && applyOriginalSource(target.original)
    }
}
