import Foundation

struct WorkspaceWritingStatistics {
    let characters: Int
    let paragraphs: Int
    let readingSeconds: Int
    let progress: Double
    init(text: String, goal: Int = 500) {
        let lines = text.components(separatedBy: "\n")
        characters = lines.reduce(0) { $0 + $1.utf16.count }
        paragraphs = max(1, lines.count)
        readingSeconds = max(10, Int((Double(characters) / 450 * 60).rounded()))
        progress = min(1, Double(characters) / Double(goal > 0 ? goal : 500))
    }
    var detail: String {
        let reading = readingSeconds >= 60 ? "읽기 약 \(Int((Double(readingSeconds) / 60).rounded()))분" : "읽기 \(readingSeconds)초"
        return "\(reading) · \(paragraphs)문단"
    }
}
