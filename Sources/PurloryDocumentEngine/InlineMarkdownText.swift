import Foundation

/// Lightweight inline HTML wrapper stripping shared by exporters and legacy title derivation.
package enum InlineMarkdownText {
    /// Removes inline wrapper tags (`<font ...>`, `</font>`, `<p align="...">`, `</p>`) while keeping inner text.
    package static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"</?(?:font|p)\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
    }
}
