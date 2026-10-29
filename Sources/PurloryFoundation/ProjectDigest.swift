import CryptoKit
import Foundation

package enum ProjectDigest {
    package static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    package static func isValid(_ hash: String) -> Bool {
        hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
