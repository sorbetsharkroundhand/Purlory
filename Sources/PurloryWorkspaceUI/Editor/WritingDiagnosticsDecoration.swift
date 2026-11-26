import AppKit
import PurloryFoundation
import PurloryIntelligence

/// Derived native spans, separate from author attributes and temporary search/selection layers.
@MainActor
final class WritingDiagnosticsDecorationLayer {
    struct ResolutionKey: Hashable {
        let id: String
        let profileRevision: UInt64
        let providerRevision: String
        let ruleRevision: Int
        let windowDigest: String
        let quote: String

        init(finding: WritingDiagnosticsFinding) {
            self.id = finding.id
            self.profileRevision = finding.stamp.profileRevision
            self.providerRevision = finding.stamp.providerRevision
            self.ruleRevision = finding.stamp.ruleRevision
            self.windowDigest = finding.stamp.windowDigest
            self.quote = finding.evidence.quote
        }
    }
    private struct CachedResolution {
        var sourceRange: WritingDiagnosticRange
        var nativeRange: NSRange?
    }
    private var ranges: [NSRange] = []
    private var revision: UInt64 = 0
    private var identity: ProjectRuntimeIdentity?
    private var resolvedCacheRevision: UInt64 = 0
    private var resolvedCacheIdentity: ProjectRuntimeIdentity?
    private var resolvedCacheStorageLength: Int = -1
    private var resolvedRanges: [ResolutionKey: CachedResolution] = [:]
    private(set) var lastQueryVisits = 0

    func rebase(editedRange: NSRange, delta: Int, storageLength: Int) {
        guard resolvedCacheStorageLength >= 0,
              resolvedCacheStorageLength + delta == storageLength else {
            resolvedRanges.removeAll(keepingCapacity: true)
            resolvedCacheStorageLength = -1
            return
        }
        resolvedCacheStorageLength = storageLength
        guard !resolvedRanges.isEmpty else { return }
        let oldRange = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        var next: [ResolutionKey: CachedResolution] = [:]
        next.reserveCapacity(resolvedRanges.count)
        for (key, var entry) in resolvedRanges {
            guard let native = entry.nativeRange else { continue }
            if native.upperBound < oldRange.location {
                next[key] = entry
            } else if native.location > oldRange.upperBound {
                let shiftedNative = native.location + delta
                let shiftedSource = entry.sourceRange.location + delta
                guard shiftedNative >= 0, shiftedSource >= 0 else { continue }
                entry.nativeRange = NSRange(location: shiftedNative, length: native.length)
                entry.sourceRange = WritingDiagnosticRange(location: shiftedSource, length: entry.sourceRange.length)
                next[key] = entry
            }
        }
        resolvedRanges = next
    }

    func prepareResolutionCache(revision: UInt64, identity: ProjectRuntimeIdentity?, storageLength: Int, validMapping: Bool) {
        guard validMapping else {
            resolvedRanges.removeAll(keepingCapacity: true)
            resolvedCacheRevision = 0
            resolvedCacheIdentity = nil
            resolvedCacheStorageLength = -1
            return
        }
        if resolvedCacheIdentity?.key != identity?.key || resolvedCacheStorageLength != storageLength {
            resolvedRanges.removeAll(keepingCapacity: true)
        }
        resolvedCacheRevision = revision
        resolvedCacheIdentity = identity
        resolvedCacheStorageLength = storageLength
    }

    func cachedResolution(for key: ResolutionKey, source: WritingDiagnosticRange) -> NSRange?? {
        guard let entry = resolvedRanges[key], entry.sourceRange == source else { return nil }
        return entry.nativeRange
    }

    func storeResolution(_ range: NSRange?, for key: ResolutionKey, source: WritingDiagnosticRange) {
        resolvedRanges[key] = CachedResolution(sourceRange: source, nativeRange: range)
    }

    @discardableResult
    func set(_ ranges: [NSRange], revision: UInt64, identity: ProjectRuntimeIdentity?) -> Bool {
        var normalized: [NSRange] = []
        normalized.reserveCapacity(ranges.count)
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = normalized.last, last.upperBound >= range.location {
                normalized[normalized.count - 1].length = max(last.upperBound, range.upperBound) - last.location
            } else { normalized.append(range) }
        }
        let changed = self.ranges != normalized
            || (!normalized.isEmpty && (self.revision != revision || self.identity != identity))
        self.revision = revision
        self.identity = identity
        self.ranges = normalized
        return changed
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
        let storageLength = textStorage?.length ?? 0
        let validMapping = revision == writingNativeRevision
            && !hasMarkedText()
            && writingProjectionCapture.compositionDepth == 0
            && writingProjectionCapture.mappedRevision == revision
            && writingProjectionCapture.mappedIdentity == identity
        writingDecorations.prepareResolutionCache(
            revision: revision, identity: identity, storageLength: storageLength, validMapping: validMapping)
        var ranges: [NSRange] = []
        if validMapping {
            for finding in findings where finding.diagnostic.category == .correctness && finding.diagnostic.severity == .correctness {
                guard finding.stamp.nativeRevision == revision, finding.stamp.runtime == identity,
                      finding.sourceRanges.count == 1, let source = finding.sourceRanges.first,
                      finding.evidence.documentID == identity?.key.documentID, finding.evidence.utf16Hint == source.location else { continue }
                let key = WritingDiagnosticsDecorationLayer.ResolutionKey(finding: finding)
                if let cached = writingDecorations.cachedResolution(for: key, source: source) {
                    if let resolved = cached { ranges.append(resolved) }
                    continue
                }
                writingDecorationLookupCount += 1
                guard let native = nativeRange(forSource: source, revision: revision, expectedQuote: finding.evidence.quote) else {
                    writingDecorations.storeResolution(nil, for: key, source: source)
                    continue
                }
                writingDecorations.storeResolution(native.nsRange, for: key, source: source)
                ranges.append(native.nsRange)
            }
        }
        if writingDecorations.set(ranges, revision: revision, identity: identity) {
            needsDisplay = true
        }
    }
    func writingDecorationRanges(visible: NSRange) -> [NSRange] {
        guard !isWritingDiagnosticsSuppressedByWorkspace else { return [] }
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
        let (ranges, dangerColor) = MainActor.assumeIsolated {
            (view.writingDecorationRanges(visible: characters), view.palette.danger)
        }
        guard !ranges.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        dangerColor.setStroke()
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
