import AppKit

/// Derived native spans, separate from author attributes and temporary search/selection layers.
@MainActor
final class WritingDiagnosticsDecorationLayer {
    private var ranges: [NSRange] = []
    private var revision: UInt64 = 0
    private var identity: ProjectRuntimeIdentity?
    private(set) var lastQueryVisits = 0
    func set(_ ranges: [NSRange], revision: UInt64, identity: ProjectRuntimeIdentity?) {
        self.revision = revision; self.identity = identity
        self.ranges.removeAll(keepingCapacity: true)
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = self.ranges.last, last.upperBound >= range.location {
                self.ranges[self.ranges.count - 1].length = max(last.upperBound, range.upperBound) - last.location
            } else { self.ranges.append(range) }
        }
    }
    func visible(_ range: NSRange, revision: UInt64, identity: ProjectRuntimeIdentity?, marked: NSRange?) -> [NSRange] {
        lastQueryVisits = 0
        guard revision == self.revision, identity != nil, identity == self.identity else { return [] }
        var lower = 0, upper = ranges.count
        while lower < upper {
            lastQueryVisits += 1
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upperBound <= range.location { lower = middle + 1 } else { upper = middle }
        }
        var visible: [NSRange] = []
        while lower < ranges.count && ranges[lower].location < range.upperBound {
            lastQueryVisits += 1
            let candidate = ranges[lower]; lower += 1
            if let marked, NSIntersectionRange(marked, candidate).length > 0 { continue }
            let clipped = NSIntersectionRange(range, candidate)
            if clipped.length > 0 { visible.append(clipped) }
        }
        return visible
    }
}

extension BlockTextView {
    func setWritingDiagnostics(_ findings: [WritingDiagnosticsFinding], revision: UInt64) {
        let identity = writingRuntimeIdentityProvider?()
        var ranges: [NSRange] = []
        if revision == writingNativeRevision, !hasMarkedText() {
            for finding in findings where finding.diagnostic.category == .correctness && finding.diagnostic.severity == .correctness {
                guard finding.stamp.nativeRevision == revision, finding.stamp.runtime == identity,
                      finding.sourceRanges.count == 1, let source = finding.sourceRanges.first,
                      finding.evidence.documentID == identity?.key.documentID, finding.evidence.utf16Hint == source.location,
                      let native = nativeRange(forSource: source, revision: revision),
                      let mapped = writingProjectionCapture.nativeLookup?(source),
                      mapped.original.utf16.elementsEqual(finding.evidence.quote.utf16) else { continue }
                ranges.append(native.nsRange)
            }
        }
        writingDecorations.set(ranges, revision: revision, identity: identity)
        needsDisplay = true
    }
    func writingDecorationRanges(visible: NSRange) -> [NSRange] {
        let length = textStorage?.length ?? 0
        guard visible.location >= 0, visible.location <= length, visible.length >= 0, visible.length <= length - visible.location else { return [] }
        return writingDecorations.visible(visible, revision: writingNativeRevision, identity: writingRuntimeIdentityProvider?(),
            marked: hasMarkedText() ? markedRange() : nil)
    }
}

extension PurloryLayoutManager {
    func drawWritingDiagnostics(forGlyphRange visible: NSRange, at origin: NSPoint, view: BlockTextView) {
        guard Thread.isMainThread, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        // TextKit's drawing override is nonisolated; Purlory paints editor chrome on main.
        let ranges = MainActor.assumeIsolated { view.writingDecorationRanges(visible: characters) }
        guard !ranges.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        view.palette.danger.setStroke()
        for range in ranges {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let line = NSBezierPath()
                line.lineWidth = 0.75
                line.move(to: NSPoint(x: origin.x + rect.minX, y: origin.y + rect.maxY - 1))
                line.line(to: NSPoint(x: origin.x + rect.maxX, y: origin.y + rect.maxY - 1))
                line.stroke()
            }
        }
    }
}
