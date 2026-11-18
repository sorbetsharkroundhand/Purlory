import AppKit
import CryptoKit
@testable import PurloryWorkspaceUI

/// Nearest-rank percentiles, without interpolation or a fabricated zero for missing data.
struct InputBenchmarkDistribution: Codable {
    let n: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let max: Double
    init?(_ values: [Double]) {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let sorted = values.sorted()
        n = sorted.count
        func rank(_ percentile: Double) -> Double { sorted[Int(ceil(percentile * Double(sorted.count))) - 1] }
        p50 = rank(0.5); p95 = rank(0.95); p99 = rank(0.99); max = sorted.last!
    }
}
struct InputBenchmarkMetrics: Codable {
    struct DrawObservation: Codable { let revision: Int; let drawID: Int; let delaySeconds: Double }
    let drawObservations: [DrawObservation]
    let unmatchedRevisions: [Int]
    let distributionsSeconds: [String: InputBenchmarkDistribution]
    let sampleCount: Int
    let characterRevisionCount: Int
    let completedDrawCount: Int
    init(trace: EditorInputTrace) {
        var pending: [Int: Double] = [:]
        var starts: [Int: EditorInputTrace.Sample] = [:]
        var observations: [DrawObservation] = []
        var values: [String: [Double]] = [:]
        var drawCount = 0
        var revisionCount = 0
        for row in trace.samples {
            if row.kind.contains(".begin") {
                starts[row.id] = row
            } else if let start = starts[row.id], row.kind.contains(".end") {
                values[start.kind, default: []].append(row.timestamp - start.timestamp)
                starts.removeValue(forKey: row.id)
            }
            if row.kind == "storage", row.editedCharacters == true {
                pending[row.revision] = row.timestamp
                revisionCount += 1
                if let operation = row.operationID, let start = starts[operation] {
                    values["operationToStorage", default: []].append(row.timestamp - start.timestamp)
                }
            }
            if row.kind == "draw.end" {
                drawCount += 1
                for revision in pending.keys.sorted() where revision <= row.revision {
                    let delay = row.timestamp - pending.removeValue(forKey: revision)!
                    observations.append(DrawObservation(revision: revision, drawID: row.id, delaySeconds: delay))
                    values["storageToObservedDrawEnd", default: []].append(delay)
                }
            }
        }
        drawObservations = observations
        unmatchedRevisions = pending.keys.sorted()
        distributionsSeconds = values.compactMapValues(InputBenchmarkDistribution.init)
        sampleCount = trace.samples.count
        characterRevisionCount = revisionCount
        completedDrawCount = drawCount
    }
}
struct InputBenchmarkFixture {
    enum Shape: String, CaseIterable, Codable { case short, long }
    enum Format: String, CaseIterable, Codable { case plain, markdown }
    struct Metadata: Codable {
        let version: Int
        let shape: Shape
        let format: Format
        let characterCount: Int
        let utf8Count: Int
        let utf16Count: Int
        let paragraphCount: Int
        let sha256: String
    }
    let text: String
    let metadata: Metadata
    init(size: Int, shape: Shape, format: Format) {
        precondition(size >= 1000)
        let base = format == .plain
            ? "마을 앞 넓은 들판에 바람이 불고 사람들은 길을 걸었다. Synthetic prose. "
            : "**마을** 앞 넓은 들판에 *바람*이 불고 사람들은 길을 걸었다. Synthetic prose. "
        let unit = base + (shape == .short ? "\n" : " ")
        text = String(String(repeating: unit, count: size / unit.count + 1).prefix(size))
        metadata = Metadata(version: 1, shape: shape, format: format, characterCount: text.count,
            utf8Count: text.utf8.count, utf16Count: text.utf16.count,
            paragraphCount: text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 },
            sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
    }
}

enum InputBenchmarkTrace: String, CaseIterable, Codable {
    case latin, hangul, editing, paste
    enum Action: String, Codable {
        case latin, markJamo, markSyllable, commit, newline, deleteBackward, left, right, replace, paste
        case moveToMiddle, moveToEnd, moveToStart

