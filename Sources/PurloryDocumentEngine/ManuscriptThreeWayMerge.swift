import Foundation

/// Deterministic paragraph-level 3-way merge without developer conflict markers.
public struct ManuscriptThreeWayMerge: Equatable, Sendable {
    public enum Resolution: String, Codable, Equatable, Sendable {
        case ours
        case theirs
        case both
    }

    public struct Conflict: Equatable, Identifiable, Sendable {
        public let id: Int
        public let base: String
        public let ours: String
        public let theirs: String
    }

    fileprivate struct BlockPiece: Equatable, Sendable {
        let content: String
        let nonFinalSeparator: String
        let finalSeparator: String
    }

    fileprivate enum Segment: Equatable, Sendable {
        case raw(String)
        case clean(BlockPiece)
        case conflict(Conflict, oursSeparator: BlockPiece, theirsSeparator: BlockPiece)
    }

    private struct ParagraphUnit: Equatable, Sendable {
        let content: String
        let trailingSeparator: String
    }

    private struct EditHunk: Equatable, Sendable {
        let baseRange: Range<Int>
        let targetRange: Range<Int>
    }

    private static let blankLineSeparatorRegex = try! NSRegularExpression(
        pattern: "\\r?\\n[\\t ]*\\r?\\n(?:[\\t ]*\\r?\\n)*"
    )

    public let conflicts: [Conflict]
    private let segments: [Segment]

    public var hasConflicts: Bool { !conflicts.isEmpty }

    public func resolvedText(using resolutions: [Int: Resolution] = [:]) -> String {
        if segments.count == 1, case .raw(let text) = segments[0] {
            return text
        }
        var pieces: [BlockPiece] = []
        for segment in segments {
            switch segment {
            case .raw(let text):
                if !text.isEmpty {
                    pieces.append(BlockPiece(content: text, nonFinalSeparator: "\n\n", finalSeparator: ""))
                }
            case .clean(let piece):
                if !piece.content.isEmpty {
                    pieces.append(piece)
                }
            case .conflict(let conflict, let oursSep, let theirsSep):
                let choice = resolutions[conflict.id] ?? .ours
                switch choice {
                case .ours:
                    if !conflict.ours.isEmpty {
                        pieces.append(BlockPiece(
                            content: conflict.ours,
                            nonFinalSeparator: oursSep.nonFinalSeparator,
                            finalSeparator: oursSep.finalSeparator
                        ))
                    }
                case .theirs:
                    if !conflict.theirs.isEmpty {
                        pieces.append(BlockPiece(
                            content: conflict.theirs,
                            nonFinalSeparator: theirsSep.nonFinalSeparator,
                            finalSeparator: theirsSep.finalSeparator
                        ))
                    }
                case .both:
                    let a = conflict.ours
                    let b = conflict.theirs
                    if !a.isEmpty && !b.isEmpty {
                        let sep = Self.isBlankLineSeparator(oursSep.nonFinalSeparator) ? oursSep.nonFinalSeparator : "\n\n"
                        pieces.append(BlockPiece(
                            content: a + sep + b,
                            nonFinalSeparator: theirsSep.nonFinalSeparator,
                            finalSeparator: theirsSep.finalSeparator
                        ))
                    } else if !a.isEmpty {
                        pieces.append(BlockPiece(
                            content: a,
                            nonFinalSeparator: oursSep.nonFinalSeparator,
                            finalSeparator: oursSep.finalSeparator
                        ))
                    } else if !b.isEmpty {
                        pieces.append(BlockPiece(
                            content: b,
                            nonFinalSeparator: theirsSep.nonFinalSeparator,
                            finalSeparator: theirsSep.finalSeparator
                        ))
                    }
                }
            }
        }
        guard !pieces.isEmpty else { return "" }
        var output = ""
        for (index, piece) in pieces.enumerated() {
            output += piece.content
            if index < pieces.count - 1 {
                output += piece.nonFinalSeparator
            } else {
                output += piece.finalSeparator
            }
        }
        return output
    }

