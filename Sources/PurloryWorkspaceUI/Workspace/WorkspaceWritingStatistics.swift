import Foundation

struct WorkspaceWritingStatistics {
    nonisolated(unsafe) static var scanCount = 0
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (text: String, characters: Int, paragraphs: Int)?

    let characters: Int
    let paragraphs: Int
    let readingSeconds: Int
    let progress: Double

    init(characters: Int, paragraphs: Int, goal: Int = 500) {
        let safeChars = max(0, characters)
        self.characters = safeChars
        self.paragraphs = max(1, paragraphs)
        self.readingSeconds = max(10, Int((Double(safeChars) / 450 * 60).rounded()))
        self.progress = min(1, Double(safeChars) / Double(goal > 0 ? goal : 500))
    }

    init(source: DocumentSource, goal: Int = 500) {
        let newlines = source.newlineCount
        self.init(
            characters: max(0, source.utf16Length - newlines),
            paragraphs: max(1, newlines + 1),
            goal: goal
        )
    }

    init(text: String, goal: Int = 500) {
        let counts = Self.counts(for: text)
        self.init(characters: counts.characters, paragraphs: counts.paragraphs, goal: goal)
    }

    private static func counts(for text: String) -> (characters: Int, paragraphs: Int) {
        cacheLock.lock()
        if let cached, cached.text == text {
            let result = (cached.characters, cached.paragraphs)
            cacheLock.unlock()
            return result
        }
        cacheLock.unlock()

        scanCount += 1
        var newlines = 0
        let utf16 = text.utf16
        for unit in utf16 where unit == 0x000A {
            newlines += 1
        }
        let characters = utf16.count - newlines
        let paragraphs = max(1, newlines + 1)

        cacheLock.lock()
        cached = (text, characters, paragraphs)
        cacheLock.unlock()
        return (characters, paragraphs)
    }

    var detail: String {
        let reading = readingSeconds >= 60 ? "읽기 약 \(Int((Double(readingSeconds) / 60).rounded()))분" : "읽기 \(readingSeconds)초"
        return "\(reading) · \(paragraphs)문단"
    }
}