        var isCaretMove: Bool {
            switch self {
            case .moveToMiddle, .moveToEnd, .moveToStart: true
            default: false
            }
        }

        func caretMoveLocation(length: Int) -> Int? {
            switch self {
            case .moveToMiddle: length / 2
            case .moveToEnd: length
            case .moveToStart: 0
            default: nil
            }
        }
    }
    var actions: [Action] {
        switch self {
        case .latin: Array(repeating: .latin, count: 12)
        case .hangul: Array(repeating: [Action.markJamo, .markSyllable, .commit], count: 4).flatMap { $0 }
        case .editing: Array(repeating: [Action.latin, .newline, .deleteBackward, .left, .right, .replace], count: 2).flatMap { $0 }
        case .paste: [.paste]
        }
    }
    func scheduledActions(moving: Bool) -> [Action] {
        let input = actions
        guard moving else { return input }
        return input + [.moveToMiddle] + input + [.moveToEnd] + input + [.moveToStart] + input
    }

    static let pasteText = String(repeating: "Synthetic paste. ", count: 8)
    func expectedText(_ text: String, location: Int, moving: Bool = false) -> String {
        let expected = NSMutableString(string: text)
        var cursor = location
        var marked: NSRange?
        func replace(_ value: String, range: NSRange) {
            expected.replaceCharacters(in: range, with: value)
            cursor = range.location + (value as NSString).length
        }
        for action in scheduledActions(moving: moving) {
            switch action {
            case .latin: replace("a", range: NSRange(location: cursor, length: 0))
            case .markJamo, .markSyllable:
                let range = marked ?? NSRange(location: cursor, length: 0)
                replace(action == .markJamo ? "ㅎ" : "한", range: range)
                marked = NSRange(location: range.location, length: 1)
            case .commit:
                replace("한", range: marked ?? NSRange(location: cursor, length: 0)); marked = nil
            case .newline: replace("\n", range: NSRange(location: cursor, length: 0))
            case .deleteBackward: if cursor > 0 { replace("", range: NSRange(location: cursor - 1, length: 1)) }
            case .left: cursor = max(0, cursor - 1)
            case .right: cursor = min(expected.length, cursor + 1)
            case .replace: replace("Z", range: NSRange(location: max(0, cursor - 1), length: cursor > 0 ? 1 : 0))
            case .paste: replace(Self.pasteText, range: NSRange(location: cursor, length: 0))
            case .moveToMiddle, .moveToEnd, .moveToStart:
                cursor = action.caretMoveLocation(length: expected.length)!
            }
        }
        return expected as String
    }
    @MainActor
    static func perform(_ action: Action, in view: NSTextView) throws -> Int? {
        switch action {
        case .latin: view.insertText("a", replacementRange: view.selectedRange())
        case .markJamo, .markSyllable:
            view.setMarkedText(action == .markJamo ? "ㅎ" : "한", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: view.hasMarkedText() ? view.markedRange() : view.selectedRange())
        case .commit: view.insertText("한", replacementRange: view.markedRange())
        case .newline: view.insertNewline(nil)
        case .deleteBackward: view.deleteBackward(nil)
        case .left: view.moveLeft(nil)
        case .right: view.moveRight(nil)
        case .replace:
            let cursor = view.selectedRange().location
            view.setSelectedRange(NSRange(location: max(0, cursor - 1), length: cursor > 0 ? 1 : 0))
            view.insertText("Z", replacementRange: view.selectedRange())
        case .paste: view.insertText(pasteText, replacementRange: view.selectedRange())
        case .moveToMiddle, .moveToEnd, .moveToStart:
            guard !view.hasMarkedText(), let storage = view.textStorage,
                  let location = action.caretMoveLocation(length: storage.length)
            else { throw InputBenchmarkError.integrity("caret move with unfinished composition or missing text storage") }
            let range = NSRange(location: location, length: 0)
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            return location
        }
        return nil
    }
}