    public static func merge(base: String?, ours: String, theirs: String) -> Self {
        if ours.utf8.elementsEqual(theirs.utf8) {
            return Self(conflicts: [], segments: ours.isEmpty ? [] : [.raw(ours)])
        }
        if let base {
            if ours.utf8.elementsEqual(base.utf8) {
                return Self(conflicts: [], segments: theirs.isEmpty ? [] : [.raw(theirs)])
            }
            if theirs.utf8.elementsEqual(base.utf8) {
                return Self(conflicts: [], segments: ours.isEmpty ? [] : [.raw(ours)])
            }
        }

        let oursUnits = splitUnits(ours)
        let theirsUnits = splitUnits(theirs)
        let defaultEOF = resolveEOF(base: base.map(splitUnits), ours: oursUnits, theirs: theirsUnits)

        guard let base else {
            return mergeTwoWay(oursUnits: oursUnits, theirsUnits: theirsUnits, defaultEOF: defaultEOF)
        }

        let baseUnits = splitUnits(base)
        let oursHunks = computeEditHunks(base: baseUnits, target: oursUnits)
        let theirsHunks = computeEditHunks(base: baseUnits, target: theirsUnits)

        var segments: [Segment] = []
        var conflicts: [Conflict] = []
        var bCursor = 0
        var oCursor = 0
        var tCursor = 0
        var i = 0
        var j = 0

        func emitUnchangedAnchor(baseIndex: Int, oursIndex: Int, theirsIndex: Int) {
            let bUnit = baseUnits[baseIndex]
            let oUnit = oursUnits[oursIndex]
            let tUnit = theirsUnits[theirsIndex]
            let nonFinal = resolveNonFinalSeparator(base: bUnit, ours: oUnit, theirs: tUnit)
            let finalSep = resolveAnchorFinalSeparator(base: bUnit, ours: oUnit, theirs: tUnit, defaultEOF: defaultEOF)
            segments.append(.clean(BlockPiece(
                content: oUnit.content,
                nonFinalSeparator: nonFinal,
                finalSeparator: finalSep
            )))
        }

        func emitCleanSlice(_ slice: ArraySlice<ParagraphUnit>) {
            for unit in slice where !unit.content.isEmpty {
                let nonFinal = isBlankLineSeparator(unit.trailingSeparator) ? unit.trailingSeparator : "\n\n"
                let finalSep = isBlankLineSeparator(unit.trailingSeparator) ? defaultEOF : unit.trailingSeparator
                segments.append(.clean(BlockPiece(
                    content: unit.content,
                    nonFinalSeparator: nonFinal,
                    finalSeparator: finalSep
                )))
            }
        }

        while i < oursHunks.count || j < theirsHunks.count {
            let nextO = i < oursHunks.count ? oursHunks[i] : nil
            let nextT = j < theirsHunks.count ? theirsHunks[j] : nil

            let hunkBaseStart: Int
            if let nextO, let nextT {
                hunkBaseStart = min(nextO.baseRange.lowerBound, nextT.baseRange.lowerBound)
            } else if let nextO {
                hunkBaseStart = nextO.baseRange.lowerBound
            } else {
                hunkBaseStart = nextT!.baseRange.lowerBound
            }

            while bCursor < hunkBaseStart {
                emitUnchangedAnchor(baseIndex: bCursor, oursIndex: oCursor, theirsIndex: tCursor)
                bCursor += 1
                oCursor += 1
                tCursor += 1
            }

            if let nextO, let nextT, hunksConflict(nextO, nextT) {
                var groupO = [nextO]
                var groupT = [nextT]
                i += 1
                j += 1
                var bEnd = max(nextO.baseRange.upperBound, nextT.baseRange.upperBound)

                while true {
                    if i < oursHunks.count,
                       oursHunks[i].baseRange.lowerBound < bEnd
                        || groupT.contains(where: { hunksConflict(oursHunks[i], $0) }) {
                        bEnd = max(bEnd, oursHunks[i].baseRange.upperBound)
                        groupO.append(oursHunks[i])
                        i += 1
                        continue
                    }
                    if j < theirsHunks.count,
                       theirsHunks[j].baseRange.lowerBound < bEnd
                        || groupO.contains(where: { hunksConflict($0, theirsHunks[j]) }) {
                        bEnd = max(bEnd, theirsHunks[j].baseRange.upperBound)
                        groupT.append(theirsHunks[j])
                        j += 1
                        continue
                    }
                    break
                }

                let bStart = bCursor
                let oStart = oCursor
                let lastO = groupO.last!
                let oEnd = lastO.targetRange.upperBound + (bEnd - lastO.baseRange.upperBound)
                let tStart = tCursor
                let lastT = groupT.last!
                let tEnd = lastT.targetRange.upperBound + (bEnd - lastT.baseRange.upperBound)

                let baseSlice = baseUnits[bStart..<bEnd]
                let oursSlice = oursUnits[oStart..<oEnd]
                let theirsSlice = theirsUnits[tStart..<tEnd]

                bCursor = bEnd
                oCursor = oEnd
                tCursor = tEnd

                if oursSlice.map(\.content) == theirsSlice.map(\.content) {
                    emitCleanSlice(oursSlice)
                } else {
                    let conflict = Conflict(
                        id: conflicts.count,
                        base: joinUnitContents(baseSlice),
                        ours: joinUnitContents(oursSlice),
                        theirs: joinUnitContents(theirsSlice)
                    )
                    conflicts.append(conflict)
                    segments.append(.conflict(
                        conflict,
                        oursSeparator: sliceSeparatorPiece(oursSlice, defaultEOF: defaultEOF),
                        theirsSeparator: sliceSeparatorPiece(theirsSlice, defaultEOF: defaultEOF)
                    ))
                }
            } else {
                let takeOurs: Bool
                if let nextO, let nextT {
                    if nextO.baseRange.lowerBound != nextT.baseRange.lowerBound {
                        takeOurs = nextO.baseRange.lowerBound < nextT.baseRange.lowerBound
                    } else {
                        takeOurs = nextO.baseRange.isEmpty
                    }
                } else {
                    takeOurs = nextO != nil
                }

                if takeOurs, let hunk = nextO {
                    emitCleanSlice(oursUnits[hunk.targetRange])
                    let count = hunk.baseRange.count
                    bCursor = hunk.baseRange.upperBound
                    oCursor = hunk.targetRange.upperBound
                    tCursor += count
                    i += 1
                } else if let hunk = nextT {
                    emitCleanSlice(theirsUnits[hunk.targetRange])
                    let count = hunk.baseRange.count
                    bCursor = hunk.baseRange.upperBound
                    oCursor += count
                    tCursor = hunk.targetRange.upperBound
                    j += 1
                }
            }
        }

        while bCursor < baseUnits.count {
            emitUnchangedAnchor(baseIndex: bCursor, oursIndex: oCursor, theirsIndex: tCursor)
            bCursor += 1
            oCursor += 1
            tCursor += 1
        }

        return Self(conflicts: conflicts, segments: segments)
    }

