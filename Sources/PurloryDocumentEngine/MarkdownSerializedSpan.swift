import Foundation

package struct MarkdownSerializedSpan: Sendable {
    package let source: NSRange
    package let body: NSRange?
    package let native: NSRange
    package let style: MarkdownInlineScanner.Style
    package var prefix = ""
    package var suffix = ""
    package var opaqueID: ObjectIdentifier? = nil
    package init(source: NSRange, body: NSRange?, native: NSRange, style: MarkdownInlineScanner.Style,
                 prefix: String = "", suffix: String = "", opaqueID: ObjectIdentifier? = nil) {
        self.source = source; self.body = body; self.native = native; self.style = style
        self.prefix = prefix; self.suffix = suffix; self.opaqueID = opaqueID
    }
}
