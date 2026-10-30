import Foundation

public struct WritingProviderOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case success, failed, unavailable }
    public enum Reason: String, Sendable { case provider, resource, unsupportedInput }
    public let providerID: String
    public let status: Status
    public let reason: Reason?
    public init(providerID: String, status: Status, reason: Reason? = nil) {
        self.providerID = providerID; self.status = status; self.reason = reason
    }
}

/// Optional provider-local error classification; no library error or manuscript excerpt crosses it.
package protocol WritingDiagnosticsFailureClassifying: Sendable {
    func failureOutcome(_ error: any Error) -> WritingProviderOutcome
}

package struct WritingDiagnosticsStamp: Hashable, Sendable {
    package let runtime: ProjectRuntimeIdentity
    package let nativeRevision: UInt64
    package let profileRevision: UInt64
    package let providerRevision: String
    package let ruleRevision: Int
    package let windowDigest: String
}

package struct WritingDiagnosticsFinding: Identifiable, Sendable {
    package let id: String
    package var diagnostic: WritingDiagnostic
    package var sourceRanges: [WritingDiagnosticRange]
    package var relatedSourceRanges: [[WritingDiagnosticRange]]
    package var evidence: EvidenceAnchor
    package var relatedEvidence: [EvidenceAnchor] = []
    /// All input context can affect a pattern count, even outside representative evidence.
    package var contextRange: WritingDiagnosticRange
    package var stamp: WritingDiagnosticsStamp
}

package struct WritingDiagnosticsCoverage: Sendable, Equatable {
    package var assessed: [WritingDiagnosticRange] = []
    package var dirty: [WritingDiagnosticRange] = []
    package var pending: [WritingDiagnosticRange] = []
    package var unsupported: [WritingDiagnosticRange] = []
    package var isComplete = false
}

package enum WritingDiagnosticsAvailability: String, Sendable {
    case available, unsupportedLanguage, unsupportedInput
    case unavailableResource, unavailableProvider, unavailableProfile, pausedPolicy
}

package struct WritingDiagnosticsState: Sendable {
    package enum Status: String, Sendable { case idle, checking, partial, unavailable, paused }
    package var findings: [WritingDiagnosticsFinding] = []
    package var coverage = WritingDiagnosticsCoverage()
    package var availability = WritingDiagnosticsAvailability.available
    package var status = Status.idle
}

package protocol WritingDiagnosticsClock: Sendable { func sleep(for duration: Duration) async throws }
package struct ContinuousWritingDiagnosticsClock: WritingDiagnosticsClock {
    package init() {}
    package func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