    private static func mergeTwoWay(
        oursUnits: [ParagraphUnit],
        theirsUnits: [ParagraphUnit],
        defaultEOF: String
    ) -> Self {
        let diff = theirsUnits.map(\.content).difference(from: oursUnits.map(\.content))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let idx, _, _): removed.insert(idx)
            case .insert(let idx, _, _): inserted.insert(idx)
            }
        }
        let unremovedO = (0..<oursUnits.count).filter { !removed.contains($0) }
        let uninsertedT = (0..<theirsUnits.count).filter { !inserted.contains($0) }
        guard !unremovedO.isEmpty else {
            let conflict = Conflict(
                id: 0,
                base: "",
                ours: joinUnitContents(oursUnits[...]),
                theirs: joinUnitContents(theirsUnits[...])
            )
            return Self(
                conflicts: [conflict],
                segments: [.conflict(
                    conflict,
                    oursSeparator: sliceSeparatorPiece(oursUnits[...], defaultEOF: defaultEOF),
                    theirsSeparator: sliceSeparatorPiece(theirsUnits[...], defaultEOF: defaultEOF)
                )]
            )
        }

        var segments: [Segment] = []
        var conflicts: [Conflict] = []
        var oCursor = 0
        var tCursor = 0

        for (oAnchor, tAnchor) in zip(unremovedO, uninsertedT) {
            if oCursor < oAnchor || tCursor < tAnchor {
                let oSlice = oursUnits[oCursor..<oAnchor]
                let tSlice = theirsUnits[tCursor..<tAnchor]
                let conflict = Conflict(
                    id: conflicts.count,
                    base: "",
                    ours: joinUnitContents(oSlice),
                    theirs: joinUnitContents(tSlice)
                )
                conflicts.append(conflict)
                segments.append(.conflict(
                    conflict,
                    oursSeparator: sliceSeparatorPiece(oSlice, defaultEOF: defaultEOF),
                    theirsSeparator: sliceSeparatorPiece(tSlice, defaultEOF: defaultEOF)
                ))
            }
            let oUnit = oursUnits[oAnchor]
            let nonFinal = isBlankLineSeparator(oUnit.trailingSeparator) ? oUnit.trailingSeparator : "\n\n"
            let finalSep = isBlankLineSeparator(oUnit.trailingSeparator) ? defaultEOF : oUnit.trailingSeparator
            segments.append(.clean(BlockPiece(
                content: oUnit.content,
                nonFinalSeparator: nonFinal,
                finalSeparator: finalSep
            )))
            oCursor = oAnchor + 1
            tCursor = tAnchor + 1
        }

        if oCursor < oursUnits.count || tCursor < theirsUnits.count {
            let oSlice = oursUnits[oCursor..<oursUnits.count]
            let tSlice = theirsUnits[tCursor..<theirsUnits.count]
            let conflict = Conflict(
                id: conflicts.count,
                base: "",
                ours: joinUnitContents(oSlice),
                theirs: joinUnitContents(tSlice)
            )
            conflicts.append(conflict)
            segments.append(.conflict(
                conflict,
                oursSeparator: sliceSeparatorPiece(oSlice, defaultEOF: defaultEOF),
                theirsSeparator: sliceSeparatorPiece(tSlice, defaultEOF: defaultEOF)
            ))
        }

        return Self(conflicts: conflicts, segments: segments)
    }

    private static func splitUnits(_ text: String) -> [ParagraphUnit] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let matches = blankLineSeparatorRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        var units: [ParagraphUnit] = []

        for match in matches {
            if match.range.location == 0 {
                if match.range.upperBound == ns.length {
                    return [ParagraphUnit(content: "", trailingSeparator: text)]
                }
                continue
            }
            guard match.range.location > cursor else { continue }
            let content = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let sep = ns.substring(with: match.range)
            units.append(ParagraphUnit(content: content, trailingSeparator: sep))
            cursor = match.range.upperBound
        }

        if cursor < ns.length {
            let remainder = ns.substring(from: cursor)
            if remainder.hasSuffix("\r\n") {
                units.append(ParagraphUnit(content: String(remainder.dropLast(2)), trailingSeparator: "\r\n"))
            } else if remainder.hasSuffix("\n") {
                units.append(ParagraphUnit(content: String(remainder.dropLast(1)), trailingSeparator: "\n"))
            } else {
                units.append(ParagraphUnit(content: remainder, trailingSeparator: ""))
            }
        }
        return units
    }

    private static func computeEditHunks(
        base: [ParagraphUnit],
        target: [ParagraphUnit]
    ) -> [EditHunk] {
        let diff = target.map(\.content).difference(from: base.map(\.content))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let idx, _, _): removed.insert(idx)
            case .insert(let idx, _, _): inserted.insert(idx)
            }
        }
        let unremovedBase = (0..<base.count).filter { !removed.contains($0) }
        let uninsertedTarget = (0..<target.count).filter { !inserted.contains($0) }
        let baseToTarget = Dictionary(uniqueKeysWithValues: zip(unremovedBase, uninsertedTarget))

        var hunks: [EditHunk] = []
        var b = 0
        var t = 0
        while b < base.count || t < target.count {
            if b < base.count, let matchedT = baseToTarget[b] {
                if matchedT == t {
                    b += 1
                    t += 1
                } else {
                    hunks.append(EditHunk(baseRange: b..<b, targetRange: t..<matchedT))
                    t = matchedT
                }
            } else if b < base.count {
                var bNext = b + 1
                while bNext < base.count && baseToTarget[bNext] == nil {
                    bNext += 1
                }
                let tNext = bNext < base.count ? baseToTarget[bNext]! : target.count
                hunks.append(EditHunk(baseRange: b..<bNext, targetRange: t..<tNext))
                b = bNext
                t = tNext
            } else {
                hunks.append(EditHunk(baseRange: base.count..<base.count, targetRange: t..<target.count))
                t = target.count
            }
        }
        return hunks
    }

    private static func hunksConflict(_ hO: EditHunk, _ hT: EditHunk) -> Bool {
        if max(hO.baseRange.lowerBound, hT.baseRange.lowerBound) < min(hO.baseRange.upperBound, hT.baseRange.upperBound) {
            return true
        }
        if hO.baseRange.isEmpty && hT.baseRange.isEmpty && hO.baseRange.lowerBound == hT.baseRange.lowerBound {
            return true
        }
        if hO.targetRange.isEmpty && hT.targetRange.isEmpty
            && (hO.baseRange.upperBound == hT.baseRange.lowerBound || hT.baseRange.upperBound == hO.baseRange.lowerBound) {
            return true
        }
        return false
    }

    private static func isBlankLineSeparator(_ separator: String) -> Bool {
        var newlineCount = 0
        for scalar in separator.unicodeScalars where scalar == "\n" {
            newlineCount += 1
            if newlineCount >= 2 { return true }
        }
        return false
    }

    private static func resolveEOF(
        base: [ParagraphUnit]?,
        ours: [ParagraphUnit],
        theirs: [ParagraphUnit]
    ) -> String {
        let oEOF = ours.last?.trailingSeparator ?? ""
        let tEOF = theirs.last?.trailingSeparator ?? ""
        if oEOF == tEOF { return oEOF }
        if let bEOF = base?.last?.trailingSeparator {
            if oEOF == bEOF { return tEOF }
            if tEOF == bEOF { return oEOF }
        }
        return oEOF
    }

    private static func resolveNonFinalSeparator(
        base: ParagraphUnit,
        ours: ParagraphUnit,
        theirs: ParagraphUnit
    ) -> String {
        let bSep = isBlankLineSeparator(base.trailingSeparator) ? base.trailingSeparator : "\n\n"
        let oSep = isBlankLineSeparator(ours.trailingSeparator) ? ours.trailingSeparator : nil
        let tSep = isBlankLineSeparator(theirs.trailingSeparator) ? theirs.trailingSeparator : nil
        if let oSep, let tSep {
            if oSep == tSep { return oSep }
            if oSep == bSep { return tSep }
            return oSep
        }
        return oSep ?? tSep ?? bSep
    }

    private static func resolveAnchorFinalSeparator(
        base: ParagraphUnit,
        ours: ParagraphUnit,
        theirs: ParagraphUnit,
        defaultEOF: String
    ) -> String {
        let oFinal = isBlankLineSeparator(ours.trailingSeparator) ? nil : ours.trailingSeparator
        let tFinal = isBlankLineSeparator(theirs.trailingSeparator) ? nil : theirs.trailingSeparator
        let bFinal = isBlankLineSeparator(base.trailingSeparator) ? nil : base.trailingSeparator
        if let oFinal, let tFinal {
            if oFinal == tFinal { return oFinal }
            if let bFinal, oFinal == bFinal { return tFinal }
            return oFinal
        }
        return oFinal ?? tFinal ?? defaultEOF
    }

    private static func joinUnitContents(_ slice: ArraySlice<ParagraphUnit>) -> String {
        guard !slice.isEmpty else { return "" }
        var output = ""
        for (offset, unit) in slice.enumerated() {
            output += unit.content
            if offset < slice.count - 1 {
                output += isBlankLineSeparator(unit.trailingSeparator) ? unit.trailingSeparator : "\n\n"
            }
        }
        return output
    }

    private static func sliceSeparatorPiece(
        _ slice: ArraySlice<ParagraphUnit>,
        defaultEOF: String
    ) -> BlockPiece {
        guard let last = slice.last else {
            return BlockPiece(content: "", nonFinalSeparator: "\n\n", finalSeparator: defaultEOF)
        }
        let nonFinal = isBlankLineSeparator(last.trailingSeparator) ? last.trailingSeparator : "\n\n"
        let finalSep = isBlankLineSeparator(last.trailingSeparator) ? defaultEOF : last.trailingSeparator
        return BlockPiece(content: "", nonFinalSeparator: nonFinal, finalSeparator: finalSep)
    }
}
